import SwiftUI

/// The few lines at the top of a project page, like an executive summary: what the project is, how
/// it came in, and where it stands. Lens writes it from the project's emails, call notes, people and
/// enquiry, and writes it again only when one of those changes. The details stay in the tabs below.
struct ProjectSummaryView: View {
    let project: Project
    var size: CGFloat = 16

    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var deals: DealStore
    @EnvironmentObject private var history: EmailHistory
    @EnvironmentObject private var ai: LensAI
    @State private var busy = false
    @State private var hovering = false

    /// Projects Lens is writing a summary for right now, so two pages never ask twice.
    @MainActor private static var writing: Set<UUID> = []

    private var quote: Deal? { deals.quote(for: project) }
    private var key: String { ProjectSummaryFacts.key(project, quote: quote, history: history) }

    var body: some View {
        let text = project.summary ?? fallback
        Group {
            if let text, !text.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(text)
                        .font(Theme.font(size: size))
                        .foregroundStyle(Theme.text2)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: 780, alignment: .leading)
                    if busy {
                        ProgressView().controlSize(.mini)
                    } else if ai.hasKey && hovering {
                        Button { Task { await write(force: true) } } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.muted)
                        }
                        .buttonStyle(.plain)
                        .help("Write this summary again")
                    }
                }
            } else if busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("Catching up on this project…").font(Theme.font(size: 13)).foregroundStyle(Theme.muted)
                }
            }
        }
        .onHover { hovering = $0 }
        .task(id: key) { await write(force: false) }
    }

    /// Without Claude: the one line she or the enquiry already gave about what it's for.
    private var fallback: String? {
        guard let quote else { return nil }
        let line = [quote.story.logline, quote.disc.goal].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return line
    }

    private func write(force: Bool) async {
        guard ai.hasKey, !Self.writing.contains(project.id) else { return }
        let key = self.key
        guard force || project.summaryKey != key else { return }
        let facts = ProjectSummaryFacts.text(project, quote: quote, history: history)
        guard ProjectSummaryFacts.enough(project, quote: quote) else { return }
        Self.writing.insert(project.id)
        busy = true
        defer { busy = false; Self.writing.remove(project.id) }
        guard let summary = try? await ai.summarizeProject(facts), var latest = projects.project(id: project.id) else { return }
        latest.summary = summary
        latest.summaryKey = key
        projects.update(latest)
    }
}

/// What Lens tells Claude about a project when writing its summary, and the fingerprint that says
/// when it's worth writing again.
enum ProjectSummaryFacts {
    private static let maxEmails = 12
    private static let maxNotes = 6

    /// Changes when something new happens: a new email or call, a new step, a date, a person.
    @MainActor static func key(_ p: Project, quote: Deal?, history: EmailHistory) -> String {
        let threads = allEmails(p, quote)
        let emailMark = threads.map { "\($0.id)\(Int($0.lastDate.timeIntervalSince1970))\(history.summary(for: $0.id).map { Int($0.updated.timeIntervalSince1970) } ?? 0)" }
        let notes = allNotes(p, quote).map(\.id)
        var parts: [String] = [p.name, p.client, p.stage.label, p.location,
                               "\(Int(p.shootDate?.timeIntervalSince1970 ?? 0))",
                               (p.people ?? []).map { $0.name + $0.role }.joined(separator: ","),
                               "\(p.events.count)"]
        if let q = quote {
            parts += [q.stage.label, q.source, q.budgetHint, "\(q.callNotes.count)", q.disc.goal, q.story.logline,
                      "\(Int(q.eventDate?.timeIntervalSince1970 ?? 0))", "\(q.events.count)",
                      q.nextSteps.map { $0.text + ($0.done ? "1" : "0") }.joined()]
        }
        parts += emailMark + notes
        var hash: UInt64 = 1469598103934665603
        for byte in parts.joined(separator: "|").utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(hash, radix: 36)
    }

