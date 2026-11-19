import Foundation

/// Finds Emma's Zoom AI Companion summaries and attaches each one to the deal or project it's about,
/// matched by the client's name or email (and, for summaries read from Zoom, who was in the call).
/// When Zoom is connected, Lens reads every full summary straight from Zoom: on the first connect it
/// goes back as far as Zoom keeps them, then checks hourly. Otherwise it falls back to the summary
/// emails Zoom sends to Gmail. Recent summaries Lens can't place wait in a short "Unmatched notes"
/// list until Emma picks where they go; older ones are kept quietly so Ask Lens can still search them.
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
    /// While reading from Zoom: "Reading your Zoom summaries… 40 so far".
    @Published private(set) var progress: String?
    /// How many summaries Lens has read straight from Zoom, and the newest one's date.
    var zoomCount: Int { zoomRead.count }
    @Published private(set) var zoomNewest: Date?
    /// Every summary read from Zoom has been read, back to the oldest Zoom keeps.
    @Published private(set) var backfillDone = false

    private weak var deals: DealStore?
    private weak var projects: ProjectStore?
    private weak var logins: ConnectionStore?
    /// Summaries already placed (on a deal, a project, or set aside), so they aren't placed again.
    private var handled: Set<String> = []
    private var loop: Task<Void, Never>?
    /// Older summaries that didn't match a client, or that Emma set aside. Not shown as a to-do,
    /// but Ask Lens can still read them.
    private(set) var kept: [MeetingNote] = []
    /// Zoom meeting ids already read from Zoom.
    private var zoomRead: Set<String> = []
    /// Summaries older than this are still to be read on the first pass through her Zoom history.
    private var backfillCursor: Date?
    private var lastZoomSync: Date?
    /// The Zoom app can only see her own meetings (not the whole account's summary list).
    private var userLevel = false
    /// Notes Emma said aren't for a client, so the same meeting read again from Zoom stays out of the way.
    private var dismissedStubs: [Stub] = []
    private var again = false

    /// Zoom's AI summaries started in 2023, so there's nothing older to look for.
    private static let oldest = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2023, month: 1, day: 1).date!
    /// Unmatched summaries newer than this go on the to-do list; older ones are just kept.
    private static let recentDays = 60.0

    init() { load() }

    func attach(deals: DealStore, projects: ProjectStore, logins: ConnectionStore) {
        self.deals = deals
        self.projects = projects
        self.logins = logins
        updateReport()
    }

    var ready: Bool { (logins?.zoomConnected ?? false) || (logins?.gmailReady ?? false) }

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

    /// Reads from Zoom when it's connected, otherwise from Gmail.
    func check() async {
        guard ready, let logins, let deals, let projects else { return }
        // Already checking: go round once more when it finishes (for example, Zoom was just connected).
        if checking { again = true; return }
        checking = true
        defer { checking = false; progress = nil }
        repeat {
            again = false
            if logins.zoomConnected {
                await checkZoom(logins: logins, deals: deals, projects: projects)
            } else if logins.gmailReady {
                await checkGmail(logins: logins, deals: deals, projects: projects)
            }
        } while again
    }

    // MARK: Straight from Zoom

    private func checkZoom(logins: ConnectionStore, deals: DealStore, projects: ProjectStore) async {
        var attempts = 0
        while true {
            do {
                try await syncZoom(logins: logins, deals: deals, projects: projects)
                problem = nil
                lastChecked = Date()
                break
            } catch let failure as ZoomAuth.Failure where failure.code == "rate_limited" && attempts < 5 {
                // Zoom wants a pause; carry on where Lens left off.
                attempts += 1
                save()
                try? await Task.sleep(for: .seconds(60))
            } catch {
                problem = ZoomAuth.explain(error).message
                break
            }
        }
        unmatched.sort { $0.date > $1.date }
        updateReport()
        save()
    }

    private func syncZoom(logins: ConnectionStore, deals: DealStore, projects: ProjectStore) async throws {
        let started = Date()
        // New summaries since the last look, with a few days' overlap in case Zoom finished one late.
        let since = (lastZoomSync ?? started.addingTimeInterval(-30 * 86400)).addingTimeInterval(-3 * 86400)
        if !userLevel {
            do {
                try await readWindow(from: since, to: started, logins: logins, deals: deals, projects: projects)
            } catch let failure as ZoomAuth.Failure where failure.code == "missing_scope" {
                // This Zoom app can't list the account's summaries; go through her own meetings instead.
                userLevel = true
            }
        }
        if userLevel {
            try await readPastMeetings(logins: logins, deals: deals, projects: projects)
            backfillDone = true
        }
        if backfillCursor == nil { backfillCursor = since }
        lastZoomSync = started
        save()

        // First time: go back through her Zoom history a month at a time, saving after each month.
        while !backfillDone, let cursor = backfillCursor {
            let from = max(cursor.addingTimeInterval(-30 * 86400), Self.oldest)
            try await readWindow(from: from, to: cursor, logins: logins, deals: deals, projects: projects)
            backfillCursor = from
            if from <= Self.oldest { backfillDone = true }
            updateReport()
            save()
        }
    }

    private func readWindow(from: Date, to: Date, logins: ConnectionStore, deals: DealStore, projects: ProjectStore) async throws {
        var page: String?
        repeat {
            let result = try await ZoomAPI.summaries(from: from, to: to, pageToken: page, token: try await logins.zoomAccessToken())
            for ref in result.refs {
                try await read(ref, logins: logins, deals: deals, projects: projects)
            }
            page = result.next
        } while page != nil
    }

    private func readPastMeetings(logins: ConnectionStore, deals: DealStore, projects: ProjectStore) async throws {
        var page: String?
        repeat {
            let result = try await ZoomAPI.pastMeetings(pageToken: page, token: try await logins.zoomAccessToken())
            for ref in result.refs {
                try await read(ref, logins: logins, deals: deals, projects: projects)
            }
            page = result.next
        } while page != nil
    }

    /// Reads one meeting's full summary and puts it where it belongs.
    private func read(_ ref: ZoomAPI.Ref, logins: ConnectionStore, deals: DealStore, projects: ProjectStore) async throws {
        let key = "zoom:" + ref.uuid
        if handled.contains(key) || zoomRead.contains(ref.uuid) { return }
        if allNotes(deals: deals, projects: projects).contains(where: { $0.zoomMeetingID == ref.uuid }) {
            zoomRead.insert(ref.uuid)
            return
        }
        try? await Task.sleep(for: .milliseconds(150))   // gentle on Zoom
        let token = try await logins.zoomAccessToken()
        guard let s = try await ZoomAPI.summary(ref, token: token) else {
            // No summary for this meeting. A call that only just ended may still get one, so look again later.
            if (ref.start ?? .distantPast) < Date().addingTimeInterval(-86400) { handled.insert(key) }
            return
        }
        let host = s.hostEmail?.lowercased() ?? ""
        let people = await ZoomAPI.people(ref, token: token).filter { host.isEmpty || $0.email != host }
        let shortText = s.overview.isEmpty ? (s.sections.first?.text ?? "") : s.overview
        let note = MeetingNote(id: key, title: s.title, date: s.date, summary: shortText,
                               link: s.link ?? "https://zoom.us/meeting", source: "zoom", zoomMeetingID: ref.uuid,
                               overview: s.overview, sections: s.sections, nextSteps: s.nextSteps, people: people)
        zoomRead.insert(ref.uuid)
        handled.insert(key)
        if zoomNewest.map({ note.date > $0 }) ?? true { zoomNewest = note.date }
        progress = "Reading your Zoom summaries… \(zoomRead.count) so far"
        if !logins.isConfirmed("zoom") { logins.setConfirmed("zoom", true) }

        // The same call Lens already has from its Gmail email: swap in the full summary, same place.
        if let twin = allNotes(deals: deals, projects: projects).first(where: { !$0.fromZoom && Self.sameMeeting($0, note) }) {
            upgrade(twin, to: note, deals: deals, projects: projects)
            return
        }
        if dismissedStubs.contains(where: { $0.matches(note) }) {
            kept.append(note)
            return
        }
        if let target = Self.match(note, deals: deals, projects: projects) {
            place(note, dealID: target.dealID, projectID: target.projectID)
        } else if note.date > Date().addingTimeInterval(-Self.recentDays * 86400) {
            unmatched.append(note)
        } else {
            kept.append(note)
        }
    }

    /// Replaces a Gmail note with the full Zoom summary, keeping it wherever it already is.
    private func upgrade(_ old: MeetingNote, to new: MeetingNote, deals: DealStore, projects: ProjectStore) {
        var full = new
        full.id = old.id
        for d in deals.deals where (d.meetingNotes ?? []).contains(where: { $0.id == old.id }) { deals.attachNote(full, to: d.id) }
        for p in projects.projects where (p.meetingNotes ?? []).contains(where: { $0.id == old.id }) { projects.attachNote(full, to: p.id) }
        if let i = unmatched.firstIndex(where: { $0.id == old.id }) {
            unmatched[i] = full
            // With who was in the call, Lens may now know where it goes.
            if let target = Self.match(full, deals: deals, projects: projects) {
                place(full, dealID: target.dealID, projectID: target.projectID)
            }
        }
        if let i = kept.firstIndex(where: { $0.id == old.id }) { kept[i] = full }
    }

    /// The Gmail email and the Zoom summary of one call: same meeting name, within two days.
    nonisolated static func sameMeeting(_ a: MeetingNote, _ b: MeetingNote) -> Bool {
        normal(a.title) == normal(b.title) && abs(a.date.timeIntervalSince(b.date)) < 2 * 86400
    }

    nonisolated private static func normal(_ title: String) -> String {
        String(title.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Every note Lens has: on deals, on projects, unmatched and kept.
    func allNotes(deals: DealStore, projects: ProjectStore) -> [MeetingNote] {
        var seen = Set<String>()
        let all = deals.deals.flatMap { $0.meetingNotes ?? [] } + projects.projects.flatMap { $0.meetingNotes ?? [] } + unmatched + kept
        return all.filter { seen.insert($0.id).inserted }
    }

    /// "143 summaries read · newest Nov 18", shown in Log-ins.
    private func updateReport() {
        guard let logins else { return }
        guard logins.zoomConnected else { logins.zoomReport = nil; return }
        let n = zoomRead.count
        var text = "\(n) summar\(n == 1 ? "y" : "ies") read"
        if let newest = zoomNewest { text += " · newest \(newest.formatted(.dateTime.month(.abbreviated).day()))" }
        logins.zoomReport = text
    }

    // MARK: From Gmail (when Zoom isn't connected)

    private func checkGmail(logins: ConnectionStore, deals: DealStore, projects: ProjectStore) async {
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
                // Lens already read this call's full summary from Zoom.
                if allNotes(deals: deals, projects: projects).contains(where: { $0.fromZoom && Self.sameMeeting($0, note) }) {
                    handled.insert(note.id)
                    continue
                }
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
        let haystack = (note.title + "\n" + note.fullText).lowercased()
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

    /// Not about any client: set it aside for good (Ask Lens can still read it).
    func dismiss(_ note: MeetingNote) {
        unmatched.removeAll { $0.id == note.id }
        handled.insert(note.id)
        dismissedStubs.append(Stub(title: note.title, date: note.date))
        if !kept.contains(where: { $0.id == note.id }) { kept.append(note) }
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
        kept.removeAll { $0.id == note.id }
        if !unmatched.contains(where: { $0.id == note.id }) { unmatched.insert(note, at: 0) }
        save()
    }

    // MARK: Saving (zoom_notes.json)

    /// Enough to recognise a meeting Emma set aside.
    private struct Stub: Codable {
        var title: String
        var date: Date
        func matches(_ note: MeetingNote) -> Bool {
            ZoomNotes.sameMeeting(MeetingNote(id: "", title: title, date: date, summary: "", link: ""), note)
        }
    }

    private struct Saved: Codable {
        var unmatched: [MeetingNote]?
        var handled: [String]?
        var lastChecked: Date?
        var foundCount: Int?
        var newestSummary: Date?
        var kept: [MeetingNote]?
        var zoomRead: [String]?
        var zoomNewest: Date?
        var backfillCursor: Date?
        var backfillDone: Bool?
        var lastZoomSync: Date?
        var userLevel: Bool?
        var dismissed: [Stub]?
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
        kept = saved.kept ?? []
        zoomRead = Set(saved.zoomRead ?? [])
        zoomNewest = saved.zoomNewest
        backfillCursor = saved.backfillCursor
        backfillDone = saved.backfillDone ?? false
        lastZoomSync = saved.lastZoomSync
        userLevel = saved.userLevel ?? false
        dismissedStubs = saved.dismissed ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let saved = Saved(unmatched: unmatched, handled: Array(handled), lastChecked: lastChecked,
                          foundCount: foundCount, newestSummary: newestSummary, kept: kept, zoomRead: Array(zoomRead),
                          zoomNewest: zoomNewest, backfillCursor: backfillCursor, backfillDone: backfillDone,
                          lastZoomSync: lastZoomSync, userLevel: userLevel, dismissed: dismissedStubs)
        if let data = try? encoder.encode(saved) { try? data.write(to: DealStore.url("zoom_notes.json"), options: .atomic) }
    }
}
