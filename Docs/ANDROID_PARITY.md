# Android parity tracker

Goal: bring every feature of Anu for Android (github.com/sandeepvijayarao09/Android_ANU, `docs/ARCHITECTURE.md`
component-status table at commit `c3ba167`) to Anu for iOS, one feature at a time, on top of the trust-core baseline.

Statuses follow the Android project: **Planned → In progress → Implemented → Verified** (its test or eval passes on a
device). "Blocked by iOS" means the platform has no public API for it; the row says what the closest iOS form is.

Order of work: rows 1–2 landed first; the rest are built in parallel, one branch per feature group, then merged and tested together. Each lands with its own tests and a row update here.

Wave 1 (started 2026-11-12): rows 3–5 (memory), 6–8 + 24 (answer details, thinking, lab, calibration), 9 (skills), 10–11 (Gmail, email/scheduling), 16–17 + 23 (phone controls, Direct tier, heat guard), 18–19 (Mac brain, A2A).
Wave 2: rows 12–13 + 25 (voice), 14–15 (photos, PDFs), 20–21 (writing extension, keyboard), 22 (live camera).

## Baseline

| Area | iOS today | Status |
|---|---|---|
| Trust core: Tool Broker, risk tiers, exact-payload approvals, taint, audit, action claims | `Agent/ToolBroker.swift`, `ApprovalCenter`, `ToolAudit`, `ActionClaims`, `Tools/ToolPolicy.swift`, `UI/ApprovalSheet`, `UI/ActivityView` | Implemented (unit tests) |
| Chat + voice on one page, streaming, model label | `ChatView`, `VoiceOrb`, `SpeechRecognizer`, `SpeechSynthesizer` | Implemented |
| Model tiers + router + escalation | Gemma 4 (LiteRT-LM), Gemini, and Anu's own Private Compute server (`PrivateComputeClient`, not Apple PCC); `MessageRouter`, `EscalationRouter`, `PlanGate`. Apple's models are not used yet: see "Apple integration" below | Implemented |
| Model catalog, verified resumable download | `ModelCatalog`, `ModelDownloadManager`, `ModelAllowlist` | Implemented |
| Calendar, contacts, reminders, timers | `CalendarTool`, `ContactsTool`, `ContactActionTool`, `RemindersTool`, `TimerTool` | Implemented |
| MCP connector, UCP shopping, REST connectors | `Connectors/*` | Implemented (DeepWiki MCP verified live) |
| Privacy ledger | `PrivacyLedger` | Implemented |
| Photos + camera in chat, PDFs (text) | `PhotoLibraryTool`, `CameraCaptureView`, PDFKit in `UtilityTools` | Implemented |
| Siri / App Intents, Spotlight, widget, share sheet, writing intents | `App/*Intent*.swift`, `AnuWidget`, `AnuShare` | Implemented |
| Workflows + schedules | `Workflows/*` | Implemented |
| Conversation window | `ConversationWindow` | Implemented |

## Features to build, in order

| # | Android feature (ADR) | iOS form | Status |
|---|---|---|---|
| 1 | Vault (ADR-135) + host-bound secret injection (I1/P3) | `Vault/Vault.swift`: Keychain items (`ThisDeviceOnly`, `.userPresence` for passwords) addressed by `SecretRef`; `Vault.authorize` attaches a value only over HTTPS to a bound host from an allowed caller, refuses redirects, and audits every use; a binding stored with each value refuses tampered metadata. Gemini and Brave keys migrate from the old Keychain entries; MCP bearer tokens and REST auth headers move out of connector configs (`ConnectorSecrets`). Settings → Vault lists items, "Sent only to …", last use and activity; Show needs Face ID/passcode, Copy expires in 60 s, the value hides when the app leaves the foreground. 18 unit tests (`VaultTests`, `ConnectorSecretsTests`), UI test `testGeminiKeyIsSavedToVault` (needs an ad-hoc signed build for the Keychain) | Implemented |
| 2 | Encrypted store for transcript, ledger, audit, memory | `Vault/SecureFile.swift`: chats, session index, memory, privacy ledger and tool audit are AES-256-GCM with a per-install Keychain key (`ThisDeviceOnly`), plus `.completeFileProtection`, excluded from backup; plain files from earlier builds load and re-encrypt on save. App Group files (workflows, inbox) keep file protection only, since the extensions can't read the app's Keychain key. 8 unit tests (`SecureFileTests`) | Implemented |
| 3 | Memory v2: capture, on-device extraction, reconcile, sources, dated facts (ADR-054, ADR-147) | Fact store with source, confidence and history; extraction on the on-device model while charging (BGProcessingTask) | In progress |
| 4 | Memory Inspector: search, correct, delete, add, Confirm pill | SwiftUI Memory screen | In progress |
| 5 | Search by meaning (EmbeddingGemma) | `NLContextualEmbedding` first; EmbeddingGemma via LiteRT if available | In progress |
| 6 | About this answer (ADR-071) + model sheet with real use and Test speed (ADR-073) | Per-message details sheet; tok/s from the engine | In progress |
| 7 | Thinking switch + collapsed reasoning (ADR-077) | Gemma 4 thought channel, Apple FM where supported | In progress |
| 8 | Prompt lab (ADR-080) | Settings page: templates, sampling, thinking, side conversation | In progress |
| 9 | Agent Skills: `SKILL.md`, `load_skill`, `run_js`, `run_intent`, Settings → Skills (ADR-120) | JavaScriptCore sandbox for `run_js`; `run_intent` → URL schemes / App Intents | In progress |
| 10 | Gmail: search, thread, draft, approved send (ADR, `connector:gmail`) | Google OAuth (ASWebAuthenticationSession), tokens in the vault, ledgered | In progress |
| 11 | AI Email / Scheduling skills | Skill detection + tool bundles | In progress |
| 12 | Voice notes transcribed on device (ADR-078) | Record → Gemma 4 audio input, SpeechAnalyzer fallback | In progress |
| 13 | Voice turn-taking: endpointer, barge-in, early first clause (ADR-129) | AVAudioEngine + voice processing IO | In progress |
| 14 | Several photos per message, camera, secrets masked in pictures (ADR-082, ADR-094) | Up to four images; Vision text detection masks codes | In progress |
| 15 | PDFs as pages-as-pictures, reading in pieces (ADR-095) | PDFKit render + chunked reading | In progress |
| 16 | Phone controls: alarms, timers, flashlight, brightness, open app, navigate, share, call (ADR-076, ADR-099, ADR-107) | AlarmKit, AVCaptureDevice torch, `UIScreen.brightness`, URL schemes; volume and DND **blocked by iOS** | In progress |
| 17 | Direct tier: whole phone commands with no model | Deterministic parser ahead of the router | In progress |
| 18 | Mac as the top model (Ollama, ADR-113) | Ollama client over local network, egress-gated | In progress |
| 19 | A2A client for local agents (ADR-105) | URLSession A2A client | In progress |
| 20 | AI Writing everywhere (ADR-042, ADR-116) | Action extension + existing writing intents | In progress |
| 21 | Anu keyboard with AI strip (ADR-109, ADR-122) | Custom keyboard extension; model runs in the app via App Group hand-off (keyboard memory limit); secure fields are excluded by iOS | In progress |
| 22 | Live camera with object boxes (ADR, `brain:vision`) | Vision / Core ML YOLOX-Nano on AVCapture | In progress |
| 23 | Heat and battery guard for routing (ADR-072) | `ProcessInfo.thermalState`, `UIDevice.batteryLevel` | In progress |
| 24 | Token calibration (ADR-041) | Runtime counts vs estimates, persisted | In progress |
| 25 | "Hey Anu" wake phrase (ADR-045, ADR-121) | Foreground only (no always-on mic for third parties); Siri App Shortcut phrase as the background form | In progress |

