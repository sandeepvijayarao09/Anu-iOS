# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims
to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
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
