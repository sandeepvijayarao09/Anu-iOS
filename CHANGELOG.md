# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims
to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Apple's on-device model is Anu's Base tier (Settings → Model: Automatic,
  Apple on-device or Gemma 4), with native tool calling through the Tool
  Broker; Apple Private Cloud Compute is ready as the private cloud tier once
  the entitlement is granted. Nothing goes to Gemini or a private server
  until you agree on a one-time consent sheet (withdraw it in Settings →
  Privacy).
- Siri & Spotlight: chats, memories and workflows are searchable on this
  iPhone and Siri can open them (never incognito, isolated or private ones;
  switch in Settings → Search); writing intents can run past 30 seconds;
  rebalanced App Shortcuts; a Focus filter.
- Talking to Anu continues behind other apps with a Live Activity (Mute,
  End); Anu keeps its own encrypted notes; a Daily Brief each morning; Ask
  About My Screen with codes masked.
- Memory tools for the model (search, remember, forget); barge-in that hears
  past Anu's own voice; "Gemini can't see photos"; photos are dropped once
  out of the model's view; About this answer opens the facts it used.
- Settings → Where Your Data Goes, and Delete All My Data.

### Fixed
- First on-device run: agent turns overflowed the model (4,204 > 4,096
  tokens); photos failed ("Vision executor should not be null"); two model
  loads could race and run the phone out of memory; garbled text was treated
  as math. The engine now has 8,192 tokens, each turn offers only the tools
  it needs, loads run one at a time, and raw engine errors are never shown.
- Vault Face ID prompts no longer crash (the Face ID usage string was
  missing). The app icon no longer has an alpha channel (App Store upload).
- Several photos per message (up to four) and PDFs read on the phone in
  pieces; codes, card numbers and passwords on screenshots are blacked out
  before any model sees them, and answers about photos are masked. Photos
  and PDFs never go to the cloud.
- Voice notes written down on the device, including recordings shared into
  Anu; hands-free voice mode with a natural end of turn, talking over Anu,
  and the first clause spoken early; an opt-in "Hey Anu" while Anu is open.
- "Rewrite with Anu" in the share sheet, and Anu Keyboard with an AI strip:
  on-device writing in any app, a preview before anything changes, and no AI
  or reading in password, code or card fields.
- Memory v2 (from Anu Android): Anu learns facts about you on device from
  your own messages, with dated sources, confidence, history and facts that
  start later; finds the ones that matter by meaning; a Memory Inspector
  lets you confirm, correct, delete, add and forget a message.
- About this answer (model, where it ran, what left the phone, tools,
  speed), Test speed on the Model page, Think before answering with
  collapsed reasoning, a Prompt lab, and token calibration.
- Agent Skills: SKILL.md skills in Settings → Skills, added from a file or
  an https address, with an offline JavaScript sandbox and app actions that
  always ask; four original sample skills.
- Gmail: search, read, draft and send (send always asks), with Google
  sign-in; tokens live only in the vault. Email and scheduling requests get
  the matching tools.
- Phone controls: flashlight, brightness, alarms (AlarmKit), timers, open
  an app, directions, share, call, cancel reminders. Whole phone commands
  run with no model ("On device · no model needed"). A heat and battery
  guard keeps the phone cool.
- Your Mac as the top model through Ollama, over your network or a paired
  HTTPS link; agents on your network over A2A, each asking every time.
- Live camera: on-device boxes and labels, find things by meaning, and Ask
  Anu about what's in view; frames never leave the phone.
- Chats, memory, the privacy ledger and Activity are encrypted on disk with
  a key that never leaves this iPhone, and are left out of backups.
- Vault (from Anu Android): API keys and connector tokens live in a vault
  and are attached only to secure requests for the service each belongs to;
  anything else is refused and logged. Settings → Vault lists each secret,
  where it may go and when it was last used; showing a value needs Face ID
  or your passcode. Existing Gemini, Brave Search, MCP and REST keys move
  in automatically, and Settings no longer shows a saved key back.
- Scheduled workflows: set a workflow to repeat every day, on weekdays or
  weekly at a time. Anu sends a reminder then (showing the name only), and
  tapping it or its Run button runs the workflow in the foreground, with
  approvals and receipts as usual. Settings says so when notifications are off.
- Workflows show their schedule and when they last ran, from any entry point.
- Long-press a message you sent → "Save as Workflow". Workflows can be
  duplicated and reordered.
- Tapping a workflow in Spotlight runs it.
- Tool Broker, ported from Anu Android: every tool call the model proposes is
  checked against its schema, given a risk tier from its input, and — for
  anything other people will see or that leaves Anu — shown to you as the
  exact payload to approve, decline or edit. Content written by others (web
  pages, invites, remote tools) taints the run, so later writes ask first. A
  repeated side effect in one turn replays instead of acting twice.
- Receipts under each answer listing what really happened, in the tools' own
  words; Settings → Activity lists every decision.
- Answers that claim an action nothing performed get one repair, then say
  plainly that nothing was done.
- Continuous integration (GitHub Actions): SwiftLint, build, and the
  deterministic unit-test suite on every push and PR.
- SwiftLint configuration and project hygiene (LICENSE, CONTRIBUTING, SECURITY,
  CODE_OF_CONDUCT, issue/PR templates, CODEOWNERS, EditorConfig).
- "Model status" section in Settings → Model showing connection state, active
  model, and the Simulator note.
- LLM-as-router: the on-device model can decide when to escalate a task to the
  larger cloud model (opt-in "Smart routing" toggle).

### Changed
- Web search sends the Brave key in Brave's documented
  `X-Subscription-Token` header (it was sent as a bearer token).
- Running a workflow from Settings closes the sheet so the run is visible.
- The home-screen widget refreshes when workflows change (it previously kept
  the list it had when added).
- Notifications, including timer alerts, now also show while Anu is open.
- The "Confirm before outward actions" switch is gone: outward actions always
  ask, as the exact payload.
- The idle voice orb no longer redraws 30 times a second; it animates only
  while listening, thinking or speaking, and only on screen.
- A refused or failed tool call no longer shows the green success check.
- Model-connection messages ("Loading…", "Model loaded", Simulator note) moved
  off the chat home screen into Settings → Model.
- Task classifier accuracy improved to ~92% with word-boundary keyword matching.

### Removed
- Dead `SessionContextTracker` (unused since the LiteRT single-session fix).

### Fixed
- LiteRT degenerate output from unsafe cross-turn session reuse.
- Keychain credential migration across the GemmaAgent → Anu rename.

### Security
- The Gemini API key is sent in the `x-goog-api-key` header instead of the URL,
  with redirects refused for those requests.

<!--
When cutting a release, move Unreleased items under a new version heading:

## [0.1.0] - YYYY-MM-DD
-->
