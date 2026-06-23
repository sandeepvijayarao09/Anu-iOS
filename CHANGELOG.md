# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims
to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Continuous integration (GitHub Actions): SwiftLint, build, and the
  deterministic unit-test suite on every push and PR.
- SwiftLint configuration and project hygiene (LICENSE, CONTRIBUTING, SECURITY,
  CODE_OF_CONDUCT, issue/PR templates, CODEOWNERS, EditorConfig).
- "Model status" section in Settings → Model showing connection state, active
  model, and the Simulator note.
- LLM-as-router: the on-device model can decide when to escalate a task to the
  larger cloud model (opt-in "Smart routing" toggle).

### Changed
- Model-connection messages ("Loading…", "Model loaded", Simulator note) moved
  off the chat home screen into Settings → Model.
- Task classifier accuracy improved to ~92% with word-boundary keyword matching.

### Removed
- Dead `SessionContextTracker` (unused since the LiteRT single-session fix).

### Fixed
- LiteRT degenerate output from unsafe cross-turn session reuse.
- Keychain credential migration across the GemmaAgent → Anu rename.

<!--
When cutting a release, move Unreleased items under a new version heading:

## [0.1.0] - YYYY-MM-DD
-->
