# App Store compliance (audit of 13 November 2026)

This audit covers Anu for iOS/iPadOS (the `Anu` app and its four extensions: `AnuWidget`, `AnuShare`, `AnuWriting` and `AnuKeyboard`) and the `AnuMac` target. It was checked against Apple's rules as published on the audit date:

- the App Review Guidelines, last updated 16 October 2026;
- Apple's upcoming-requirements page;
- the privacy manifest and required-reason API documentation;
- the encryption export documentation;
- the Custom Keyboard and App Extension programming guides.

Each section lists the rule, the evidence in the code, what this audit changed, and what is left for the owner. Items marked **OWNER** can only be done in App Store Connect, the developer portal or a legal document.

Sources:
[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) ·
[Upcoming requirements](https://developer.apple.com/news/upcoming-requirements/) ·
[Required reason API](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api) ·
[Encryption export](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations) ·
[Guideline update, 16 Oct 2026](https://developer.apple.com/news?id=vvzx6cul) ·
[Updated age ratings](https://developer.apple.com/news/?id=ks775ehf)

## 1. Upload requirements (SDK, Xcode, minimum OS)

| Rule | Status |
|---|---|
| Since 28 April 2026, uploads must be built with Xcode 26 or later and an iOS 26 SDK | The project builds with Xcode 27.2 and the iOS 27.2 SDK. |
| Since 9 September 2026, uploads must target iOS 13 or later | Every iOS target has `IPHONEOS_DEPLOYMENT_TARGET = 17.0`. AnuMac uses `MACOSX_DEPLOYMENT_TARGET = 15.0`. |
| 2.5.1: phase out deprecated APIs | Fixed (see §5). |

**Note:** a Release build for the simulator that builds every architecture fails to link: the LiteRT-LM xcframework has no x86_64 simulator slice. Device archives (arm64) are not affected. To build Release for the simulator, pass `ONLY_ACTIVE_ARCH=YES` on Apple silicon.

**Note:** `GenerationOptions(samplingMode:)` (§5) is back-deployed to iOS 26, but the symbol exists only in the Xcode 27 SDK. Building with Xcode 26 now needs that one line reverted.

## 2. Privacy manifests and required-reason APIs

**Rule:** Apple has required manifests since 1 May 2024. Every bundle whose executable or dylib calls a required-reason API must declare an approved reason for it in its own `PrivacyInfo.xcprivacy`.

**How it was verified:** The Swift sources, `ThirdParty/LiteRTLM` and the SwiftPM checkouts were searched with grep. Then `nm -u` was run on every Mach-O in the built `Anu.app`.

| API category | Where it is used | Declared in | Reason |
|---|---|---|---|
| UserDefaults | `@AppStorage` / `UserDefaults.standard` in about 30 app files. No App Group suite. Not used in any extension. | Anu | CA92.1 |
| File timestamp | `SharedAudio.drain()` (`.creationDateKey`, App Group); `ModelDownloadStore.fileSize`; `stat`/`fstat`/`lstat` in `CLiteRTLM.framework` and the Swift packages (app container) | Anu | C617.1 |
| File timestamp | `SkillLibrary.addFromFile` (`attributesOfItem` on a SKILL.md chosen in the document picker) | Anu | 3B52.1 |
| File timestamp | `SharedAudio` is compiled into AnuShare (`NSURLCreationDateKey`) | AnuShare | C617.1 |
| System boot time | `ProcessInfo.systemUptime` (`SpeechRecognizer.nowMs`, speech endpointing); `mach_absolute_time` in `CLiteRTLM.framework` | Anu | 35F9.1 |
| Disk space | Not used anywhere | none | |
| Active keyboards | `activeInputModes` is not used, including in the keyboard | none | |

`CACurrentMediaTime` (LiveCameraView) is not a required-reason API.

**Data the app sends off the device (`NSPrivacyCollectedDataTypes`)**

Nothing is sent to the developer: there are no analytics, no crash SDK and no server. Two types are declared because a third party can keep the data after the request is served:

- **Other User Content**: the redacted text of a request, sent to Google Gemini with the user's own key, or to the user's private compute server. App Functionality; not linked; not tracking.
- **Search History**: web queries sent to Brave Search with the user's own key. App Functionality; not linked; not tracking.

Some destinations are not declared, because the user chooses and configures them and the developer has no relationship with the operator:

- MCP servers, REST APIs and A2A agents the user adds;
- the user's own Mac;
- Gmail, which is the user's own mail account.

They are disclosed in the app (§7).

**Changed in this audit**

- `Anu/PrivacyInfo.xcprivacy` now declares FileTimestamp (C617.1, 3B52.1), SystemBootTime (35F9.1) and the two collected data types. It used to declare only UserDefaults, with an empty collected-data list.
- New manifests:
  - `AnuShare/PrivacyInfo.xcprivacy` declares FileTimestamp C617.1.
  - `AnuKeyboard/`, `AnuWidget/` and `AnuWriting/` manifests declare no tracking, no collection and no required-reason APIs.
- `generate_xcodeproj.py` adds each extension's manifest to that target's Resources phase (`EXT_PRIVACY`, `ext_privacy_objects`, `ext_privacy_resource`).
- `DataEraserTests` checks the built app's manifest, so a change that drops a category fails the tests.

**OWNER**

- `CLiteRTLM.framework` (from the LiteRT-LM v0.13.0 release zip) ships no privacy manifest of its own. Its API use is declared in the app manifest, which is the usual fix for ITMS-91053. If App Store Connect still flags the framework, ask upstream for a `PrivacyInfo.xcprivacy` inside the framework, or repackage the xcframework with one.
- App Store Connect → App Privacy must match this manifest:
  - Data Not Collected by the developer.
  - "Other User Content" and "Search History": App Functionality, not linked to the user, not used for tracking.
  - Gemini is optional, but it is a third party that can keep data.

## 3. Info.plist usage strings

Every permission request was traced to its call site, and each string now says when and why the permission is used.

| Key | Requested at | Change |
|---|---|---|
| NSCameraUsageDescription | `CameraCaptureView`, `LiveCameraView` (`AVCaptureDevice.requestAccess`) | Made more specific |
| NSMicrophoneUsageDescription | `SpeechRecognizer`, `VoiceNoteRecorder` (`AVAudioApplication.requestRecordPermission`) | Made more specific |
| NSSpeechRecognitionUsageDescription | `SpeechRecognizer`, `VoiceNoteTranscriber` | **Corrected.** It said "on-device", but live dictation falls back to Apple's server when the language has no on-device model (`SpeechRecognizer.swift`, where `requiresOnDeviceRecognition` is set only when supported). |
| NSPhotoLibraryUsageDescription | `PhotoLibraryTool` count/recent (`.readWrite`) | Made more specific |
| NSPhotoLibraryAddUsageDescription | `PhotoLibraryTool` save | Saving now asks for `.addOnly` access instead of full library access, so the least access needed is requested. |
| NSContactsUsageDescription | `ContactsTool`, `ContactActionTool` | Made more specific |
| NSCalendarsFullAccessUsageDescription, NSRemindersFullAccessUsageDescription | `CalendarAccess` (`requestFullAccessToEvents` / `…Reminders`) | Made more specific |
| NSLocalNetworkUsageDescription | Your Mac, A2A agents | Unchanged, already accurate |
| NSAlarmKitUsageDescription | `SystemAlarmScheduler` | Unchanged |
| **NSFaceIDUsageDescription** | `VaultView` / `Vault` (`LAContext.evaluatePolicy(.deviceOwnerAuthentication)`) | **Added. It was missing.** iOS terminates an app that uses Face ID without this key, so the vault reveal would have crashed on Face ID devices. |

The app requests no location, Bluetooth, tracking (ATT), HealthKit, motion or media library access, and declares no strings for them. `DataEraserTests.testInfoPlistCarriesComplianceKeys` checks that the required strings are present and the unneeded ones are absent. The same strings are set on AnuMac.

## 4. Export compliance (`ITSAppUsesNonExemptEncryption`)

Anu uses only encryption that is built into Apple's operating system:

- HTTPS through URLSession, which the MCP SDK and swift-nio also use. There is no NIOSSL or BoringSSL: the shipped binaries contain no OpenSSL or BoringSSL symbols.
- CryptoKit AES-GCM to protect files on the device (`SecureFile`).
- SHA-256 hashing.
- The Keychain.
- App Attest.

There is no proprietary or custom encryption protocol. Apple's documentation treats encryption built into the OS as exempt from export documentation, so **`ITSAppUsesNonExemptEncryption = NO`** is now set for both Anu and AnuMac through `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption`. `DataEraserTests` checks the value.

**OWNER:** Exempt encryption can still require the annual self-classification report to the US BIS (EAR 740.17(b)(1)). The developer is responsible for filing it. When App Store Connect asks, answer "uses only exempt encryption".

## 5. Private and deprecated API (2.5.1)

The sources and ThirdParty were searched for these patterns: `dlsym`, `dlopen`, `NSClassFromString`, `NSSelectorFromString`, `performSelector`, `objc_msgSend`, method swizzling, `value(forKey: "_`, `@_spi`, `@_silgen_name`, PrivateFrameworks, and `_ModelDelegationIntent`.

- `JSSandbox`: `dlsym("JSContextGroupSetExecutionTimeLimit")` is compiled only under `#if DEBUG`. The Release path returns nil.
- `_ModelDelegationIntent` and the other underscore-prefixed AppIntents types appear in the SDK but are not used anywhere.
- `@_implementationOnly import` (MCP, LiteRTLM) hides third-party packages from Anu's module interface. It is not Apple private API. It produces compiler warnings that the attribute is deprecated without library evolution. Moving to `internal import` (SE-0409) is left for later, because the test target relies on not linking those packages.

Deprecations fixed:

- `@AssistantIntent(schema:)` is now `@AppIntent(schema:)` (renamed in the iOS 27 SDK; available from iOS 18). `.system.search` stays: its replacement, `.system.searchInApp`, exists only from iOS 27.
- `GenerationOptions(sampling:…)` is now `GenerationOptions(samplingMode:…)` in `ExtensionWritingEngine` (back-deployed to iOS 26).

The remaining warnings are Swift 6 concurrency diagnostics. They are not deprecations and do not affect review.

## 6. Keyboard extension (4.4.1 and the Custom Keyboard guide)

| Requirement | Evidence |
|---|---|
| Next-keyboard key | `KeyboardLayout.rows/pad(globe:)` adds `.globe` whenever `needsInputModeSwitchKey` is true; tapping it calls `advanceToNextInputMode()`. |
| Works without Full Access | Typing uses only `textDocumentProxy.insertText`. Apple's on-device model runs in the process. Only the hand-off to the app and the status file need Full Access. Both are behind `hasFullAccess`. |
| No AI and no reading in secure fields | `FieldPolicy.of` marks `isSecureTextEntry` and password, one-time-code and card `textContentType` fields as private: no AI, and no read even for capitals (`autoShift`). iOS also gives secure fields to the system keyboard. |
| Phone and number pads respected | `keyboardType` number, phone and decimal pads, and `tel` / `postal-code` content types, get a pad layout and no AI. |
| No keystroke collection | No dictionary, history or learning. The field is read only when an AI action is tapped, and is cleared in `viewWillDisappear`. The keyboard has no network code. |
| Doesn't launch other apps | No `openURL` in the extension. |
| Privacy explanation | Settings → Keyboard → Privacy (`KeyboardSettingsView`). |
| Privacy manifest | Added (§2). |

Nothing needed fixing.

Optional improvement: wire the globe key to `handleInputModeList(from:with:)` so that a long press shows the keyboard list. Apple recommends this but does not require it.

## 7. Third-party AI and data disclosure (5.1.2(i))

**Rule:** Disclose clearly where personal data is shared with third parties, including third-party AI, and get explicit permission before sharing it.

**Evidence:**

- Each destination is off until the user sets it up: a Gemini key, a private compute URL, pairing a Mac, adding an MCP or REST server, signing in to Gmail, or a Brave key.
- PII is redacted before cloud egress.
- `ApprovalCenter` makes any action that acts on the user's behalf wait for approval of the exact content.
- The Privacy Ledger logs every send.

**Changed in this audit:** A new **Settings → Where Your Data Goes** screen (`DataPrivacyViews.swift`) lists every destination, what is sent and when:

- this device;
- Gemini;
- private compute;
- your Mac;
- MCP, REST and agents;
- Gmail;
- Brave Search;
- model downloads.

The screen links to the ledger.

Consent before the first send: `Sources/Anu/Agent/AIShareConsent.swift` and `Sources/Anu/UI/AIShareConsentViews.swift`. A sheet names the provider (Google Gemini, or the user's private server) and what is sent; nothing goes until the user agrees; the choice is stored with its date and wording version and can be withdrawn in Settings → Privacy. Headless requests (Siri, Shortcuts) with no sheet on screen are refused. The user's own Mac and Apple Private Cloud Compute are not third-party AI and don't ask.

**OWNER**

- The privacy policy URL in App Store Connect must name Google Gemini and Brave Search, say what they receive, and state that Google's terms govern what Google keeps.
- In the App Review notes, explain that every cloud feature is opt-in and uses the user's own key.
- The Gmail restricted scopes need Google's OAuth verification before public release (`Docs/GMAIL_SETUP.md`).

## 8. Data deletion (5.1.1)

Anu has no accounts, so 5.1.1(v) (account deletion) does not apply. Even so, a user must be able to remove everything Anu stores.

**Changed in this audit:** **Settings → Delete All My Data** (`DeleteAllDataSection`, `DataEraser`).

What it removes:

- chats and sessions;
- memory;
- the privacy ledger and the activity log;
- the vault and every Keychain item under Anu's services (`com.anu.app`, `com.gemmaagent.app`, `com.anu.app.vault`, `com.anu.app.shared`), which covers saved keys, Gmail and MCP OAuth tokens, and the file-encryption keys;
- voice notes;
- added skills;
- workflows and notes;
- App Group hand-offs;
- settings (the UserDefaults domain);
- Spotlight items;
- scheduled reminders;
- cookies and the URL cache.

On iOS it empties the sandbox (Documents, Application Support, Caches, tmp, and the App Group container). It keeps two things:

- the downloaded model and its engine cache, which hold no personal data and are gigabytes to fetch again;
- alarms already handed to the Clock app.

The Mac app is not sandboxed, so its Documents folder is the user's own. There, only Anu's own files are removed (`DataEraser.knownDocuments` / `knownApplicationSupport`).

Objects in memory could write a stale copy back, so the erase leaves a marker. `AnuApp.init` runs the erase again before any store loads (`DataEraser.finishPendingErase`). A full-screen confirmation that can't be dismissed asks the user to close and reopen Anu.

The tests are in `DataEraserTests`.

## 9. Background execution (2.5.4)

The only background mode is `processing`, which runs `BGProcessingTask` `com.anu.app.memory.learn` (Memory v2 learning) with `requiresExternalPower = true`. There is no audio, location, VoIP or fetch mode. This complies.

The task identifier predates the bundle-ID change. Apple does not require it to match the bundle ID, so it was left unchanged.

## 10. Live Activities, AlarmKit, ATT, children

- **Live Activities:** one, for live talk behind other apps (`AnuWidget/LiveTalkLiveActivity.swift`, `NSSupportsLiveActivities` on the app target). It shows only the phase (Listening, Thinking, Speaking, Muted) with Mute and End, never what was said, and ends when live talk ends. The `audio` background mode is used only while live talk is on. AlarmKit alarms use the fixed alert presentation and need no Live Activity widget.
- **ATT:** there is no tracking, no IDFA and no AdSupport, so the app never asks. `NSPrivacyTracking` is false in every manifest.
- **Children and age rating, OWNER:**
  - Answer the age-rating questionnaire introduced in 2025. It was required from 31 January 2026 and covers AI assistants and chatbots.
  - Anu's chatbot is an open model with optional web search and Gemini. Expect 13+ or 16+ rather than 4+, depending on how the frequency of sensitive content is answered.
  - Watch for further descriptors announced for late 2026.
  - Do not target the Kids category.
- **1.2 (AI content):** image creation uses Apple's Image Playground, which has Apple's own safeguards. Anu creates no shared or public user-generated content.

## 10a. Third-party models in the app

- **Live camera detector:** `Anu/LiveDetector.mlmodelc`, Apple's Core ML build of YOLOv3 Tiny (`YOLOv3TinyInt8LUT.mlmodel`, 8,913,366 bytes, SHA-256 `cde8af2528d6eca1d1580fdd0f0147cb6613d40ba962656b5f683c65f571870e`), downloaded on 2026-11-13 from Apple's Core ML model gallery (`ml-assets.apple.com`) with the owner's approval. Authors Joseph Redmon and Ali Farhadi; its metadata points to Darknet (github.com/pjreddie/darknet), which its author released into the public domain. Runs on the device only; frames never leave the phone.
- **Gemma 4** (`Anu/gemma4e4b.litertlm`, when bundled) is under Google's Gemma terms; the downloadable builds come from Google AI Edge Gallery's allowlist.

## 11. App icon, launch screen, orientations, bundle IDs

- **App icon:** a single 1024×1024 universal iOS icon. **Fixed:** the PNG had an alpha channel (every pixel was opaque, but App Store Connect rejects any alpha channel in the large icon, ITMS-90717). It was re-encoded as opaque RGB with no visible change.
- **AnuMac:** the asset catalog has no macOS icon sizes. This doesn't matter while the Mac app is distributed outside the Mac App Store. **OWNER:** add macOS sizes, or an Icon Composer `.icon`, before Mac App Store distribution.
- **Launch screen:** `UILaunchScreen_Generation = YES`.
- **Orientations:** iPhone supports portrait and both landscapes. iPad supports all four, which iPad multitasking requires.
- **Bundle IDs:** `io.github.sandeepvijayarao09.anu`, with `.widget`, `.share`, `.writing`, `.keyboard`, `.tests` and `.uitests`. The App Group is `group.io.github.sandeepvijayarao09.anu`. AnuMac uses the base ID. All are consistent.

## 12. Entitlements

| Entitlement | Note |
|---|---|
| App Groups | Self-service in the developer portal. |
| `com.apple.developer.kernel.increased-memory-limit` | Self-service capability. |
| `com.apple.developer.devicecheck.appattest-environment = development` | App Store and TestFlight builds always use the production App Attest environment regardless of this value. |

**OWNER (Mac):** before Mac App Store submission, add App Sandbox, `network.client`, a Team-prefixed App Group and Hardened Runtime.

## Owner checklist

1. App Store Connect → App Privacy: match §2.
2. Answer the age-rating questionnaire (§10).
3. Answer the export compliance question as exempt (also set by the plist), and consider the annual BIS self-classification report (§4).
4. Privacy policy URL naming Gemini, Brave and Gmail (§7). Google OAuth verification for Gmail scopes.
5. App Review notes: every cloud feature is opt-in and uses the user's own key; the keyboard works without Full Access.
6. If ITMS-91053 names `CLiteRTLM.framework`, get a manifest into the framework itself (§2).
7. Mac App Store only: sandbox, icon sizes, notarization (§11, §12).
