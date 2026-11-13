# On-device test checklist

Everything in `Docs/ANDROID_PARITY.md` passes its unit tests and UI tests in the simulator, but none of it has run on an iPhone. This list covers what only a real device can show. Tick each item, or note what happened, then I'll fix what fails and mark the tracker rows **Verified**.

Device: iPhone 18 Pro (iPhone19,2). Build: `feature/trust-core`.

Before you start: Settings → Privacy & Security → Developer Mode on; trust the developer certificate in Settings → General → VPN & Device Management the first time.

## 1. Install and first launch
- [ ] Anu installs and opens without crashing.
- [ ] Settings → On-device Model lists Gemma 4; downloading one works (Wi-Fi), and it loads.
- [ ] Ask "What's the capital of France?" → an answer streams. The caption under it opens **About this answer** with real numbers (not "about").

## 2. Speed and thinking (rows 6–8, 24)
- [ ] Model page → **Test speed**: note the tokens/s here: ______
- [ ] Settings → Performance → **Think before answering** on; ask a reasoning question → "Thought it through" appears collapsed under the answer and expands.
- [ ] Settings → Performance → **Prompt lab**: Run a template, then Stop mid-answer.

## 3. Vault and storage (rows 1–2)
- [ ] Enter a Gemini key (if you have one) → Settings → Vault shows it, "Sent only to generativelanguage.googleapis.com".
- [ ] Vault → the item → **Show** asks for Face ID, then shows the value; leaving the app hides it.
- [ ] Copy, wait 60 s, paste elsewhere → the clipboard is empty.

## 4. Memory (rows 3–5)
- [ ] Say "My sister Priya's birthday is 12 March" in a chat, wait 2 minutes or tap Memory → **Learn now** → the fact appears with its source.
- [ ] Ask "When is Priya's birthday?" in a new chat → answered from memory.
- [ ] Correct and delete a fact in the Memory screen.
- [ ] Leave the phone charging overnight → next day, did facts from earlier chats appear? (background learning)

## 5. Phone controls and Direct tier (rows 16, 17, 23)
- [ ] "flashlight on" / "flashlight off" → the torch changes; the answer says "On device · no model needed".
- [ ] "brightness 30%" → the screen dims.
- [ ] "set an alarm for 7am" → AlarmKit asks permission the first time; the alarm appears in the Clock app's alarms and **rings through silent mode**.
- [ ] "set a timer for 1 minute" → it rings.
- [ ] "remind me to call the bank at 5pm", then "cancel the bank reminder" → asks before deleting.
- [ ] "call Mom" (or a real contact) → approval sheet, then the phone dials.
- [ ] "navigate to the nearest coffee shop" → Maps opens with directions.
- [ ] "turn the volume up" → says iPhone doesn't allow it and names Control Center.
- [ ] Optional: with Low Power Mode on and battery under 15%, the trace says "Kept short to save battery".

## 6. Voice (rows 12, 13, 25)
- [ ] "+" → **Voice Note**, record 10 seconds, Send → the words appear; About says which engine wrote it down (Gemma, SpeechTranscriber or SFSpeech).
- [ ] Share a voice memo from the Voice Memos app into Anu → it waits above the composer as a voice note.
- [ ] Voice mode: ask a question → Anu starts speaking the first sentence before the answer finishes.
- [ ] Voice mode: talk over Anu while it speaks → it stops and listens. **(Key risk: echo cancellation may not work. Note whether it stops by itself from its own voice, or never stops.)**
- [ ] Pull out headphones while Anu speaks → it stops.
- [ ] Settings → **Hey Anu while Anu is open** on → with Anu open, say "Hey Anu, what time is it?" → voice mode opens and answers.

## 7. Photos, PDFs, camera (rows 14, 15, 22)
- [ ] Attach 4 photos and ask about them → one answer covering all four. Try a 5th → "up to 4 photos".
- [ ] Take a screenshot of a text with a one-time code, attach it, ask "what's in this?" → the code is blacked out / masked in the answer.
- [ ] "+" → PDF, pick a long PDF (10+ pages), ask for a summary → "Reading … page N of M", then an answer.
- [ ] "+" → **Live Camera**: boxes appear on people, pets and text; note the fps shown: ______
- [ ] Live Camera → "where's the exit" with a sign in view → the sign's box highlights.
- [ ] Live Camera → **Ask Anu about this** → an answer about the frozen frame.
- [ ] After 5 minutes in Live Camera, does the phone get hot? Does fps drop?

## 8. Writing and keyboard (rows 20, 21)
- [ ] In Notes, select text → Share → **Rewrite with Anu** → pick "More formal" → preview → Replace (or Copy if Notes doesn't accept it).
- [ ] Settings → General → Keyboard → Keyboards → Add **Anu**; allow Full Access.
- [ ] In Messages, type with the Anu keyboard; tap **Fix grammar** and **Emoji** on the AI strip.
- [ ] In a password field, the AI strip is hidden.
- [ ] Without Full Access: typing still works, and the strip explains what it needs.

## 9. Skills, Gmail, Mac, A2A (rows 9–11, 18, 19)
- [ ] "What's the SHA-256 of hello world?" → loads the calculate-hash skill and answers `b94d27b9…`.
- [ ] Gmail (needs your Google OAuth client ID, see `Docs/GMAIL_SETUP.md`): sign in, "find my last email from …", draft a reply, send → asks first.
- [ ] Your Mac: on the Mac run `python3 Scripts/mac-brain.py` (needs Ollama), pair from Settings → Your Mac, ask something big → "your Mac" in About. Note whether it times out at 30 s with a large model.
- [ ] A2A (optional): on the Mac run `python3 Scripts/dev-mock-a2a.py`, add it in Connectors → Agents on your network, ask it something → approval sheet first.

## 10. Siri and extensions
- [ ] "Hey Siri, ask Anu what's on my calendar today" → answers.
- [ ] The home-screen widget shows workflows and runs one.

## What to send back
For each failure: the item, what happened, and a screenshot or screen recording if you can. Crash? Settings → Privacy & Security → Analytics & Improvements → Analytics Data → the newest `Anu-…` file.
