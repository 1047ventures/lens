import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Time

/// A Zoom call or calendar event that looks like time spent on the project. Suggested, never added on its own.
private struct TimeSuggestion: Identifiable {
    let id: String          // the source, e.g. "zoom:<id>"
    let title: String
    let date: Date
    let hours: Double
    let kind: TimeKind
    let from: String        // "Zoom call", "Calendar"
}

/// Hours on one project: the timer, time added by hand, suggestions from Zoom and the calendar, and totals.
struct ProjectTimePanel: View {
    let project: Project
    let books: ProjectBooks
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var logins: ConnectionStore
    @State private var kind: TimeKind?
    @State private var editing: TimeEntryDraft?
    @State private var showAll = false
    @State private var events: [LensCalendarEvent] = []

    private var timerKind: TimeKind { kind ?? TimeKind.guess(for: project.stage) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ColorLabel("Time", Palette.gold)
            timerRow
            totals
            suggestionsList
            entriesList
        }
        .panel(padding: 22)
        .accentBar(Palette.gold)
        .sheet(item: $editing) { draft in
            TimeEntrySheet(draft: draft) { projects.saveTime($0, to: project.id) }
        }
        .task(id: project.id) { await loadEvents() }
    }

    // MARK: Timer

    @ViewBuilder private var timerRow: some View {
        HStack(spacing: 10) {
            if let started = project.timerStartedAt {
                Circle().fill(Theme.coral).frame(width: 9, height: 9)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Hours.clock(context.date.timeIntervalSince(started)))
                        .font(.system(size: 22, weight: .light)).monospacedDigit()
                        .foregroundStyle(Theme.text)
                }
                Text((project.timerKind ?? timerKind).label)
                    .font(.system(size: 13)).foregroundStyle(Theme.text3)
                Spacer()
                Button("Stop") { projects.stopTimer(project.id) }
                    .buttonStyle(PrimaryButtonStyle())
            } else {
                Button("Start timer") { projects.startTimer(project.id, kind: timerKind) }
                    .buttonStyle(PrimaryButtonStyle())
                Menu {
                    ForEach(TimeKind.allCases) { k in Button(k.label) { kind = k } }
                } label: {
                    Text(timerKind.label).font(.system(size: 13))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("What the timer is counting")
                Spacer()
                Button("Add time") {
                    editing = TimeEntryDraft(entry: TimeEntry(date: Date(), hours: 1, kind: timerKind), isNew: true)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    // MARK: Totals

    @ViewBuilder private var totals: some View {
        if books.hours > 0 {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    HeadlineNumber(text: Hours.short(books.hours), size: 30)
                    Text("in total · \(Hours.short(project.hoursThisWeek)) this week")
                        .font(.system(size: 14)).foregroundStyle(Theme.text3)
                }
                let byKind = project.hoursByKind
                if !byKind.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(byKind, id: \.kind) { item in
                            Text("\(item.kind.label) \(Hours.short(item.hours))")
                                .font(.system(size: 12))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Theme.raised)
                                .foregroundStyle(Theme.text2)
                                .clipShape(Capsule())
                        }
                    }
                }
                if let perHour = books.perHour {
                    Text("About \(Money.string(perHour)) per hour so far, after expenses.")
                        .font(.system(size: 13)).foregroundStyle(perHour >= 0 ? Theme.teal : Theme.coral)
                }
            }
        } else {
            Text("No time logged yet. Start the timer when you sit down to work, or add time by hand.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Suggestions

    private var suggestions: [TimeSuggestion] {
        let used = Set(project.times.compactMap(\.source) + (project.skippedTimeSources ?? []))
        var out: [TimeSuggestion] = []
        var eventsUsed = Set<String>()
        for note in project.meetingNotes ?? [] where !used.contains("zoom:\(note.id)") {
            // The summary email arrives after the call, so look for the calendar event just before it.
            let event = events.first { $0.start <= note.date && note.date.timeIntervalSince($0.end) < 3 * 3600 && $0.matchesZoom(note) }
            if let event { eventsUsed.insert(event.id) }
            out.append(TimeSuggestion(id: "zoom:\(note.id)", title: note.title, date: event?.start ?? note.date,
                                      hours: event.map { $0.end.timeIntervalSince($0.start) / 3600 } ?? 1,
                                      kind: .calls, from: "Zoom call"))
        }
        for event in events where !eventsUsed.contains(event.id) && !used.contains("calendar:\(event.id)") {
            guard !event.allDay, event.end <= Date(), project.matches(event.title) else { continue }
            let hours = event.end.timeIntervalSince(event.start) / 3600
            guard hours >= 0.15, hours <= 14 else { continue }
            out.append(TimeSuggestion(id: "calendar:\(event.id)", title: event.title, date: event.start,
                                      hours: hours, kind: event.guessKind(shootDate: project.shootDate), from: "Calendar"))
        }
        return out.sorted { $0.date > $1.date }.prefix(6).map { $0 }
    }

    @ViewBuilder private var suggestionsList: some View {
        let list = suggestions
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Count these as time?").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                ForEach(list) { s in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title).font(.system(size: 13)).foregroundStyle(Theme.text2).lineLimit(1)
                            Text("\(s.from) · \(s.date.formatted(date: .abbreviated, time: .shortened)) · \(Hours.short(s.hours))")
                                .font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Button("Add") {
                            editing = TimeEntryDraft(entry: TimeEntry(date: s.date, hours: (s.hours * 100).rounded() / 100,
                                                                      kind: s.kind, note: s.title, source: s.id), isNew: true)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        Button("Skip") { projects.skipTimeSource(s.id, on: project.id) }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                }
            }
            .padding(12)
            .background(Theme.raised.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: Entries

    @ViewBuilder private var entriesList: some View {
        let all = project.times
        if !all.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(showAll ? all : Array(all.prefix(6))) { entry in
                    HStack(spacing: 12) {
                        Text(entry.date.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.muted)
                            .frame(width: 52, alignment: .leading)
                        Text(entry.kind.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text2)
                            .frame(width: 70, alignment: .leading)
                        Text(entry.note ?? "").font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                        Spacer()
                        Text(Hours.short(entry.hours)).font(.system(size: 13)).monospacedDigit().foregroundStyle(Theme.text2)
                        Button {
                            projects.deleteTime(entry.id, from: project.id)
                        } label: {
                            Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                        .buttonStyle(.plain)
                        .help("Delete this time")
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onTapGesture { editing = TimeEntryDraft(entry: entry, isNew: false) }
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.lineSoft).frame(height: 1) }
                }
                if all.count > 6 {
                    Button(showAll ? "Show less" : "Show all \(all.count)") { showAll.toggle() }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.teal)
                        .padding(.top, 8)
                }
            }
        }
    }

    private func loadEvents() async {
        let start = min(project.createdAt, project.shootDate ?? project.createdAt).addingTimeInterval(-30 * 86400)
        let found = await logins.calendarEvents(from: start, to: Date())
        let notes = project.meetingNotes ?? []
        events = found.filter { e in project.matches(e.title) || notes.contains { e.matchesZoom($0) } }
    }
}

