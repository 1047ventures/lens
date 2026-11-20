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
            }
        } catch {
            // Gmail or Claude didn't answer: carry on from here next hour.
        }
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
            summaries[thread.id] = Summary(summary: s("summary"), decisions: (a["decisions"] as? [String] ?? []).filter { !$0.isEmpty },
                                           updated: Date(), history: history)
            let link = gmail.threadLink(thread, me: me)

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
                let amount = (q["amount"] as? Double) ?? (q["amount"] as? Int).map(Double.init) ?? 0
                guard amount > 0, let quotes else { continue }
                if quotes.quotes.contains(where: { $0.location == link.link && $0.amount == amount }) { continue }
                var quote = Quote(date: day.date(from: (q["date"] as? String) ?? "") ?? link.lastDate,
                                  client: s("client"), title: ((q["what"] as? String) ?? "").isEmpty ? link.subject : (q["what"] as? String ?? ""))
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
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: DealStore.url("email_history.json")),
              let saved = try? decoder.decode(Saved.self, from: data) else { return }
        summaries = saved.summaries ?? [:]
        pageToken = saved.pageToken
        done = saved.done ?? false
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Saved(summaries: summaries, pageToken: pageToken, done: done)) {
            try? data.write(to: DealStore.url("email_history.json"), options: .atomic)
        }
    }
}
