import Foundation

/// Finds the Zoom AI Companion summaries Zoom emails to Emma's Gmail and attaches each one to the
/// deal or project it's about, matched by the client's name or email. Summaries Lens can't place
/// wait in a short "Unmatched notes" list until Emma picks where they go.
@MainActor
final class ZoomNotes: ObservableObject {
    /// A summary that didn't clearly belong to one deal or project.
    @Published private(set) var unmatched: [MeetingNote] = []
    @Published private(set) var checking = false
    @Published private(set) var lastChecked: Date?
    /// How many Zoom summaries Lens has found in Gmail so far, and when the newest one arrived.
    @Published private(set) var foundCount = 0
    @Published private(set) var newestSummary: Date?
    @Published private(set) var problem: String?

    private weak var deals: DealStore?
    private weak var projects: ProjectStore?
    private weak var logins: ConnectionStore?
    /// Summaries already placed (on a deal, a project, or set aside), so they aren't placed again.
    private var handled: Set<String> = []
    private var loop: Task<Void, Never>?

    init() { load() }

    func attach(deals: DealStore, projects: ProjectStore, logins: ConnectionStore) {
        self.deals = deals
        self.projects = projects
        self.logins = logins
    }

    var ready: Bool { logins?.gmailReady ?? false }

    /// Checks now, then every hour while Lens is open.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    // MARK: Checking

    /// Gmail search for AI Companion meeting summaries (and Zoom Phone call summaries).
    static let query = "from:zoom.us {subject:\"meeting summary\" subject:\"meeting assets\" subject:\"call summary\" subject:recap} newer_than:120d -in:spam -in:trash"

    func check() async {
        guard !checking, ready, let logins, let deals, let projects else { return }
        checking = true
        defer { checking = false }
        do {
            let token = try await logins.googleAccessToken()
            let me = logins.ownerEmail
            let account = me.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? me
            let found = try await GmailAPI.threadIDs(matching: Self.query, max: 50, token: token)
            var read = 0
            for item in found where !handled.contains(item.id) && !unmatched.contains(where: { $0.id == item.id }) {
                guard read < 25 else { break }   // the rest wait for the next check
                read += 1
                let thread = try await GmailAPI.thread(item.id, token: token)
                guard let message = thread.messages.last(where: { GmailAPI.parseAddress($0.from).email.hasSuffix("zoom.us") }) else {
                    handled.insert(item.id)
                    continue
                }
                let note = MeetingNote(id: item.id, title: Self.title(from: message.subject), date: message.date,
                                       summary: Self.clean(message.text),
                                       link: "https://mail.google.com/mail/?authuser=\(account)#all/\(item.id)")
                foundCount += 1
                if alreadyOnFile(note.id, deals: deals, projects: projects) { handled.insert(note.id); continue }
                if let target = Self.match(note, deals: deals, projects: projects) {
                    place(note, dealID: target.dealID, projectID: target.projectID)
                } else {
                    unmatched.append(note)
                }
            }
            if foundCount > 0 {
                // Emma doesn't need to tick "done" in Log-ins once summaries are actually arriving.
                if !logins.isConfirmed("zoom") { logins.setConfirmed("zoom", true) }
            }
            let dates = (deals.deals.flatMap { $0.meetingNotes ?? [] } + projects.projects.flatMap { $0.meetingNotes ?? [] } + unmatched).map(\.date)
            newestSummary = dates.max()
            unmatched.sort { $0.date > $1.date }
            lastChecked = Date()
            problem = nil
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "Lens couldn't check for Zoom notes just now."
        }
        save()
    }

    private func alreadyOnFile(_ id: String, deals: DealStore, projects: ProjectStore) -> Bool {
        deals.deals.contains { ($0.meetingNotes ?? []).contains { $0.id == id } }
            || projects.projects.contains { ($0.meetingNotes ?? []).contains { $0.id == id } }
    }

    /// "Meeting summary for Smith wedding planning (11/18/2026)" → "Smith wedding planning".
    static func title(from subject: String) -> String {
        var t = subject.trimmingCharacters(in: .whitespaces)
        for prefix in ["Meeting summary for ", "Meeting assets for ", "Call summary for ", "Call summary with ", "Recap of "] {
            if t.lowercased().hasPrefix(prefix.lowercased()) { t = String(t.dropFirst(prefix.count)); break }
        }
        t = t.replacingOccurrences(of: "\\s*\\([0-9/.\\-]+\\)\\s*$", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s+are ready!?$", with: "", options: [.regularExpression, .caseInsensitive])
        return t.isEmpty ? "Zoom call" : t
    }

    /// The summary itself, without Zoom's buttons and small print at the bottom.
    static func clean(_ text: String) -> String {
        var t = text
        for marker in ["Please rate the accuracy", "AI-generated content may be inaccurate", "Share this summary",
                       "Edit Summary", "Is this summary helpful", "Unsubscribe", "Copyright ©"] {
            if let r = t.range(of: marker, options: .caseInsensitive), t.distance(from: t.startIndex, to: r.lowerBound) > 80 {
                t = String(t[..<r.lowerBound])
            }
        }
        t = t.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return String(t.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8000))
    }

    // MARK: Matching

    private struct Target {
        var dealID: UUID?
        var projectID: UUID?
        var active: Bool
        var keys: [(text: String, weight: Int)]
    }

