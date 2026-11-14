# Anu benchmark (AI Edge Gallery style)

`ModelBenchmarkTests` measures the real model the way Google AI Edge Gallery's
benchmark does (load, time to first token, read and write tokens a second) and
checks answers against a fixed set, repeated `BENCH_RUNS` times:

```
TEST_RUNNER_REAL_MODEL_TEST=1 TEST_RUNNER_BENCH_RUNS=10 xcodebuild test \
  -project Anu.xcodeproj -scheme Anu -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:AnuTests/ModelBenchmarkTests CODE_SIGNING_ALLOWED=NO
```

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