    /// Whether there's anything to write from beyond the name.
    static func enough(_ p: Project, quote: Deal?) -> Bool {
        !allEmails(p, quote).isEmpty || !allNotes(p, quote).isEmpty || !(p.people ?? []).isEmpty
            || !(quote?.callNotes ?? "").isEmpty || !(quote?.disc.goal ?? "").isEmpty || !(quote?.story.logline ?? "").isEmpty
            || p.events.count > 1
    }

    @MainActor static func text(_ p: Project, quote: Deal?, history: EmailHistory) -> String {
        var lines: [String] = ["Today: \(day(Date()))", "Project: \(p.name)"]
        func add(_ label: String, _ value: String?) {
            let v = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { lines.append("\(label): \(v)") }
        }
        add("Client", p.client)
        add("Step it's at", p.stage.label)
        add("Shoot date", p.shootDate.map { $0.formatted(date: .complete, time: .shortened) })
        add("Location", p.location)
        if let price = p.price { add("Price", Money.string(price)) }
        let people = (p.people ?? []).map { $0.role.isEmpty ? $0.name : "\($0.name) (\($0.role))" }
        add("People on it", people.joined(separator: ", "))

        if let q = quote {
            lines.append("\nThe enquiry:")
            add("Came in by", q.source)
            add("Enquiry step", q.stage.label)
            add("First came in", day(q.createdAt))
            add("Event date", q.eventDate.map(day))
            add("Contacts", q.contacts.map { $0.role.isEmpty ? $0.name : "\($0.name) (\($0.role))" }.joined(separator: ", "))
            add("What they said about budget", q.budgetHint)
            add("What the video has to do", q.disc.goal)
            add("Who it's for", q.disc.audience)
            add("The idea in one line", q.story.logline)
            add("Approach", q.approachNote)
            add("Call notes", String(q.callNotes.prefix(2500)))
            add("Next steps", q.nextSteps.map { ($0.done ? "[done] " : "") + $0.text }.joined(separator: "; "))
            if let lost = q.lostReason { add("Didn't book because", lost) }
        }

        let events = (p.events + (quote?.events ?? [])).sorted { $0.date > $1.date }.prefix(15)
        if !events.isEmpty {
            lines.append("\nWhat's happened, newest first:")
            lines += events.map { "- \(day($0.date)): \($0.text)" }
        }

        let notes = allNotes(p, quote).sorted { $0.date > $1.date }.prefix(maxNotes)
        if !notes.isEmpty {
            lines.append("\nCalls and meetings, newest first:")
            for n in notes {
                let body = (n.overview?.isEmpty == false ? n.overview! : n.summary)
                lines.append("- \(day(n.date)) \(n.title): \(String(body.prefix(1200)))")
                if let steps = n.nextSteps, !steps.isEmpty { lines.append("  Next steps: \(steps.joined(separator: "; "))") }
            }
        }

        let threads = allEmails(p, quote).sorted { $0.lastDate > $1.lastDate }.prefix(maxEmails)
        if !threads.isEmpty {
            lines.append("\nEmails, newest first:")
            for t in threads {
                lines.append("- \(day(t.lastDate)) \"\(t.subject)\", latest from \(t.from): \(String(t.snippet.prefix(300)))")
                if let s = history.summary(for: t.id), !s.summary.isEmpty {
                    lines.append("  What the conversation says: \(String(s.summary.prefix(800)))")
                    if !s.decisions.isEmpty { lines.append("  Decided: \(s.decisions.joined(separator: "; "))") }
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func allEmails(_ p: Project, _ q: Deal?) -> [EmailThread] {
        var seen = Set<String>()
        return ((p.emails ?? []) + (q?.emails ?? [])).filter { seen.insert($0.id).inserted }
    }

    private static func allNotes(_ p: Project, _ q: Deal?) -> [MeetingNote] {
        var seen = Set<String>()
        return ((p.meetingNotes ?? []) + (q?.meetingNotes ?? [])).filter { seen.insert($0.id).inserted }
    }

    private static func day(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .omitted) }
}
