import Foundation
import EventKit

/// Create or list calendar events via EventKit. Requires Calendars access
/// (NSCalendarsFullAccessUsageDescription). Denied access returns a graceful
/// message.
struct CalendarTool: Tool {
    let name = "calendar"
    let description = "Manage the user's calendar. action 'create' needs 'title' and 'start' (e.g. '2026-06-13 12:00'), optional 'end'; action 'list' returns events in the next 7 days."

    var parameters: JSONSchema? {
        .object(
            description: "Calendar parameters",
            properties: [
                "action": .string(description: "create or list", enumValues: ["create", "list"]),
                "title": .string(description: "Event title (required for create)"),
                "start": .string(description: "Start date/time (required for create), e.g. '2026-06-13 12:00'"),
                "end": .string(description: "Optional end date/time; defaults to one hour after start"),
            ],
            required: ["action"]
        )
    }

    func execute(arguments: JSONValue) async throws -> String {
        let action = (arguments["action"]?.stringValue ?? "list").lowercased()
        guard action == "create" || action == "list" else {
            throw ToolError.invalidArgument("action", expected: "'create' or 'list'")
        }
        var newTitle: String?
        var startDate: Date?
        if action == "create" {
            guard let title = arguments["title"]?.stringValue, !title.isEmpty else {
                throw ToolError.missingArgument("title")
            }
            guard let startStr = arguments["start"]?.stringValue,
                  let start = ToolDateParsing.parse(startStr) else {
                throw ToolError.invalidArgument("start", expected: "a date/time like '2026-06-13 12:00'")
            }
            newTitle = title
            startDate = start
        }

        let store = EKEventStore()
        let granted: Bool
        do { granted = try await store.requestFullAccessToEvents() }
        catch { return "Couldn't access Calendar: \(error.localizedDescription)" }
        guard granted else {
            return "Calendar access not granted. The user can enable it in Settings → Privacy → Calendars."
        }

        switch action {
        case "create":
            let event = EKEvent(eventStore: store)
            event.title = newTitle!
            event.startDate = startDate!
            if let endStr = arguments["end"]?.stringValue, let end = ToolDateParsing.parse(endStr) {
                event.endDate = end
            } else {
                event.endDate = startDate!.addingTimeInterval(3600)
            }
            event.calendar = store.defaultCalendarForNewEvents
            do { try store.save(event, span: .thisEvent, commit: true) }
            catch { return "Failed to save event: \(error.localizedDescription)" }
            let f = DateFormatter()
            f.dateStyle = .medium; f.timeStyle = .short
            return "Event created: \"\(newTitle!)\" starting \(f.string(from: startDate!))"

        default: // "list"
            let now = Date()
            let weekLater = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now
            let predicate = store.predicateForEvents(withStart: now, end: weekLater, calendars: nil)
            let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
            guard !events.isEmpty else { return "No events in the next 7 days." }
            let f = DateFormatter()
            f.dateStyle = .medium; f.timeStyle = .short
            let lines = events.prefix(10).map { "• \($0.title ?? "(untitled)") — \(f.string(from: $0.startDate))" }
            return "Upcoming events:\n" + lines.joined(separator: "\n")
        }
    }
}
