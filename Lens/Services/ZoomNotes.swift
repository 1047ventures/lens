import Foundation

/// Finds the user's Zoom AI Companion summaries and attaches each one to the deal or project it's about.
/// When Zoom is connected, Lens reads every full summary straight from Zoom: on the first connect it
/// goes back as far as Zoom keeps them, then checks hourly. Otherwise it falls back to the summary
/// emails Zoom sends to Gmail. Lens files a call by itself only on a clear match: someone on the call
/// (by email or full name) is one of an inquiry's or project's people, or the client's name is in the
/// meeting title, and only one place fits. Everything else waits under "Not placed" (recent ones) or is
/// kept quietly (older ones) so Ask Lens can still search them; Claude may suggest a project but never
/// files one. When the user picks or moves a note, Lens remembers that choice for the people on the
/// call and the meeting series.
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
    /// Lens's best guess for unmatched notes: note id → project id. Listed first when Lens asks, never filed by itself.
    @Published private(set) var suggested: [String: UUID] = [:]
    /// While reading from Zoom: "Reading your Zoom summaries… 40 so far".
    @Published private(set) var progress: String?
    /// How many summaries Lens has read straight from Zoom, and the newest one's date.
    var zoomCount: Int { zoomRead.count }
    @Published private(set) var zoomNewest: Date?
    /// Every summary read from Zoom has been read, back to the oldest Zoom keeps.
    @Published private(set) var backfillDone = false
    /// Set when Zoom won't let Lens read My Notes (the Zoom app needs the My Notes permissions).
    @Published private(set) var myNotesProblem: String?
    /// How many My Notes calls Lens has read.
    var myNotesCount: Int { myNotesRead.count }

    private weak var deals: DealStore?
    private weak var projects: ProjectStore?
    private weak var logins: ConnectionStore?
    private weak var ai: LensAI?
    /// the user's own choices, so the next call goes to the same place: "person:<email>" or
    /// "series:<meeting title>" → project id.
    private var remembered: [String: UUID] = [:]
    /// Summaries already placed (on a deal, a project, or set aside), so they aren't placed again.
    private var handled: Set<String> = []
    private var loop: Task<Void, Never>?
    /// Older summaries that didn't match a client, or that the user set aside. Not shown as a to-do,
    /// but Ask Lens can still read them.
    private(set) var kept: [MeetingNote] = []
    /// Zoom meeting ids already read from Zoom.
    private var zoomRead: Set<String> = []
    /// Summaries older than this are still to be read on the first pass through her Zoom history.
    private var backfillCursor: Date?
    private var lastZoomSync: Date?
    /// The Zoom app can only see her own meetings (not the whole account's summary list).
    private var userLevel = false
    /// Which list of summaries this Zoom app may read: "mine" (her own, the usual) or "account".
    private var summaryList: String?
    /// Placements have been checked again under the stricter matching rules.
    private var recheckVersion = 0
    /// My Notes notes already read, and how far back Lens has looked through them.
    private var myNotesRead: Set<String> = []
    private var myNotesCursor: Date?
    private var myNotesDone = false
    private var lastMyNotesSync: Date?
    /// Notes the user said aren't for a client, so the same meeting read again from Zoom stays out of the way.
    private var dismissedStubs: [Stub] = []
    private var again = false

    /// Zoom's AI summaries started in 2023, so there's nothing older to look for.
    private static let oldest = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2023, month: 1, day: 1).date!
    /// Unmatched summaries newer than this go on the to-do list; older ones are just kept.
    private static let recentDays = 60.0

    init() { load() }

    func attach(deals: DealStore, projects: ProjectStore, logins: ConnectionStore, ai: LensAI? = nil) {
        self.ai = ai
        self.deals = deals
        self.projects = projects
        self.logins = logins
        updateReport()
        recheckPlacements()
    }

    /// Once, after the matching rules got stricter: looks again at every summary Lens filed by itself and
    /// keeps it only where the new rules clearly agree. The rest are taken off and wait under "Not placed".
    /// Summaries Emma put somewhere herself (for those same people) stay where she put them. Zoom emails
    /// that aren't call summaries at all (offers, newsletters) are taken off and set aside.
    private func recheckPlacements() {
        guard recheckVersion < 1, let deals, let projects else { return }
        let onFile = deals.deals.flatMap { $0.meetingNotes ?? [] } + projects.projects.flatMap { $0.meetingNotes ?? [] }
        var seen = Set<String>()
        for note in onFile where seen.insert(note.id).inserted {
            let onProjects = Set(projects.projects.filter { ($0.meetingNotes ?? []).contains { $0.id == note.id } }.map(\.id))
            let onDeals = Set(deals.deals.filter { ($0.meetingNotes ?? []).contains { $0.id == note.id } }.map(\.id))
            // Emma's own choice for the people on this call.
            let chosen = Self.memoryKeys(note).filter { $0.hasPrefix("person:") }.compactMap { remembered[$0] }
            if chosen.contains(where: { onProjects.contains($0) }) { continue }
            if !note.fromZoom && !Self.looksLikeSummary(note) {
                removeEverywhere(note)
                handled.insert(note.id)
                kept.append(note)
                continue
            }
            switch match(note, deals: deals, projects: projects, useMemory: false) {
            case .sure(let dealID, let projectID):
                let same = projectID.map { onProjects == [$0] } ?? (onProjects.isEmpty && dealID.map { onDeals.contains($0) } == true)
                if same { continue }
                removeEverywhere(note)
                place(note, dealID: dealID, projectID: projectID, auto: true)
            case .maybe:
                removeEverywhere(note)
                handled.insert(note.id)
                if !unmatched.contains(where: { $0.id == note.id }) { unmatched.append(note) }
            }
        }
        unmatched.sort { $0.date > $1.date }
        recheckVersion = 1
        save()
    }

    /// A Zoom email that is really a call summary, not an offer or a newsletter.
    nonisolated static func looksLikeSummary(_ note: MeetingNote) -> Bool {
        let t = note.fullText.lowercased()
        return ["quick recap", "next steps", "summary", "action items", "key points"].contains { t.contains($0) }
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
        // Emma decides who is on a project: Lens only suggests people (People tab).
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

        // Calls she recorded with Zoom My Notes (phone calls too). Kept separate so a missing permission
        // there doesn't stop the meeting summaries.
        do {
            try await syncMyNotes(logins: logins, deals: deals, projects: projects)
            myNotesProblem = nil
        } catch let failure as ZoomAuth.Failure where failure.code == "missing_scope" {
            myNotesProblem = "Zoom isn't letting Lens read My Notes yet. Add the My Notes permissions to the Lens app in Zoom, then click Connect Zoom again."
        }

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

    // MARK: Zoom My Notes

    /// Zoom's My Notes started in 2025, so there's nothing older to look for.
    private static let myNotesOldest = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2025, month: 1, day: 1).date!

    private func syncMyNotes(logins: ConnectionStore, deals: DealStore, projects: ProjectStore) async throws {
        let now = Date()
        // Recent days, one day at a time so each note gets the right date.
        let since = (lastMyNotesSync ?? now.addingTimeInterval(-7 * 86400)).addingTimeInterval(-2 * 86400)
        try await readMyNotesByDay(from: since, to: now, logins: logins, deals: deals, projects: projects)
        if myNotesCursor == nil { myNotesCursor = since }
        lastMyNotesSync = now
        save()
        // First time: go back a week at a time, and day by day inside any week that has notes.
        while !myNotesDone, let cursor = myNotesCursor {
            let from = max(cursor.addingTimeInterval(-7 * 86400), Self.myNotesOldest)
            let week = try await ZoomAPI.myNotes(from: from, to: cursor, pageToken: nil, token: try await logins.zoomAccessToken())
            if !week.notes.isEmpty {
                try await readMyNotesByDay(from: from, to: cursor, logins: logins, deals: deals, projects: projects)
            }
            myNotesCursor = from
            if from <= Self.myNotesOldest { myNotesDone = true }
            save()
        }
    }

    private func readMyNotesByDay(from: Date, to: Date, logins: ConnectionStore, deals: DealStore, projects: ProjectStore) async throws {
        var dayStart = from
        while dayStart < to {
            let dayEnd = min(dayStart.addingTimeInterval(86400), to)
            var page: String?
            repeat {
                let result = try await ZoomAPI.myNotes(from: dayStart, to: dayEnd, pageToken: page, token: try await logins.zoomAccessToken())
                for ref in result.notes where !myNotesRead.contains(ref.id) {
                    try await readMyNote(ref, day: dayStart, logins: logins, deals: deals, projects: projects)
                }
                page = result.next
            } while page != nil
            dayStart = dayEnd
            try? await Task.sleep(for: .milliseconds(120))   // gentle on Zoom
        }
    }

    /// Reads one My Notes call (Zoom's notes and the transcript), writes a summary with Claude when Zoom
    /// didn't, and files it like any other call.
    private func readMyNote(_ ref: ZoomAPI.MyNoteRef, day: Date, logins: ConnectionStore, deals: DealStore, projects: ProjectStore) async throws {
        let key = "zoomnote:" + ref.id
        if allNotes(deals: deals, projects: projects).contains(where: { $0.id == key }) { myNotesRead.insert(ref.id); return }
        guard let n = try await ZoomAPI.myNote(ref, token: try await logins.zoomAccessToken()) else {
            myNotesRead.insert(ref.id)
            return
        }
        var parsed = n.content.isEmpty ? (overview: "", sections: [MeetingNoteSection](), nextSteps: [String]())
                                       : ZoomAPI.parseMarkdown(n.content)
        // Only a recording, no notes from Zoom: Claude writes the summary from the transcript.
        if parsed.overview.isEmpty && parsed.sections.isEmpty, !n.transcript.isEmpty, let ai, ai.hasKey,
           let written = try? await ai.summarizeCall(title: n.name, transcript: n.transcript) {
            parsed = written
        }
        let shortText = parsed.overview.isEmpty ? (parsed.sections.first?.text ?? String(n.transcript.prefix(400))) : parsed.overview
        // Noon on the day it was made, so it sorts with the rest of that day's calls.
        let date = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
        let note = MeetingNote(id: key, title: n.name, date: date, summary: shortText,
                               link: n.link.isEmpty ? "https://zoom.us" : n.link, source: "zoom_notes",
                               overview: parsed.overview, sections: parsed.sections, nextSteps: parsed.nextSteps,
                               people: n.speakers.map { MeetingPerson(name: $0, email: "") },
                               transcript: n.transcript.isEmpty ? nil : n.transcript)
        myNotesRead.insert(ref.id)
        handled.insert(key)
        progress = "Reading your Zoom My Notes… \(myNotesRead.count) so far"
        if dismissedStubs.contains(where: { $0.matches(note) }) { kept.append(note); return }
        switch match(note, deals: deals, projects: projects) {
        case .sure(let dealID, let projectID):
            place(note, dealID: dealID, projectID: projectID, auto: true)
        case .maybe(let projectID):
            if note.date > Date().addingTimeInterval(-Self.recentDays * 86400) {
                unmatched.append(note)
                if let projectID { suggested[note.id] = projectID }
            } else {
                kept.append(note)
            }
        }
    }

    private func readWindow(from: Date, to: Date, logins: ConnectionStore, deals: DealStore, projects: ProjectStore) async throws {
        var page: String?
        repeat {
            let result = try await summaryPage(from: from, to: to, pageToken: page, logins: logins)
            for ref in result.refs {
                try await read(ref, logins: logins, deals: deals, projects: projects)
            }
            page = result.next
        } while page != nil
    }

    /// One page of summaries. Tries her own list first (a User-managed app), then the whole account's
    /// (an Admin-managed app), and remembers which one Zoom allows.
    private func summaryPage(from: Date, to: Date, pageToken: String?, logins: ConnectionStore) async throws -> (refs: [ZoomAPI.Ref], next: String?) {
        if summaryList != "account" {
            do {
                let result = try await ZoomAPI.summaries(from: from, to: to, pageToken: pageToken, mine: true, token: try await logins.zoomAccessToken())
                summaryList = "mine"
                return result
            } catch let failure as ZoomAuth.Failure where failure.code == "missing_scope" && summaryList == nil {
                summaryList = "account"
            }
        }
        return try await ZoomAPI.summaries(from: from, to: to, pageToken: pageToken, mine: false, token: try await logins.zoomAccessToken())
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
        switch match(note, deals: deals, projects: projects) {
        case .sure(let dealID, let projectID):
            place(note, dealID: dealID, projectID: projectID, auto: true)
        case .maybe(let projectID):
            if note.date > Date().addingTimeInterval(-Self.recentDays * 86400) {
                unmatched.append(note)
                if let projectID { suggested[note.id] = projectID }
            } else {
                kept.append(note)
            }
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
            switch match(full, deals: deals, projects: projects) {
            case .sure(let dealID, let projectID): place(full, dealID: dealID, projectID: projectID, auto: true)
            case .maybe(let projectID): if let projectID { suggested[full.id] = projectID }
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
        var text = "\(n) summar\(n == 1 ? "y" : "ies") found"
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
            var unsure: [MeetingNote] = []
            for item in found where !handled.contains(item.id) && !unmatched.contains(where: { $0.id == item.id }) {
                guard read < 25 else { break }   // the rest wait for the next check
                read += 1
                let thread = try await GmailAPI.thread(item.id, token: token)
                // Only real AI Companion summaries, not Zoom's newsletters and offers.
                guard let message = thread.messages.last(where: { GmailAPI.parseAddress($0.from).email.hasSuffix("zoom.us") }),
                      Self.isSummaryEmail(message.subject) else {
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
                // Lens already read this call's full summary from Zoom.
                if allNotes(deals: deals, projects: projects).contains(where: { $0.fromZoom && Self.sameMeeting($0, note) }) {
                    handled.insert(note.id)
                    continue
                }
                switch match(note, deals: deals, projects: projects) {
                case .sure(let dealID, let projectID):
                    place(note, dealID: dealID, projectID: projectID, auto: true)
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
                // the user doesn't need to tick "done" in Log-ins once summaries are actually arriving.
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

    /// The subjects Zoom's AI Companion uses. Anything else from zoom.us is marketing or account mail.
    static let summaryPrefixes = ["Meeting summary for ", "Meeting assets for ", "Call summary for ", "Call summary with ", "Recap of "]

    static func isSummaryEmail(_ subject: String) -> Bool {
        let t = subject.trimmingCharacters(in: .whitespaces).lowercased()
        return summaryPrefixes.contains { t.hasPrefix($0.lowercased()) }
    }

    /// "Meeting summary for Smith wedding planning (11/18/2026)" → "Smith wedding planning".
    static func title(from subject: String) -> String {
        var t = subject.trimmingCharacters(in: .whitespaces)
        for prefix in summaryPrefixes {
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
    /// Leaves out the user and Zoom's own addresses.
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

    /// One inquiry or project a call could belong to, with the people and client names that point to it.
    private struct Target {
        var dealID: UUID?
        var projectID: UUID?
        var active: Bool
        var people: [(name: String, email: String)]
        var clients: [String]
    }

    /// Where the summary goes. Emma's own earlier choices for the same people or meeting series come first.
    /// Otherwise Lens only files a call when the match is clear: someone on the call (by email, or by full
    /// name) is one of that inquiry's or project's people, or the client's name is in the meeting title.
    /// Anything else stays "not placed" for Emma to decide. Lens never falls back to a project just because
    /// it's the only one, or because a word in the summary happens to match.
    private func match(_ note: MeetingNote, deals: DealStore, projects: ProjectStore, useMemory: Bool = true) -> Placement {
        if useMemory {
            for key in Self.memoryKeys(note) {
                if let id = remembered[key], let p = projects.project(id: id) {
                    return .sure(dealID: deals.deals.first(where: { $0.projectID == p.id })?.id, projectID: p.id)
                }
            }
        }
        let me = (logins?.ownerEmail ?? "").lowercased()
        let callEmails = Set(((note.attendees ?? []) + (note.people ?? []).map(\.email))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.contains("@") && $0 != me && !$0.hasSuffix("zoom.us") })
        let callNames = Set((note.people ?? []).filter { $0.email.lowercased() != me || me.isEmpty }
            .compactMap { Self.fullName($0.name) })
        let title = Self.plain(note.title)

        var targets: [Target] = []
        var linked = Set<UUID>()
        for d in deals.deals {
            var people = d.contacts.map { (name: $0.name, email: $0.email) }
            var clients = [d.client]
            var active = d.stage.isOpen
            if let pid = d.projectID, let p = projects.project(id: pid) {
                linked.insert(pid)
                people += (p.people ?? []).map { (name: $0.name, email: $0.email) }
                clients.append(p.client)
                active = active || p.stage != .archived
            }
            targets.append(Target(dealID: d.id, projectID: d.projectID, active: active, people: people, clients: clients))
        }
        for p in projects.projects where !linked.contains(p.id) {
            targets.append(Target(dealID: nil, projectID: p.id, active: p.stage != .archived,
                                  people: (p.people ?? []).map { (name: $0.name, email: $0.email) }, clients: [p.client]))
        }

        func clear(_ t: Target) -> Bool {
            for person in t.people {
                let email = person.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if email == me && !me.isEmpty { continue }   // Emma herself is on every call
                if email.contains("@"), callEmails.contains(email) { return true }
                if let name = Self.fullName(person.name), callNames.contains(name) { return true }
            }
            return t.clients.contains { Self.clientInTitle($0, title) }
        }
        let hits = targets.filter(clear)
        // A deal and its project are one place.
        var seen = Set<String>()
        let places = hits.filter { seen.insert(($0.projectID ?? $0.dealID)?.uuidString ?? "").inserted }
        let pool = places.count > 1 && places.contains(where: \.active) ? places.filter(\.active) : places
        guard pool.count == 1, let only = pool.first else { return .maybe(projectID: nil) }
        return .sure(dealID: only.dealID, projectID: only.projectID)
    }

    /// "Laura  Smith" → "laura smith". Nil unless it's at least a first and last name, since a first
    /// name alone ("Jason") matches too many calls.
    nonisolated static func fullName(_ raw: String) -> String? {
        let words = plain(raw).split(separator: " ")
        guard words.count >= 2, words.allSatisfy({ $0.count >= 2 }) else { return nil }
        return words.joined(separator: " ")
    }

    /// Lowercase words only, single spaces: "Artistry Skin & Hormone!" → "artistry skin hormone".
    nonisolated static func plain(_ text: String) -> String {
        text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").joined(separator: " ")
    }

    /// The client's whole name appears in the meeting title, as whole words.
    nonisolated static func clientInTitle(_ client: String, _ plainTitle: String) -> Bool {
        let c = plain(client)
        guard c.count >= 3, c != "new client", !plainTitle.isEmpty else { return false }
        return " \(plainTitle) ".contains(" \(c) ")
    }

    /// "Jason Lee" → "jason". Nil for very short names, which match too much.
    static func firstName(_ raw: String) -> String? {
        let words = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" }).map(String.init)
        guard let first = words.first, first.count >= 3 else { return nil }
        return first
    }

    /// Every Zoom summary email that names someone on this project, however old, filed on the project.
    /// Runs when people are added to a project, so its whole history shows up, not just new calls.
    func backfill(_ project: Project) async {
        guard let logins, let deals, let projects else { return }
        // Summaries Lens already has but couldn't place (waiting, or kept quietly): try again now that
        // the project has its people.
        for note in unmatched + kept {
            if case .sure(let dealID, let projectID) = match(note, deals: deals, projects: projects), projectID == project.id {
                place(note, dealID: dealID, projectID: projectID, auto: true)
                kept.removeAll { $0.id == note.id }
            }
        }
        save()
        guard logins.gmailReady else { return }
        var words = Set((project.people ?? []).compactMap { Self.firstName($0.name) })
        for person in project.people ?? [] where person.name.contains(" ") { words.insert(person.name.lowercased()) }
        for k in project.keywords ?? [] where k.count >= 3 { words.insert(k.lowercased()) }
        if project.name.count >= 4 { words.insert(project.name.lowercased()) }
        guard !words.isEmpty else { return }
        do {
            let token = try await logins.googleAccessToken()
            let me = logins.ownerEmail
            let account = me.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? me
            let names = words.sorted().map { "\"\($0)\"" }.joined(separator: " ")
            let q = "from:zoom.us {subject:\"meeting summary\" subject:\"meeting assets\" subject:\"call summary\" subject:recap} {\(names)} -in:spam -in:trash"
            for item in try await GmailAPI.threadIDs(matching: q, max: 100, token: token) {
                if alreadyOnFile(item.id, deals: deals, projects: projects) { continue }
                let thread = try await GmailAPI.thread(item.id, token: token)
                guard let message = thread.messages.last(where: { GmailAPI.parseAddress($0.from).email.hasSuffix("zoom.us") }),
                      Self.isSummaryEmail(message.subject) else { continue }
                let summary = Self.clean(message.text)
                let note = MeetingNote(id: item.id, title: Self.title(from: message.subject), date: message.date,
                                       summary: summary,
                                       link: "https://mail.google.com/mail/?authuser=\(account)#all/\(item.id)",
                                       attendees: Self.attendees(message, summary: summary, me: me))
                if allNotes(deals: deals, projects: projects).contains(where: { $0.fromZoom && Self.sameMeeting($0, note) }) { continue }
                if handled.contains(note.id) || unmatched.contains(where: { $0.id == note.id }) || kept.contains(where: { $0.id == note.id }) { continue }
                // Only filed when the match is clear. Otherwise it stays "not placed".
                switch match(note, deals: deals, projects: projects) {
                case .sure(let dealID, let projectID):
                    place(note, dealID: dealID, projectID: projectID, auto: true)
                case .maybe:
                    if note.date > Date().addingTimeInterval(-Self.recentDays * 86400) { unmatched.append(note) } else { kept.append(note) }
                    handled.insert(note.id)
                }
                foundCount += 1
            }
            save()
        } catch {
            // The next regular check tries again; nothing to tell Emma here.
        }
    }

    /// The people on the call and the meeting series, for remembering where the user put a note.
    static func memoryKeys(_ note: MeetingNote) -> [String] {
        var keys: [String] = []
        if let series = series(note.title) { keys.append("series:" + series) }
        let emails = (note.attendees ?? []) + (note.people ?? []).map(\.email).filter { $0.contains("@") }
        keys += Set(emails.map { $0.lowercased() }).sorted().map { "person:" + $0 }
        return keys
    }

    /// "CU documentary check-in 3" and "CU documentary check-in 4" are the same series. Zoom's
    /// default names ("the user's Zoom Meeting") are too general to count.
    static func series(_ title: String) -> String? {
        let t = title.lowercased()
            .replacingOccurrences(of: "[0-9#]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let general = ["zoom meeting", "zoom call", "personal meeting room", "meeting", "call", "quick call", "catch up", "check in"]
        if t.count < 4 || general.contains(where: { t == $0 || t.hasSuffix("'s " + $0) || t.hasSuffix("’s " + $0) }) { return nil }
        return t
    }

    /// Asks Claude for a best guess for notes Lens wasn't sure about, from the user's open projects.
    /// It is only a suggestion, listed first when Lens asks: Claude never files a note by itself.
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
             "attendees": $0.attendees ?? [], "summary": String($0.fullText.prefix(3000))]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["projects": known, "notes": calls], options: [.sortedKeys]),
              let answers = try? await ai.placeNotes(String(decoding: data, as: UTF8.self)) else { return }
        for a in answers {
            guard let noteID = a["note_id"] as? String, unmatched.contains(where: { $0.id == noteID }),
                  let id = UUID(uuidString: (a["project_id"] as? String) ?? ""), open.contains(where: { $0.id == id }) else { continue }
            suggested[noteID] = id
        }
    }

    // MARK: the user's choices

    /// Puts the note on its deal and project. `auto`: Lens did it by itself, so it shows under
    /// "Filed automatically" on the project.
    private func place(_ note: MeetingNote, dealID: UUID?, projectID: UUID?, auto: Bool = false) {
        if let dealID { deals?.attachNote(note, to: dealID) }
        if let projectID {
            projects?.attachNote(note, to: projectID)
            if auto {
                projects?.logAutoFiled(AutoFiled(kind: .note, itemID: note.id, title: note.title,
                                                 source: note.fromZoom ? "Zoom call" : "Zoom summary email"), on: projectID)
            }
        }
        unmatched.removeAll { $0.id == note.id }
        suggested.removeValue(forKey: note.id)
        handled.insert(note.id)
    }

    /// Remembers where the user put a note, for the people on the call and the meeting series.
    private func remember(_ note: MeetingNote, projectID: UUID) {
        for key in Self.memoryKeys(note) { remembered[key] = projectID }
    }

    /// Unmatched notes whose best guess is this project. On the project page Lens asks about them.
    func waiting(for projectID: UUID) -> [MeetingNote] {
        unmatched.filter { suggested[$0.id] == projectID }
    }

    /// Lens's best guess for an unmatched note, if it has one. Listed first, not filed.
    func bestGuess(for note: MeetingNote) -> UUID? {
        guard let id = suggested[note.id], projects?.project(id: id) != nil else { return nil }
        return id
    }

    /// A note Lens has, wherever it is.
    func note(id: String) -> MeetingNote? {
        guard let deals, let projects else { return nil }
        return allNotes(deals: deals, projects: projects).first { $0.id == id }
    }

    /// A new project for a call that looks like new work, filled in with what Lens can tell:
    /// the meeting name, who was on the call, and the meeting series as a keyword.
    func draft(for note: MeetingNote) -> Project {
        var p = Project(name: note.title, stage: .lead)
        var people: [ProjectPerson] = []
        var seen = Set<String>()
        for person in note.people ?? [] where person.email.contains("@") && seen.insert(person.email.lowercased()).inserted {
            people.append(ProjectPerson(name: person.name.isEmpty ? person.email : person.name, email: person.email.lowercased(), role: ""))
        }
        for e in note.attendees ?? [] where seen.insert(e.lowercased()).inserted {
            people.append(ProjectPerson(name: e, email: e.lowercased(), role: ""))
        }
        p.people = people.isEmpty ? nil : people
        if people.count == 1, let only = people.first, only.name != only.email { p.client = only.name }
        if let series = Self.series(note.title) { p.keywords = [series] }
        return p
    }

    /// A project was just made: file every waiting note that now clearly belongs to it (same people
    /// or meeting series). They show under "Filed automatically" so the user can undo any of them.
    func refile(into projectID: UUID) {
        guard let deals, let projects else { return }
        for note in unmatched {
            if case .sure(let dealID, let pid) = match(note, deals: deals, projects: projects), pid == projectID {
                place(note, dealID: dealID, projectID: pid, auto: true)
            }
        }
        save()
    }

    /// From "Filed automatically": Lens got it wrong. Take it off and ask again.
    func notThisProject(_ noteID: String) {
        guard let note = note(id: noteID) else { projects?.dropAutoFiled(.note, itemID: noteID); return }
        unassign(note)
    }

    /// the user picked the deal for an unmatched summary (it goes on the deal's project too, once booked).
    func assign(_ note: MeetingNote, toDeal id: UUID) {
        place(note, dealID: id, projectID: deals?.deal(id: id)?.projectID)
        save()
    }

    /// the user picked the project (it goes on the deal it came from too). Lens remembers the choice.
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

    /// Takes the note off wherever it is and puts it on an inquiry (and its project, once booked).
    func move(_ note: MeetingNote, toDeal id: UUID) {
        removeEverywhere(note)
        assign(note, toDeal: id)
        if let projectID = deals?.deal(id: id)?.projectID { remember(note, projectID: projectID) }
    }

    /// From the project page: take this call off and set it aside for good (Ask Lens can still read it).
    func remove(_ note: MeetingNote) {
        removeEverywhere(note)
        for key in Self.memoryKeys(note) { remembered.removeValue(forKey: key) }
        dismiss(note)
    }

    private func removeEverywhere(_ note: MeetingNote) {
        projects?.dropAutoFiled(.note, itemID: note.id)
        for d in deals?.deals ?? [] where (d.meetingNotes ?? []).contains(where: { $0.id == note.id }) {
            deals?.removeNote(note.id, from: d.id)
        }
        for p in projects?.projects ?? [] where (p.meetingNotes ?? []).contains(where: { $0.id == note.id }) {
            projects?.removeNote(note.id, from: p.id)
        }
        kept.removeAll { $0.id == note.id }
    }

    /// Not about any client: set it aside for good (Ask Lens can still read it).
    func dismiss(_ note: MeetingNote) {
        unmatched.removeAll { $0.id == note.id }
        suggested.removeValue(forKey: note.id)
        handled.insert(note.id)
        dismissedStubs.append(Stub(title: note.title, date: note.date))
        if !kept.contains(where: { $0.id == note.id }) { kept.append(note) }
        save()
    }

    /// It landed on the wrong deal or project: take it off and let the user pick again.
    func unassign(_ note: MeetingNote) {
        removeEverywhere(note)
        // Whatever Lens remembered for this call was wrong: forget it.
        for key in Self.memoryKeys(note) { remembered.removeValue(forKey: key) }
        if !unmatched.contains(where: { $0.id == note.id }) { unmatched.insert(note, at: 0) }
        save()
    }

    // MARK: Saving (zoom_notes.json)

    /// Enough to recognise a meeting the user set aside.
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
        var suggested: [String: UUID]?
        var remembered: [String: UUID]?
        var kept: [MeetingNote]?
        var zoomRead: [String]?
        var zoomNewest: Date?
        var backfillCursor: Date?
        var backfillDone: Bool?
        var lastZoomSync: Date?
        var userLevel: Bool?
        var dismissed: [Stub]?
        var myNotesRead: [String]?
        var myNotesCursor: Date?
        var myNotesDone: Bool?
        var lastMyNotesSync: Date?
        var summaryList: String?
        var recheckVersion: Int?
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
        kept = saved.kept ?? []
        zoomRead = Set(saved.zoomRead ?? [])
        zoomNewest = saved.zoomNewest
        backfillCursor = saved.backfillCursor
        backfillDone = saved.backfillDone ?? false
        lastZoomSync = saved.lastZoomSync
        userLevel = saved.userLevel ?? false
        dismissedStubs = saved.dismissed ?? []
        myNotesRead = Set(saved.myNotesRead ?? [])
        myNotesCursor = saved.myNotesCursor
        myNotesDone = saved.myNotesDone ?? false
        lastMyNotesSync = saved.lastMyNotesSync
        summaryList = saved.summaryList
        recheckVersion = saved.recheckVersion ?? 0
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let saved = Saved(unmatched: unmatched, handled: Array(handled), lastChecked: lastChecked,
                          foundCount: foundCount, newestSummary: newestSummary,
                          suggested: suggested, remembered: remembered, kept: kept, zoomRead: Array(zoomRead),
                          zoomNewest: zoomNewest, backfillCursor: backfillCursor, backfillDone: backfillDone,
                          lastZoomSync: lastZoomSync, userLevel: userLevel, dismissed: dismissedStubs,
                          myNotesRead: Array(myNotesRead), myNotesCursor: myNotesCursor, myNotesDone: myNotesDone,
                          lastMyNotesSync: lastMyNotesSync, summaryList: summaryList, recheckVersion: recheckVersion)
        if let data = try? encoder.encode(saved) { try? data.write(to: DealStore.url("zoom_notes.json"), options: .atomic) }
    }
}
