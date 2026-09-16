import XCTest
@testable import Anu

/// Measured-accuracy evaluation of the on-device task classifier — the
/// dual-llm-system methodology applied to Anu's router.
/// All cases are distinct from the classifier's training seeds.
@MainActor
final class ClassifierEvalTests: XCTestCase {

    private static let evalSet: [(String, TaskType)] = [
        // casual chat
        ("hey! long time no see", .casualChat),
        ("good evening, how was your day", .casualChat),
        ("haha that's hilarious", .casualChat),
        ("I'm feeling a bit tired today", .casualChat),
        ("you're pretty smart you know", .casualChat),
        ("what should we talk about", .casualChat),
        ("happy friday!!", .casualChat),
        ("tell me a joke", .casualChat),
        ("do you ever get bored", .casualChat),
        ("I just got back from a run", .casualChat),

        // math
        ("what's 144 divided by 12", .math),
        ("calculate the tip on an $86 bill at 20%", .math),
        ("how much is 7 factorial", .math),
        ("what is 3.5 * 240", .math),
        ("compute 18% of 950", .math),
        ("if I save $250 a month how much is that per year", .math),
        ("square root of 4096", .math),
        ("what's 2^16", .math),
        ("convert 98.6 fahrenheit to celsius", .math),
        ("add up 34, 78, and 122", .math),

        // web info
        ("what's the latest on the election", .webInfo),
        ("current temperature in boston", .webInfo),
        ("search for reviews of the new macbook", .webInfo),
        ("what's trending on tech twitter today", .webInfo),
        ("look up flight prices to tokyo", .webInfo),
        ("did the lakers win last night", .webInfo),
        ("what's the stock price of apple right now", .webInfo),
        ("find news about the fed rate decision", .webInfo),
        ("what movies are out this weekend", .webInfo),
        ("latest update on the spacex launch", .webInfo),

        // code gen
        ("write a function that checks if a string is a palindrome", .codeGen),
        ("how do I parse JSON in swift", .codeGen),
        ("fix this null pointer exception", .codeGen),
        ("write a sql query to find duplicate rows", .codeGen),
        ("implement binary search in python", .codeGen),
        ("what's wrong with this for loop", .codeGen),
        ("write a regex that matches phone numbers", .codeGen),
        ("create a bash script to backup a folder", .codeGen),
        ("refactor this function to be async", .codeGen),
        ("debug why my api call returns 401", .codeGen),

        // long writing
        ("write a poem about the ocean", .longWriting),
        ("draft a resignation letter", .longWriting),
        ("compose a birthday message for my mom", .longWriting),
        ("write a product description for a coffee mug", .longWriting),
        ("summarize the plot of hamlet in three paragraphs", .longWriting),
        ("translate this email into french", .longWriting),
        ("write a short story about a robot learning to paint", .longWriting),
        ("draft talking points for my presentation", .longWriting),
        ("write an introduction for my thesis", .longWriting),
        ("help me write my wedding speech", .longWriting),

        // general QA
        ("why do cats purr", .generalQA),
        ("what causes inflation", .generalQA),
        ("how does a refrigerator work", .generalQA),
        ("what's the difference between a virus and bacteria", .generalQA),
        ("who painted the mona lisa", .generalQA),
        ("explain quantum entanglement simply", .generalQA),
        ("what does the liver do", .generalQA),
        ("how do planes stay in the air", .generalQA),
        ("what is the tallest mountain in the world", .generalQA),
        ("why is the sea salty", .generalQA),
    ]

    func testClassifierAccuracyMeetsFloor() {
        var correct = 0
        var confusions: [String] = []
        var perClass: [TaskType: (right: Int, total: Int)] = [:]

        for (text, expected) in Self.evalSet {
            let predicted = TaskClassifier.shared.classify(text).type
            var entry = perClass[expected] ?? (0, 0)
            entry.total += 1
            if predicted == expected {
                correct += 1
                entry.right += 1
            } else {
                confusions.append("'\(text)' → \(predicted.rawValue) (expected \(expected.rawValue))")
            }
            perClass[expected] = entry
        }

        let accuracy = Double(correct) / Double(Self.evalSet.count)
        print("══════ TASK CLASSIFIER EVAL ══════")
        print(String(format: "Overall accuracy: %.1f%% (%d/%d)", accuracy * 100, correct, Self.evalSet.count))
        for (type, stat) in perClass.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            print(String(format: "  %-13@ %d/%d", type.rawValue as NSString, stat.right, stat.total))
        }
        if !confusions.isEmpty {
            print("Misclassifications:")
            confusions.forEach { print("  \($0)") }
        }

