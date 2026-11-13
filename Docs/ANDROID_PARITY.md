# Android parity tracker

Goal: bring every feature of Anu for Android (github.com/sandeepvijayarao09/Android_ANU, `docs/ARCHITECTURE.md`
component-status table at commit `c3ba167`) to Anu for iOS, one feature at a time, on top of the trust-core baseline.

Statuses follow the Android project: **Planned → In progress → Implemented → Verified** (its test or eval passes on a
device). "Blocked by iOS" means the platform has no public API for it; the row says what the closest iOS form is.

Order of work: rows 1–2 landed first; the rest are built in parallel, one branch per feature group, then merged and tested together. Each lands with its own tests and a row update here.

All of waves 1, 2 and 3 merged into `feature/trust-core` on 2026-11-13. Wave 3 added the Apple model tiers and Siri work (A1–A9), rows 26–30, and the follow-ups in rows 3, 6, 13 and 14. "Implemented (unit tests)" means not yet run on a device.

Wave 1 (started 2026-11-12): rows 3–5 (memory), 6–8 + 24 (answer details, thinking, lab, calibration), 9 (skills), 10–11 (Gmail, email/scheduling), 16–17 + 23 (phone controls, Direct tier, heat guard), 18–19 (Mac brain, A2A).
Wave 2: rows 12–13 + 25 (voice), 14–15 (photos, PDFs), 20–21 (writing extension, keyboard), 22 (live camera).

## Baseline