    /// The one deal or project the summary mentions most clearly: an email address counts most,
    /// then a full name, then a last name. A tie means Lens isn't sure, so Emma picks.
    private static func match(_ note: MeetingNote, deals: DealStore, projects: ProjectStore) -> (dealID: UUID?, projectID: UUID?)? {
        let haystack = (note.title + "\n" + note.summary).lowercased()
        var targets: [Target] = []
        var linkedProjects = Set<UUID>()
        for d in deals.deals {
            var keys = names(d.client, weight: 2)
            for c in d.contacts {
                if c.email.contains("@") { keys.append((c.email.lowercased(), 3)) }
                keys += names(c.name, weight: 2)
            }
            var active = d.stage.isOpen
            if let pid = d.projectID, let p = projects.project(id: pid) {
                linkedProjects.insert(pid)
                keys += names(p.client, weight: 2)
                active = active || p.stage != .archived
            }
            targets.append(Target(dealID: d.id, projectID: d.projectID, active: active, keys: keys))
        }
        for p in projects.projects where !linkedProjects.contains(p.id) {
            targets.append(Target(dealID: nil, projectID: p.id, active: p.stage != .archived, keys: names(p.client, weight: 2)))
        }

        func score(_ t: Target) -> Int {
            var seen = Set<String>()
            return t.keys.reduce(0) { total, key in
                guard seen.insert(key.text).inserted, mentions(haystack, key.text) else { return total }
                return total + key.weight
            }
        }
        let scored = targets.map { ($0, score($0)) }.filter { $0.1 > 0 }
        func best(_ list: [(Target, Int)]) -> Target? {
            let sorted = list.sorted { $0.1 > $1.1 }
            guard let top = sorted.first else { return nil }
            if sorted.count > 1 && sorted[1].1 == top.1 { return nil }
            return top.0
        }
        // Prefer gigs that are still going; fall back to older ones.
        guard let pick = best(scored.filter { $0.0.active }) ?? best(scored) else { return nil }
        return (pick.dealID, pick.projectID)
    }

    /// A full name, plus the last name on its own ("the Smiths" still finds Jane Smith).
    private static func names(_ raw: String, weight: Int) -> [(text: String, weight: Int)] {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard name.count >= 3, name != "new client" else { return [] }
        var keys = [(name, weight)]
        let words = name.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" }).map(String.init)
        if words.count >= 2, let last = words.last, last.count >= 4,
           !["wedding", "films", "studio", "group", "company", "family", "foundation"].contains(last) {
            keys.append((last, 1))
        }
        return keys
    }

    private static func mentions(_ haystack: String, _ key: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        let pattern = key.contains("@") ? escaped : "\\b\(escaped)(s|'s)?\\b"
        return haystack.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: Emma's choices

    private func place(_ note: MeetingNote, dealID: UUID?, projectID: UUID?) {
        if let dealID { deals?.attachNote(note, to: dealID) }
        if let projectID { projects?.attachNote(note, to: projectID) }
        unmatched.removeAll { $0.id == note.id }
        handled.insert(note.id)
    }

    /// Emma picked the deal for an unmatched summary (it goes on the deal's project too, once booked).
    func assign(_ note: MeetingNote, toDeal id: UUID) {
        place(note, dealID: id, projectID: deals?.deal(id: id)?.projectID)
        save()
    }

    /// Emma picked the project (it goes on the deal it came from too).
    func assign(_ note: MeetingNote, toProject id: UUID) {
        place(note, dealID: deals?.deals.first(where: { $0.projectID == id })?.id, projectID: id)
        save()
    }

    /// Not about any client: set it aside for good.
    func dismiss(_ note: MeetingNote) {
        unmatched.removeAll { $0.id == note.id }
        handled.insert(note.id)
        save()
    }

    /// It landed on the wrong deal or project: take it off and let Emma pick again.
    func unassign(_ note: MeetingNote) {
        for d in deals?.deals ?? [] where (d.meetingNotes ?? []).contains(where: { $0.id == note.id }) {
            deals?.removeNote(note.id, from: d.id)
        }
        for p in projects?.projects ?? [] where (p.meetingNotes ?? []).contains(where: { $0.id == note.id }) {
            projects?.removeNote(note.id, from: p.id)
        }
        if !unmatched.contains(where: { $0.id == note.id }) { unmatched.insert(note, at: 0) }
        save()
    }

    // MARK: Saving (zoom_notes.json)

    private struct Saved: Codable {
        var unmatched: [MeetingNote]?
        var handled: [String]?
        var lastChecked: Date?
        var foundCount: Int?
        var newestSummary: Date?
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: DealStore.url("zoom_notes.json")),
              let saved = try? decoder.decode(Saved.self, from: data) else { return }
        unmatched = saved.unmatched ?? []
        handled = Set(saved.handled ?? [])
        lastChecked = saved.lastChecked
        foundCount = saved.foundCount ?? 0
        newestSummary = saved.newestSummary
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let saved = Saved(unmatched: unmatched, handled: Array(handled), lastChecked: lastChecked,
                          foundCount: foundCount, newestSummary: newestSummary)
        if let data = try? encoder.encode(saved) { try? data.write(to: DealStore.url("zoom_notes.json"), options: .atomic) }
    }
}