private extension LensCalendarEvent {
    func matchesZoom(_ note: MeetingNote) -> Bool {
        let a = title.lowercased(), b = note.title.lowercased()
        return a == b || a.contains(b) || b.contains(a) || a.contains("zoom")
    }

    func guessKind(shootDate: Date?) -> TimeKind {
        let t = title.lowercased()
        if t.contains("edit") { return .edit }
        if t.contains("shoot") || t.contains("film") { return .shoot }
        if t.contains("call") || t.contains("zoom") || t.contains("meet") { return .calls }
        if let shootDate, Calendar.current.isDate(shootDate, inSameDayAs: start) { return .shoot }
        return .planning
    }
}

struct TimeEntryDraft: Identifiable {
    let entry: TimeEntry
    let isNew: Bool
    var id: UUID { entry.id }
}

/// Add time by hand, or change time already logged.
struct TimeEntrySheet: View {
    let draft: TimeEntryDraft
    let onSave: (TimeEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var hoursText = ""
    @State private var kind: TimeKind = .edit
    @State private var note = ""

    /// "1.5", "1,5" or "1:30" all mean an hour and a half.
    private var hours: Double? {
        let t = hoursText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if t.contains(":") {
            let parts = t.split(separator: ":").map { Double($0) }
            guard parts.count == 2, let h = parts[0], let m = parts[1] else { return nil }
            return h + m / 60
        }
        guard let v = Double(t), v > 0, v <= 24 else { return nil }
        return v
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(draft.isNew ? "Add time" : "Change time").font(.system(size: 20, weight: .bold))
            Form {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField("Hours", text: $hoursText, prompt: Text("1.5"))
                Picker("What it was", selection: $kind) {
                    ForEach(TimeKind.allCases) { Text($0.label).tag($0) }
                }
                TextField("Note", text: $note, prompt: Text("Optional"))
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Add time" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(hours == nil)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            date = draft.entry.date
            hoursText = draft.entry.hours == draft.entry.hours.rounded() ? String(Int(draft.entry.hours)) : String(draft.entry.hours)
            kind = draft.entry.kind
            note = draft.entry.note ?? ""
        }
    }

    private func save() {
        guard let hours else { return }
        var entry = draft.entry
        // Keep the time of day for entries from the timer or a meeting; a new hand entry is just a day.
        if !Calendar.current.isDate(entry.date, inSameDayAs: date) { entry.date = date }
        entry.hours = (hours * 100).rounded() / 100
        entry.kind = kind
        let n = note.trimmingCharacters(in: .whitespaces)
        entry.note = n.isEmpty ? nil : n
        onSave(entry)
        dismiss()
    }
}

// MARK: - Money

/// What one project costs and what the user keeps from it.
struct ProjectMoneyPanel: View {
    let project: Project
    let books: ProjectBooks
    @EnvironmentObject private var money: MoneyStore
    @EnvironmentObject private var navigator: Navigator
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                ColorLabel("Money", Palette.mint)
                Spacer()
                Button("Add expense") { adding = true }
                    .buttonStyle(SecondaryButtonStyle())
            }
            summary
            expenseList
        }
        .panel(padding: 22)
        .accentBar(Palette.mint)
        .sheet(isPresented: $adding) {
            ExpenseSheet(projectID: project.id)
        }
    }

    @ViewBuilder private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let price = books.price {
                line("Price", Money.string(price))
                if books.received > 0 { line("Paid so far", Money.string(books.received)) }
            } else if books.received > 0 {
                line("Money in so far", Money.string(books.received))
            }
            line("Spent", books.spent > 0 ? "−\(Money.string(books.spent))" : Money.string(0))
            if let keep = books.keep {
                Divider().overlay(Theme.lineSoft).padding(.vertical, 2)
                HStack(alignment: .firstTextBaseline) {
                    Text("What you keep").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    Text(Money.string(keep)).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(keep >= 0 ? Theme.teal : Theme.coral)
                }
            } else {
                Text("Add a price in Edit details to see what you keep.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.muted)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(Theme.text2)
        }
        .font(.system(size: 13))
    }

    @ViewBuilder private var expenseList: some View {
        if books.expenses.isEmpty {
            Text("No expenses on this project yet. Add one here, or tag a transaction to it in Money.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("Expenses · \(books.expenses.count)").font(.system(size: 11, weight: .bold)).tracking(0.6)
                    .foregroundStyle(Theme.muted).padding(.bottom, 4)
                ForEach(books.expenses) { t in
                    HStack(spacing: 10) {
                        Text(t.date.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.muted)
                            .frame(width: 48, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.description).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                            Text(t.category.label).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }
                        Spacer(minLength: 6)
                        if let url = MoneyStore.receiptURL(t) {
                            Button { NSWorkspace.shared.open(url) } label: {
                                Image(systemName: "paperclip").font(.system(size: 12)).foregroundStyle(Theme.teal)
                            }
                            .buttonStyle(.plain)
                            .help("Open the receipt")
                        }
                        Text(Money.string(-t.amount)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Theme.text2)
                        Menu {
                            Button("Take off this project") { money.setProject(t, nil) }
                            if t.addedByHand == true {
                                Button("Delete expense", role: .destructive) { money.deleteHandAdded(t) }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                    .padding(.vertical, 6)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.lineSoft).frame(height: 1) }
                }
            }
        }
    }
}