        XCTAssertGreaterThanOrEqual(accuracy, 0.70,
            "classifier accuracy regressed below the 70% floor")
    }

    /// End-to-end "calls the larger model" decision: classification → routing.
    /// With a cloud provider configured, the heuristic escalates heavy
    /// generation (codeGen / longWriting) to the larger cloud model and keeps
    /// everything else on-device. We derive the expectation from the same labels
    /// and measure two things that matter for the escalation path:
    ///   • recall — of the heavy tasks, how many actually reach the larger model
    ///   • specificity — of the simple tasks, how many are correctly kept local
    /// (i.e. NOT sent to the cloud needlessly — a privacy/latency/cost concern).
    func testEscalationRoutingMeetsFloor() {
        var escTotal = 0, escHit = 0
        var localTotal = 0, localFalse = 0
        var notes: [String] = []

        for (text, expectedType) in Self.evalSet {
            let task = TaskClassifier.shared.classify(text)
            let route = ModelClassifier.route(task: task, cloudAvailable: true, webSearchAvailable: false)
            let didEscalate = route == .cloudEscalate
            let shouldEscalate = expectedType == .codeGen || expectedType == .longWriting

            if shouldEscalate {
                escTotal += 1
                if didEscalate { escHit += 1 } else {
                    notes.append("missed escalation: '\(text)' → \(route.displayName)")
                }
            } else {
                localTotal += 1
                if didEscalate {
                    localFalse += 1
                    notes.append("needless escalation: '\(text)' → cloud")
                }
            }
        }

        let recall = Double(escHit) / Double(max(escTotal, 1))
        let specificity = Double(localTotal - localFalse) / Double(max(localTotal, 1))
        print("══════ ESCALATION ROUTING EVAL (cloud configured) ══════")
        print(String(format: "Escalation recall: %.1f%% (%d/%d) — heavy tasks that reach the larger model",
                     recall * 100, escHit, escTotal))
        print(String(format: "Local specificity: %.1f%% (%d/%d) — simple tasks kept on-device",
                     specificity * 100, localTotal - localFalse, localTotal))
        if !notes.isEmpty {
            print("Routing notes:")
            notes.forEach { print("  \($0)") }
        }

        // Loose floors — the NLEmbedding asset can fail to load in the test host
        // (keyword-only fallback), so don't tighten these into flakiness.
        XCTAssertGreaterThanOrEqual(recall, 0.80,
            "too few heavy tasks escalate to the larger model")
        XCTAssertGreaterThanOrEqual(specificity, 0.80,
            "too many simple tasks are needlessly escalated to the cloud")
    }

    /// Privacy invariant: with NO cloud provider configured, the heuristic must
    /// never route anything to the larger cloud model — not even heavy
    /// generation. Nothing leaves the device unless the user opted in by
    /// configuring a provider. Asserted across the whole eval set (any single
    /// `.cloudEscalate` here is a privacy regression).
    func testNeverEscalatesWithoutCloudProvider() {
        var leaked: [String] = []
        for (text, _) in Self.evalSet {
            let task = TaskClassifier.shared.classify(text)
            let route = ModelClassifier.route(task: task, cloudAvailable: false, webSearchAvailable: false)
            if route == .cloudEscalate { leaked.append(text) }
        }
        XCTAssertTrue(leaked.isEmpty,
            "routed to the larger cloud model with no provider configured: \(leaked)")
    }

    // MARK: - Daily-life action routing (consumer tasks & actions)

    /// Everyday ACTION utterances that must reach a tool-capable path, and
    /// conversational controls that must not. Distinct from the seeds.
    private static let actionSet: [(String, Bool)] = [
        // actions → must reach the agent/tool path
        ("remind me to call the dentist tomorrow", true),
        ("add buy milk to my reminders", true),
        ("schedule a dentist appointment friday at 3pm", true),
        ("am I free tomorrow afternoon", true),
        ("what's John's phone number", true),
        ("find Sarah's email address", true),
        ("what time is it", true),
        ("set a timer for 10 minutes", true),
        ("set an alarm for 6:30 am", true),
        ("wake me up at 7 tomorrow", true),
        ("text mom I'll be late", true),
        ("send a message to Alex", true),
        ("email my boss the report", true),
        ("call dad", true),
        ("phone the pharmacy", true),
        ("navigate home", true),
        ("directions to the airport", true),
        ("find coffee shops near me", true),
        ("play some jazz", true),
        ("pause the music", true),
        ("open spotify", true),
        ("launch instagram", true),
        ("run my morning routine", true),
        ("start my focus shortcut", true),
        // conversational / adversarial → must stay on chat
        ("hey how's it going", false),
        ("tell me about the roman empire", false),
        ("let's play a game of twenty questions", false),
        ("I'm open to any suggestions", false),
        ("what would you call a baby penguin", false),
        ("do you prefer phone calls or texting", false),
        ("what's a good keyboard shortcut to copy", false),
        ("I have a packed daily routine", false),
    ]

    /// Replicates the orchestrator's routing decision (classify → route →
    /// chat→agent escape hatch) for a non-image, non-fast, non-smart turn.
    private func effectiveRoute(_ text: String, cloud: Bool) -> ModelRoute {
        let task = TaskClassifier.shared.classify(text)
        var route = ModelClassifier.route(task: task, cloudAvailable: cloud, webSearchAvailable: false)
        if route == .onDeviceChat, ModelClassifier.needsDeviceTool(text) { route = .onDeviceAgent }
        return route
    }

    /// Floor-guarded: everyday actions must reach a tool-capable path, and
    /// conversation must stay on chat. Guards against the #1 daily-life failure
    /// mode — talking about an action instead of doing it.
    func testDailyActionRoutingMeetsFloor() {
        var actHit = 0, actTotal = 0, chatOK = 0, chatTotal = 0
        var notes: [String] = []
        for (text, shouldAct) in Self.actionSet {
            let reached = effectiveRoute(text, cloud: false) == .onDeviceAgent
            if shouldAct {
                actTotal += 1
                if reached { actHit += 1 } else { notes.append("no-tool: '\(text)'") }
            } else {
                chatTotal += 1
                if !reached { chatOK += 1 } else { notes.append("over-routed: '\(text)'") }
            }
        }
        let coverage = Double(actHit) / Double(actTotal)
        let chatCorrect = Double(chatOK) / Double(chatTotal)
        print("══════ DAILY-LIFE ACTION ROUTING ══════")
        print(String(format: "coverage %.1f%% (%d/%d) | chat %.1f%% (%d/%d)",
                     coverage * 100, actHit, actTotal, chatCorrect * 100, chatOK, chatTotal))
        notes.forEach { print("  \($0)") }
        XCTAssertGreaterThanOrEqual(coverage, 0.90, "too many everyday actions never reach a tool")
        XCTAssertGreaterThanOrEqual(chatCorrect, 0.90, "too much conversation pulled onto the tool path")
    }

    /// Offline-first: with NO cloud provider configured, every everyday action
    /// still reaches the on-device agent path (never cloud) — the common
    /// consumer tasks work fully offline, reinforcing the privacy-first thesis.
    func testEverydayActionsWorkOffline() {
        var leakedToCloud: [String] = []
        var unreached: [String] = []
        for (text, shouldAct) in Self.actionSet where shouldAct {
            let route = effectiveRoute(text, cloud: false)   // offline: no provider
            if route == .cloudEscalate { leakedToCloud.append(text) }
            if route != .onDeviceAgent { unreached.append(text) }
        }
        XCTAssertTrue(leakedToCloud.isEmpty, "everyday action needed the cloud while offline: \(leakedToCloud)")
        XCTAssertLessThanOrEqual(Double(unreached.count) / Double(Self.actionSet.filter { $0.1 }.count), 0.10,
            "actions that didn't reach the on-device tool path offline: \(unreached)")
    }
}
