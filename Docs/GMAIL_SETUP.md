# Connecting Gmail (one-time setup)

Anu for iOS reaches Gmail through Google's REST API, signed in with OAuth for an installed app: a Google sign-in sheet (`ASWebAuthenticationSession`), PKCE, and a redirect back to Anu. Anu for Android does the same through Google Play services ([its GMAIL_SETUP.md](https://github.com/sandeepvijayarao09) is the model for this page).

- **No client ID or secret ships in the app.** You create an OAuth client in your own Google Cloud project and paste its client ID into Anu. iOS clients have no client secret.
- **Anu never sees your password.** Google's own page asks for it.
- **Tokens live only in Anu's Vault.** The access token can be sent only to `gmail.googleapis.com`, the refresh token only to `oauth2.googleapis.com`, and only by Anu's Gmail connector. You can see them, and every use, under Settings → Vault.

You do this setup yourself, because it's your Google account. It takes about 10 minutes.

## 1. Create a Google Cloud project and turn on the Gmail API

1. Open <https://console.cloud.google.com/> and create a project, for example "Anu personal".
2. Go to **APIs & Services → Library**, search for **Gmail API**, and click **Enable**.

## 2. Set up the consent screen in testing mode

1. Go to **Google Auth Platform** (formerly the OAuth consent screen).
2. Choose **External** as the user type.
3. Fill in the app name ("Anu") and your email.
4. Under **Audience**, keep the publishing status as **Testing**, and add **your own Gmail address** as a test user.
5. Under **Data access**, add these scopes — the same three Anu for Android asks for:
   - `https://www.googleapis.com/auth/gmail.readonly`, to search and read;
   - `https://www.googleapis.com/auth/gmail.compose`, to save drafts;
   - `https://www.googleapis.com/auth/gmail.send`, to send, always after your approval in Anu.

   Google marks `gmail.readonly` and `gmail.compose` as restricted. That's fine in testing mode, which allows up to 100 test users with no verification.

   Why not `gmail.modify`? It also lets an app archive, label and trash mail, which Anu doesn't do. Three narrow scopes ask for less.

## 3. Create the iOS OAuth client

1. Go to **Credentials → Create credentials → OAuth client ID**.
2. Set **Application type** to **iOS**.
3. Set **Bundle ID** to Anu's bundle identifier (the `PRODUCT_BUNDLE_IDENTIFIER` in `generate_xcodeproj.py`, `com.anu.app` unless you changed it). The Mac app can use the same client.
4. Click **Create** and copy the **Client ID**. It looks like `1234567890-abc123def456.apps.googleusercontent.com`.

There is no client secret to copy, and no URL scheme to add to Info.plist: Anu redirects to the client ID reversed (`com.googleusercontent.apps.1234567890-abc123def456:/oauth2redirect`), which Google allows for iOS clients, and the sign-in sheet catches that redirect itself.

## 4. Sign in

1. In Anu, go to **Settings → Connectors → Gmail**.
2. Paste the client ID and tap **Sign in with Google**.
3. Pick your account and allow access. Google may warn that the app isn't verified; that's your own testing-mode project, so choose **Continue**.

The screen then shows **Signed in as** your address. Try, for example, "Anything from Maya in my inbox this week?"

**Sign out** revokes the grant at Google and deletes both tokens from the Vault.

## Troubleshooting

| What you see | Likely cause |
|---|---|
| "That doesn't look like an iOS OAuth client ID" | You pasted a Web or Android client ID, or the project number only |
| Google says `redirect_uri_mismatch` or `invalid_request` | The client isn't the **iOS** type, or its bundle ID doesn't match Anu's |
| The consent page says "Access blocked" | Your account isn't a test user |
| Signed in, but searches fail with 403 | The Gmail API isn't enabled, or a scope is missing from the consent screen |
| Anu asks you to sign in again after about a week | Google limits how long testing-mode grants for restricted scopes last. Sign in again in Settings |

## What Anu does with Gmail

- **Email tools are offered only when you ask about email** (the AI Email skill): `gmail_search`, `gmail_read_thread`, `gmail_create_draft` and `gmail_send`, with contacts and calendar lookups.
- **Reads run without asking.** Email is written by other people, so it's treated as untrusted: after Anu reads mail in a turn, any change it wants to make needs your approval.
- **Drafts stay in your mailbox.** Once mail has been read in the turn, they need approval too.
- **Sending always shows you the exact message:** recipients, subject and body. You can edit the subject and body; the recipients can't be changed on the sheet. Nothing is sent until you approve it.
- **Every request Anu makes to Google is in Settings → Privacy → Ledger:** sign-in, refresh, searches, reads, drafts and sends, as the method, path and size — never a token.
