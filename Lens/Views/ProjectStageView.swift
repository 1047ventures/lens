import SwiftUI
import AppKit

/// Where she is inside a project: one of its steps on the stage bar, or one of the "all of it" tabs.
enum ProjectPlace: Hashable {
    case stage(ProjectStage)
    case tab(ProjectTab)
}

/// The stretch of time each step covered, worked out from the dated "Moved to…" lines in the
/// project's history. Steps she skipped get no stretch; a project with no history puts
/// everything in the step it's at now.
struct StageWindows {
    let windows: [ProjectStage: DateInterval]
    let current: ProjectStage

    init(_ project: Project) {
        current = project.stage
        var starts: [ProjectStage: Date] = [.lead: .distantPast]
        for event in project.events.sorted(by: { $0.date < $1.date }) {
            guard let s = ProjectStage.mentioned(in: event.text), s != .lead,
                  s.rawValue <= project.stage.rawValue, starts[s] == nil else { continue }
            starts[s] = event.date
        }
        // The step it's at now takes over from the latest step with a known start.
        if starts[project.stage] == nil {
            let latest = starts.filter { $0.key.rawValue < project.stage.rawValue }.max { $0.key.rawValue < $1.key.rawValue }
            starts[project.stage] = latest?.value ?? .distantPast
            if let k = latest?.key, k != project.stage { starts[k] = nil }
        }
        let ordered = starts.sorted { $0.key.rawValue < $1.key.rawValue }
        var result: [ProjectStage: DateInterval] = [:]
        for (i, entry) in ordered.enumerated() {
            let end = i + 1 < ordered.count ? ordered[i + 1].value : .distantFuture
            result[entry.key] = DateInterval(start: entry.value, end: max(end, entry.value))
        }
        windows = result
    }

    func contains(_ date: Date, in stage: ProjectStage) -> Bool {
        guard let w = windows[stage] else { return false }
        return date >= w.start && (date < w.end || w.end == .distantFuture)
    }

    /// "Oct 2 to Oct 9", "Since Oct 9", "Until Oct 9", "Coming up", "Skipped".
    func when(_ stage: ProjectStage) -> String {
        if stage.rawValue > current.rawValue { return "Coming up" }
        guard let w = windows[stage] else { return "Skipped" }
        let fmt: (Date) -> String = { $0.formatted(.dateTime.month(.abbreviated).day()) }
        let openStart = w.start == .distantPast, openEnd = w.end == .distantFuture
        switch (openStart, openEnd) {
        case (true, true): return "Now"
        case (true, false): return "Until \(fmt(w.end))"
        case (false, true): return "Since \(fmt(w.start))"
        case (false, false):
            let cal = Calendar.current
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: w.start), to: cal.startOfDay(for: w.end)).day ?? 0
            return "\(fmt(w.start)) to \(fmt(w.end)) · \(days == 1 ? "1 day" : "\(days) days")"
        }
    }
}

/// One step of a project, opened from the stage bar: a short brief first, then whatever
/// happened in that step (footage, hours, money, emails, calls, files), each linking to its full tab.
struct ProjectStageView<Footage: View>: View {
    let project: Project
    let stage: ProjectStage
    let books: ProjectBooks
    let footage: Footage
    /// Only the summary at the top, for the simple page.
    var briefOnly = false
    let open: (ProjectTab) -> Void

    @EnvironmentObject private var deals: DealStore
    @EnvironmentObject private var navigator: Navigator