## Apple integration (from Docs/research/APPLE_SIRI_FOUNDATION_MODELS.md)

Not on Android; these replace parts of rows the Android plan covers with Apple's official paths. Wave 3, after waves 1–2 merge, since they touch the router and intents.

| # | Step | APIs | Status |
|---|---|---|---|
| A0 | Request the Private Cloud Compute model entitlement (owner) | Managed entitlement; Small Business Program; < 2M first-time downloads across the developer's apps | Planned (owner) |
| A1 | Apple on-device model as the Base tier, PCC as the private cloud tier; fall back to Gemma, then Gemini | `SystemLanguageModel`, `PrivateCloudComputeLanguageModel`, `LanguageModelSession`, availability and quota checks | Planned |
| A2 | Native tool calling on the Apple tiers, routed through ToolBroker approvals and receipts | FoundationModels `Tool`, `GenerationOptions.ToolCallingMode` | Planned |
| A3 | Gemma behind the same API (optional) | `protocol LanguageModel` + `LanguageModelExecutor` | Planned |
| A4 | Search intent on the current schema | `@AppIntent(schema: .system.searchInApp)` (replaces deprecated `@AssistantIntent(schema: .system.search)`) | Planned |
| A5 | Chats, memory and workflows findable by Siri and Spotlight; the open chat exposed to Siri | `IndexedEntity`, `IndexedEntityQuery` | Planned |
| A6 | Writing and inline intents as long-running | `LongRunningIntent` | Planned |
| A7 | Free App Shortcut slots (all 10 used) by dropping phrases Siri already covers | `AppShortcutsProvider` | Planned |
| A8 | Side-button assistant (Japan only, needs entitlement) | `.assistant.activate` / `ActivateAssistantIntent` | Planned (only if Japan matters) |
| A9 | Explicit first-use consent before anything goes to Gemini (guideline 5.1.2(i)) | Consent sheet + ledger | Planned |

Still not officially possible: replacing Siri's model or plugging into Writing Tools (`_ModelDelegationIntent` is still internal in 27.2), reading Mail or Messages, MCP, custom adapters for the on-device model.

## Blocked by iOS (closest form noted)

| Android feature | Why | Closest iOS form |
|---|---|---|
| Reading SMS / messaging-app notifications, learning from notifications (ADR-127) | No API to read Messages, Mail or other apps' notifications | Share sheet into Anu; Siri `.system.search` |
| Questions about the screen over any app (ADR-083) | No screen capture of other apps | Screenshot shared into Anu; Visual Intelligence integration |
| App control (ADR-098) | No accessibility automation of other apps | App Intents / Shortcuts of apps that expose them |
| Assistant role / replacing the system assistant (ADR-044) | Siri cannot be replaced | App Shortcuts, Action button, Siri intents |
| Live talk behind other apps (ADR-108) | No overlays | Live Activity + background audio session while talking |
| Notes into Samsung Notes / any notes app (ADR-093, ADR-117) | No Notes API | Share to Notes; Anu's own notes store |
| Do Not Disturb, system volume | No public API | Focus filters via App Intents |
