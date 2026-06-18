# Private Compute Server — Reference Contract

Anu can escalate heavy tasks to a **private compute server you operate**,
instead of (or alongside) Google Gemini. This documents the HTTP contract the iOS
client (`PrivateComputeClient`) depends on, the privacy design, and a minimal
reference implementation. **The server itself is separate infrastructure** — this
file defines only the surface the app talks to.

> ## Honest framing — read this first
> This is **PCC-*inspired*, not Apple Private Cloud Compute.** Apple PCC provides
> *cryptographically verifiable* guarantees (signed measured boot, a transparency
> log, clients that refuse un-attested nodes). This design is **operator-trusted**:
> the stateless / no-retention properties hold only if **you run the server
> honestly**. The app cannot prove the server is stateless. Attestation here
> authenticates the **device to the server**, not the **server to the device**.
> The app's Privacy Ledger counts every byte sent here as having **left the
> device** — the UI never implies hardware-verified privacy.

## Endpoints

Base URL is whatever the user enters in **Settings → Private Compute** (HTTPS only).

### `POST /v1/generate`
Request body (`application/json`):
```json
{
  "prompt": "string",
  "sessionId": "string",
  "sampling": { "maxTokens": 512, "temperature": 0.1, "topP": 0.95,
                "topK": 10, "repetitionPenalty": 1.05, "stop": ["<end_of_turn>"] },
  "stream": true
}
```
- **Streaming** (`stream: true`, `Accept: text/event-stream`) → SSE:
  ```
  data: {"delta":"Hel"}

  data: {"delta":"lo"}

  data: [DONE]
  ```
- **Non-streaming** (`stream: false`) → `{ "text": "…" }` or `{ "error": {"code":N,"message":"…"} }`.

### `POST /v1/session/reset`
`{ "sessionId": "string" }` → `204`. Drops that session's ephemeral context.
Called by the app on sandbox switch / clear.

### `GET /v1/health`
Liveness, no auth.

## Auth — anonymous, account-free (App Attest)

No accounts, no email. The **key id is the identity**.

- **First request after key creation** carries the full attestation:
  - `X-Key-Id: <keyId>`
  - `X-Device-Attestation: <base64 App Attest attestation object>`
  The server verifies it against Apple's App Attest root, extracts the public key,
  and stores `{keyId → publicKey}`.
- **Subsequent requests**:
  - `X-Key-Id: <keyId>`
  - `X-Device-Assertion: <base64 assertion>` — signs `SHA256(request body)`.
  The server verifies the assertion against the stored public key and the body hash.
- **Replay protection**: the body should include a client nonce/timestamp; the
  assertion covers the body hash, so the nonce is bound. Reject stale/duplicate nonces.
- **Dev mode** (simulator / CI only, behind an explicit non-production flag):
  accept `Authorization: Bearer <devToken>` instead. The app uses this whenever
  `DCAppAttestService.isSupported == false`.

Status codes the client maps: `401` → unauthorized, `403` → attestation failed,
`429` → rate limited, `5xx`/other → server error.

## Privacy design (what the app can honestly claim)

- **Stateless / ephemeral**: per-`sessionId` context lives **only in RAM**,
  TTL-bounded (e.g. 30 min idle), dropped on `/v1/session/reset` or process exit.
  No prompts/responses written to disk.
- **Content-free logging**: log metadata only (hashed keyId, latency, status) —
  never payload bodies.
- **TLS 1.2+** required; reject cleartext. (Cert pinning is a future hardening.)
- The app sanitizes PII (`PIISanitizer`) **before** sending and records the
  sanitized payload + redaction count in the Privacy Ledger as
  `.privateComputeServer(endpoint:)`.

## Minimal reference implementation (sketch — separate build)

A single stateless service behind TLS (any language). Pseudocode:

```
POST /v1/generate:
  verify App Attest assertion over sha256(body)   # or dev bearer in dev mode → 401/403 on failure
  ctx = sessions.get(sessionId) or []             # in-RAM LRU, TTL
  prompt = buildPrompt(ctx, body.prompt)
  if body.stream:
     stream model deltas as `data: {"delta": "..."}` ; end with `data: [DONE]`
  else:
     return { "text": model.generate(prompt) }
  sessions.put(sessionId, ctx + turn)             # RAM only, never persisted

POST /v1/session/reset: sessions.evict(sessionId) -> 204
GET  /v1/health: 200
```

Real infra (model hosting, autoscaling, the App Attest verification library,
public-key storage, nonce replay cache) is out of scope here — this contract is
all the iOS client requires. For local end-to-end verification, expose the server
over a valid-cert HTTPS tunnel (e.g. `cloudflared`) since iOS ATS blocks cleartext.
```
