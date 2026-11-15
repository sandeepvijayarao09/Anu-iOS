# Anu × Apple Siri / App Intents / Foundation Models — integration research

**As of:** 2026-11-12. **Ground truth:** Xcode 27.2 (27B52), iPhoneOS27.2.sdk, Swift 6.4.2.
**Method:** I read the `.swiftinterface` files for `FoundationModels`, `AppIntents`,
`_CoreSpotlight_FoundationModels`, `_Vision_FoundationModels`, `_FoundationModels_UIKit/SwiftUI` and
`VisualIntelligence`. I queried the toolchain's schema database
(`XcodeDefault.xctoolchain/usr/lib/AppIntentSchemas.framework/.../AppIntentSchemas.sqlite`) and
type-checked two throwaway probe files with
`xcrun --sdk iphoneos swiftc -typecheck -target arm64-apple-ios27.0`, which **both passed**. I then
checked Apple's documentation and the press.

**Source labels used below:**
- **[SDK]** means verified in the 27.2 SDK or the toolchain.
- **[Apple]** means Apple's documentation or developer pages.
- **[Report]** means press or third-party reporting.
- **[Unverified]** means an inference or claim I could not confirm.

---

## 1. Summary — what matters for Anu

1. **Apple's models can be Anu's Base and private-cloud tiers with almost no new plumbing.**
   - `SystemLanguageModel` and `PrivateCloudComputeLanguageModel` both conform to the public `LanguageModel` protocol [SDK], so one `LanguageModelSession` API covers both.
   - Gemma 4 (LiteRT-LM) can be wrapped as a third `LanguageModel` + `LanguageModelExecutor`. This type-checks [SDK].
   - Apple's own wrappers give Gemini the same shape: Firebase AI Logic `geminiLanguageModel(name:)`, currently a preview [Apple/Google].
   - **Anu's code uses none of this today.** There is no `import FoundationModels` anywhere in `Sources/`.
2. **Private Cloud Compute (PCC) is gated and not free-for-all.**
   - It needs a *managed entitlement* [Apple].
   - The developer must be in the **App Store Small Business Program** and have **under 2 M first-time downloads across all their apps**. If either stops being true, you have 6 months to migrate [Apple].
   - Each user gets a daily request quota [Apple, SDK `quotaUsage`]. "Expanded access … for a fee in the future" [Apple].
   - Context is 32K tokens (vs 4K on-device), with reasoning levels `.light/.moderate/.deep` [Apple, SDK].
   - **Apply for the entitlement now.** It is the long-lead item.
3. **There is no public way to *be* Siri's brain, or to replace Siri, outside Japan.**
   - Third-party apps reach Siri AI only by exposing actions (App Schemas / App Intents), entities (`IndexedEntity` / Spotlight) and on-screen content.
   - The "Siri Extensions" / model-delegation path (`_ModelDelegationIntent`, which covers system assistant, Writing Tools, Visual Intelligence, Image Playground and Shortcuts) exists in the 27.2 SDK. It is still marked `@_documentation(visibility: internal)` and is unannounced [SDK, Report]. Don't ship on it.
   - The only official "be the assistant" hook is `@AppIntent(schema: .assistant.activate)` (iOS 26.2). It works **only for the side button in Japan** and needs a side-button entitlement [SDK, Report].
4. **Anu's Siri surface needs a 27-era refresh.** Its schema search intent uses deprecated API:
   - `@AssistantIntent` has been renamed to `@AppIntent(schema:)`.
   - `.system.search` is deprecated in 27.0. Use `.system.searchInApp` [SDK, compiler warning confirmed].
   - Natural-language Siri AI routing now prefers schema-conforming intents. New 27.0 domains that fit Anu's existing features include `.reminders.createReminder`, `.calendar.createEvent` and `.notes.createNote` [SDK]. Each means Anu claims that role for its *own* data, so adopt them only where Anu owns the data.
5. **Siri AI's reach keeps growing, and so do its gaps.**
   - iOS 27.2 (shipped 2026-10-26) added Siri AI memory, five more languages, and a per-app "excluded apps" control [Report].
   - Siri AI is still unavailable in the EU and mainland China [Report].
   - Anu's differentiators (offline Gemma, EU, inspectable memory/receipts, MCP connectors) remain things Siri doesn't do. That supports the "standalone + alongside Siri" decision.

---

## 2. Foundation Models (SDK-verified signatures)

### 2.1 On-device model — `SystemLanguageModel`

