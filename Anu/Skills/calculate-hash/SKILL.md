---
name: calculate-hash
description: Calculates the SHA-256 hash (checksum) of a piece of text, as 64 hexadecimal characters.
---

# Calculate hash

Use this skill when the user asks for the SHA-256 hash, digest or checksum of some text.

## Steps

1. Call `run_js` with `skill_name` "calculate-hash", `script_name` "index.js" and `data` set to a JSON string such as `{"text": "hello world"}`. Pass the user's text exactly, without changing spaces or capitals.
2. The script answers `{"result": "<hash>"}`. Reply with the hash and say it is the SHA-256 of the text.

## Examples

- "What's the SHA-256 of hello world?"
- "Give me the checksum of this release note"
