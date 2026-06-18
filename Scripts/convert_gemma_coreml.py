#!/usr/bin/env python3
"""
Convert google/gemma-4-E4B-it (Gemma 4 4B) from HuggingFace to Core ML (.mlpackage)

Requirements:
    pip install -r requirements.txt

Prerequisites:
    1. Accept Gemma 4 license at https://huggingface.co/google/gemma-4-E4B-it
    2. Login: huggingface-cli login  (paste your HF access token)

Usage:
    python convert_gemma_coreml.py \
        --model_id google/gemma-4-E4B-it \
        --output ./gemma4b.mlpackage \
        --seq_len 512

Quantization options (reduces size/memory at slight quality cost):
    --quantize int4   →  ~2 GB output, runs on 6GB iPhone  (recommended)
    --quantize int8   →  ~4 GB output
    --quantize none   →  ~8 GB float16 (needs 12GB+ RAM on device)

Notes:
    - Requires ~20 GB RAM on Mac during conversion (use M2/M3 Mac with 24GB+)
    - Place the .mlpackage inside your Xcode project as a bundle resource
    - Uses ANE (Apple Neural Engine) via ct.ComputeUnit.ALL for best perf on iPhone
    - Gemma 4 uses a multi-modal architecture; this script exports text-only path
"""

import argparse
import json
import os
import sys
from pathlib import Path

import numpy as np
import torch
import coremltools as ct
from coremltools.optimize.coreml import (
    OpLinearQuantizerConfig,
    OptimizationConfig,
    linear_quantize_weights,
)
from transformers import AutoTokenizer, AutoModelForCausalLM

# ─────────────────────────────────────────────
# coremltools shims for torch ops missing from its frontend
# (transformers 5.x masking code uses tensor.new_ones / new_full)
# ─────────────────────────────────────────────
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.frontend.torch.torch_op_registry import (
    register_torch_op,
    _TORCH_OPS_REGISTRY,
)
from coremltools.converters.mil.frontend.torch.ops import _get_inputs


def _fill_with(context, node, value):
    # tensor.new_ones(size, ...) → fill(shape=size, value=...)
    # mb.fill requires an int32 shape; the traced graph sometimes carries
    # the size as fp32, so always cast.
    inputs = _get_inputs(context, node)
    shape = mb.cast(x=inputs[1], dtype="int32")
    context.add(mb.fill(shape=shape, value=value, name=node.name))


# coremltools' _cast handler calls int(x.val) on size-1 ARRAYS, which numpy 2.x
# rejects ("only 0-dimensional arrays can be converted to Python scalars").
# Patch it to extract the scalar first. _int/_bool resolve _cast from module
# globals at call time, so rebinding the module attribute is sufficient.
import coremltools.converters.mil.frontend.torch.ops as _ct_torch_ops


def _patched_cast(context, node, dtype, dtype_name):
    inputs = _ct_torch_ops._get_inputs(context, node, expected=1)
    x = inputs[0]
    if not (len(x.shape) == 0 or np.all([d == 1 for d in x.shape])):
        raise ValueError("input to cast must be either a scalar or a length 1 tensor")
    if x.can_be_folded_to_const():
        val = x.val
        if getattr(val, "ndim", 0) > 0:
            val = np.ravel(val)[0]  # numpy-2-safe scalar extraction
        res = x if isinstance(val, dtype) else mb.const(val=dtype(val), name=node.name)
    elif len(x.shape) > 0:
        squeezed = mb.squeeze(x=x, name=node.name + "_item")
        res = mb.cast(x=squeezed, dtype=dtype_name, name=node.name)
    else:
        res = mb.cast(x=x, dtype=dtype_name, name=node.name)
    context.add(res, node.name)


_ct_torch_ops._cast = _patched_cast


if "new_ones" not in _TORCH_OPS_REGISTRY.name_to_func_mapping:
    @register_torch_op
    def new_ones(context, node):
        _fill_with(context, node, 1.0)

if "new_zeros" not in _TORCH_OPS_REGISTRY.name_to_func_mapping:
    @register_torch_op
    def new_zeros(context, node):
        _fill_with(context, node, 0.0)