| Symbol | Availability | Notes |
|---|---|---|
| `final class SystemLanguageModel : Sendable`, `static var default` | iOS 26.0 | `init(useCase: .general/.contentTagging, guardrails: .default/.permissiveContentTransformations)` |
| `availability` → `.available` / `.unavailable(.deviceNotEligible / .appleIntelligenceNotEnabled / .modelNotReady)` | iOS 26.0 | |
| `extension SystemLanguageModel : LanguageModel` (+ `Executor`) | **iOS 27.0** | Lets it be used through the generic API. |
| `contextSize: Int` | 26.0 (back-deployed; returns 4096 before 26.4) | Apple docs table: **4K** on-device. |
| `tokenCount(for:)` — prompt / instructions / tools / schema / transcript entries | iOS 26.4 | async throws |
| `variant: Variant`; `Variant.core3`, `Variant.coreAdvanced3`, `displayName` | iOS 27.0 | Which variant runs is device-dependent. |
| `Adapter` (custom LoRA adapters) | **deprecated 26.4, obsoleted 27.0** | You can no longer bring fine-tuned adapters to the on-device model. |
| `SystemLanguageModel.Error.assetsUnavailable` | iOS 27.0 | |
| watchOS | `SystemLanguageModel` **unavailable** on watchOS | PCC *is* available on watchOS 27. |

### 2.2 Private Cloud Compute — `PrivateCloudComputeLanguageModel`

```swift
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
final public class PrivateCloudComputeLanguageModel : Sendable, Observable, LanguageModel
  convenience public init()
  final public var availability: Availability   // .available | .unavailable(.deviceNotEligible | .systemNotReady)
  final public var isAvailable: Bool
  final public var quotaUsage: QuotaUsage       // status: .belowLimit(isApproachingLimit) | .limitReached; resetDate; limitIncreaseSuggestion?.show()
  nonisolated(nonsending) final public var contextSize: Int { get async throws }
  final public var supportedLanguages: Set<Locale.Language> { get async throws }
  final public func supportsLocale(_:) async throws -> Bool
  public enum Error { case networkFailure, quotaLimitReached(QuotaLimitReached /* resetDate, limitIncreaseSuggestion */), serviceUnavailable }
```

**Facts from Apple's documentation** ([Adding server-side intelligence with PCC](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute), [PrivateCloudComputeLanguageModel](https://developer.apple.com/documentation/foundationmodels/privatecloudcomputelanguagemodel)):
- 32K context and "stronger reasoning".
- Reasoning goes through `ContextOptions(reasoningLevel: .light | .moderate | .deep | .custom(String))`. Reasoning tokens consume context.
- **Usage limits:** unlimited on-device; "Limit per day" on PCC. Needs a network connection. Apple says to fall back to on-device on network failure.
- No API keys or user authentication needed.
- Apple's doc: "People can upgrade their iCloud+ subscription to get more access". **Conflict:** John Gruber reports iCloud+ gives *no* extra third-party quota ([Daring Fireball](https://daringfireball.net/linked/2026/06/13/pcc-severely-limited-third-party-developers)). Treat it as unresolved and test on-device.
- Xcode scheme option *Simulated Apple Foundation Models Availability* → "Approaching Quota Usage Limit" / "Quota Usage Limit Reached" lets you test quota UI.

