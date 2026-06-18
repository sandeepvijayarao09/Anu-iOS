"""Agent-loop test against the converted Core ML model — replicates the app's
exact GemmaChatTemplate prompt (system prompt folded into first user turn,
tool results as user turns) and runs the ReAct cycle headlessly."""
import json, re, time
import numpy as np, coremltools as ct
from transformers import AutoTokenizer

SEQ = 512
tok = AutoTokenizer.from_pretrained("./gemma4b_tokenizer")
model = ct.models.MLModel("./gemma4b.mlpackage")

SYSTEM = """You are Anu, an intelligent agentic AI assistant running on-device using the Gemma 4B model.

You operate in a ReAct (Reason, Act, Observe) loop:
1. **Reason**: Think through what the user needs.
2. **Act**: Either answer directly OR call a tool using the JSON format below.
3. **Observe**: Review tool results and continue reasoning.

Guidelines:
- For simple questions, math, factual recall, or short tasks: answer directly.
- For arithmetic calculations: use the calculator tool.
- Always be concise and helpful.
- When you have a final answer, just state it clearly without tool calls.

Available tools:
- **calculator**: Evaluates mathematical expressions. Supports +, -, *, /, ^, sqrt(), and parentheses.
  Parameters: {"type": "object", "properties": {"expression": {"type": "string", "description": "The mathematical expression to evaluate"}}, "required": ["expression"]}

To call a tool, output a JSON block on its own line:
```json
{"tool_call": {"name": "tool_name", "arguments": {"arg1": "value1"}}}
```
Wait for the tool result before continuing."""

def build_prompt(turns):
    p = ""
    first_user = True
    for role, text in turns:
        if role == "user":
            if first_user:
                p += f"<start_of_turn>user\n{SYSTEM}\n\n{text}<end_of_turn>\n"
                first_user = False
            else:
                p += f"<start_of_turn>user\n{text}<end_of_turn>\n"
        else:
            p += f"<start_of_turn>model\n{text}<end_of_turn>\n"
    return p + "<start_of_turn>model\n"

def generate(prompt, max_tokens=64):
    ids = [tok.bos_token_id] + tok.encode(prompt, add_special_tokens=False)
    print(f"  [prompt: {len(ids)} tokens]", flush=True)
    out = []
    t0 = time.time()
    for _ in range(max_tokens):
        window = ids[-SEQ:]
        pad = SEQ - len(window)
        x = np.array([[0]*pad + window], dtype=np.int32)
        m = np.array([[0]*pad + [1]*len(window)], dtype=np.int32)
        logits = model.predict({"input_ids": x, "attention_mask": m})["logits"]
        nxt = int(np.argmax(logits[0]))
        if nxt in (tok.eos_token_id, 106):
            break
        out.append(nxt); ids.append(nxt)
    text = tok.decode(out)
    print(f"  [{len(out)} tokens, {len(out)/(time.time()-t0):.2f} tok/s]", flush=True)
    return text

def extract_tool_call(text):
    cleaned = text.replace("```json", "").replace("```", "")
    match = re.search(r'\{.*"tool_call".*\}', cleaned, re.DOTALL)
    if not match:
        return None
    try:
        return json.loads(match.group(0))["tool_call"]
    except Exception:
        return None

# ── Round 1: math question → expect calculator tool call ──
print("ROUND 1: 'What is 12 * 8 + 5?'", flush=True)
turns = [("user", "What is 12 * 8 + 5?")]
reply = generate(build_prompt(turns))
print("  MODEL:", reply.strip()[:200], flush=True)
call = extract_tool_call(reply)
if call and call.get("name") == "calculator":
    print("  ✅ valid calculator tool call:", json.dumps(call), flush=True)
    expr = call["arguments"].get("expression", "")
    result = eval(expr, {"__builtins__": {}})  # stands in for CalculatorTool
    # ── Round 2: tool result → expect final answer ──
    print(f"ROUND 2: feeding tool result '{expr} = {result}'", flush=True)
    turns.append(("model", reply.strip()))
    turns.append(("user", f"Tool result:\n{expr} = {result}"))
    final = generate(build_prompt(turns))
    print("  MODEL:", final.strip()[:200], flush=True)
    print("  ✅ PASS" if "101" in final else "  ❌ final answer missing 101", flush=True)
else:
    print("  ⚠️ no tool call — model answered directly:", flush=True)
    print("  " + ("✅ direct answer contains 101" if "101" in reply else "❌ neither tool call nor correct answer"), flush=True)