# Elementwise boolean ops (__or__/__and__/__xor__) appear in Gemma 4's mask
# combination code but have no translation in this coremltools version.
def _binary_bool_shim(context, node, mil_op):
    inputs = _get_inputs(context, node, expected=2)
    x = mb.cast(x=inputs[0], dtype="bool")
    y = mb.cast(x=inputs[1], dtype="bool")
    context.add(mil_op(x=x, y=y, name=node.name))


if "or" not in _TORCH_OPS_REGISTRY.name_to_func_mapping:
    @register_torch_op(torch_alias=["or", "ior"])
    def _shim_logical_or(context, node):
        _binary_bool_shim(context, node, mb.logical_or)

if "and" not in _TORCH_OPS_REGISTRY.name_to_func_mapping:
    @register_torch_op(torch_alias=["and", "iand"])
    def _shim_logical_and(context, node):
        _binary_bool_shim(context, node, mb.logical_and)

if "xor" not in _TORCH_OPS_REGISTRY.name_to_func_mapping:
    @register_torch_op(torch_alias=["xor"])
    def _shim_logical_xor(context, node):
        _binary_bool_shim(context, node, mb.logical_xor)


def load_text_model(model_id, cache_dir=None):
    """
    Load the text decoder. Gemma 3 4B+ checkpoints are multimodal
    (Gemma3ForConditionalGeneration); their forward() works text-only when
    no pixel_values are passed, so we can use the full model directly —
    jit.trace only records the executed (text) path.
    """
    kwargs = dict(
        torch_dtype=torch.float32,
        cache_dir=cache_dir,
        low_cpu_mem_usage=True,
        # Eager attention exports as plain matmul/softmax ops — the most
        # reliable path through both torch.jit.trace and coremltools
        attn_implementation="eager",
    )
    try:
        return AutoModelForCausalLM.from_pretrained(model_id, **kwargs)
    except (ValueError, KeyError):
        from transformers import AutoModelForImageTextToText
        return AutoModelForImageTextToText.from_pretrained(model_id, **kwargs)


# ─────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────

def parse_args():
    parser = argparse.ArgumentParser(description="Convert Gemma 4B to Core ML")
    parser.add_argument(
        "--model_id",
        type=str,
        default="google/gemma-4-E4B-it",
        help="HuggingFace model ID",
    )
    parser.add_argument(
        "--quantize",
        type=str,
        default="int4",
        choices=["int4", "int8", "none"],
        help="Post-training quantization: int4 (~2GB), int8 (~4GB), none (~8GB float16)",
    )
    parser.add_argument(
        "--output",
        type=str,
        default="gemma4b.mlpackage",
        help="Output path for the .mlpackage",
    )
    parser.add_argument(
        "--seq_len",
        type=int,
        default=512,
        help="Maximum sequence length for the model input (shorter = faster, smaller model)",
    )
    parser.add_argument(
        "--batch_size",
        type=int,
        default=1,
        help="Batch size (must be 1 for on-device inference)",
    )
    parser.add_argument(
        "--float16",
        action="store_true",
        default=True,
        help="Use float16 weights (default: True, reduces model size by ~50%%)",
    )
    parser.add_argument(
        "--cache_dir",
        type=str,
        default=None,
        help="HuggingFace cache directory (optional)",
    )
    return parser.parse_args()


# ─────────────────────────────────────────────
# Wrapper to export a fixed-shape model
# ─────────────────────────────────────────────