**Eligibility and entitlement** ([developer.apple.com/private-cloud-compute](https://developer.apple.com/private-cloud-compute/)):
- **Requirements:**
  - (a) the developer is enrolled in the App Store Small Business Program;
  - (b) fewer than 2 M first-time downloads from *any* of the developer's apps;
  - (c) the "Private Cloud Compute entitlement" is assigned to the account.
- **Request:** [developer.apple.com/contact/request/private-cloud-compute](https://developer.apple.com/contact/request/private-cloud-compute/).
- **Cost:** "no cloud API cost". "Expanded access … will be available for a fee in the future."
- **Distribution:** TestFlight and ad hoc test installs don't count toward the 2 M. Exceeding the threshold or leaving the Small Business Program means you must migrate within 6 months.
- **Entitlement key string: [Unverified].** It appears neither on the public pages nor in the SDK. It will show up in the Developer portal capability list once granted.

### 2.3 Bring your own model — `LanguageModel` / `LanguageModelExecutor` (iOS 27.0)

```swift
public protocol LanguageModel : Sendable {
  associatedtype Executor : LanguageModelExecutor where Self == Self.Executor.Model
  var capabilities: LanguageModelCapabilities { get }          // [.vision, .guidedGeneration, .reasoning, .toolCalling]
  var executorConfiguration: Self.Executor.Configuration { get }
  @available(iOS 27.2) func supportsDataAttachmentType(_: UTType) async throws -> Bool   // default impl provided
  @available(iOS 27.2) func supportsDataEntryType(_: UTType) async throws -> Bool        // default impl provided
}
public protocol LanguageModelExecutor : Sendable {
  associatedtype Configuration : Hashable, Sendable
  associatedtype Model : LanguageModel
  init(configuration: Configuration) throws
  func prewarm(model: Model, transcript: Transcript)
  nonisolated(nonsending) func respond(to request: LanguageModelExecutorGenerationRequest,
                                       model: Model,
                                       streamingInto channel: LanguageModelExecutorGenerationChannel) async throws
}
// request: id, transcript, enabledToolDefinitions, schema: GenerationSchema?, generationOptions, contextOptions, metadata
// channel.send(.response(action: .appendText(_, tokenCount:)) | .reasoning(...) | .toolCalls(action: .toolCall(id:name:action: .appendArguments(_, tokenCount:))) | .data(...)[27.2])
// usage reporting: .updateUsage(input:output:)
```

**Session constructors:**
- `LanguageModelSession(model: some LanguageModel, tools: [any Tool] = [], instructions: Instructions? = nil)`.
- A `transcript:` variant.
- `LanguageModelSession(model:dynamicInstructions:history:)`.
- `LanguageModelSession(profile:history:)`.

**Probe result:** a Gemma-style `struct GemmaModel: LanguageModel` with its executor, used in a session with a `Tool`, **type-checks** against the iOS 27 SDK.

**How Apple frames it** ([WWDC26 session 339 "Bring an LLM provider to the Foundation Models framework"](https://developer.apple.com/videos/play/wwdc2026/339/)):
- Providers ship Swift packages.
- Apple mentions open-source Core AI and MLX conformers.
- Google and Anthropic packages are "soon" [Apple/Report].
- Firebase AI Logic (`firebase-ios-sdk` ≥ 12.19.0) already exposes `FirebaseAI.firebaseAI(backend: .googleAI()).geminiLanguageModel(name:)`. It is a **preview** with no SLA, and App Check is required ([Firebase docs](https://firebase.google.com/docs/ai-logic/apple-foundation-models-framework/get-started)).

### 2.4 Tools, options, structured output, errors

- **`Tool` protocol** (iOS 26): `Arguments: ConvertibleFromGeneratedContent` (use `@Generable`), `Output: PromptRepresentable`, `name`, `description`, `parameters`, `includesSchemaInInstructions`, `call(arguments:)`. A primitive `String`/`Int`/… as `Arguments` is explicitly unavailable.
- **`GenerationOptions`:** `samplingMode` (`.greedy`, `.random(top:seed:)`, `.random(probabilityThreshold:seed:)`), `temperature`, `maximumResponseTokens`, and `toolCallingMode: .allowed/.required/.disallowed` (27.0).
- **`ContextOptions`** (27.0): `includeSchemaInPrompt`, `reasoningLevel`.
- **`DynamicProfile` / `DynamicInstructions` builders** (27.0) are SwiftUI-like session configuration:
  - `.model(_:)` swaps the model per profile, which is a natural fit for Anu's tiering;
  - `.temperature`, `.reasoningLevel`, `.toolCallingMode`, `.historyTransform`;
  - event hooks `onPrompt`, `onResponse`, `onToolCall` and `onToolOutput`, which are useful for Anu's ToolBroker and receipts;
  - `@SessionProperty`.
- **`LanguageModelError`** (27.0, `@nonexhaustive`): `contextSizeExceeded(contextSize, tokenCount)`, `rateLimited(resetDate)`, `guardrailViolation`, `refusal`, `unsupportedCapability`, `unsupportedTranscriptContent`, `unsupportedGenerationGuide`, `unsupportedLanguageOrLocale`, `timeout`. The old `GenerationError` cases are deprecated in 27.0.
- **`TranscriptErrorHandlingPolicy`:** `.revertTranscript` / `.preserveTranscript`.
- **Attachments:**
  - images (27.0), e.g. `Attachment(UIImage)` in `_FoundationModels_UIKit`;
  - **data attachments (27.2)**, below.
- **System tools:**
  - `SpotlightSearchTool` (`_CoreSpotlight_FoundationModels`, iOS 27.0, not watchOS). Its sources are `.coreSpotlight` / `.files`, with a guide (`.complete`, `.focused(domain)`, `.dynamic`), a `ContactResolver`, `CustomStage` pipeline stages, and `searchResults` as an AsyncSequence.
  - `OCRTool` and `BarcodeReaderTool` (`_Vision_FoundationModels`, iOS 27.0).

---

## 3. Siri and App Intents — how a third-party assistant appears today

### 3.1 Surfaces that are officially available

| Surface | API | Status for Anu |
|---|---|---|
| **App Shortcuts** (voice phrases, Spotlight, Action button) | `AppShortcutsProvider`, `AppShortcut(intent:phrases:shortTitle:systemImageName:)`, `negativePhrases`, `shortcutTileColor` | Anu has 10, the max. The limit is enforced by `appintentsmetadataprocessor` (per Anu's own notes and Apple docs); the exact error string wasn't found in toolchain strings [Unverified]. |
| **App Schemas** (Siri AI natural-language actions) | `@AppIntent(schema:)`, `@AppEntity(schema:)`, `@AppEnum(schema:)`; the old `@AssistantIntent/@AssistantEntity/@AssistantEnum` are `deprecated, renamed:` | See 3.2 |
| **Entities in the semantic index** | `IndexedEntity` (`attributeSet`, `hideInSpotlight`), `IndexedEntityQuery.reindexEntities(for:indexDescription:)`, `@ComputedProperty/@DeferredProperty(indexingKey:)`, `CSSearchableItem.relatedAppEntityIdentifier`, `SyncableEntity` (27.0) | Anu indexes workflows as plain `CSSearchableItem`s (`Sources/Anu/Utilities/SpotlightIndexer.swift`). They aren't linked to entities. |
| **On-screen awareness** | `NSUserActivity` with an entity identifier, or view annotations via `appEntityIdentifier` | Not adopted. |
| **Long jobs** | `LongRunningIntent : ProgressReportingIntent` → `performBackgroundTask(options: [.requiresGPU], operation:)` (27.0) | This is the officially sanctioned way to run Gemma or PCC inference from an intent beyond the normal time budget. |
| **Inline UI** | `SnippetIntent` (26.0), `ShowsSnippetView` | Not adopted. |
| **Visual Intelligence** | `@AppIntent(schema: .visualIntelligence.semanticContentSearch)` (`ShowVisualSearchResultsInAppIntent`, iOS 26), `SemanticContentDescriptor` (VisualIntelligence.framework) | Optional. Apps return *their own* search results for a camera or screenshot query. |
| **Writing Tools** | Apps only *consume* Writing Tools in text views. There is no public provider API. The `writingTools.*` schemas in the schema database have visibility = 1, i.e. not exposed in Swift [SDK] | Anu's `WritingIntents` stay Shortcuts actions. |
| **Default assistant (side button)** | `@AppIntent(schema: .assistant.activate)` (`ActivateAssistantIntent`, iOS 26.2, iOS-only) plus a side-button entitlement | **Japan only** (Apple doc as quoted by [MacRumors](https://www.macrumors.com/2025/11/17/ios-26-2-iphone-users-japan-siri/), [9to5Mac](https://9to5mac.com/2025/11/17/iphone-replace-siri-side-button-japan-ios-26-2/)). The reported entitlement is `com.apple.developer.side-button-access.allow` [Report, Unverified]. Not EU as of today. |

### 3.2 App Schema domains in the 27.2 SDK

- **Schema-database domains** (34): notes, findMy, reminders, playbackControls, whiteboard, journal, messages, camera, audio, notifications, contacts, video, visualIntelligence, spreadsheet, wordProcessor, browser, writingTools, files, books, clock, presentation, maps, reader, phone, appLaunch, assistant, home, health, appStore, voiceMemos, system, calendar, photos, mail, imageGeneration.
- **Swift-exposed in `AppIntents`:**
  - 18.0: books, browser, camera, files, journal, mail, photos, presentation, reader, spreadsheet, system, whiteboard, wordProcessor.
  - 26.0: visualIntelligence.
  - 26.2: assistant.
  - **27.0: audio, calendar, clock, maps, messages, notes, phone, reminders.**
  - Not exposed (schema-database visibility 1): writingTools, imageGeneration, appLaunch, contacts, appStore, and others.

**Schemas relevant to Anu** [SDK]:
- **`.system`:**
  - `.search` (deprecated 27.0: "Use .system.searchInApp instead");
  - `.searchInApp` (`SystemSearchInAppIntent`, 27.0; parameter `criteria: StringSearchCriteria`; opens the app);
  - `.open` (`OpenIntent`, 27.0).
- **`.reminders`:** `.createReminder` (title, list: ListEntity?, note, …), `.updateReminder`, `.deleteReminders`, `.createList`, `.createSection`.
- **`.calendar`:** `.createEvent` (title, startDate, endDate?, location union place/address, calendar entity …), `.updateEvent`, `.deleteEvent`.
- **`.notes`:** `.createNote`, `.updateNote`, `.appendText`.
- **`.clock`:** alarm, timer and stopwatch intents.
- **`.mail`:** still only draft, send, reply, forward, archive, delete, update and open (`MailOpenDraft`, `MailOpenMessage`). There is **no search or read schema**, which reconfirms the earlier note.
- **`.messages`:** send, draft, edit, unsend, mark read. There is no read schema.

**"All-or-nothing", corrected.** The schema database has no per-domain all-or-nothing flag. Instead it defines **facets**: named groups of intents that must be adopted together.
- Mail Composing = create/update/send/save draft.
- Mail Replying / Forwarding = reply or forward + update/send/save draft.
- Message Sending = draft + send.
- Cancel Alarm = dismiss + update alarm.
- Start Navigation, Play Audio, Play Video and Install Application are one intent each.

WWDC26 session 240 says the same: "sendMessage also requires draftMessage" ([wwdcnotes summary](https://wwdcnotes.com/documentation/wwdc26-240-build-intelligent-siri-experiences-with-app-schemas/)). Reminders, calendar and notes intents can be adopted individually [SDK, inferred from the absence of facets].

No intent schema lists `_requiredEntitlements` [SDK]. So, apart from the Japan side-button case, schema adoption needs no special entitlement.

### 3.3 What is *not* officially possible

- **Replacing Siri's model** with Anu's, or registering as a Siri, Writing Tools, Visual Intelligence or Image Playground "model provider":
  - `_ModelDelegationIntent` / `@_ModelDelegationIntent` macro, `_ModelDelegationFeatures` (`.systemAssistant/.writingTools/.visualIntelligence/.imagePlayground/.shortcuts`), `_ModelDelegationConfiguration`, `IntentPrompt(text:files:)`, `responseStream.append(text:)`, `append(writingToolsOutput:)`, `enabledStatus`;
  - all are present in 27.2 but `@_documentation(visibility: internal)` [SDK];
  - press reports describe this as the hidden "Siri Extensions" system, not switched on ([TNW](https://thenextweb.com/news/apple-siri-extensions-third-party-ai-missing-wwdc), [iClarified](https://www.iclarified.com/101188/apple-has-built-a-framework-for-thirdparty-ai-models-in-siri-report)) [Report].
- **Reading Mail or Messages** content, or iterating Siri's personal context. There is no API.
- **Calling another app's intents** from Anu. No API: Siri and Shortcuts orchestrate (WWDC26 Q&A 8011) [Report via search].
- **MCP:** no MCP symbols in `AppIntents` or `FoundationModels` [SDK].
- **Custom on-device adapters:** `SystemLanguageModel.Adapter` is obsoleted in 27.0 [SDK].
- **Siri AI in the EU or China:** not available, so schema-driven Siri AI routing does nothing for EU users. Classic App Shortcuts still work [Report].

---

## 4. What's new since the 27.0-based notes (2026-09-27)

**Confirmed unchanged [SDK]:** PCC class and API, 32K (doc), reasoningLevel, quotaUsage, `LanguageModel`/`LanguageModelExecutor`, `Variant.core3/.coreAdvanced3`, `contextSize`, `tokenCount(for:)`, `ToolCallingMode`, the four capabilities, image attachments, `SpotlightSearchTool`, `IndexedEntity`, `LongRunningIntent`, `IndexedEntityQuery`, `_ModelDelegationIntent` (still internal), no MCP, `.mail.*` write-only.

**New in 27.2 [SDK]:**
- **FoundationModels, arbitrary typed data in transcripts:**
  - `Transcript.DataAttachment(contentType: UTType, content: Data, metadata: GeneratedContent)`;
  - `Transcript.Attachment.data(_)`;
  - `Transcript.DataEntry` plus `Transcript.Entry.data(_)`;
  - protocols `DataAttachmentRepresentable` and `DataEntryRepresentable`;
  - `Attachment<Content>.init(_:)` where `Content: DataAttachmentRepresentable`;
  - `LanguageModel.supportsDataAttachmentType(_:)` / `supportsDataEntryType(_:)`, default implementations provided;
  - executor events `LanguageModelExecutorGenerationChannel.Event.data(entryID:action:)` with `DataEntry.Action.update(contentType:content:metadata:)`.
  - **Effect:** PDFs, audio and other files can go through a session to models that declare support. For a custom Gemma model this is opt-in: it requires the new protocol methods.
- **AppIntents:**
  - `IntentValueRepresentation(importing:)`-only initialisers for IntentPerson-style values;
  - new `IntentParameter` convenience inits for `_IntentValueRepresentable` values;
  - `AssistantSchemaEnum.caseDisplayRepresentations` default.
  - Minor; nothing Siri-architectural.
- **Xcode 27.2 release notes** contain no Foundation Models, App Intents or Siri items ([release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_2-release-notes)).

**Corrections and clarifications to the old notes:**
- `@AssistantIntent(schema:)` → **deprecated, renamed `@AppIntent(schema:)`** (also Entity and Enum). `AssistantSchema(s)` → `AppSchema`. (Deprecated in this SDK; it may already have been so in 27.0.)
- `.system.search` is **deprecated in 27.0** → `.system.searchInApp`. The old "only fitting schema" note stands, with the new name.
- New `.system.open` (`OpenIntent`) schema.
- "Mail/Clock/Messages all-or-nothing" → really **facet groups** (§3.2), and *not* all of Clock.
- **New domains in 27.0** (calendar, reminders, notes, clock, messages, phone, maps, audio) are directly relevant to Anu's existing daily-action intents.
- `.assistant.activate` (26.2, Japan side button) was missing from the old notes.
- "App Toolbox": the term does not appear in the SDK or the WWDC26 session pages I found [Unverified]. Apple's wording is "App Schemas" and "App Schema domains".
- On-device context: Apple's doc table now says **4K**. The earlier "4K–8K" figure is unverified.
- PCC "free under 2M downloads" also requires **Small Business Program enrolment**, and the 2M counts **all** of the developer's apps [Apple].

**Platform and news since 27.0 [Report]:**
- iOS 27.2 shipped 2026-10-26 ([TNW](https://thenextweb.com/news/ios-27-2-siri-ai-memory-languages-excluded-apps-eu), [TidBITS](https://tidbits.com/?p=76093)):
  - Siri AI memory of past conversations;
  - personal context extended to Messages photos, Calendar invitees, voicemail, and Safari history and Reading List;
  - languages: FR, JA, KO, PT, ES;
  - **Settings page to exclude apps from Siri, Search and suggestions.** Anu's intents can be switched off by the user.
- EU and China are still excluded.
- MacRumors (2026-11-09, via [LDS](https://letsdatascience.com/news/apple-says-extra-private-cloud-compute-usage-will-cost-a-fee-f5d3f0bf)) says paid expanded PCC access is likely bundled into iCloud+, with no date.

---

## 5. Gap analysis against Anu's code (branch `feature/trust-core`)

| Area | Anu today | Gap |
|---|---|---|
| Foundation Models | **No `import FoundationModels`** anywhere in `Sources/` or `Tests/`. `ARCHITECTURE.md` §Models says "Core ML and Apple Foundation Models were removed" and lists the tiers as "Planned". **`Docs/ANDROID_PARITY.md` line 20 claims "Apple Foundation Models, Private Cloud Compute … Implemented". That is inaccurate for iOS.** | Everything in §6 steps 1–3. |
| "Private Compute" | `Sources/Anu/API/PrivateComputeClient.swift` + `PrivateComputeModels.swift` + `Tools/BuiltinTools/EscalateToPrivateCloudTool.swift` + `UI/PrivateCloudView.swift`. This is Anu's **own operator-hosted HTTPS server with App Attest** (`Utilities/DeviceAttestation.swift`), *not* Apple PCC. | Naming clash with Apple PCC. Decide whether Apple PCC replaces or sits beside it. |
| Model abstraction | `protocol LocalLanguageModel` (`Models/GemmaModel.swift`): string prompt in, `AsyncStream<String>` out, with the Gemma chat template applied by the orchestrator (`AgentOrchestrator.completeHeadless`, `GemmaChatTemplate.format`). Routing goes through `CloudProvider.resolved()` (`Agent/CloudProvider.swift`: auto / private / gemini) and `RoutingDecision` (`answerLocally / callTool / escalateToGemini`). | No tier for Apple on-device or PCC. Tool calling is a hand-rolled text protocol (`Utilities/StreamParser.swift`, `GemmaPromptParser.swift`) rather than `Tool` / `@Generable`. |
| Deployment target | `IPHONEOS_DEPLOYMENT_TARGET = 17.0` (`generate_xcodeproj.py`) | All FM work needs `if #available(iOS 26/27, *)` gates, which is fine. |
| Entitlements | `Anu/Anu.entitlements`: app group + App Attest only | PCC entitlement missing. |
| App Shortcuts | `App/AskAnuIntent.swift` `AnuShortcuts`: 10/10 used (TodaysSchedule, NextEvent, AskAnu, AskAnuInline, StartVoice, RunWorkflow, Summarize, Rewrite, CreateReminder, AddCalendarEvent) | Full. Adding one means retiring one. |
| Schema intent | `App/AssistantSearchIntent.swift`: `@AssistantIntent(schema: .system.search) struct SearchAnuIntent: ShowInAppSearchResultsIntent` | Deprecated macro + deprecated schema → migrate to `@AppIntent(schema: .system.searchInApp)` (§6 step 4). |
| Daily actions | `App/DailyActionIntents.swift`: `CreateReminderIntent`, `SetTimerIntent`, `SetAlarmIntent`, `AddCalendarEventIntent`. These are plain `AppIntent`s that write to EventKit/system. `App/CalendarQueryIntents.swift`: TodaysSchedule / NextEvent. | Siri AI already does these natively with the system apps. Schema-conforming them (`.reminders.createReminder`, `.calendar.createEvent`, `.clock.*`) would advertise Anu as a reminders/calendar/clock *app*. Not recommended unless Anu owns those stores; see §7. |
| Writing | `App/WritingIntents.swift`: Summarize / Rewrite / Proofread as `ReturnsValue<String>` intents | Fine as Shortcuts actions. No provider API exists. Could run on the Apple on-device model for speed (step 2). |
| Entities / Spotlight | `Workflows/WorkflowEntity.swift` (`AppEntity` + `EntityQuery`), `Utilities/SpotlightIndexer.swift` (raw `CSSearchableItem`), `AnuApp.swift` handles `CSSearchableItemActionType` | Not `IndexedEntity`. Conversations and memory notes aren't entities, so Siri AI can't reason over them. No on-screen annotation. |
| Inline answers | `AskAnuInlineIntent` with a blocking `completeHeadless` (25 s timeout, 256 tokens) | Should be a `LongRunningIntent` (and/or `SnippetIntent`) for Gemma or PCC paths. |
| Widget / Share | `AnuWidget/AnuWidget.swift`, `AnuShare/ShareViewController.swift` | No Apple-Intelligence-specific gaps. A share extension could hand files to a 27.2 `DataAttachment` later. |

---

## 6. Recommended integration plan (ordered)

**Step 0 — Paperwork. Do it now; it has the longest lead time. Effort: hours, then waiting.**
- **User:**
  - confirm enrolment in the **App Store Small Business Program**;
  - confirm the developer account's apps total under 2 M first-time downloads;
  - request the **Private Cloud Compute entitlement** at <https://developer.apple.com/contact/request/private-cloud-compute/>;
  - once granted, enable the capability on the `com.anu.app` App ID in Certificates, Identifiers & Profiles and regenerate the provisioning profiles.
- Decide whether to also apply for the Japan side-button entitlement (step 8). Only worth it if Japan is a target market.

**Step 1 — Add a FoundationModels tier behind Anu's model abstraction. Effort: about 3–5 days.**
- New `AppleModelProvider` (gated `@available(iOS 26.0, *)` for on-device and `iOS 27.0` for PCC) wrapping `LanguageModelSession`:
  - **Base tier:** `SystemLanguageModel.default`. Check `availability` and `supportsLocale()`. Use `tokenCount(for:)` against `contextSize` (4K) to decide when to escalate.
  - **Private-cloud tier:** `PrivateCloudComputeLanguageModel()`. Use `quotaUsage` for a quota pill in the UI, `limitIncreaseSuggestion?.show()`, and `ContextOptions(reasoningLevel: .moderate)` as the default. Catch `.quotaLimitReached` → fall to Gemma (offline/EU) → Gemini last.
- Extend `CloudProvider` / `RoutingDecision` with `.appleOnDevice` and `.applePCC`. Keep the existing operator "Private Compute" server as a separate, clearly named option (rename it in the UI to avoid the PCC clash).
- Add Privacy Ledger entries per tier: on-device, PCC (Apple, attested, no retention), Gemini (third party).
- Update `ARCHITECTURE.md` and correct `Docs/ANDROID_PARITY.md` line 20.
- **APIs:** `SystemLanguageModel`, `PrivateCloudComputeLanguageModel`, `LanguageModelSession(model:tools:instructions:)`, `GenerationOptions`, `ContextOptions`, `LanguageModelError`, `PrivateCloudComputeLanguageModel.Error`.

**Step 2 — Move tool calling for Apple tiers onto native `Tool` / `@Generable`. Effort: about 1 week.**
- Adapt Anu's `ToolRegistry` tools into `FoundationModels.Tool` shims whose `call` routes through Anu's **ToolBroker / approval / receipt** path.
- Use `DynamicProfile.onToolCall/onToolOutput` hooks for audit, and `toolCallingMode: .required` for forced-tool turns.
- This removes the fragile text tool-call parsing on Apple tiers. Gemma's lenient parser stays for Gemma, per the memory note about Gemma 4 dialects.
- Run the Writing intents (Summarize/Rewrite/Proofread) on the on-device model when available, because it is faster and quota-free.

**Step 3 (optional, after step 2) — Wrap Gemma (LiteRT-LM) as a `LanguageModel`. Effort: about 1–2 weeks.**
- `struct GemmaLiteRTModel: LanguageModel` + `GemmaExecutor: LanguageModelExecutor` translates `LanguageModelExecutorGenerationRequest.transcript` and `enabledToolDefinitions` into Gemma's native `<|tool_call>` template, and streams `.response` / `.toolCalls` events.
- `capabilities` = `[.toolCalling, .vision]` (add `.guidedGeneration` only if constrained decoding is implemented).
- Benefit: one session and tool stack for all tiers, with `DynamicProfile.model(_:)` switching per turn. Risk: the executor's whole-transcript-per-call design versus LiteRT-LM's KV-cache reuse. Measure prefill cost.
- Gemini could likewise move to Firebase AI Logic's `geminiLanguageModel` (preview; adds Firebase + App Check dependencies). Not recommended until GA.

**Step 4 — Modernise the Siri schema surface. Effort: about 0.5 day.**
- Replace `@AssistantIntent(schema: .system.search)` with `@AppIntent(schema: .system.searchInApp)` inside `if #available`-safe code. The type-check probe passes with `criteria: StringSearchCriteria`.
- Keep the `.system.search` variant for iOS 18.2–26.x if needed (two intents, availability-gated).
- Validate with a real build, since `appintentsmetadataprocessor` checks schema shape, and with the new AppIntentsTesting framework.

**Step 5 — Make Anu's content visible to Siri AI and Spotlight. Effort: about 3–4 days.**
- Make conversations, memory notes and workflows `IndexedEntity` (with `@ComputedProperty(indexingKey:)` on title/summary/date) and add `IndexedEntityQuery.reindexEntities`.
- Link the existing `CSSearchableItem`s with `relatedAppEntityIdentifier`.
- Respect privacy: index only titles or summaries the user opts into, and keep `hideInSpotlight` for vault-tainted items.
- Add on-screen awareness: an `NSUserActivity` + entity identifier on the open conversation, so "Siri, summarise this" can target Anu content.

**Step 6 — Long-running and inline intents. Effort: about 2 days.**
- Make `AskAnuInlineIntent` and the Writing intents `LongRunningIntent` using `performBackgroundTask(options: [.requiresGPU])` for Gemma.
- Optionally add a `SnippetIntent` to show the answer card instead of only speaking it.
- Removes the 25 s / 256-token compromise in `completeHeadless`.

**Step 7 — Rationalise the 10 App Shortcuts. Effort: about 0.5 day.**
- Siri AI already performs reminder, timer, alarm and calendar actions natively; Anu duplicating them adds little.
- Consider retiring `CreateReminderIntent`/`AddCalendarEventIntent` phrases (keep the intents in Shortcuts) to free slots for Anu-unique actions, e.g. "Ask Anu offline", "Run workflow" or "What did Anu do today" (receipts).
- Do **not** adopt `.reminders.*` / `.calendar.*` / `.clock.*` schemas unless Anu becomes the owner of that data (§7).

**Step 8 (conditional) — Japan default-assistant. Effort: about 1 day plus approval.**
- `@AppIntent(schema: .assistant.activate)` intent that opens voice mode (reuse `StartVoiceIntent` logic), plus the side-button entitlement.
- Only pays off for users in Japan with a Japan Apple Account. Track whether the EU gets it under the DMA.

**Step 9 — App Store Connect / review hygiene. Effort: about 1 day.**
- Guideline **5.1.2(i)** (since Nov 2025) requires disclosure and consent before sending personal data to a *third-party* AI (Gemini, MCP servers) ([TechCrunch](https://techcrunch.com/2025/11/13/apples-new-app-review-guidelines-clamp-down-on-apps-sharing-personal-data-with-third-party-ai)).
- Anu's existing approval sheet and ledger cover most of this. Add an explicit first-use consent for Gemini.
- Update App Privacy labels for PCC, which is Apple-processed: not "third-party", but still describe it.
- Re-read the live guideline text before submission [Unverified: no 2026 revision found].

**Do not do:** build on `_ModelDelegationIntent` or any `_`-prefixed / internal-visibility API.

---

## 7. Open questions and risks

1. **PCC eligibility can be lost.** If any of the developer's apps passes 2 M downloads, or the account leaves the Small Business Program, PCC must be replaced within 6 months. There is no paid tier yet. Keep Gemma and Gemini as real fallbacks, not dead code.
2. **PCC quota size is undisclosed and per user.** The iCloud+ effect is contradictory between Apple's doc and Gruber [Unverified]. Design so the Base tier and Gemma carry most traffic.
3. **PCC entitlement key and approval latency** are unknown [Unverified].
4. **Schema overreach.** Adopting `.reminders`/`.calendar`/`.notes` schemas tells Siri AI that Anu *is* such an app. Siri may route "add a reminder" to Anu instead of Reminders, and App Review may question it. Unclear policy [Unverified].
5. **Siri Extensions** may launch later (possibly with an entitlement) and would let Anu's models serve Siri, Writing Tools and so on. Watch WWDC27 / iOS 27.x notes. The API shape in the SDK may change.
6. **EU:** Siri AI and most Apple Intelligence surfaces are off in the EU [Report]. Check `SystemLanguageModel` / PCC availability for EU devices on real hardware; the docs say availability depends on region [Unverified for EU specifically]. Gemma remains the EU tier.
7. **Excluded apps (27.2):** users can cut Anu off from Siri and Search. Intents must degrade gracefully.
8. **Custom-model executor performance:** re-sending the whole transcript per call may hurt LiteRT-LM prefill on long chats. Prototype before committing to step 3.
9. **Firebase Gemini `LanguageModel`** is a preview with no SLA and adds Firebase + App Check dependencies.
10. **Metadata-processor validation:** `@AppIntent(schema: .system.searchInApp)` and `.assistant.activate` type-check, but schema conformance is enforced at build time by `appintentsmetadataprocessor`. Not yet verified with a full Anu build.

---

## Appendix — verification artefacts (not in repo)

- **Probe files:** `/private/tmp/claude-501/-Users-sandeepvijayarao--claude-spares-spare-PcvkQf/d80d4766-87a0-40fd-8b3e-66a5b815c727/scratchpad/probe.swift` and `probe2.swift`.
  - `probe.swift`: custom `LanguageModel`/executor, PCC session with tools, `GenerationOptions(toolCallingMode:)`, `ContextOptions(reasoningLevel:)`, quota error handling, 27.2 `DataAttachment`, `SpotlightSearchTool`, `@AppIntent(schema: .system.search)`. It type-checked, with one warning: `.system.search` is deprecated → `.system.searchInApp`.
  - `probe2.swift`: `@AppIntent(schema: .system.searchInApp)` and `@AppIntent(schema: .assistant.activate)` both type-check cleanly.
- **Schema database copy:** `/private/tmp/claude-501/-Users-sandeepvijayarao--claude-spares-spare-PcvkQf/d80d4766-87a0-40fd-8b3e-66a5b815c727/scratchpad/db/s.sqlite`. Tables: `domainSchema`, `intentSchema`, `facetSchema`, etc.
- **Sources:**
  - [developer.apple.com/private-cloud-compute](https://developer.apple.com/private-cloud-compute/)
  - [PCC article](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute)
  - [WWDC26 339](https://developer.apple.com/videos/play/wwdc2026/339/)
  - [WWDC26 240](https://developer.apple.com/videos/play/wwdc2026/240)
  - [Xcode 27.2 notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_2-release-notes)
  - [Firebase AI Logic + FM](https://firebase.google.com/docs/ai-logic/apple-foundation-models-framework/get-started)
  - Press links inline above.
