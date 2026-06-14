import XCTest
@testable import GemmaAgent

/// Measured-accuracy evaluation of the on-device task classifier — the
/// dual-llm-system methodology applied to GemmaAgent's router.
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
}