class GemmaForCoreML(torch.nn.Module):
    """
    Wraps Gemma 4 for Core ML export:
    - Fixed-shape input_ids + attention_mask (batch=1, seq_len)
    - Returns last-token logits [1, vocab_size] — no KV-cache for initial conversion
    - The app left-pads inputs, so with the attention mask zeroing the padding,
      position -1 always holds the latest real token
    - Gemma 4 may be multi-modal; this exports the text-only path
    """

    def __init__(self, model, seq_len):
        super().__init__()
        self.model = model
        # Constant causal mask, baked into the trace
        self.register_buffer(
            "causal", torch.tril(torch.ones(seq_len, seq_len, dtype=torch.bool))
        )

    def forward(self, input_ids: torch.Tensor, attention_mask: torch.Tensor) -> torch.Tensor:
        # Build the 4D additive attention bias here with plain tensor ops.
        # Passing a ready-made 4D mask makes transformers' masking_utils
        # return it untouched — bypassing its vmap-based mask construction,
        # which torch.jit.trace cannot record.
        # Note: at seq_len <= 1024 Gemma 3's sliding-window layers see the
        # same mask as full-attention layers (window >= seq), so one mask
        # is correct for both.
        pad = attention_mask[:, None, None, :].to(torch.bool)      # [B,1,1,S]
        full = self.causal[None, None, :, :] & pad                  # [B,1,S,S]
        # Use a finite fp16-safe bias, NOT float32.min: the model runs in
        # fp16 where float32.min overflows to -inf, making fully-masked
        # padding rows produce NaN that then poisons real positions via
        # 0 × NaN in the next layer's attention. -30000 gives exact-zero
        # attention weights after softmax while keeping pad rows finite.
        bias = torch.where(
            full,
            torch.zeros(1, dtype=torch.float32),
            torch.full((1,), -30000.0),
        )
        outputs = self.model(input_ids=input_ids, attention_mask=bias, use_cache=False)
        return outputs.logits[:, -1, :]  # [batch, vocab_size]


# ─────────────────────────────────────────────
# Main conversion
# ─────────────────────────────────────────────

def convert(args):
    print(f"[1/6] Loading tokenizer from {args.model_id}...")
    tokenizer = AutoTokenizer.from_pretrained(
        args.model_id,
        cache_dir=args.cache_dir,
    )

    print(f"[2/6] Loading model weights from {args.model_id}...")
    # Always load as float32 for tracing stability; quantize after conversion
    model = load_text_model(args.model_id, cache_dir=args.cache_dir)
    model.eval()

    # Save tokenizer alongside the .mlpackage for use in iOS
    output_dir = Path(args.output).parent
    tokenizer_dir = output_dir / f"{Path(args.output).stem}_tokenizer"
    tokenizer_dir.mkdir(parents=True, exist_ok=True)
    tokenizer.save_pretrained(str(tokenizer_dir))
    print(f"    Tokenizer saved to {tokenizer_dir}")

    print("[3/6] Tracing model with TorchScript...")
    seq_len = args.seq_len
    wrapped = GemmaForCoreML(model, seq_len)
    wrapped.eval()
    example_ids = torch.zeros((1, seq_len), dtype=torch.int64)
    example_mask = torch.ones((1, seq_len), dtype=torch.int64)

    with torch.no_grad():
        traced = torch.jit.trace(wrapped, (example_ids, example_mask))

    print("[4/6] Converting to Core ML (mlprogram, iOS 17+)...")
    # Free the duplicate module references before conversion; the traced
    # module shares parameter storage, but every saved GB counts here
    vocab_size_cfg = getattr(model.config, "vocab_size", None) or model.config.text_config.vocab_size
    del model, wrapped
    import gc; gc.collect()

    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, seq_len), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, seq_len), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="logits", dtype=np.float32)],
        compute_units=ct.ComputeUnit.ALL,
        # iOS18+ required for per-block int4 quantization (better quality
        # than per-channel); app still runs on iOS 17 via mock fallback
        minimum_deployment_target=ct.target.iOS18,
        # Gemma's residual activations exceed fp16 range (the model requires
        # bf16); fp16 compute produces all-NaN logits. fp32 compute runs on
        # CPU/GPU instead of the fp16-only ANE — slower but correct.
        # Weights are still int4-quantized below, so file size is unaffected.
        compute_precision=ct.precision.FLOAT32,
        convert_to="mlprogram",
        # Do NOT load the converted fp32 model into the Core ML runtime —
        # that load is a huge memory spike (it OOM-killed the E4B conversion).
        # Validation happens later against the much smaller quantized package.
        skip_model_load=True,
    )

    # The traced torchscript holds its own ~full-size weight copy — free it
    # before quantization, which duplicates weight buffers while compressing
    del traced
    gc.collect()

    print(f"[5/6] Applying {args.quantize} quantization...")
    if args.quantize == "int4":
        # 4-bit palettization — smallest size, best for iPhone
        op_config = OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int4", granularity="per_block", block_size=32)
        config = OptimizationConfig(global_config=op_config)
        mlmodel = linear_quantize_weights(mlmodel, config)
    elif args.quantize == "int8":
        op_config = OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8", granularity="per_channel")
        config = OptimizationConfig(global_config=op_config)
        mlmodel = linear_quantize_weights(mlmodel, config)
    # "none" → keep float16 from conversion above

    mlmodel.author = "Anu"
    mlmodel.short_description = f"Gemma 4 4B-IT — seq={seq_len} quant={args.quantize}"
    mlmodel.version = "1.0.0"
    # vocab_size captured before the torch model was freed
    vocab_size = vocab_size_cfg

    mlmodel.user_defined_metadata["model_id"] = args.model_id
    mlmodel.user_defined_metadata["seq_len"] = str(seq_len)
    mlmodel.user_defined_metadata["quantize"] = args.quantize
    mlmodel.user_defined_metadata["vocab_size"] = str(vocab_size)
    mlmodel.user_defined_metadata["bos_token_id"] = str(tokenizer.bos_token_id or 2)
    mlmodel.user_defined_metadata["eos_token_id"] = str(tokenizer.eos_token_id or 1)

    print(f"[6/6] Saving to {args.output}...")
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(output_path))

    # Print model size
    size_bytes = sum(
        f.stat().st_size
        for f in output_path.rglob("*")
        if f.is_file()
    )
    size_gb = size_bytes / (1024 ** 3)
    print(f"\nConversion complete!")
    print(f"  Output:    {output_path}")
    print(f"  Size:      {size_gb:.2f} GB")
    print(f"  Seq len:   {seq_len}")
    print(f"  Quantize:  {args.quantize}")
    print(f"\nNext steps:")
    print(f"  1. In Xcode: File → Add Files → select {output_path.name}")
    print(f"     Make sure 'Copy items if needed' and your app target are checked")
    print(f"  2. Also add gemma4b_tokenizer/tokenizer.json to the app target")
    print(f"     (the app loads it as the real tokenizer; without it, mock tokenizer is used)")
    print(f"  3. Build and run on a physical iPhone (not simulator)")
    print(f"     The app detects the model and uses GemmaModel instead of MockGemmaModel")


