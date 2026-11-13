# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims
to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
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
