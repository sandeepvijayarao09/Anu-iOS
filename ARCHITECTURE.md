# Anu — Architecture & Workflow

Anu is an on-device agentic assistant for iOS and macOS. A Gemma 4 model runs
locally through Google's LiteRT-LM runtime; it can call tools, remember things
across sessions, and — only when asked — escalate a sanitised task to a cloud
model. Every byte that leaves the device is recorded.

~14,800 lines of Swift across 110 files. Single app target plus a share
extension and a widget.

---

## 1. The shape of it

```
                    ┌─────────────────────────────┐
   you ───────────▶ │  UI  (SwiftUI, 20 files)    │
                    │  ChatView · VoiceMode ·      │
                    │  Settings · Connectors       │
                    └──────────────┬──────────────┘
                                   │ user message
                                   ▼
                    ┌─────────────────────────────┐
                    │  AgentOrchestrator          │  ← the only brain
                    │  @MainActor, one instance   │
                    └──┬────────┬────────┬────────┘
                       │        │        │
         ┌─────────────┘        │        └──────────────┐
         ▼                      ▼                       ▼
  ┌─────────────┐      ┌────────────────┐      ┌────────────────┐
  │  Routing    │      │  Model layer   │      │  Tools         │
  │ TaskClassif.│      │ ModelFactory   │      │ ToolRegistry   │
  │ ModelClassif│      │ LiteRTLMModel  │      │ 16 built-ins + │
  │ MessageRtr  │      │ (Gemma 4)      │      │ connector tools│
  └─────────────┘      └────────────────┘      └───────┬────────┘
                                                       │
                                        ┌──────────────┴───────────┐
                                        ▼                          ▼
                                ┌───────────────┐        ┌──────────────────┐
                                │ On-device     │        │ Off-device       │
                                │ calendar,     │        │ MCP · REST · UCP │
                                │ reminders,    │        │ Gemini escalation│
                                │ calc, photos… │        │ app launch       │
                                └───────────────┘        └────────┬─────────┘
                                                                  │ always
                                                                  ▼
                                                        ┌──────────────────┐
                                                        │  PrivacyLedger   │
                                                        └──────────────────┘
```

**One rule holds the design together:** anything that leaves the device passes
through a tool, and every such tool records an `EgressDestination` in the
`PrivacyLedger`. There is no second path out.

---

## 2. Directory map

| Directory | Files | Lines | What lives there |
|---|---:|---:|---|
| `Agent/` | 20 | 3,486 | Orchestrator, routing, planning, memory, privacy ledger |
| `UI/` | 20 | 4,053 | SwiftUI screens, design system, type scale |
| `Tools/` | 19 | 2,099 | `Tool` protocol, registry, 16 built-in tools |
| `Models/` | 12 | 1,407 | Model catalog, factory, LiteRT-LM backend, downloads |
| `Connectors/` | 10 | 1,346 | MCP client, REST connectors, UCP commerce, app launcher |
| `Utilities/` | 11 | 1,128 | Keychain, speech, attestation, shared formatters |
| `App/` | 7 | 558 | App entry, App Intents / Siri |
| `API/` | 4 | 526 | Gemini client, private-compute client |
| `Workflows/` | 7 | 248 | Saved prompts runnable from Siri, widget, share sheet |

---

## 3. A turn, end to end

This is the path every message takes. Entry point:
`AgentOrchestrator.run(userMessage:imageData:)`.

```
 1. CLASSIFY      TaskClassifier      → what kind of request is this?
 2. ROUTE         ModelClassifier     → which path does it deserve?
                  ┌──────────────────────────────────────────────┐
                  │ image attached or Fast mode → onDeviceChat    │
                  │ needsDeviceTool(…)          → force agent     │
                  │ otherwise                   → classifier's call│
                  └──────────────────────────────────────────────┘
 3. EXECUTE       one of three modes (below)
 4. RECORD        PrivacyLedger per egress; per-turn summary in the chat
 5. PERSIST       session + memory written; Spotlight index updated
```