    private var windows: StageWindows { StageWindows(project) }
    private var reached: Bool { stage.rawValue <= project.stage.rawValue && windows.windows[stage] != nil }
    private var deal: Deal? { deals.deals.first { $0.projectID == project.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            brief
            if reached && !briefOnly {
                main
                let cards = smallCards
                if cards.isEmpty {
                    if !hasMain {
                        Text("Nothing has been filed in this step yet. " + stage.collects)
                            .font(Theme.font(size: 14)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    // One or two cards share the width; more wrap into as many columns as fit.
                    let columns = cards.count <= 2
                        ? Array(repeating: GridItem(.flexible(), spacing: 20, alignment: .top), count: cards.count)
                        : [GridItem(.adaptive(minimum: 340), spacing: 20, alignment: .top)]
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(cards, id: \.self) { card($0) }
                    }
                }
            }
        }
    }

    // MARK: Brief

    private var brief: some View {
        let isNow = stage == project.stage
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(stage.label).font(Theme.display(size: 24)).foregroundStyle(Theme.text)
                Text(windows.when(stage))
                    .font(Theme.font(size: 12, weight: .semibold))
                    .foregroundStyle(isNow ? Theme.onTeal : Theme.text3)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(isNow ? Theme.teal : Theme.raised)
                    .clipShape(Capsule())
            }
            Text(briefSentence)
                .font(Theme.font(size: 15)).foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 20)
    }

    private var briefSentence: String {
        if stage == project.stage {
            if stage == .archived, let deal, deal.stage == .lost {
                return (deal.lostReason.map { "Didn't book: \($0)." } ?? "Didn't book.") + " Reopen it from the button above if they come back."
            }
            if stage == .lead, let deal { return DealCard.nextMove(deal) + "." }
            return SimpleProject.nextLine(project)
        }
        if stage.rawValue > project.stage.rawValue {
            if stage == .shoot, let d = project.shootDate, d > Date() {
                return "Shoot day is \(SimpleProject.when(d))\(project.location.isEmpty ? "" : " at \(project.location)"). " + stage.collects
            }
            return stage.collects
        }
        if !reached { return "This project went straight past this step." }
        var parts: [String] = []
        let mails = emails.count, calls = notes.count, hrs = hours.reduce(0) { $0 + $1.hours }
        if mails > 0 { parts.append("\(mails) email\(mails == 1 ? "" : "s")") }
        if calls > 0 { parts.append("\(calls) call\(calls == 1 ? "" : "s")") }
        if hrs > 0 { parts.append(Hours.short(hrs) + " of work") }
        if parts.isEmpty { return "Nothing was filed while \(stage.label.lowercased())." }
        let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts[0]
        return "While \(stage.label.lowercased()): " + list + "."
    }

    // MARK: The big panel for each step

    private var hasMain: Bool { [.lead, .shoot, .edit, .delivered, .paid, .archived].contains(stage) }

    @ViewBuilder private var main: some View {
        switch stage {
        case .lead: quoteCard
        case .booked: EmptyView()
        case .shoot, .edit:
            footage
            if stage == .edit { ProjectTimePanel(project: project, books: books) }
        case .delivered: ProjectMoneyPanel(project: project, books: books)
        case .paid, .archived:
            ProjectMoneyPanel(project: project, books: books)
            wrapCard
        }
    }

    /// The quote, right here in the Quoting step: options, prices, the pitch and the plan.
    @ViewBuilder private var quoteCard: some View {
        if let deal {
            if stage == project.stage {
                DealDetailView(dealID: deal.id, embedded: true)
            } else {
                // Looking back once it's booked: what was quoted and how it came in.
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("The quote")
                    let price = books.price.map { Money.string($0) }
                    Text([deal.source.isEmpty ? nil : "Came in by \(deal.source.lowercased())",
                          "asked \(deal.createdAt.formatted(.dateTime.month(.abbreviated).day()))",
                          price.map { "booked at \($0)" }].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.font(size: 13)).foregroundStyle(Theme.muted)
                    if let chosen = deal.chosenOption {
                        Text("\(chosen.name) · \(chosen.tagline)").font(Theme.font(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    }
                    Button("See the proposal") { navigator.openBuilder(deal.id) }.buttonStyle(SecondaryButtonStyle())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel(padding: 22)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("The quote")
                Text(project.client.isEmpty
                     ? "No quote on this one. If someone's paying for it, start a quote and price it here."
                     : "No quote yet. Start one to lay out the options and the price.")
                    .font(Theme.font(size: 14)).foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Start a quote") { deals.startQuote(for: project) }.buttonStyle(PrimaryButtonStyle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel(padding: 22)
        }
    }

    private var wrapCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Loose ends")
            line(project.isOnServer ? "checkmark.circle.fill" : "externaldrive",
                 project.isOnServer ? "Footage is on the server." : project.folderPath == nil ? "No footage folder set." : "Footage is still on the working drive.")
            line(project.testimonial?.isEmpty == false ? "checkmark.circle.fill" : "quote.bubble",
                 project.testimonial?.isEmpty == false ? "Testimonial saved." : "No testimonial yet. A kind word from them helps the next quote.")
            line(project.portfolioURL?.isEmpty == false ? "checkmark.circle.fill" : "link",
                 project.portfolioURL?.isEmpty == false ? "In your portfolio." : "Not in your portfolio yet.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 22)
    }

    private func line(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(icon.hasPrefix("checkmark") ? Theme.teal : Theme.muted)
            Text(text).font(Theme.font(size: 14)).foregroundStyle(Theme.text2)
        }
    }

    // MARK: What happened in this step

    private var emails: [EmailThread] {
        var all = project.emails ?? []
        if stage == .lead { all += deal?.emails ?? [] }
        var seen = Set<String>()
        return all.filter { seen.insert($0.id).inserted && windows.contains($0.lastDate, in: stage) }
            .sorted { $0.lastDate > $1.lastDate }
    }

    private var notes: [MeetingNote] {
        var all = project.meetingNotes ?? []
        if stage == .lead { all += deal?.meetingNotes ?? [] }
        var seen = Set<String>()
        return all.filter { seen.insert($0.id).inserted && windows.contains($0.date, in: stage) }
            .sorted { $0.date > $1.date }
    }

    private var hours: [TimeEntry] {
        (project.timeEntries ?? []).filter { windows.contains($0.date, in: stage) }
    }

    private var history: [ProjectEvent] {
        project.events.filter { windows.contains($0.date, in: stage) }.sorted { $0.date > $1.date }
    }

    /// Files belong to a step by what they are; anything else by when it was added.
    private var files: [ProjectFile] {
        (project.documents ?? []).filter { f in
            switch f.kind {
            case "Proposal", "Quote": return stage == .lead
            case "Contract", "Treatment", "Call sheet", "Script", "Release form": return stage == .booked
            default: return windows.contains(f.added, in: stage)
            }
        }
    }

    private enum Card: Hashable { case people, plan, emails, notes, files, hours, history }

    private var smallCards: [Card] {
        var cards: [Card] = []
        if stage == .booked { cards += [.plan, .people] }
        if !emails.isEmpty { cards.append(.emails) }
        if !notes.isEmpty { cards.append(.notes) }
        if !files.isEmpty { cards.append(.files) }
        if !hours.isEmpty && stage != .edit { cards.append(.hours) }
        if !history.isEmpty { cards.append(.history) }
        return cards
    }

    @ViewBuilder private func card(_ c: Card) -> some View {
        switch c {
        case .plan: planCard
        case .people: peopleCard
        case .emails:
            listCard("Emails", count: emails.count, tab: .emails) {
                ForEach(emails.prefix(4)) { mail in
                    row(mail.subject.isEmpty ? "No subject" : mail.subject, mail.from, mail.lastDate) {
                        if let url = URL(string: mail.link) { NSWorkspace.shared.open(url) }
                    }
                }
            }
        case .notes:
            listCard("Calls and meeting notes", count: notes.count, tab: .notes) {
                ForEach(notes.prefix(4)) { note in
                    row(note.title, note.nextSteps?.first ?? "", note.date) { open(.notes) }
                }
            }
        case .files:
            listCard("Files", count: files.count, tab: .proposal) {
                ForEach(files.prefix(5)) { file in
                    row(file.name, file.kind, file.added) {
                        if file.isWebLink, let url = URL(string: file.location) { NSWorkspace.shared.open(url) }
                        else { NSWorkspace.shared.open(URL(fileURLWithPath: file.location)) }
                    }
                }
            }
        case .hours:
            let total = hours.reduce(0) { $0 + $1.hours }
            let kinds = Dictionary(grouping: hours, by: \.kind).map { ($0.key, $0.value.reduce(0) { $0 + $1.hours }) }
                .sorted { $0.1 > $1.1 }
            listCard("Hours", count: nil, tab: .hours) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    HeadlineNumber(text: Hours.short(total), size: 26)
                    Text(kinds.map { "\($0.0.label) \(Hours.short($0.1))" }.joined(separator: " · "))
                        .font(Theme.font(size: 13)).foregroundStyle(Theme.text3)
                }
            }
        case .history:
            listCard("What happened", count: nil, tab: nil) {
                ForEach(history.prefix(6)) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(event.date.formatted(.dateTime.month(.abbreviated).day()))
                            .font(Theme.font(size: 12)).foregroundStyle(Theme.muted).frame(width: 52, alignment: .leading)
                        Text(event.text).font(Theme.font(size: 13)).foregroundStyle(Theme.text2)
                    }
                }
            }
        }
    }

    private var planCard: some View {
        listCard("The plan", count: nil, tab: nil) {
            planRow("calendar", project.shootDate.map { $0.formatted(date: .complete, time: .shortened) } ?? "No shoot date yet")
            planRow("mappin.and.ellipse", project.location.isEmpty ? "No place set" : project.location)
            if let price = books.price { planRow("dollarsign.circle", "Booked at \(Money.string(price))") }
        }
    }

    private func planRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.muted).frame(width: 18)
            Text(text).font(Theme.font(size: 14)).foregroundStyle(Theme.text2)
        }
    }

    private var peopleCard: some View {
        let people = project.people ?? []
        return listCard("People involved", count: people.count + (project.client.isEmpty ? 0 : 1), tab: .people) {
            if !project.client.isEmpty { person(project.client, "Client") }
            ForEach(people.filter { $0.name != project.client }.prefix(5)) { person($0.name, $0.role) }
            if people.isEmpty && project.client.isEmpty {
                Text("No one added yet.").font(Theme.font(size: 13)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func person(_ name: String, _ role: String) -> some View {
        HStack(spacing: 10) {
            Text(String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased())
                .font(Theme.font(size: 11, weight: .bold)).foregroundStyle(Palette.orchid)
                .frame(width: 30, height: 30)
                .background(Palette.orchid.opacity(0.16)).clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(Theme.font(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                if !role.isEmpty { Text(role).font(Theme.font(size: 12)).foregroundStyle(Theme.muted) }
            }
        }
    }

    // MARK: Building blocks

    private func listCard<Content: View>(_ title: String, count: Int?, tab: ProjectTab?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(count.map { "\(title) · \($0)" } ?? title)
                Spacer()
                if let tab {
                    Button { open(tab) } label: {
                        HStack(spacing: 3) {
                            Text("See all")
                            Image(systemName: "chevron.right").font(Theme.font(size: 9, weight: .bold))
                        }
                        .font(Theme.font(size: 12, weight: .semibold)).foregroundStyle(Theme.teal)
                    }
                    .buttonStyle(.plain)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 20)
    }

    private func row(_ title: String, _ detail: String, _ date: Date, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.font(size: 14, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail).font(Theme.font(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(date.formatted(.dateTime.month(.abbreviated).day()))
                    .font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
