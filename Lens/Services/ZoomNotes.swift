import Foundation

/// Finds the Zoom AI Companion summaries Zoom emails to Emma's Gmail and attaches each one to the
/// deal or project it's about. Lens looks at who was on the call, the meeting title, the client,
/// the people on each project (directors, interviewees, crew), and the project's name and keywords.
/// When that isn't clear, Claude picks from her open projects. A note is only placed by itself when
/// Lens is sure; otherwise it waits in "Unmatched notes", with a one-tap suggestion when there is one.
/// When Emma moves a note, Lens remembers that choice for the people on the call and the meeting series.
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
    /// Unmatched notes Lens thinks belong to a project: note id → project id.
    @Published private(set) var suggested: [String: UUID] = [:]

    private weak var deals: DealStore?
    private weak var projects: ProjectStore?
    private weak var logins: ConnectionStore?
    private weak var ai: LensAI?
    /// Emma's own choices, so the next call goes to the same place: "person:<email>" or
    /// "series:<meeting title>" → project id.
    private var remembered: [String: UUID] = [:]
    /// Summaries already placed (on a deal, a project, or set aside), so they aren't placed again.
    private var handled: Set<String> = []
    private var loop: Task<Void, Never>?

    init() { load() }

    func attach(deals: DealStore, projects: ProjectStore, logins: ConnectionStore, ai: LensAI? = nil) {
        self.ai = ai
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
            var unsure: [MeetingNote] = []
            for item in found where !handled.contains(item.id) && !unmatched.contains(where: { $0.id == item.id }) {
                guard read < 25 else { break }   // the rest wait for the next check
                read += 1
                let thread = try await GmailAPI.thread(item.id, token: token)
                guard let message = thread.messages.last(where: { GmailAPI.parseAddress($0.from).email.hasSuffix("zoom.us") }) else {
                    handled.insert(item.id)
                    continue
                }
                let summary = Self.clean(message.text)
                let note = MeetingNote(id: item.id, title: Self.title(from: message.subject), date: message.date,
                                       summary: summary,
                                       link: "https://mail.google.com/mail/?authuser=\(account)#all/\(item.id)",
                                       attendees: Self.attendees(message, summary: summary, me: me))
                foundCount += 1
                if alreadyOnFile(note.id, deals: deals, projects: projects) { handled.insert(note.id); continue }
                switch match(note, deals: deals, projects: projects) {
                case .sure(let dealID, let projectID):
                    place(note, dealID: dealID, projectID: projectID)
                case .maybe(let projectID):
                    unmatched.append(note)
                    if let projectID { suggested[note.id] = projectID }
                    unsure.append(note)
                }
            }
            if !unsure.isEmpty, ai?.hasKey == true {
                await askClaude(unsure, projects: projects)
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

    /// Who was on the call: addresses the summary email went to, or that appear in the summary.
    /// Leaves out Emma and Zoom's own addresses.
    static func attendees(_ message: GmailAPI.Message, summary: String, me: String) -> [String]? {
        var found = GmailAPI.addresses(message.to)
        if let regex = try? NSRegularExpression(pattern: "[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}") {
            let range = NSRange(summary.startIndex..., in: summary)
            for m in regex.matches(in: summary, range: range) {
                if let r = Range(m.range, in: summary) { found.append(summary[r].lowercased()) }
            }
        }
        var seen = Set<String>()
        let people = found.filter { email in
            email != me.lowercased() && !email.hasSuffix("zoom.us") && !email.contains("no-reply") && !email.contains("noreply")
                && seen.insert(email).inserted
        }
        return people.isEmpty ? nil : people
    }

    // MARK: Matching

    enum Placement {
        /// Clear enough to file by itself.
        case sure(dealID: UUID?, projectID: UUID?)
        /// Not sure. The project is Lens's best guess, if it has one.
        case maybe(projectID: UUID?)
    }

    private struct Target {
        var dealID: UUID?
        var projectID: UUID?
        var active: Bool
        var keys: [(text: String, weight: Int)]
    }

    /// Where the summary goes. Emma's earlier choices for the same people or meeting series come first.
    /// Then every deal and project is scored on what the call mentions: an email address counts most,
    /// then a person's full name, the project's name or keywords, then a last name. Anything named in the
    /// meeting title counts a little extra. Lens only files it by itself when one clearly leads.
    private func match(_ note: MeetingNote, deals: DealStore, projects: ProjectStore) -> Placement {
        for key in Self.memoryKeys(note) {
            if let id = remembered[key], let p = projects.project(id: id) {
                return .sure(dealID: deals.deals.first(where: { $0.projectID == p.id })?.id, projectID: p.id)
            }
        }
        let title = note.title.lowercased()
        let haystack = (note.title + "\n" + note.summary + "\n" + (note.attendees ?? []).joined(separator: " ")).lowercased()
        var targets: [Target] = []
        var linkedProjects = Set<UUID>()
        for d in deals.deals {
            var keys = Self.names(d.client, weight: 2)
            for c in d.contacts {
                if c.email.contains("@") { keys.append((c.email.lowercased(), 3)) }
                keys += Self.names(c.name, weight: 2)
            }
            var active = d.stage.isOpen
            if let pid = d.projectID, let p = projects.project(id: pid) {
                linkedProjects.insert(pid)
                keys += Self.projectKeys(p)
                active = active || p.stage != .archived
            }
            targets.append(Target(dealID: d.id, projectID: d.projectID, active: active, keys: keys))
        }
        for p in projects.projects where !linkedProjects.contains(p.id) {
            targets.append(Target(dealID: nil, projectID: p.id, active: p.stage != .archived, keys: Self.projectKeys(p)))
        }

        func score(_ t: Target) -> Int {
            var seen = Set<String>()
            return t.keys.reduce(0) { total, key in
                guard seen.insert(key.text).inserted, Self.mentions(haystack, key.text) else { return total }
                return total + key.weight + (Self.mentions(title, key.text) ? 1 : 0)
            }
        }
        let scored = targets.map { ($0, score($0)) }.filter { $0.1 > 0 }
        // Prefer gigs that are still going; fall back to older ones.
        let pool = scored.contains { $0.0.active } ? scored.filter { $0.0.active } : scored
        let sorted = pool.sorted { $0.1 > $1.1 }
        guard let top = sorted.first else { return .maybe(projectID: nil) }
        let runnerUp = sorted.count > 1 ? sorted[1].1 : 0
        if runnerUp == top.1 { return .maybe(projectID: nil) }
        // Sure: a strong lead (an email, or a name plus something else), or one clear name with nothing competing.
        if (top.1 >= 3 && top.1 - runnerUp >= 2) || (top.1 >= 2 && runnerUp == 0) {
            return .sure(dealID: top.0.dealID, projectID: top.0.projectID)
        }
        return .maybe(projectID: top.0.projectID)
    }

    /// What points to a project: its client, its people, its name and Emma's keywords.
    private static func projectKeys(_ p: Project) -> [(text: String, weight: Int)] {
        var keys = names(p.client, weight: 2)
        for person in p.people ?? [] {
            if person.email.contains("@") { keys.append((person.email.lowercased(), 3)) }
            keys += names(person.name, weight: 2)
        }
        let name = p.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.count >= 4 { keys.append((name, 2)) }
        for word in p.keywords ?? [] {
            let k = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // A keyword alone ("documentary") only suggests; in the meeting title (+1) it's enough to file.
            if k.count >= 2 { keys.append((k, 1)) }
        }
        return keys
    }

    /// The people on the call and the meeting series, for remembering where Emma put a note.
    static func memoryKeys(_ note: MeetingNote) -> [String] {
        var keys: [String] = []
        if let series = series(note.title) { keys.append("series:" + series) }
        keys += (note.attendees ?? []).map { "person:" + $0.lowercased() }
        return keys
    }

    /// "CU documentary check-in 3" and "CU documentary check-in 4" are the same series. Zoom's
    /// default names ("Emma's Zoom Meeting") are too general to count.
    static func series(_ title: String) -> String? {
        let t = title.lowercased()
            .replacingOccurrences(of: "[0-9#]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let general = ["zoom meeting", "zoom call", "personal meeting room", "meeting", "call", "quick call", "catch up", "check in"]
        if t.count < 4 || general.contains(where: { t == $0 || t.hasSuffix("'s " + $0) || t.hasSuffix("’s " + $0) }) { return nil }
        return t
    }

    /// Asks Claude to pick the project for notes Lens wasn't sure about, from Emma's open projects.
    /// Sure answers are filed; the rest become one-tap suggestions.
    private func askClaude(_ notes: [MeetingNote], projects: ProjectStore) async {
        guard let ai else { return }
        let open = projects.active
        guard !open.isEmpty else { return }
        let known: [[String: Any]] = open.map { p in
            ["id": p.id.uuidString, "name": p.name, "client": p.client, "keywords": p.keywords ?? [],
             "people": (p.people ?? []).map { "\($0.name) (\($0.role)) \($0.email)" },
             "earlier_calls": (p.meetingNotes ?? []).prefix(8).map(\.title)]
        }
        let calls: [[String: Any]] = notes.map {
            ["note_id": $0.id, "title": $0.title, "date": $0.date.formatted(.iso8601.year().month().day()),
             "attendees": $0.attendees ?? [], "summary": String($0.summary.prefix(3000))]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["projects": known, "notes": calls], options: [.sortedKeys]),
              let answers = try? await ai.placeNotes(String(decoding: data, as: UTF8.self)) else { return }
        for a in answers {
            guard let noteID = a["note_id"] as? String, let note = unmatched.first(where: { $0.id == noteID }),
                  let id = UUID(uuidString: (a["project_id"] as? String) ?? ""), open.contains(where: { $0.id == id }) else { continue }
            if (a["sure"] as? Bool) == true {
                place(note, dealID: deals?.deals.first(where: { $0.projectID == id })?.id, projectID: id)
            } else {
                suggested[noteID] = id
            }
        }
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
        suggested.removeValue(forKey: note.id)
        handled.insert(note.id)
    }

    /// Remembers where Emma put a note, for the people on the call and the meeting series.
    private func remember(_ note: MeetingNote, projectID: UUID) {
        for key in Self.memoryKeys(note) { remembered[key] = projectID }
    }

    /// Unmatched notes Lens thinks belong to this project, for the one-tap Add on the project page.
    func suggestions(for projectID: UUID) -> [MeetingNote] {
        unmatched.filter { suggested[$0.id] == projectID }
    }

    /// The project Lens suggests for an unmatched note, if any.
    func suggestedProject(for note: MeetingNote) -> UUID? { suggested[note.id] }

    /// Emma picked the deal for an unmatched summary (it goes on the deal's project too, once booked).
    func assign(_ note: MeetingNote, toDeal id: UUID) {
        place(note, dealID: id, projectID: deals?.deal(id: id)?.projectID)
        save()
    }

    /// Emma picked the project (it goes on the deal it came from too). Lens remembers the choice.
    func assign(_ note: MeetingNote, toProject id: UUID) {
        place(note, dealID: deals?.deals.first(where: { $0.projectID == id })?.id, projectID: id)
        remember(note, projectID: id)
        save()
    }

    /// Takes the note off wherever it is and puts it on another project. Lens remembers the choice.
    func move(_ note: MeetingNote, toProject id: UUID) {
        removeEverywhere(note)
        assign(note, toProject: id)
    }

    private func removeEverywhere(_ note: MeetingNote) {
        for d in deals?.deals ?? [] where (d.meetingNotes ?? []).contains(where: { $0.id == note.id }) {
            deals?.removeNote(note.id, from: d.id)
        }
        for p in projects?.projects ?? [] where (p.meetingNotes ?? []).contains(where: { $0.id == note.id }) {
            projects?.removeNote(note.id, from: p.id)
        }
    }

    /// Not about any client: set it aside for good.
    func dismiss(_ note: MeetingNote) {
        unmatched.removeAll { $0.id == note.id }
        suggested.removeValue(forKey: note.id)
        handled.insert(note.id)
        save()
    }

    /// It landed on the wrong deal or project: take it off and let Emma pick again.
    func unassign(_ note: MeetingNote) {
        removeEverywhere(note)
        // Whatever Lens remembered for this call was wrong: forget it.
        for key in Self.memoryKeys(note) { remembered.removeValue(forKey: key) }
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
        var suggested: [String: UUID]?
        var remembered: [String: UUID]?
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
        suggested = saved.suggested ?? [:]
        remembered = saved.remembered ?? [:]
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let saved = Saved(unmatched: unmatched, handled: Array(handled), lastChecked: lastChecked,
                          foundCount: foundCount, newestSummary: newestSummary,
                          suggested: suggested, remembered: remembered)
        if let data = try? encoder.encode(saved) { try? data.write(to: DealStore.url("zoom_notes.json"), options: .atomic) }
    }
}
