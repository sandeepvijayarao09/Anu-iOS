# Anu — Architecture & Workflow

Anu is an on-device agentic assistant for iOS and macOS. A Gemma 4 model runs
locally through Google's LiteRT-LM runtime; it can call tools, remember things
across sessions, and — only when asked — escalate a sanitised task to a cloud
model. Every byte that leaves the device is recorded.

~16,200 lines of Swift across 116 files. Single app target plus a share
extension, a widget, and a native macOS target.

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

**Two rules hold the design together:**

1. **The model proposes; the Tool Broker decides.** Every tool call the model
   makes goes through `ToolBroker`, which checks it, applies policy, and asks you
   to approve the exact payload when it matters (§4).
2. **Anything that leaves the device passes through a tool**, and every such
   tool records an `EgressDestination` in the `PrivacyLedger`. There is no
   second path out.

---

## 2. Directory map

| Directory | Files | Lines | What lives there |
|---|---:|---:|---|
| `Agent/` | 24 | 4,031 | Orchestrator, Tool Broker, routing, planning, memory, privacy ledger |
| `UI/` | 22 | 4,420 | SwiftUI screens, approval sheet, design system, type scale |
| `Tools/` | 20 | 2,521 | `Tool` protocol, policy types, registry, 16 built-in tools |
| `Models/` | 12 | 1,407 | Model catalog, factory, LiteRT-LM backend, downloads |
| `Connectors/` | 10 | 1,346 | MCP client, REST connectors, UCP commerce, app launcher |
| `Utilities/` | 11 | 1,128 | Keychain, speech, attestation, shared formatters |
| `App/` | 7 | 558 | App entry, App Intents / Siri |
| `API/` | 4 | 526 | Gemini client, private-compute client |
| `Workflows/` | 9 | 603 | Saved prompts runnable from Siri, widget, share sheet, Spotlight, scheduled reminders |

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

The model emits a tool call, `ResponseParser` extracts it, and
`gatedToolResult` hands it to `ToolBroker` — the only thing that runs tools
(§4). The ReAct loop, the planner's sub-agents and the cloud route all use that
one gate.

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

### The answer is checked against what happened