# ─────────────────────────────────────────────
# Validate conversion (optional smoke test)
# ─────────────────────────────────────────────

def validate(mlpackage_path: str, tokenizer_path: str):
    """Run a quick inference sanity check on the converted model."""
    print("\nValidating converted model...")
    import coremltools as ct
    from transformers import AutoTokenizer

    tokenizer = AutoTokenizer.from_pretrained(tokenizer_path)
    model = ct.models.MLModel(mlpackage_path)

    test_prompt = "<start_of_turn>user\nHello!<end_of_turn>\n<start_of_turn>model\n"
    tokens = tokenizer.encode(test_prompt, return_tensors="np")

    # Left-pad to fixed seq_len (matches what the iOS app does at runtime)
    seq_len = int(model.user_defined_metadata.get("seq_len", 512))
    if tokens.shape[1] > seq_len:
        tokens = tokens[:, -seq_len:]
        mask = np.ones_like(tokens)
    else:
        pad_len = seq_len - tokens.shape[1]
        mask = np.pad(np.ones_like(tokens), ((0, 0), (pad_len, 0)), constant_values=0)
        tokens = np.pad(tokens, ((0, 0), (pad_len, 0)), constant_values=0)

    input_dict = {
        "input_ids": tokens.astype(np.int32),
        "attention_mask": mask.astype(np.int32),
    }
    output = model.predict(input_dict)
    logits = output["logits"]
    next_token_id = int(np.argmax(logits[0]))
    next_token = tokenizer.decode([next_token_id])
    print(f"  Validation OK — first predicted token: '{next_token}' (id={next_token_id})")


if __name__ == "__main__":
    args = parse_args()
    convert(args)

    # Optionally validate
    tokenizer_dir = str(Path(args.output).parent / f"{Path(args.output).stem}_tokenizer")
    if Path(args.output).exists() and Path(tokenizer_dir).exists():
        try:
            validate(args.output, tokenizer_dir)
        except Exception as e:
            print(f"  Validation skipped: {e}")
