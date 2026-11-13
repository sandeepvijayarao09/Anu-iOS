# Android parity tracker

Goal: bring every feature of Anu for Android (github.com/sandeepvijayarao09/Android_ANU, `docs/ARCHITECTURE.md`
component-status table at commit `c3ba167`) to Anu for iOS, one feature at a time, on top of the trust-core baseline.

Statuses follow the Android project: **Planned → In progress → Implemented → Verified** (its test or eval passes on a
device). "Blocked by iOS" means the platform has no public API for it; the row says what the closest iOS form is.

Order of work: the numbered rows are built in this order. Each lands with its own tests and a row update here.

## Baseline

| Area | iOS today | Status |
|---|---|---|
| Trust core: Tool Broker, risk tiers, exact-payload approvals, taint, audit, action claims | `Agent/ToolBroker.swift`, `ApprovalCenter`, `ToolAudit`, `ActionClaims`, `Tools/ToolPolicy.swift`, `UI/ApprovalSheet`, `UI/ActivityView` | Implemented (unit tests) |
| Chat + voice on one page, streaming, model label | `ChatView`, `VoiceOrb`, `SpeechRecognizer`, `SpeechSynthesizer` | Implemented |
| Model tiers + router + escalation | Gemma 4 (LiteRT-LM), Apple Foundation Models, Private Cloud Compute, Gemini; `MessageRouter`, `EscalationRouter`, `PlanGate` | Implemented |
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
| 3 | Memory v2: capture, on-device extraction, reconcile, sources, dated facts (ADR-054, ADR-147) | Fact store with source, confidence and history; extraction on the on-device model while charging (BGProcessingTask) | Planned |
| 4 | Memory Inspector: search, correct, delete, add, Confirm pill | SwiftUI Memory screen | Planned |
| 5 | Search by meaning (EmbeddingGemma) | `NLContextualEmbedding` first; EmbeddingGemma via LiteRT if available | Planned |
| 6 | About this answer (ADR-071) + model sheet with real use and Test speed (ADR-073) | Per-message details sheet; tok/s from the engine | Planned |
| 7 | Thinking switch + collapsed reasoning (ADR-077) | Gemma 4 thought channel, Apple FM where supported | Planned |
| 8 | Prompt lab (ADR-080) | Settings page: templates, sampling, thinking, side conversation | Planned |
| 9 | Agent Skills: `SKILL.md`, `load_skill`, `run_js`, `run_intent`, Settings → Skills (ADR-120) | JavaScriptCore sandbox for `run_js`; `run_intent` → URL schemes / App Intents | Planned |
| 10 | Gmail: search, thread, draft, approved send (ADR, `connector:gmail`) | Google OAuth (ASWebAuthenticationSession), tokens in the vault, ledgered | Planned |
| 11 | AI Email / Scheduling skills | Skill detection + tool bundles | Planned |
| 12 | Voice notes transcribed on device (ADR-078) | Record → Gemma 4 audio input, SpeechAnalyzer fallback | Planned |
| 13 | Voice turn-taking: endpointer, barge-in, early first clause (ADR-129) | AVAudioEngine + voice processing IO | Planned |
| 14 | Several photos per message, camera, secrets masked in pictures (ADR-082, ADR-094) | Up to four images; Vision text detection masks codes | Planned |
| 15 | PDFs as pages-as-pictures, reading in pieces (ADR-095) | PDFKit render + chunked reading | Planned |
| 16 | Phone controls: alarms, timers, flashlight, brightness, open app, navigate, share, call (ADR-076, ADR-099, ADR-107) | AlarmKit, AVCaptureDevice torch, `UIScreen.brightness`, URL schemes; volume and DND **blocked by iOS** | Planned |
| 17 | Direct tier: whole phone commands with no model | Deterministic parser ahead of the router | Planned |
| 18 | Mac as the top model (Ollama, ADR-113) | Ollama client over local network, egress-gated | Planned |
| 19 | A2A client for local agents (ADR-105) | URLSession A2A client | Planned |
| 20 | AI Writing everywhere (ADR-042, ADR-116) | Action extension + existing writing intents | Planned |
| 21 | Anu keyboard with AI strip (ADR-109, ADR-122) | Custom keyboard extension; model runs in the app via App Group hand-off (keyboard memory limit); secure fields are excluded by iOS | Planned |
| 22 | Live camera with object boxes (ADR, `brain:vision`) | Vision / Core ML YOLOX-Nano on AVCapture | Planned |
| 23 | Heat and battery guard for routing (ADR-072) | `ProcessInfo.thermalState`, `UIDevice.batteryLevel` | Planned |
| 24 | Token calibration (ADR-041) | Runtime counts vs estimates, persisted | Planned |
| 25 | "Hey Anu" wake phrase (ADR-045, ADR-121) | Foreground only (no always-on mic for third parties); Siri App Shortcut phrase as the background form | Planned |

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
