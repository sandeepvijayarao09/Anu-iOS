# Your Mac as Anu's top model, and agents on your network

Ported from Anu for Android (ADR-113 `brain:ollama`, ADR-105 `connector:a2a`).

## Your Mac (Ollama)

Anu can hand big tasks (long writing, code, multi-step reasoning) to a larger
Gemma on your own Mac instead of Gemini. The request crosses your Wi-Fi, so it
is treated like the cloud: personal details are redacted by the same sanitizer,
the request is recorded in the Privacy Ledger with your Mac as the destination,
and photos, voice notes and documents stay on the phone. Tools are never run on
the Mac's say-so: any it proposes are reported, not run.

There are two ways to connect.

**1. Straight to Ollama over your network (simplest, no auth).**

```sh
ollama pull gemma4:26b        # or gemma4:e4b on a Mac with less memory
OLLAMA_HOST=0.0.0.0 ollama serve
```

In Anu: Settings → Your Mac → address `192.168.1.20:11434` (your Mac's Wi-Fi
address; `ipconfig getifaddr en0`), Save, Test connection, pick the model.
This is plain HTTP, so Anu allows it only to a local-network address (private
IPs, `.local` names, unqualified names) and never sends a secret over it.
Anyone on the same Wi-Fi can reach an Ollama bound to `0.0.0.0`; use this at
home, not on shared Wi-Fi.

**2. Through `Scripts/mac-brain.py` (HTTPS + token).**

```sh
ollama pull gemma4:26b
python3 Scripts/mac-brain.py            # phone on the same Wi-Fi
python3 Scripts/mac-brain.py --simulator   # the iOS Simulator on this Mac
```

Ollama stays on the Mac's `127.0.0.1`. The gateway listens on port 11435 over
HTTPS with its own certificate and answers only `POST /api/chat` and
`GET /anu/ping`, only with the bearer token; it sets the model, its context
(32K by default) and `keep_alive`, and logs sizes, never content. It prints a
pairing code, `anu-mac://<address>:11435?pin=<sha-256>&token=<token>`. Paste it
into Settings → Your Mac → Pairing code → Pair: Anu then trusts exactly that
certificate (by its SHA-256) for that host only, and the token goes into the
vault, bound to that host and to the Mac client alone.

Choosing the provider: Settings → Private Compute → Provider. In Automatic, the
order is your private server, then your Mac, then Gemini.

Limits: a tool call times out after 30 seconds (the Tool Broker's limit), so a
slow model or a cold load (20 s for 26B) can time out; keep the model warm or
use `gemma4:e4b`.

## Agents on your network (A2A)

Settings → Connectors → Agents on your network → add an agent's address. Anu
reads its card at `/.well-known/agent-card.json` (or the older
`/.well-known/agent.json`) and offers it to the model as a tool,
`a2a_<name>`. Every message to an agent waits for you to approve the exact
words (you may edit them), is recorded in the Privacy Ledger, and the answer,
written by another program, marks the request as tainted so later actions ask
first. Anu is only a client; nothing on the network can call into the phone.

To try it, run the made-up Home Lab agent:

```sh
python3 Scripts/dev-mock-a2a.py --host 127.0.0.1   # Simulator; use the Mac's LAN IP for a phone
```

Add `http://127.0.0.1:8768/`, then ask "Ask the Home Lab agent what the
temperature is".
