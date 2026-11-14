import SwiftUI
import EventKit

/// Today's calendar and reminders from EventKit (the same shared store the
/// calendar and reminders tools use). Asks for access the first time.
struct EventKitBriefSource: DailyBriefCalendarSource {
    func events(on day: Date, calendar: Calendar) async -> Result<[DailyBrief.Event], BriefSourceProblem> {
        let access = CalendarAccess.shared
        if let problem = await access.ensureEventAccess() { return .failure(BriefSourceProblem(message: problem)) }
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return .success([]) }
        let events = access.events(from: start, to: end).map {
            DailyBrief.Event(title: $0.title ?? "Untitled", start: $0.startDate, end: $0.endDate,
                             allDay: $0.isAllDay, location: $0.location.flatMap { $0.isEmpty ? nil : $0 })
        }
        return .success(events)
    }

    func reminders(dueBy day: Date, calendar: Calendar) async -> Result<[DailyBrief.Reminder], BriefSourceProblem> {
        let access = CalendarAccess.shared
        if let problem = await access.ensureReminderAccess() { return .failure(BriefSourceProblem(message: problem)) }
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return .success([]) }
        let store = access.store
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: nil)
        let titlesAndDue: [(String, Date?)] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { found in
                cont.resume(returning: (found ?? []).map { ($0.title ?? "Untitled", $0.dueDateComponents.flatMap { calendar.date(from: $0) }) })
            }
        }
        let reminders = titlesAndDue
            .map { DailyBrief.Reminder(title: $0.0, due: $0.1, overdue: ($0.1 ?? start) < start) }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        return .success(reminders)
    }
}

/// The brief page's state: gathers on the phone, then (when the on-device
/// model is ready) asks it once to write the brief up.
@MainActor
final class DailyBriefModel: ObservableObject {
    @Published private(set) var brief: DailyBrief?
    @Published private(set) var summary: String?
    /// "Written on this phone by Gemma 4", or why the plain summary is shown.
    @Published private(set) var caption: String?
    @Published private(set) var gathering = false
    @Published private(set) var writing = false
    @Published var settings = DailyBriefSettings.load()
    @Published var notice: String?

    private let source: any DailyBriefCalendarSource
    init(source: any DailyBriefCalendarSource = EventKitBriefSource()) {
        self.source = source
    }

    func refresh(now: Date = Date()) async {
        gathering = true
        let calendar = Calendar.current
        let brief = await DailyBriefGatherer.gather(
            day: now, calendar: calendar, source: source,
            memory: { titles in
                let store = MemoryStore.shared
                let relevant = titles.isEmpty ? [] : store.relevant(for: titles.joined(separator: ", "), limit: DailyBrief.maxRemembered)
                return DailyBriefGatherer.remembered(startingToday: store.shown, relevant: relevant, day: now, calendar: calendar)
            },
            notes: { NoteStore.shared.all.map(\.title) })
        self.brief = brief
        summary = DailyBriefText.summary(brief, calendar: calendar)
        caption = nil
        gathering = false
        await write(brief, calendar: calendar)
    }

    /// One on-device model call; the plain summary stays when it can't run.
    private func write(_ brief: DailyBrief, calendar: Calendar) async {
        let orchestrator = AgentOrchestrator.shared
        guard !brief.isEmpty else { return }
        guard orchestrator.modelLoadState == .ready else {
            caption = "Written without a model: the on-device model isn't ready."
            return
        }
        writing = true
        defer { writing = false }
        var config = GenerationConfig.deterministic
        config.maxNewTokens = DailyBriefWriter.maxTokens
        let written = await DailyBriefWriter.write(brief, calendar: calendar) { prompt in
            try await orchestrator.sideGeneration(prompt: prompt, config: config).text
        }
        if let written {
            summary = written
            caption = "Written on this device by \(orchestrator.model.modelName). Nothing left the device."
        } else {
            caption = orchestrator.isThinking ? "Anu is answering in the chat, so this is the plain summary."
                : "The on-device model couldn't write it up, so this is the plain summary."
        }
    }

    func saveSettings() async {
        settings.save()
        #if canImport(UserNotifications)
        let ok = await DailyBriefScheduler.sync(settings, center: SystemDailyBriefNotificationCenter())
        notice = ok ? nil : "Allow Anu's notifications in Settings to get the brief each morning."
        #endif
    }
}

/// The Daily Brief: today's calendar, reminders, what Anu remembers that
/// bears on today, and the newest notes, with the morning notification's time.
struct DailyBriefView: View {
    @StateObject private var model = DailyBriefModel()
    var onClose: (() -> Void)?

    var body: some View {
        List {
            Section {
                if model.gathering && model.brief == nil {
                    ProgressView("Gathering your day…")
                } else if let summary = model.summary {
                    Text(summary)
                        .font(.anuBody)
                        .accessibilityIdentifier("briefSummary")
                    if model.writing {
                        Label("Writing it up on this device…", systemImage: "sparkles").font(.anuMeta).foregroundStyle(.secondary)
                    } else if let caption = model.caption {
                        Text(caption).font(.anuMeta).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(model.brief.map { DailyBriefText.headline($0) } ?? "Today")
            }

            if let brief = model.brief {
                Section("Calendar") {
                    if brief.events.isEmpty { Text("Nothing today").foregroundStyle(.secondary) }
                    ForEach(Array(brief.events.enumerated()), id: \.offset) { _, event in
                        Label(DailyBriefText.line(event), systemImage: "calendar")
                    }
                }
                if !brief.reminders.isEmpty {
                    Section("Reminders") {
                        ForEach(Array(brief.reminders.enumerated()), id: \.offset) { _, reminder in
                            Label(DailyBriefText.line(reminder), systemImage: reminder.overdue ? "exclamationmark.circle" : "checklist")
                        }
                    }
                }
                if !brief.remembered.isEmpty {
                    Section("Remembered") {
                        ForEach(brief.remembered, id: \.self) { Label($0, systemImage: "brain.head.profile") }
                    }
                }
                if !brief.notes.isEmpty {
                    Section("Newest notes") {
                        ForEach(brief.notes, id: \.self) { Label($0, systemImage: "note.text") }
                    }
                }
                if !brief.problems.isEmpty {
                    Section {
                        ForEach(brief.problems, id: \.self) { Text($0).font(.anuMeta).foregroundStyle(.secondary) }
                    }
                }
            }

            Section {
                Toggle("Morning brief", isOn: $model.settings.enabled)
                    .accessibilityIdentifier("briefToggle")
                DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .disabled(!model.settings.enabled)
                if let notice = model.notice {
                    Text(notice).font(.anuMeta).foregroundStyle(.red)
                }
            } footer: {
                Text("A notification each morning says your brief is ready; tapping it makes the brief then, on this device. iOS doesn't let apps run the model at a set time in the background, so it's never made unattended. The notification never shows what's in it.")
            }
        }
        .navigationTitle("Daily Brief")
        .toolbar {
            ToolbarItem(placement: .anuTrailing) {
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh")
                    .disabled(model.gathering || model.writing)
            }
            if let onClose {
                ToolbarItem(placement: .cancellationAction) { Button("Done", action: onClose) }
            }
        }
        .task { await model.refresh() }
        .onChange(of: model.settings) { _, _ in Task { await model.saveSettings() } }
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(from: model.settings.trigger) ?? Date() },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                model.settings.hour = parts.hour ?? 7
                model.settings.minute = parts.minute ?? 30
            })
    }
}
