# Anu benchmark (AI Edge Gallery style)

`ModelBenchmarkTests` measures the real model the way Google AI Edge Gallery's
benchmark does (load, time to first token, read and write tokens a second) and
checks answers against a fixed set, repeated `BENCH_RUNS` times:

```
TEST_RUNNER_REAL_MODEL_TEST=1 TEST_RUNNER_BENCH_RUNS=10 xcodebuild test \
  -project Anu.xcodeproj -scheme Anu -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:AnuTests/ModelBenchmarkTests CODE_SIGNING_ALLOWED=NO
```

Add `TEST_RUNNER_BENCH_MODEL=liteRT` (Gemma) or `apple` to pick the model;
otherwise it uses the app's own choice, which is Apple's model wherever that
runs. On an iPhone the report also prints how much memory iOS still allows.

## 2026-11-14, iPhone 18 Pro (12 GB, iOS 27.0.1, GPU), 3 runs

| Case | Apple on-device | Gemma 4 E4B, 16K, MTP |
|---|---|---|
| fact | 3/3 | 3/3 |
| math (17 × 6) | 0/3 | 3/3 |
| instruction | 3/3 | 3/3 |
| recall | 3/3 | 3/3 |
| reasoning | 3/3 | 3/3 |
| date (knows today) | 3/3 | 3/3 |
| summary | 3/3 | 3/3 |
| tool: calculator | 3/3 | 3/3 |
| tool: web search | 1/3 | 3/3 |
| tool: fresh facts | 0/3 | 3/3 |
| follow-up | 3/3 | 3/3 |
| **Overall** | **25/33** | **33/33** |
| Median first token | 0.7–1.4 s | 2.7–5.0 s (follow-up 0.9 s) |
| Read / write tok/s (median) | estimated, not comparable | 155–320 / 53–195 |

Apple's model was given Gemma's tool-call format here; in the app it gets
tools its own way, and sums never reach a model (the calculator answers).
Gemma loads in 10 s.

Memory iOS still allowed Anu with Gemma (`os_proc_available_memory`):

| Context | After load | After the first answer | Later |
|---|---|---|---|
| 8K | 4.5 GB | 3.8 GB | 3.7 GB steady |
| 12K | 4.3 GB | 2.4 GB | not measured |
| 16K | 4.2 GB | 1.6 GB | 1.0 GB, then killed on a longer run |
| 32K | – | killed on the first answer | |

So iPhones load Gemma with 8K. A locked phone also stops the run: iOS
doesn't let an app in the background use the graphics chip.

## 2026-11-14, iOS 26.5 Simulator (CPU, M5 Pro host), Gemma 4 E4B, 32K context, MTP on

| Case | Right | Median first token (ms) | Read tok/s | Write tok/s |
|---|---|---|---|---|
| fact | 10/10 | 15492 | 38.3 | 6.8 |
| math | 10/10 | 15694 | 37.7 | 11.1 |
| instruction ("only YES") | 10/10 | 15531 | 37.7 | – |
| recall (same chat) | 10/10 | 15379 | 40.0 | 27.8 |
| reasoning | 10/10 | 15676 | 37.5 | 7.2 |
| knows today's year | 10/10 | 16391 | 37.5 | 16.0 |
| summary | 10/10 | 15321 | 38.8 | 16.7 |
| tool: calculator | 10/10 | 15816 | 63.0 | 15.0 |
| tool: web search | 10/10 | 16167 | 63.6 | 14.1 |
| tool: fresh facts → web search | 10/10 | 15057 | 65.7 | 13.6 |
| follow-up in the same chat | 10/10 | 1674 | 31.2 | 13.8 |

Overall right: **110/110**. Follow-ups that read on from the live chat: **10/10**.
Load 954 ms.

How it moved tonight (same Simulator):

| | Before | After |
|---|---|---|
| Right | 30/35 (recall 0/5, instruction 0/5) | 110/110 |
| Read tok/s | ~15 | ~38 (host cores) |
| Write tok/s | 5–9 | 7–28 (MTP) |
| Follow-up first token | full re-read | ~1.7 s (reads on) |

A first message in a new chat waits on reading Anu's instructions (~560 tokens)
plus any tools: ~15 s on the Simulator's CPU, a few seconds on an iPhone's GPU.
Simulator numbers are CPU-only; a real iPhone is much faster.