| Area | iOS today | Status |
|---|---|---|
| Trust core: Tool Broker, risk tiers, exact-payload approvals, taint, audit, action claims | `Agent/ToolBroker.swift`, `ApprovalCenter`, `ToolAudit`, `ActionClaims`, `Tools/ToolPolicy.swift`, `UI/ApprovalSheet`, `UI/ActivityView` | Implemented (unit tests) |
| Chat + voice on one page, streaming, model label | `ChatView`, `VoiceOrb`, `SpeechRecognizer`, `SpeechSynthesizer` | Implemented |
| Model tiers + router + escalation | Gemma 4 (LiteRT-LM), Gemini, and Anu's own Private Compute server (`PrivateComputeClient`, not Apple PCC); `ModelClassifier`, `EscalationRouter`, `PlanGate`. Apple's models are not used yet: see "Apple integration" below | Implemented |
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
| 3 | Memory v2: capture, on-device extraction, reconcile, sources, dated facts (ADR-054, ADR-147) | `Agent/MemoryStore.swift` facts with dated sources, confidence, history, via SecureFile; `MemoryExtraction.swift` (own turns only, secrets refused, on-device model only, strict parse + one repair); `MemoryLearner.swift` (BGProcessingTask on power, quiet chat, Learn now). Model tools `memory_search` (read), `memory_remember` (private write), `memory_forget` (destructive, always asks, as on Android) through the broker; off in private sandboxes. Never-learn rules not built (planned on Android too). Not run on a device | Implemented (unit tests) |
| 4 | Memory Inspector: search, correct, delete, add, Confirm pill | `UI/MemoryView.swift`: sections, search, badges, per-fact sheet with dated sources, Forget this message, history, That's right / Correct / Delete, Add, Learn now, Forget Everything. No UI test yet | Implemented (unit tests) |
| 5 | Search by meaning (EmbeddingGemma) | `Agent/MemoryRelevance.swift`: words + meaning (`NLContextualEmbedding` if installed, else `NLEmbedding`, else words; never downloads); 400-token [M1] block in on-device prompts only. Thresholds not tuned on a device; EmbeddingGemma not done | Implemented (unit tests) |
| 6 | About this answer (ADR-071) + model sheet with real use and Test speed (ADR-073) | `AnswerDetails` on each message; caption opens `AboutAnswerSheet`, which lists the Memory facts used and opens each one; Model page Speed (median of last 20, Test speed). Device tokens/s unverified | Implemented (unit tests) |
| 7 | Thinking switch + collapsed reasoning (ADR-077) | Settings → Performance → Think before answering; LiteRT `enable_thinking`, thought channel kept apart, shown collapsed, timed in About, never fed back. Gemma template behaviour on device unverified; Apple FM not wired | Implemented (unit tests) |
| 8 | Prompt lab (ADR-080) | Settings → Performance → Prompt lab: templates, sampling, Think first, Greedy, Run/Stop; no memory, tools, history or cloud; nothing saved | Implemented (unit tests) |
| 9 | Agent Skills: `SKILL.md`, `load_skill`, `run_js`, `run_intent`, Settings → Skills (ADR-120) | `Skills/*`: parser with Android's refusals; 4 original bundled skills; add from file, folder or https (ledgered, SecureFile); `run_js` in a bare JavaScriptCore context (size limits, 5 s timeout; CPU limit DEBUG-only because it's a private symbol); `run_intent` always asks; taint; "load it first" for a skill called as a tool. No UI test | Implemented (unit tests) |
| 10 | Gmail: search, thread, draft, approved send | `Connectors/Gmail*`: OAuth (ASWebAuthenticationSession + PKCE, owner's iOS client ID), tokens only in the vault bound to Google hosts, MIME writer (header-injection fix), send always asks, every request ledgered; Settings → Connectors → Gmail; Docs/GMAIL_SETUP.md. Live mailbox untested (needs owner's client ID) | Implemented (unit tests) |
| 11 | AI Email / Scheduling skills | `Agent/SkillDetector.swift` (port, follow-up replay); email = Gmail + contacts + calendar + datetime, scheduling = calendar + contacts + datetime, on-device agent path | Implemented (unit tests) |
| 12 | Voice notes transcribed on device (ADR-078) | `Voice/*`: "+" → Voice Note (16 kHz, up to 5 min, audio only via SecureFile until written down, then deleted); Gemma 4 audio input through LiteRT-LM, else SpeechTranscriber (installed models only), else on-device SFSpeechRecognizer; shared audio decoded in AnuShare and handed over sealed with a separate App Group key; only the words are kept; voice-note turns stay on device and cloud escalation is refused. Recording, sharing and Gemma audio unverified on a device (the simulator has no mic) | Implemented (unit tests) |
| 13 | Voice turn-taking: endpointer, barge-in, early first clause (ADR-129) | Tested logic (`Endpointer`, `BargeInDetector`, `SpokenStream`, `LiveTalk`); in live talk, speech plays through the voice-processing `AVAudioEngine` (`DuplexVoiceEngine`), so the echo canceller hears Anu's own voice and barge-in works; engines rebuilt after a media-services reset. Echo cancellation unverified on a device | Implemented (unit tests) |
| 14 | Several photos per message, secrets masked in pictures (ADR-082, ADR-094) | Up to four photos, ≤ 4 in the model's view; Vision masks codes, cards and passwords on screen-like pictures; answers masked with the stream held; photo turns on device only; "Gemini can't see photos" when Gemini is named; a photo is deleted once out of the model's view ("Photo no longer kept", ADR-091). Not run on a device | Implemented (unit tests) |
| 15 | PDFs: pages as pictures, reading in pieces (ADR-095) | File picker and shares; pill in composer and turn; PDFKit text (first 20 pages) or page pictures for scans; read in 7,000-character pieces with notes; locked PDFs refused; text kept only via SecureFile; tainted; cloud refused at the gate | Implemented (unit tests) |
| 16 | Phone controls (ADR-076, ADR-099, ADR-107) | `PhoneControlTools.swift`: flashlight, brightness, open app (fixed list), Maps directions, share (asks), call via `contact_action` (asks); AlarmKit alarms (iOS 26.1+, notification fallback); reminders cancel (destructive, asks). Volume and DND **blocked by iOS** (Direct tier names Control Center / Focus). Torch, AlarmKit, share sheet unverified on a device | Implemented (unit tests) |
| 17 | Direct tier: whole phone commands with no model | `Agent/PhoneCommands.swift` + `AgentOrchestrator+Direct.swift`: ahead of the router, one broker call (tiers, approvals, receipts), "On device · no model needed"; near misses fall through | Implemented (unit tests) |
| 18 | Mac as the top model (Ollama, ADR-113) | `API/MacBrainClient.swift`: Ollama streaming, sanitized + ledgered as `.mac(host:)`, photos refused, tool calls never run; plain HTTP to LAN only (no secret) or HTTPS pairing via `Scripts/mac-brain.py` (pinned cert, vault token); `CloudProvider.mac`, `escalate_to_mac`; Settings → Your Mac. Real Ollama untested; 30 s broker timeout vs slow models open | Implemented (unit tests) |
| 19 | A2A client for local agents (ADR-105) | `Connectors/A2AClient.swift`: agent card (+ older address), `message/send`, tasks/artifacts; each agent an `a2a_<name>` tool that always asks, ledgered, taints; Settings → Connectors → Agents on your network. No live agent tried | Implemented (unit tests) |
| 20 | AI Writing everywhere (ADR-042, ADR-116) | `AnuWriting` action extension "Rewrite with Anu": six actions + your own instruction, preview, Replace (where the host accepts it) or Copy; Apple's on-device Foundation Models in the extension when available, else App Group hand-off to Anu's on-device model; never the cloud. Not tried in a real host app | Implemented (unit tests) |
| 21 | Anu keyboard with AI strip (ADR-109, ADR-122) | `AnuKeyboard`: QWERTY, symbols, number and phone pads, no dictionary or history; AI strip (Ask Anu, Fix grammar, Expand, Emoji, Improve, Continue, Shorter, Friendlier, More formal, Summarize, Reply), read only on tap, preview, still-there check; no AI or reads in password, code or card fields; Settings → Keyboard. Not tried in a host app; memory not measured | Implemented (unit tests) |
| 22 | Live camera with object boxes | `LiveCameraView` + `LiveVision` + `LiveLabelMatcher`: AVCapture, Apple Vision boxes (animals, people, faces, rectangles, text, scene labels), 5/3/1 fps by heat, find by meaning, Ask Anu through the on-device photo path; frames never stored unless sent. No YOLOX model (`CoreMLLiveDetector` seam); no real camera tried | Implemented (unit tests) |
| 23 | Heat and battery guard (ADR-072) | `Agent/DeviceGuard.swift`: thermal serious/critical or battery ≤ 15% unplugged → skip planner and escalation judge, cap on-device answers at 256 tokens, say why | Implemented (unit tests) |
| 24 | Token calibration (ADR-041) | `TokenCalibration`: prose and JSON rates from the engine tokenizer, smoothed, clamped, persisted; `ConversationWindow` budgets 800 calibrated tokens. Device ratios still to measure | Implemented (unit tests) |
| 25 | "Hey Anu" wake phrase (ADR-045, ADR-121) | Foreground-only on-device recognition with Android's WakePhrase rules and WakeLoop backoff; Settings switch (off by default) saying it works only while Anu is open; "Hey Siri, ask Anu" is the background path (still 10 App Shortcuts). No "Your voice" model | Implemented (unit tests) |

