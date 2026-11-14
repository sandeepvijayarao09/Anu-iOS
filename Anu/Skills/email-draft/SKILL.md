---
name: email-draft
description: Opens a new email in the Mail app with the recipient, subject and body filled in, for the user to review and send.
---

# Email draft

Use this skill when the user asks to write or draft an email to an address and wants it ready to send.

## Steps

1. Write a short subject and body from what the user said. Don't invent facts, names or dates.
2. Call `run_intent` with `intent` "send_email" and `parameters` set to a JSON string such as
   `{"extra_email": "maya@example.com", "extra_subject": "Lunch on Friday", "extra_text": "Hi Maya, ..."}`.
3. The user is asked to approve, then Mail opens with the draft. Nothing is sent until they tap Send in Mail. Tell them that in one sentence.

## Examples

- "Draft an email to sam@example.com saying the report is late"