Before a final answer stands, it is checked against the broker's record
(`ActionClaims`, ported from Anu Android's ADR-027). An answer that claims an
action nobody performed ("I've sent the text…") or leaks tool-call markup gets
**one** repair: a note rides only in that prompt, the bad answer is never shown
or saved. If the repair still claims it, the answer is kept but ends with
"Note from Anu: nothing was actually created or sent." Under every answer, the
chat lists what really happened, in each tool's own words (`ReceiptList`).

---

## 4. Tool Broker (the trust core)

Ported from Anu Android's `ToolBroker` (`Agent/ToolBroker.swift`). Tools never
decide whether they run; they answer the broker's questions from the validated
payload: `risk(for:)`, `describe(_:)`, `sendsTo(_:)`,
`returnsUntrustedContent(for:)`, `editableFields`, `approvalNote(for:)`.

For each call, in order:

1. **Check** the arguments against the tool's schema and re-encode them
   (`ToolArguments.canonicalize`): unknown top-level keys dropped, required
   keys present, unambiguous coercions ("5" → 5), enums in the schema's
   spelling. What you approve is exactly what runs. Invalid calls never run.
2. **Policy:** a switched-off capability blocks first; then the risk tier:

   | Risk | Example | Runs by itself? |
   |---|---|---|
   | `read` | calendar list, web search | Yes — unless the run is tainted **and** the call sends data to a third party |
   | `writePrivate` | a reminder, an event (EventKit adds no invitees) | Yes — unless the run is tainted |
   | `writeExternal` | text/call/email, open another app, a Shortcut, any MCP tool, a REST write | **Never**: always the exact payload |
   | `destructive` | (none yet) | Never |

3. **Taint (P4):** a result from a tool that returns content written by others
   (web pages, invites, shared lists, images, PDFs, remote tools) taints the
   run. The approval sheet then asks for a closer read.
4. **Replay:** side effects are keyed by `sha256(turn | tool | payload)`; the
   same call in the same turn replays its stored result instead of acting twice.
5. **Approval** (`ApprovalCenter` → `ApprovalSheet`): the tool's summary, why it
   asks, where it goes, and the payload field by field. **Edit** changes only
   the tool's `editableFields`; saving approves nothing — the broker checks the
   edit and asks again ("Edited by you"). No answer in 10 minutes is a denial.
6. **Run** with a 30 s timeout, then record: `ToolAuditLog` (Settings →
   Activity, 500 entries, on device) and the receipt under the answer.

Budget: 12 tool calls per turn. Refusals tell the model why, by code
(`declined`, `no_answer`, `not_allowed`, `budget`, `cancelled`), so it can tell
a person's "no" from a rule.

---

## 5. The model layer

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

## 6. Privacy model

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

The Gemini key travels in the `x-goog-api-key` header, never the URL (URLs end
up in logs and proxies), and those requests refuse redirects, because
URLSession forwards custom headers to wherever a redirect points.

---

## 7. Connectors

`ConnectorManager` owns three kinds, all surfaced to the model as ordinary
tools through `ToolRegistry.replaceConnectorTools`:

- **MCP** — remote Model Context Protocol servers over HTTPS. Tools discovered
  at connect time, named `mcp__server__tool`.
- **REST** — any HTTP API exposed as a single tool, pinned to one host.
- **UCP** — Google's Universal Commerce Protocol via Shopify storefronts.

Built-in tools always win a name collision; a refresh removes exactly the
connector tools it previously installed, never a built-in that shares a prefix.

---

## 8. Siri & App Intents

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

## 9. Build & test

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

Default: 436 unit + 18 UI (2026-09-28). The opt-in flags above unlock the
gated ones.

**Permission-dependent tests** (EventKit, Contacts, Photos) skip unless the app
holds the grant — and `xcodebuild test` reinstalls the app, which **resets TCC**.
Granting before a run is wiped by the install.

---

## 10. Traps worth knowing

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

## 11. Design system

Two token files, and the rule is that the step encodes intent:

- `UI/Typography.swift` — five steps. `anuLabel` (13pt) is the floor for
  anything load-bearing; `anuMeta` (12pt) is for timestamps and nothing else.
- `UI/DesignSystem.swift` — `Space` (4pt scale), `Radius` (3 steps),
  and colour.

**Motion follows real signal.** The voice orb animates only while listening,
thinking or speaking, and only on screen; idle, it rests and draws nothing
(Anu Android measured its idle loop at 43% of a CPU core).

**The accent marks one thing per view**: the primary action, the active
selection, or your own message. Everything else is neutral. Before this rule,
blue was on twenty elements including four decorative bullets, so it meant
nothing.

---

## 12. Invariants, decisions, status

Adopted from Anu Android's process: docs describe what exists, and a change
that alters the design updates this file in the same change.

**Invariants** (the ones enforced today have tests):

| # | Invariant | Status |
|---|---|---|
| I2 | No `writeExternal`/`destructive` tool runs without your approval of the exact payload | Enforced (`ToolBrokerTests`, UI test `testOutwardActionAsksForTheExactPayload`) |
| I6 | Output that triggers an action is schema-checked first; invalid output never runs | Enforced (`ToolArguments`) |
| P4 | Content written by others taints the run and removes automatic permissions | Enforced (`ToolBrokerTests`) |
| — | An answer can't claim an action the broker didn't record | Enforced (`AnswerCheckTests`) |
| I1 | No secret in a URL, prompt, log or memory | Partial: Gemini key moved to a header; vault handles not yet |
| I3 | Every egress writes a ledger entry | Existing `PrivacyLedger`; not yet test-enforced |
| I8 | Chat templates and tool formats come from the runtime | **Not yet**: prompts are still hand-built Gemma 3 strings (next slice) |

**Decision log**

| Date | Decision | Why |
|---|---|---|
| 2026-09-28 | Port Anu Android's Tool Broker: risk tiers by input, exact-payload approval with Edit, taint, replay keys, audit, receipts, claim check | Siri AI (iOS 27) now covers the general assistant; checkable trust is where Anu differs. The old gate was one alert that a Settings switch could turn off |
| 2026-09-28 | Remove "Confirm before outward actions" | I2 has no off switch: the exact payload always asks |
| 2026-09-28 | Gemini key in `x-goog-api-key`, redirects refused | Anu Android lesson: the key was in the URL |
| 2026-09-28 | The orb rests when idle | It redrew at 30 fps while idle; Android measured the same loop at 43% of a CPU core |

**Component status**

| Component | Status |
|---|---|
| Tool Broker, approval sheet, receipts, Activity | Implemented: 29 unit tests and 1 UI test (approve sheet → Edit → Decline → receipt) on the iPhone 17 Pro simulator |
| Answer check (claims, markup) | Implemented in the ReAct loop; the plan pipeline marks unbacked claims without a repair |
| MCP tool risk from server annotations | Planned: every MCP call asks today |
| Native Gemma templates and tool calls (I8) | Planned — next slice |
| Apple Foundation Models (on-device + Private Cloud Compute) tiers | Planned, decided 2026-09-27 |
| Memory with provenance, vault, reversible redaction | Planned |
