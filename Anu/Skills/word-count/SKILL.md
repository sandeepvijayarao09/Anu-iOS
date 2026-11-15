---
name: word-count
description: Counts the words, characters, sentences and lines in a piece of text, and estimates its reading time.
---

# Word count

Use this skill when the user asks how many words or characters a text has, or how long it takes to read.

## Steps

1. Call `run_js` with `skill_name` "word-count", `script_name` "index.js" and `data` set to a JSON string such as `{"text": "..."}` holding the user's text exactly.
2. The script answers `{"result": {"words": …, "characters": …, "charactersWithoutSpaces": …, "sentences": …, "lines": …, "readingMinutes": …}}`. Reply with the counts the user asked for.

## Examples

- "How many words are in this paragraph?"
- "Count the characters in my bio"
