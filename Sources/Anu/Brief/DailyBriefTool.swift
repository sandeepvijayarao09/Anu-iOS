import Foundation

/// The Daily Brief from chat: "brief me", "what's my day look like", or the
/// model asking for it. A read through the Tool Broker, so it gets a receipt
/// and an audit entry like any other tool. Gathers exactly what the brief
/// page shows (today's events, reminders due, relevant facts, newest notes)
/// and returns it as text; the Direct tier shows that text, and on the agent
/// path the model writes it up.
struct DailyBriefTool: Tool {
    let name = "daily_brief"
    let description = "Today's brief for the user: their calendar, reminders due, what Anu remembers that bears on today, and their newest notes. Use it when they ask about their day."
    let parameters: JSONSchema? = nil

    var source: any DailyBriefCalendarSource = EventKitBriefSource()
    var now: @Sendable () -> Date = Date.init

    func describe(_ arguments: JSONValue) -> String { "Gather today's brief" }

    func execute(arguments: JSONValue) async throws -> String {
        let day = now()
        let calendar = Calendar.current
        let brief = await DailyBriefGatherer.gather(
            day: day, calendar: calendar, source: source,
            memory: { titles in
                let store = MemoryStore.shared
                let relevant = titles.isEmpty ? []
                    : store.relevant(for: titles.joined(separator: ", "), limit: DailyBrief.maxRemembered)
                return DailyBriefGatherer.remembered(startingToday: store.shown, relevant: relevant,
                                                     day: day, calendar: calendar)
            },
            notes: { NoteStore.shared.all.map(\.title) })
        var text = DailyBriefText.full(brief, calendar: calendar)
        if !brief.problems.isEmpty {
            text += "\n\n" + brief.problems.joined(separator: "\n")
        }
        return text
    }
}