/// Add an expense by hand, with an optional receipt photo or PDF.
struct ExpenseSheet: View {
    let projectID: UUID?
    @EnvironmentObject private var money: MoneyStore
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var date = Date()
    @State private var what = ""
    @State private var category: MoneyCategory = .travel
    @State private var account: MoneyAccount = .card
    @State private var receipt: URL?

    private static let kinds: [MoneyCategory] = MoneyCategory.pickable.filter {
        [.direct, .overhead].contains($0.group)
    }

    private var amount: Double? {
        MoneyStore.parseAmount(amountText).map(abs).flatMap { $0 > 0 ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add expense").font(.system(size: 20, weight: .bold))
            Form {
                TextField("Amount", text: $amountText, prompt: Text("$120"))
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField("What it was", text: $what, prompt: Text("Lens rental"))
                Picker("Kind", selection: $category) {
                    ForEach(Self.kinds) { Text($0.label).tag($0) }
                }
                Picker("Paid with", selection: $account) {
                    ForEach(MoneyAccount.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Receipt") {
                    HStack {
                        Text(receipt?.lastPathComponent ?? "None").foregroundStyle(.secondary).lineLimit(1)
                        Button("Choose…") { chooseReceipt() }
                    }
                }
            }
            .formStyle(.grouped)
            Text("Already on a bank or card statement? Find it in Money and add it to the project there instead, so it isn't counted twice.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add expense") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(amount == nil || what.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onChange(of: what) { _, text in
            let guess = money.categorize(text, amount: -1)
            if Self.kinds.contains(guess) { category = guess }
        }
    }

    private func chooseReceipt() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.message = "Choose a photo or PDF of the receipt."
        panel.prompt = "Use this receipt"
        if panel.runModal() == .OK { receipt = panel.urls.first }
    }

    private func save() {
        guard let amount else { return }
        money.addExpense(amount: amount, date: date, description: what.trimmingCharacters(in: .whitespaces),
                         category: category, account: account, projectID: projectID, receipt: receipt)
        dismiss()
    }
}

// MARK: - Sidebar

/// Always on show in the sidebar while a timer runs, so it can't be forgotten.
struct RunningTimerBadge: View {
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var navigator: Navigator

    var body: some View {
        if let project = projects.timing, let started = project.timerStartedAt {
            HStack(spacing: 8) {
                Button {
                    navigator.openProject(project.id)
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(Theme.coral).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(project.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(Hours.clock(context.date.timeIntervalSince(started)))
                                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.text3)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Timer running. Click to open the project.")
                Button("Stop") { projects.stopTimer(project.id) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.teal)
            }
            .padding(10)
            .background(Theme.coral.opacity(0.14))
            .foregroundStyle(Theme.text)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.coral.opacity(0.4)))
        }
    }
}
