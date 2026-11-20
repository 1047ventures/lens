import Foundation

/// Goes through every work conversation in Emma's Gmail (the ones she replied to, going back three years),
/// and for each one keeps a short summary of what was discussed and decided. It fills in the people's
/// details (phone, company, role) in People, and adds any price she quoted to her quote history.
/// After the first pass it keeps up with new replies every hour. Saved in email_history.json.
@MainActor
final class EmailHistory: ObservableObject {
    struct Summary: Codable, Hashable {
        var summary: String
        var decisions: [String]
        var updated: Date
        /// Gmail's change counter when Lens read it, so it's only read again when something new arrives.
        var history: String
        // Added for finding Emma's current work. Optional so older saved summaries still load.
        var subject: String?
        var lastDate: Date?
        var client: String?
        var kind: String?
        /// "booked", "ongoing", "upcoming", "potential", "done" or "other".
        var status: String?
        var projectName: String?
        var people: [String]?
    }

    @Published private(set) var summaries: [String: Summary] = [:]
    @Published private(set) var progress: String?
    @Published private(set) var done = false

    private weak var logins: ConnectionStore?
    private weak var gmail: GmailSync?
    private weak var people: PeopleStore?
    private weak var quotes: QuoteStore?
    private weak var ai: LensAI?
    private var pageToken: String?
    private var running = false
    private var loop: Task<Void, Never>?

    static let query = "in:sent newer_than:3y -in:chats"

    init() { load() }