## iOS-native forms of Android-only features (wave 3)

| # | Android feature (ADR) | iOS form | Status |
|---|---|---|---|
| 26 | Live talk behind other apps (ADR-108) | Live Activity (Lock Screen, Dynamic Island) with the phase, Mute and End, never the words; `audio` background mode only during live talk. On-device answers in the background unverified (iOS may refuse GPU work) | Implemented (unit tests) |
| 27 | Notes (ADR-093, ADR-119) | Anu's own notes via SecureFile; `notes_add` / `notes_search` / `notes_list` through the broker; Settings → Notes & Brief; Share to Notes | Implemented (unit tests) |
| 28 | AI Daily Brief (§1) | Today's events, reminders, relevant facts and recent notes; plain summary plus one on-device write-up; morning notification opens it (content never in the notification); Brief Me intent; "brief me" in chat runs the `daily_brief` tool on the Direct tier | Implemented (unit tests) |
| 29 | Questions about the screen (ADR-083) | "Ask About My Screen" (Screenshots picker), "Ask Anu About a Screenshot" for shortcuts (Action button, Back Tap), shared screenshots; always masked first | Implemented (unit tests) |
| 30 | App Store compliance | Privacy manifests for the app and all four extensions, Face ID usage string, `ITSAppUsesNonExemptEncryption = NO`, specific permission strings, Settings → Where Your Data Goes and Delete All My Data, icon without alpha, deprecations fixed. Owner items in `Docs/APP_STORE_COMPLIANCE.md` | Implemented |

## Apple integration (from Docs/research/APPLE_SIRI_FOUNDATION_MODELS.md)

Not on Android; these replace parts of rows the Android plan covers with Apple's official paths. Wave 3, after waves 1–2 merge, since they touch the router and intents.

| # | Step | APIs | Status |
|---|---|---|---|
| A0 | Request the Private Cloud Compute model entitlement (owner) | Managed entitlement; Small Business Program; < 2M first-time downloads across the developer's apps | Planned (owner) |
| A1 | Apple on-device model as the Base tier, PCC as the private cloud tier; fall back to Gemma, then Gemini | `AppleFoundationModel` (`SystemLanguageModel`), `escalate_to_apple_pcc` (`PrivateCloudComputeLanguageModel`), honest unavailability reasons, quota back-off; Settings → Model: Automatic / Apple on-device / Gemma 4. PCC off until `AnuPrivateCloudComputeEntitled` is set with the granted entitlement. iOS/macOS 27. Not run on a device | Implemented (unit tests) |
| A2 | Native tool calling on the Apple tiers, routed through ToolBroker approvals and receipts | `BrokeredTool` bridges each Anu tool to FoundationModels `Tool`; ToolSelector budget 900 tokens; too-long retry | Implemented (unit tests) |
| A3 | Gemma behind the same API (optional) | `GemmaFoundationModel` + `GemmaFoundationExecutor`; LiteRT path stays the default (resending the transcript defeats KV-cache reuse) | Implemented (not the default) |
| A4 | Search intent on the current schema | `@AppIntent(schema: .system.searchInApp)` (iOS 27); `supportedModes` beside every `openAppWhenRun`; Siri search now opens the list with the term | Implemented |
| A5 | Chats, memory and workflows findable by Siri and Spotlight | `IndexedEntity` chats and facts, workflow items linked to entities, Open Chat / Open Memory intents, the open chat exposed to Siri; never incognito, isolated, private or replaced content; Settings → Search switch | Implemented (unit tests) |
| A6 | Writing and inline intents as long-running | `LongRunningIntent` + `performBackgroundTask(.requiresGPU)` with token progress, 180 s (iOS 27) | Implemented (unit tests) |
| A7 | Rebalanced App Shortcuts (cap 10) | Calendar/reminder phrases dropped (Siri does those); live camera, voice note, open chat, proofread added; count unit-tested | Implemented |
| A8 | Side-button assistant (Japan only) | `ActivateAnuIntent` (`.assistant.activate`); builds without the entitlement, which isn't requested yet | Implemented in code (owner: entitlement) |
| A9 | First-use consent before anything goes to Gemini (5.1.2(i)) | Consent sheet naming the provider and what's sent; nothing sent until agreed; dated and versioned, withdrawable in Settings → Privacy; also the private server; headless requests refused | Implemented (unit tests) |

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