### The three modes

**`chatTurn`** — single shot, no tools. The cheapest path. Fast mode forces
every turn here.

**`reactLoop`** — the agent path. Reason → tool call → observe, repeated until
the model answers or hits the iteration cap. Each tool call appears in the
chat as a card and in the reasoning trace.

**`cloudTurn`** — the classifier decided this needs a cloud model.
`CloudProvider.resolved()` prefers a configured private compute server over
Gemini. **PII is stripped before the request is built**, and the redaction
count is shown to you in the chat — the tool that sends is the same one that
records, so the count can't drift from what actually left.

### Tool calls

The model emits a tool call, `ResponseParser` extracts it, `ToolRegistry`
resolves the name, `executeTool` runs it.

Two dialects are accepted, because Gemma 4 does not reliably follow the JSON
contract in the prompt:

```
{"tool_call": {"name": "calculator", "arguments": {"expression": "2+2"}}}   ← documented
<|tool_call>call:calculator{expression: "2+2"}<tool_call|>                   ← what it often emits
```

Argument objects also alternate between strict JSON and JavaScript literals
(bare keys, single quotes) *between runs of the same prompt*. `repairLooseJSON`
is tried only after a strict decode fails, so valid JSON is never touched.
See `Agent/RoutingDecision.swift`.

> If a third dialect shows up, constrain the prompt — don't add a third repair
> branch. That road doesn't converge.

---

## 4. The model layer

`ModelFactory.makeModel()` resolves the user's `selected_model` choice:

```
selected_model ──▶ .liteRT       → bundled Gemma 4 E4B
                 ├ .downloadable → a fetched allowlist model
                 └ .automatic    → bundled E4B
                                   → downloaded E4B
                                   → downloaded E2B
                                   → UnavailableModel (fails loudly)
```

Only **two** models exist in the catalog, both Gemma 4 on LiteRT-LM:

| | Size | RAM floor | Source |
|---|---|---|---|
| E4B | 3.4 GB | 12 GB | bundled in the app |
| E2B | 2.6 GB | 8 GB | downloaded from Hugging Face |

Core ML and Apple Foundation Models were removed; `UnavailableModel` throws a
specific reason rather than silently faking a reply.

**Budget:** the agent's system prompt plus tool descriptions is ~3,056 tokens.
`LiteRTLMModel` defaults to 4,096. Don't lower it — a 2,048 cap rejected every
single message with *"Input token ids are too long."*

---

## 5. Privacy model

Sessions are **sandboxes**. Each `ChatSession` carries its own memory scope and
an `ephemeral` flag; switching sessions resets the model's KV cache so one
conversation's context cannot leak into another.

`EgressDestination` enumerates every way out:

```swift
case cloud(model:)                  // Gemini
case privateComputeServer(endpoint:)
case mcpServer(name:host:)
case restHost(name:host:)
case appLaunch(scheme:target:)
```

Colour carries this meaning in the UI: **orange in the Privacy Ledger means
bytes left the device.** Nothing else is coloured there, so the signal stays
readable.

---

## 6. Connectors

`ConnectorManager` owns three kinds, all surfaced to the model as ordinary
tools through `ToolRegistry.replaceConnectorTools`:

- **MCP** — remote Model Context Protocol servers over HTTPS. Tools discovered
  at connect time, named `mcp__server__tool`.
- **REST** — any HTTP API exposed as a single tool, pinned to one host.
- **UCP** — Google's Universal Commerce Protocol via Shopify storefronts.

Built-in tools always win a name collision; a refresh removes exactly the
connector tools it previously installed, never a built-in that shares a prefix.

---

## 7. Siri & App Intents

15 intents ship; **10 get a registered voice phrase** — that is a hard iOS
limit, enforced at build time by `appintentsmetadataprocessor`, not by the
compiler. Adding one means retiring one. Intents without a phrase remain fully
usable in the Shortcuts app.

