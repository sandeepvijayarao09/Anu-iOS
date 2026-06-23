# Security Policy

Anu is a privacy-first, on-device AI app. Security and privacy are core to the
product, so we take reports seriously.

## Reporting a vulnerability

**Please do not open a public issue for security vulnerabilities.**

Email **vijayarao.s@northeastern.edu** with:

- a description of the issue and its impact,
- steps to reproduce (or a proof of concept),
- the affected version / commit.

You'll get an acknowledgement within a few days. Please allow reasonable time
for a fix before any public disclosure.

## Scope & privacy posture

Anu is designed so that, by default, prompts are processed **on-device** and
nothing leaves the device. Things worth scrutinizing:

- **Cloud escalation** (Gemini / a private compute server) is opt-in and gated
  on a configured provider. The `PIISanitizer` redacts personal details before
  anything is sent, and every egress is recorded in the in-app Privacy Ledger.
- **Connectors** (MCP servers, REST APIs, app launchers) are user-configured;
  outward-acting capabilities require explicit consent in Settings.
- **Credentials** (API keys, OAuth tokens) are stored in the iOS Keychain.

If you find a path where data leaves the device without going through the
sanitizer/ledger, or where a credential is exposed, that's exactly the kind of
report we want.