    func attach(logins: ConnectionStore, gmail: GmailSync, people: PeopleStore, quotes: QuoteStore, ai: LensAI) {
        self.logins = logins
        self.gmail = gmail
        self.people = people
        self.quotes = quotes
        self.ai = ai
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            // Let the regular email check go first.
            try? await Task.sleep(for: .seconds(90))
            while !Task.isCancelled {
                await self?.run()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// The summary of one conversation, if Lens has read it and it's about work.
    func summary(for threadID: String) -> Summary? {
        guard let s = summaries[threadID], !s.summary.isEmpty else { return nil }
        return s
    }

    var workCount: Int { summaries.values.filter { !$0.summary.isEmpty }.count }

    func run() async {
        guard !running, let logins, logins.gmailReady, ai?.hasKey == true else { return }
        running = true
        defer { running = false; progress = nil }
        do {
            let token = try await logins.googleAccessToken()
            // New replies in the last few days.
            let recent = try await GmailAPI.threadPage(matching: "in:sent newer_than:3d", pageToken: nil, max: 50, token: token)
            try await process(recent.threads)
            // The first time: everything she replied to, a page at a time, saving as it goes.
            while !done {
                let page = try await GmailAPI.threadPage(matching: Self.query, pageToken: pageToken, max: 40,
                                                         token: try await logins.googleAccessToken())
                try await process(page.threads)
                pageToken = page.next
                if page.next == nil { done = true }
                save()
                // Gmail gives the newest first, so after a few hundred conversations Lens knows the current work.
                if lastFind == nil && summaries.count >= 200 { await findWork(force: true) }
            }
        } catch {
            // Gmail or Claude didn't answer: carry on from here next hour.
        }
        save()
        await findWork()
    }

    // MARK: Finding Emma's current work

    private weak var deals: DealStore?
    private weak var projects: ProjectStore?
    private weak var zoom: ZoomNotes?
    /// Projects and inquiries Lens added by itself, newest first, so Emma can see and undo them.
    @Published private(set) var found: [Found] = []
    /// Names Lens has already added, or Emma removed ("removed:<name>"), so they aren't added again.
    private var known: Set<String> = []
    private var lastFind: Date?

    struct Found: Codable, Identifiable, Hashable {
        var id: UUID           // the project or deal
        var name: String
        var isProject: Bool
        var why: String
        var added: Date
    }

    func attachWork(deals: DealStore, projects: ProjectStore, zoom: ZoomNotes) {
        self.deals = deals
        self.projects = projects
        self.zoom = zoom
    }

    /// Looks at recent work email (summaries) and call notes, works out Emma's current, upcoming and
    /// possible projects, and puts each one in Lens: booked work becomes a project with its people and
    /// keywords (so its emails and calls are pulled in), possible work becomes an inquiry on Pipeline.
    /// Things already in Lens get any missing people and keywords. Runs at most every six hours.
    func findWork(force: Bool = false) async {
        guard let ai, ai.hasKey, let deals, let projects else { return }
        if !force, let lastFind, Date().timeIntervalSince(lastFind) < 6 * 3600 { return }
        let since = Date().addingTimeInterval(-270 * 86400)
        var recent: [Summary] = []
        for s in summaries.values where !s.summary.isEmpty && s.status != "other" {
            if let last = s.lastDate, last > since { recent.append(s) }
        }
        recent.sort { ($0.lastDate ?? .distantPast) > ($1.lastDate ?? .distantPast) }
        var mail: [[String: Any]] = []
        for s in recent.prefix(250) {
            var d: [String: Any] = ["summary": s.summary, "decisions": s.decisions]
            d["date"] = (s.lastDate ?? Date()).formatted(.iso8601.year().month().day())
            d["subject"] = s.subject ?? ""
            d["project"] = s.projectName ?? ""
            d["client"] = s.client ?? ""
            d["kind"] = s.kind ?? ""
            d["status"] = s.status ?? ""
            d["people"] = s.people ?? []
            mail.append(d)
        }
        let calls: [[String: Any]] = (zoom?.allNotes(deals: deals, projects: projects) ?? [])
            .filter { $0.date > since }
            .sorted { $0.date > $1.date }
            .prefix(120)
            .map { n -> [String: Any] in
                let names: [String] = (n.people ?? []).map(\.name) + (n.attendees ?? [])
                return ["date": n.date.formatted(.iso8601.year().month().day()), "title": n.title,
                 "people": names, "summary": String(n.fullText.prefix(1200))]
            }
        guard !mail.isEmpty || !calls.isEmpty else { return }
        var existing: [[String: Any]] = []
        for p in projects.projects where p.stage != .archived {
            let people: [String] = (p.people ?? []).map { "\($0.name) \($0.email)" }
            existing.append(["id": p.id.uuidString, "type": "project", "name": p.name, "client": p.client,
                             "people": people, "keywords": p.keywords ?? []])
        }
        for d in deals.deals where d.stage != .lost && d.projectID == nil {
            let people: [String] = d.contacts.map { "\($0.name) \($0.email)" }
            existing.append(["id": d.id.uuidString, "type": "deal", "name": d.title, "client": d.client, "people": people])
        }
        let removed = known.filter { $0.hasPrefix("removed:") }.map { String($0.dropFirst(8)) }
        let payload: [String: Any] = ["today": Date().formatted(.iso8601.year().month().day()), "already_in_lens": existing,
                                      "email_conversations": mail, "calls": calls, "removed_before": removed]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let work = try? await ai.findWork(String(decoding: data, as: UTF8.self)) else { return }
        lastFind = Date()
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.locale = Locale(identifier: "en_US_POSIX")

        for w in work {
            func s(_ k: String) -> String { ((w[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            let name = s("name")
            let status = s("status")
            guard !name.isEmpty, ["booked", "ongoing", "upcoming", "potential"].contains(status) else { continue }
            let people: [ProjectPerson] = (w["people"] as? [[String: Any]] ?? []).compactMap { p in
                let n = ((p["name"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
                let e = ((p["email"] as? String) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                guard !n.isEmpty || e.contains("@") else { return nil }
                return ProjectPerson(name: n.isEmpty ? e : n, email: e, role: (p["role"] as? String) ?? "")
            }
            let keywords = (w["keywords"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 2 }
            let dates = (w["dates"] as? [String] ?? []).compactMap { day.date(from: $0) }.sorted()
            let upcoming = dates.first(where: { $0 > Date().addingTimeInterval(-86400) })

            // Already in Lens: add any people and keywords it's missing, so its emails and calls come in.
            if let id = UUID(uuidString: s("existing_id")) {
                if projects.project(id: id) != nil {
                    projects.edit(id) { p in
                        var list = p.people ?? []
                        for person in people where !list.contains(where: {
                            (!person.email.isEmpty && $0.email.lowercased() == person.email) || $0.name.lowercased() == person.name.lowercased()
                        }) { list.append(person) }
                        p.people = list.isEmpty ? nil : list
                        var words = p.keywords ?? []
                        for k in keywords where !words.contains(where: { $0.lowercased() == k.lowercased() }) { words.append(k) }
                        p.keywords = words.isEmpty ? nil : words
                        if p.shootDate == nil, let upcoming { p.shootDate = upcoming }
                    }
                }
                continue
            }
            let key = name.lowercased()
            guard (w["sure"] as? Bool) == true, !known.contains(key), !known.contains("removed:" + key),
                  !projects.projects.contains(where: { $0.name.lowercased() == key }),
                  !deals.deals.contains(where: { $0.title.lowercased() == key }) else { continue }
            known.insert(key)
            let why = s("why")
            if status == "potential" {
                var deal = Deal(client: s("client").isEmpty ? name : s("client"), title: name, source: "Found in email", stage: .inquiry,
                                lastTouch: Date(), createdAt: Date())
                deal.contacts = people.map { Contact(name: $0.name, role: $0.role, email: $0.email) }
                deal.eventDate = upcoming
                deal.callNotes = why
                deals.add(deal)
                found.insert(Found(id: deal.id, name: name, isProject: false, why: why, added: Date()), at: 0)
            } else {
                var project = Project(name: name, client: s("client"), shootDate: upcoming ?? dates.first,
                                      stage: status == "ongoing" ? .edit : .booked)
                project.people = people.isEmpty ? nil : people
                project.keywords = keywords.isEmpty ? nil : keywords
                projects.add(project)
                found.insert(Found(id: project.id, name: name, isProject: true, why: why, added: Date()), at: 0)
            }
        }
        save()
    }

    /// Emma took something Lens added back out: remove it and don't add it again.
    func undo(_ item: Found) {
        if item.isProject, let p = projects?.project(id: item.id) { projects?.delete(p) }
        if !item.isProject, let d = deals?.deal(id: item.id) { deals?.delete(d) }
        found.removeAll { $0.id == item.id }
        known.insert("removed:" + item.name.lowercased())
        save()
    }

    /// Emma is happy with it: stop showing it in the "found" list.
    func keep(_ item: Found) {
        found.removeAll { $0.id == item.id }
        save()
    }


    private func process(_ items: [(id: String, history: String)]) async throws {
        guard let logins, let ai, let gmail else { return }
        let todo = items.filter { summaries[$0.id]?.history != $0.history }
        guard !todo.isEmpty else { return }
        let me = logins.ownerEmail
        var batch: [(GmailAPI.Thread, String)] = []
        for item in todo {
            let thread = try await GmailAPI.thread(item.id, token: try await logins.googleAccessToken())
            guard !thread.messages.isEmpty else { continue }
            batch.append((thread, item.history))
            if batch.count == 8 {
                try await read(batch, me: me, ai: ai, gmail: gmail)
                batch = []
            }
        }
        if !batch.isEmpty { try await read(batch, me: me, ai: ai, gmail: gmail) }
    }

    private func read(_ batch: [(GmailAPI.Thread, String)], me: String, ai: LensAI, gmail: GmailSync) async throws {
        let conversations: [[String: Any]] = batch.map { thread, _ in
            ["thread_id": thread.id,
             "subject": thread.messages.first(where: { !$0.subject.isEmpty })?.subject ?? "",
             "messages": thread.messages.suffix(10).map { m -> [String: Any] in
                 ["from": m.from, "to": m.to, "date": m.date.formatted(.iso8601), "text": String(m.text.prefix(3000))]
             }]
        }
        let payload: [String: Any] = ["emma_email": me, "today": Date().formatted(.iso8601.year().month().day()),
                                      "conversations": conversations]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let answers = try await ai.readConversations(String(decoding: data, as: UTF8.self))
        let byID = Dictionary(answers.compactMap { a in (a["thread_id"] as? String).map { ($0, a) } }, uniquingKeysWith: { a, _ in a })
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.locale = Locale(identifier: "en_US_POSIX")

        for (thread, history) in batch {
            guard let a = byID[thread.id], (a["is_work"] as? Bool) == true else {
                // Not about work (or Claude skipped it): remember it was read, keep nothing.
                summaries[thread.id] = Summary(summary: "", decisions: [], updated: Date(), history: history)
                continue
            }
            func s(_ k: String) -> String { ((a[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            let link = gmail.threadLink(thread, me: me)
            var summary = Summary(summary: s("summary"), decisions: (a["decisions"] as? [String] ?? []).filter { !$0.isEmpty },
                                  updated: Date(), history: history)
            summary.subject = link.subject
            summary.lastDate = link.lastDate
            summary.client = s("client")
            summary.kind = s("kind_of_work")
            summary.status = s("work_status")
            summary.projectName = s("project_name")
            summary.people = link.people
            summaries[thread.id] = summary

            // The person: details go into People, and the conversation goes on their page.
            if let who = a["person"] as? [String: Any] {
                func p(_ k: String) -> String { ((who[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
                let email = p("email").lowercased()
                if !p("name").isEmpty || email.contains("@") {
                    var person = Person(name: p("name").isEmpty ? email : p("name"), emails: email.contains("@") ? [email] : [], automatic: true)
                    person.phone = p("phone")
                    person.company = p("company")
                    person.role = p("role")
                    person.met = "Email"
                    person.addedFrom = "Gmail"
                    person.addedOn = Date()
                    person.threads = [link]
                    people?.bringIn([person])
                }
            }
            people?.noteThread(thread, link: link, me: me, onFile: true)

            // Prices she quoted in the conversation go into her quote history.
            for q in a["quotes"] as? [[String: Any]] ?? [] {
                var amount: Double = 0
                if let d = q["amount"] as? Double { amount = d } else if let i = q["amount"] as? Int { amount = Double(i) }
                guard amount > 0, let quotes else { continue }
                if quotes.quotes.contains(where: { $0.location == link.link && $0.amount == amount }) { continue }
                let what: String = (q["what"] as? String) ?? ""
                let when: Date = day.date(from: (q["date"] as? String) ?? "") ?? link.lastDate
                var quote = Quote(date: when, client: s("client"), title: what.isEmpty ? link.subject : what)
                quote.amount = amount
                quote.source = "Email"
                quote.location = link.link
                quote.kind = s("kind_of_work")
                quote.status = (q["status"] as? String) ?? ""
                quotes.add(quote)
            }
        }
        progress = "Reading your email history… \(summaries.count) conversations so far"
        save()
    }

    // MARK: Saving (email_history.json)

    private struct Saved: Codable {
        var summaries: [String: Summary]?
        var pageToken: String?
        var done: Bool?
        var found: [Found]?
        var known: [String]?
        var lastFind: Date?
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: DealStore.url("email_history.json")),
              let saved = try? decoder.decode(Saved.self, from: data) else { return }
        summaries = saved.summaries ?? [:]
        pageToken = saved.pageToken
        done = saved.done ?? false
        found = saved.found ?? []
        known = Set(saved.known ?? [])
        lastFind = saved.lastFind
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Saved(summaries: summaries, pageToken: pageToken, done: done, found: found,
                                               known: Array(known), lastFind: lastFind)) {
            try? data.write(to: DealStore.url("email_history.json"), options: .atomic)
        }
    }
}