`SearchAnuIntent` adopts the `.system.search` Apple Intelligence schema — the
only schema that fits an assistant. (The `.mail.*` family is ten *mutations* on
an app-owned mailbox with no search or read schema; adopting it would mean
claiming to be a mail client.)

**Adopting a schema is a promise.** `.system.search` tells Siri that
"search … in Anu" leads somewhere, which is why `SessionListView` has real
search behind it.

### What iOS will not give you

Verified against the iOS 26.5 SDK, not from documentation:

- **Messages** — no read API. `Messages.framework` ships only iMessage
  *extension* classes; `MSConversation` sees just the message selected inside
  your own extension.
- **Mail** — no read API. `MailKit.framework` **is not in the iOS SDK at all**
  (macOS only). `MessageUI` composes; the user must tap Send.

Mail access therefore has to come from account APIs (Gmail / Microsoft Graph /
IMAP) through the connector stack. No entitlement changes this.

---

## 8. Build & test

No CocoaPods, no workspace — a single generated project.

```bash
python3 generate_xcodeproj.py                 # regenerate after adding a file
xcodebuild -project Anu.xcodeproj -scheme Anu \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

> **Adding a source file means editing `generate_xcodeproj.py`.** The file list
> is explicit, not globbed. Forgetting produces a confusing
> *"type has no member"* error rather than a missing-file error.

### Running the whole suite

Roughly 40% of coverage is gated off by default and **reports as green while
untested**:

```bash
TEST_RUNNER_VERIFY_DRIVERS=1 \
TEST_RUNNER_REAL_MODEL_TEST=1 \
TEST_RUNNER_LIVE_CONNECTOR_TEST=1 \
xcodebuild -project Anu.xcodeproj -scheme Anu \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

| Flag | Unlocks |
|---|---|
| `VERIFY_DRIVERS` | 4 GUI driver tests |
| `REAL_MODEL_TEST` | 4 real-engine tests incl. multi-turn KV reuse |
| `LIVE_CONNECTOR_TEST` | live DeepWiki MCP + registry (network) |
| `MCP_TEST_URL` | needs a *fixture* server with a `ping` tool |

Default: 420 unit + 17 UI. With flags: 419 of 437 actually execute.

**Permission-dependent tests** (EventKit, Contacts, Photos) skip unless the app
holds the grant — and `xcodebuild test` reinstalls the app, which **resets TCC**.
Granting before a run is wiped by the install.

---

## 9. Traps worth knowing

Each of these cost real time; they are not hypothetical.

**Never put a tool's dependency behind `@MainActor`.** XCTest blocks the main
thread to drive an `async` test, so a tool awaiting main-actor state deadlocks
forever — the suite hangs with no output instead of failing. `CalendarAccess`
is deliberately *not* `@MainActor`; only its `@Published` bump hops to main.

**`EKEventStore` must be long-lived** to receive `.EKEventStoreChanged`, and
must be `reset()` after a change before its cached objects are trustworthy.

**`AVSpeechSynthesizer` needs a delegate** or `isSpeaking` never returns to
false — it was set on `speak()` and cleared only by `stop()`.

**`Canvas` clips to its frame.** A halo or glow drawn past the edge renders as a
visible square instead of fading out.

**The iOS Simulator has no audio input** (`error -10879`). Anything mic-driven
can only be verified on hardware. TTS output does work there.

---

## 10. Design system

Two token files, and the rule is that the step encodes intent:

- `UI/Typography.swift` — five steps. `anuLabel` (13pt) is the floor for
  anything load-bearing; `anuMeta` (12pt) is for timestamps and nothing else.
- `UI/DesignSystem.swift` — `Space` (4pt scale), `Radius` (3 steps),
  and colour.

**The accent marks one thing per view**: the primary action, the active
selection, or your own message. Everything else is neutral. Before this rule,
blue was on twenty elements including four decorative bullets, so it meant
nothing.
