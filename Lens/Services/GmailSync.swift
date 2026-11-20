import Foundation

// MARK: - Gmail (read-only)

/// Reads the user's Gmail through Google's Gmail API, using the read-only permission from Google sign-in.
enum GmailAPI {
    struct Message {
        let from: String
        let to: String
        let replyTo: String
        let subject: String
        let date: Date
        let text: String
    }

    struct Thread {
        let id: String
        let messages: [Message]
        let snippet: String
    }

    private static func get(_ path: String, query: [URLQueryItem] = [], token: String) async throws -> [String: Any] {
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/" + path)!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data: Data
        do { (data, _) = try await URLSession.shared.data(for: request) } catch { throw GoogleAuth.explain(error) }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if json["error"] != nil { throw GoogleAuth.Failure(message: "Gmail didn't answer just now. Lens will try again in a while.") }
        return json
    }

    /// Thread ids (with Gmail's change counter) matching a Gmail search, newest first.
    static func threadIDs(matching q: String, max: Int, token: String) async throws -> [(id: String, history: String)] {
        let json = try await get("threads", query: [URLQueryItem(name: "q", value: q),
                                                    URLQueryItem(name: "maxResults", value: String(max))], token: token)
        return (json["threads"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? String else { return nil }
            return (id, ($0["historyId"] as? String) ?? "")
        }
    }

    static func thread(_ id: String, token: String) async throws -> Thread {
        let json = try await get("threads/\(id)", query: [URLQueryItem(name: "format", value: "full")], token: token)
        let messages = (json["messages"] as? [[String: Any]] ?? []).map(message)
        let snippet = ((json["messages"] as? [[String: Any]])?.last?["snippet"] as? String) ?? ""
        return Thread(id: id, messages: messages, snippet: decodeEntities(snippet))
    }

    private static func message(_ m: [String: Any]) -> Message {
        let payload = m["payload"] as? [String: Any] ?? [:]
        var headers: [String: String] = [:]
        for h in payload["headers"] as? [[String: Any]] ?? [] {
            if let name = (h["name"] as? String)?.lowercased(), let value = h["value"] as? String { headers[name] = value }
        }
        let millis = Double((m["internalDate"] as? String) ?? "") ?? 0
        return Message(from: headers["from"] ?? "", to: [headers["to"], headers["cc"]].compactMap { $0 }.joined(separator: ", "),
                       replyTo: headers["reply-to"] ?? "", subject: headers["subject"] ?? "",
                       date: millis > 0 ? Date(timeIntervalSince1970: millis / 1000) : Date(),
                       text: bodyText(payload))
    }

    /// The readable text of a message: the plain part when there is one, otherwise the HTML with tags removed.
    private static func bodyText(_ payload: [String: Any]) -> String {
        var plain: String?
        var html: String?
        func walk(_ part: [String: Any]) {
            let type = (part["mimeType"] as? String) ?? ""
            if let data = (part["body"] as? [String: Any])?["data"] as? String, let text = decode(data) {
                if type == "text/plain", plain == nil { plain = text }
                if type == "text/html", html == nil { html = text }
            }
            for child in part["parts"] as? [[String: Any]] ?? [] { walk(child) }
        }
        walk(payload)
        if let plain { return plain }
        guard let html else { return "" }
        let stripped = html
            .replacingOccurrences(of: "<(style|script)[^>]*>[\\s\\S]*?</\\1>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<br\\s*/?>|</p>|</div>|</tr>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return decodeEntities(stripped)
    }

    private static func decode(_ base64url: String) -> String? {
        var s = base64url.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Jane Doe <jane@x.com>" → ("Jane Doe", "jane@x.com").
    static func parseAddress(_ raw: String) -> (name: String, email: String) {
        let first = raw.split(separator: ",").first.map(String.init) ?? raw
        if let open = first.firstIndex(of: "<"), let close = first.firstIndex(of: ">"), open < close {
            let email = String(first[first.index(after: open)..<close]).trimmingCharacters(in: .whitespaces).lowercased()
            let name = String(first[..<open]).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            return (name.isEmpty ? email : name, email)
        }
        let email = first.trimmingCharacters(in: .whitespaces).lowercased()
        return (email, email)
    }

    /// Every email address in a header like To or Cc.
    static func addresses(_ raw: String) -> [String] {
        raw.split(separator: ",").map { parseAddress(String($0)).email }.filter { $0.contains("@") }
    }
}

// MARK: - Suggestions

/// Something Lens found in Gmail that the user decides on: a new inquiry, new booked work (Add project),
/// or a conversation Lens wasn't sure about ("Which project is this for?").
struct EmailSuggestion: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case inquiry, project, attach }

    var id: String { thread.id }
    var kind: Kind
    var person: String
    var email: String
    var client: String
    var title: String
    var wants: String
    var eventDate: Date?
    var location: String
    var budget: String
    var source: String
    /// For `.attach`: the deal or project this conversation belongs to. On Projects this is only Lens's best
    /// guess (sure ones are filed by themselves); both empty means Lens has no guess.
    var targetDealID: UUID?
    var targetProjectID: UUID?
    var targetName: String?
    var thread: EmailThread

    var displayTitle: String {
        if !title.isEmpty { return title }
        if !client.isEmpty { return client }
        return thread.subject.isEmpty ? "An email" : thread.subject
    }
}

/// Looks through recent Gmail when Lens opens and every hour after, and turns new inquiries and booked
/// work into suggestions. Conversations that clearly belong to a project (people on it, the user's earlier
/// choices, or Claude is sure) are filed there by themselves and listed under "Filed automatically".
/// When Lens isn't sure it asks "Which project is this for?". No new deal or project is made until the user says so.
@MainActor
final class GmailSync: ObservableObject {
    @Published private(set) var suggestions: [EmailSuggestion] = []
    @Published private(set) var checking = false
    @Published private(set) var lastChecked: Date?
    /// A plain sentence when the last check didn't work.
    @Published private(set) var problem: String?

    private weak var deals: DealStore?
    private weak var projects: ProjectStore?
    private weak var logins: ConnectionStore?
    private weak var ai: LensAI?
    private weak var people: PeopleStore?
    private var ignored: Set<String> = []
    /// Gmail's change counter for each conversation already looked at, so it's only read again when something new arrives.
    private var seen: [String: String] = [:]
    /// the user's own choices: "person:<email>" → project, so their next emails go to the same place.
    private var remembered: [String: UUID] = [:]
    /// Conversations the user said aren't for a project: thread id → those projects, so Lens doesn't put them back.
    private var notFor: [String: [UUID]] = [:]
    private var loop: Task<Void, Never>?

    /// Website builders and directories whose lead emails count as inquiries.
    static let leadSenders: [(domain: String, source: String)] = [
        ("theknot.com", "The Knot"), ("weddingwire.com", "WeddingWire"), ("thumbtack.com", "Thumbtack"),
        ("zola.com", "Zola"), ("yelp.com", "Yelp"), ("business.google.com", "Google"),
        ("squarespace.com", "Website form"), ("squarespace-mail.com", "Website form"), ("wix.com", "Website form"),
        ("wixforms.com", "Website form"), ("showit.co", "Website form"), ("honeybook.com", "Website form"),
        ("jotform.com", "Website form"), ("typeform.com", "Website form"), ("formspree.io", "Website form"),
        ("acuityscheduling.com", "Website form"),
    ]

    init() { load() }

    func attach(deals: DealStore, projects: ProjectStore, logins: ConnectionStore, ai: LensAI, people: PeopleStore? = nil) {
        self.people = people
        self.deals = deals
        self.projects = projects
        self.logins = logins
        self.ai = ai
    }

    var ready: Bool { logins?.gmailReady ?? false }
    var canSortWithClaude: Bool { ai?.hasKey ?? false }

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

    func suggestions(for kinds: Set<EmailSuggestion.Kind>, deals forDeals: Bool) -> [EmailSuggestion] {
        suggestions.filter { s in
            guard kinds.contains(s.kind) else { return false }
            if s.kind == .attach {
                if forDeals { return s.targetDealID != nil && s.targetProjectID == nil }
                return s.targetProjectID != nil || s.targetDealID == nil
            }
            return true
        }
    }

    // MARK: Checking

    func check() async {
        guard !checking, ready, let logins, let deals, let projects else { return }
        checking = true
        defer { checking = false }
        do {
            let token = try await logins.googleAccessToken()
            let me = logins.ownerEmail
            let skip = "-in:chats -in:spam -in:trash"
            var found = try await GmailAPI.threadIDs(
                matching: "newer_than:21d \(skip) -category:promotions -category:social", max: 40, token: token)
            let leadQuery = Self.leadSenders.map { "from:\($0.domain)" }.joined(separator: " ")
            for extra in try await GmailAPI.threadIDs(
                matching: "newer_than:21d \(skip) {\(leadQuery) subject:inquiry subject:enquiry subject:\"form submission\" subject:\"new lead\" subject:\"new appointment\"}",
                max: 20, token: token) where !found.contains(where: { $0.id == extra.id }) {
                found.append(extra)
            }
            // Instagram and Facebook email the user when someone messages her. Those land in Social, so look for them too.
            for extra in try await GmailAPI.threadIDs(
                matching: "newer_than:21d \(skip) {from:facebookmail.com from:instagram.com from:mail.instagram.com} {subject:message subject:messaged subject:messages}",
                max: 15, token: token) where !found.contains(where: { $0.id == extra.id }) {
                found.append(extra)
            }

            var fresh: [(GmailAPI.Thread, EmailThread)] = []
            for item in found where seen[item.id] != item.history {
                guard fresh.count < 30 else { break }   // the rest wait for the next check
                let thread = try await GmailAPI.thread(item.id, token: token)
                guard !thread.messages.isEmpty else { seen[item.id] = item.history; continue }
                // Someone messaged the user on Instagram or Facebook: they go in People.
                if Self.isSocial(thread) {
                    people?.noteSocial(thread)
                    seen[item.id] = item.history
                    continue
                }
                let link = threadLink(thread, me: me)
                // Already linked to a deal or project: just bring the conversation up to date.
                if linkKnown(link, deals: deals, projects: projects) || linkByMemory(link, deals: deals, projects: projects)
                    || linkByContact(thread, link, me: me, deals: deals, projects: projects) {
                    people?.noteThread(thread, link: link, me: me, onFile: true)
                    suggestions.removeAll { $0.id == item.id && $0.kind != .attach }
                    seen[item.id] = item.history
                    continue
                }
                // Put the conversation on the page of anyone in People, and suggest new people from real two-way conversations.
                people?.noteThread(thread, link: link, me: me, onFile: false)
                if ignored.contains(item.id) { seen[item.id] = item.history; continue }
                fresh.append((thread, link))
            }

            if !fresh.isEmpty {
                let sorted = canSortWithClaude ? try await sortWithClaude(fresh, deals: deals, projects: projects, me: me)
                                               : fresh.compactMap { leadByRules($0.0, $0.1, me: me) }
                for s in sorted {
                    suggestions.removeAll { $0.id == s.id }
                    suggestions.append(s)
                }
                let histories = Dictionary(found.map { ($0.id, $0.history) }, uniquingKeysWith: { a, _ in a })
                for (thread, _) in fresh { seen[thread.id] = histories[thread.id] ?? "" }
            }
            suggestions.sort { $0.thread.lastDate > $1.thread.lastDate }
            // People who keep turning up on one project's calls and emails go on its People list.
            projects.addRegulars()
            lastChecked = Date()
            problem = nil
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "Lens couldn't check your email just now."
        }
        save()
    }

    /// An Instagram or Facebook notification email.
    static func isSocial(_ thread: GmailAPI.Thread) -> Bool {
        guard let first = thread.messages.first else { return false }
        let domain = GmailAPI.parseAddress(first.from).email.split(separator: "@").last.map { String($0).lowercased() } ?? ""
        return domain == "facebookmail.com" || domain.hasSuffix(".facebookmail.com")
            || domain == "instagram.com" || domain.hasSuffix(".instagram.com")
    }

    private func threadLink(_ thread: GmailAPI.Thread, me: String) -> EmailThread {
        let last = thread.messages.last!
        let subject = thread.messages.first(where: { !$0.subject.isEmpty })?.subject ?? ""
        let from = GmailAPI.parseAddress(last.from)
        let account = me.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? me
        var people: [String] = [], seen = Set<String>()
        for m in thread.messages {
            for raw in [m.from, m.to, m.replyTo].flatMap({ $0.split(separator: ",").map(String.init) }) {
                let a = GmailAPI.parseAddress(raw)
                guard a.email.contains("@"), a.email != me, seen.insert(a.email).inserted else { continue }
                people.append(a.name == a.email ? a.email : "\(a.name) <\(a.email)>")
            }
        }
        return EmailThread(id: thread.id, subject: subject, from: from.email == me ? "You" : from.name,
                           snippet: String(thread.snippet.prefix(220)), lastDate: last.date,
                           messageCount: thread.messages.count,
                           link: "https://mail.google.com/mail/?authuser=\(account)#all/\(thread.id)",
                           people: people.isEmpty ? nil : people)
    }

    /// The conversation is already on a deal or project (added from email earlier): refresh it there.
    private func linkKnown(_ link: EmailThread, deals: DealStore, projects: ProjectStore) -> Bool {
        var linked = false
        for d in deals.deals where (d.emails ?? []).contains(where: { $0.id == link.id }) {
            deals.attachEmail(link, to: d.id); linked = true
        }
        for p in projects.projects where (p.emails ?? []).contains(where: { $0.id == link.id }) {
            projects.attachEmail(link, to: p.id); linked = true
        }
        return linked
    }

    /// Someone already listed on a deal is in the conversation: link it to that deal (and its project, once booked).
    private func linkByContact(_ thread: GmailAPI.Thread, _ link: EmailThread, me: String, deals: DealStore, projects: ProjectStore) -> Bool {
        var people = Set<String>()
        for m in thread.messages {
            people.formUnion(GmailAPI.addresses(m.from) + GmailAPI.addresses(m.to) + GmailAPI.addresses(m.replyTo))
        }
        people.remove(me)
        guard !people.isEmpty else { return false }
        var linked = false
        let declined = notFor[link.id] ?? []
        let matches = deals.deals.filter { d in
            !(d.projectID.map(declined.contains) ?? false) && d.contacts.contains { people.contains($0.email.lowercased()) }
        }
        // A person on several deals: only link when it's clear which one (a single open deal).
        let open = matches.filter { $0.stage.isOpen }
        let pick = open.count == 1 ? open : (open.isEmpty && matches.count == 1 ? matches : [])
        if let deal = pick.first {
            deals.attachEmail(link, to: deal.id)
            if let projectID = deal.projectID { fileOnProject(link, projectID, deals: deals, projects: projects) }
            linked = true
        }
        // Someone on a project's people list (a director, an interviewee, crew): link it to that project,
        // when only one project that's still going has them.
        let onProjects = projects.active.filter { p in
            !declined.contains(p.id) && (p.people ?? []).contains { $0.email.contains("@") && people.contains($0.email.lowercased()) }
        }
        if onProjects.count == 1, let p = onProjects.first {
            fileOnProject(link, p.id, deals: deals, projects: projects)
            linked = true
        }
        return linked
    }

    /// the user put an earlier email with the same people on a project: this one goes there too.
    private func linkByMemory(_ link: EmailThread, deals: DealStore, projects: ProjectStore) -> Bool {
        let declined = notFor[link.id] ?? []
        let picks = Set(Self.emails(in: link).compactMap { remembered["person:" + $0] }
            .filter { id in !declined.contains(id) && projects.active.contains { $0.id == id } })
        guard picks.count == 1, let id = picks.first else { return false }
        fileOnProject(link, id, deals: deals, projects: projects)
        return true
    }

    /// Files the conversation on the project (and the deal it came from) by itself, and lists it under
    /// "Filed automatically" so the user can see it and undo it.
    private func fileOnProject(_ link: EmailThread, _ projectID: UUID, deals: DealStore, projects: ProjectStore) {
        let already = (projects.project(id: projectID)?.emails ?? []).contains { $0.id == link.id }
        projects.attachEmail(link, to: projectID)
        if let deal = deals.deals.first(where: { $0.projectID == projectID }) { deals.attachEmail(link, to: deal.id) }
        suggestions.removeAll { $0.id == link.id }
        if !already {
            projects.logAutoFiled(AutoFiled(kind: .email, itemID: link.id, title: link.subject.isEmpty ? "An email" : link.subject,
                                            source: "Email"), on: projectID)
        }
    }

    /// Every conversation with the people on a project, however old, filed on that project. Runs when
    /// people are added to a project, so its whole email history shows up, not just the last few weeks.
    func backfill(_ project: Project) async {
        guard let logins, let deals, let projects, logins.googleConnected else { return }
        let me = logins.ownerEmail.lowercased()
        let emails = Set((project.people ?? []).map { $0.email.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("@") && $0 != me })
        guard !emails.isEmpty else { return }
        do {
            let token = try await logins.googleAccessToken()
            let terms = emails.sorted().flatMap { ["from:\($0)", "to:\($0)", "cc:\($0)"] }.joined(separator: " ")
            let found = try await GmailAPI.threadIDs(matching: "{\(terms)} -in:spam -in:trash -in:chats", max: 150, token: token)
            for item in found {
                if (notFor[item.id] ?? []).contains(project.id) { continue }
                if (projects.project(id: project.id)?.emails ?? []).contains(where: { $0.id == item.id }) { continue }
                let thread = try await GmailAPI.thread(item.id, token: token)
                guard !thread.messages.isEmpty else { continue }
                let link = threadLink(thread, me: logins.ownerEmail)
                // Older history: filed quietly, not listed one by one under "Filed automatically".
                projects.attachEmail(link, to: project.id)
                if let deal = deals.deals.first(where: { $0.projectID == project.id }) { deals.attachEmail(link, to: deal.id) }
                suggestions.removeAll { $0.id == link.id }
                people?.noteThread(thread, link: link, me: logins.ownerEmail, onFile: true)
                seen[item.id] = item.history
            }
            save()
        } catch {
            // The next regular check tries again.
        }
    }

    /// The email addresses in a conversation (not the user's).
    static func emails(in link: EmailThread) -> [String] {
        (link.people ?? []).map { GmailAPI.parseAddress($0).email }.filter { $0.contains("@") }
    }

    /// Without Claude: website forms, directories and emails that say "inquiry" become inquiry suggestions.
    private func leadByRules(_ thread: GmailAPI.Thread, _ link: EmailThread, me: String) -> EmailSuggestion? {
        guard let first = thread.messages.first else { return nil }
        let sender = GmailAPI.parseAddress(first.from)
        guard sender.email != me else { return nil }
        let domain = sender.email.split(separator: "@").last.map(String.init) ?? ""
        let directory = Self.leadSenders.first { domain == $0.domain || domain.hasSuffix("." + $0.domain) }
        let subject = first.subject.lowercased()
        let asks = ["inquiry", "enquiry", "form submission", "new lead", "new appointment", "videographer", "availability", "quote"]
        guard directory != nil || asks.contains(where: subject.contains) else { return nil }
        var person = first.replyTo.isEmpty ? sender : GmailAPI.parseAddress(first.replyTo)
        // Booking forms like Acuity send from their own no-reply address: the client's email is in the message.
        if directory != nil, person.email == sender.email, let client = Self.clientEmail(in: first.text, me: me, sender: sender.email) {
            person = (name: Self.clientName(in: first.text) ?? client, email: client)
        }
        return EmailSuggestion(kind: .inquiry, person: person.name, email: person.email, client: person.name,
                               title: "", wants: String(first.text.prefix(300)), eventDate: nil, location: "",
                               budget: "", source: directory?.source ?? "Email", thread: link)
    }

    /// The first email address in a form or booking email that isn't Emma's or the form service's.
    static func clientEmail(in text: String, me: String, sender: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}") else { return nil }
        let senderDomain = sender.split(separator: "@").last.map(String.init) ?? ""
        for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text) else { continue }
            let email = text[r].lowercased()
            if email == me.lowercased() || email.hasSuffix("@" + senderDomain) || email.contains("no-reply") || email.contains("noreply") { continue }
            if leadSenders.contains(where: { email.hasSuffix("@" + $0.domain) || email.hasSuffix("." + $0.domain) }) { continue }
            return email
        }
        return nil
    }

    /// "Name: Jane Smith" (or "Client: …") in a form or booking email.
    static func clientName(in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            for label in ["Name:", "Client:", "Full name:", "Client name:"] where l.lowercased().hasPrefix(label.lowercased()) {
                let v = l.dropFirst(label.count).trimmingCharacters(in: .whitespaces)
                if !v.isEmpty && v.count < 60 { return v }
            }
        }
        return nil
    }

    private func sortWithClaude(_ fresh: [(GmailAPI.Thread, EmailThread)], deals: DealStore, projects: ProjectStore,
                                me: String) async throws -> [EmailSuggestion] {
        guard let ai else { return [] }
        let day = Date().formatted(.iso8601.year().month().day())
        let known: [[String: Any]] = deals.deals.filter { $0.stage != .lost }.map {
            ["id": $0.id.uuidString, "type": "deal", "client": $0.client, "title": $0.title,
             "people": $0.contacts.map { "\($0.name) \($0.email)" }]
        } + projects.projects.filter { $0.stage != .archived }.map {
            ["id": $0.id.uuidString, "type": "project", "client": $0.client, "title": $0.name,
             "keywords": $0.keywords ?? [], "people": ($0.people ?? []).map { "\($0.name) (\($0.role)) \($0.email)" }]
        }
        let conversations: [[String: Any]] = fresh.map { thread, link in
            ["thread_id": thread.id, "subject": link.subject,
             "messages": thread.messages.suffix(4).map { m -> [String: Any] in
                 ["from": m.from, "to": m.to, "reply_to": m.replyTo, "date": m.date.formatted(.iso8601),
                  "text": String(m.text.prefix(2500))]
             }]
        }
        let payload: [String: Any] = ["today": day, "emma_email": me, "already_in_lens": known, "conversations": conversations]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let answers = try await ai.sortEmails(String(decoding: data, as: UTF8.self))

        let links = Dictionary(fresh.map { ($0.0.id, $0.1) }, uniquingKeysWith: { a, _ in a })
        let dayFormat = DateFormatter()
        dayFormat.dateFormat = "yyyy-MM-dd"
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        return answers.compactMap { a in
            func s(_ k: String) -> String { ((a[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let link = links[s("thread_id")] else { return nil }
            var suggestion = EmailSuggestion(kind: .inquiry, person: s("person"), email: s("email").lowercased(),
                                             client: s("client"), title: s("title"), wants: s("wants"),
                                             eventDate: dayFormat.date(from: s("event_date")), location: s("location"),
                                             budget: s("budget"), source: s("source").isEmpty ? "Email" : s("source"),
                                             thread: link)
            switch s("kind") {
            case "inquiry": return suggestion
            case "project": suggestion.kind = .project; return suggestion
            case "existing":
                let id = UUID(uuidString: s("existing_id"))
                suggestion.kind = .attach
                let sure = (a["sure"] as? Bool) == true
                // A booked deal counts as its project.
                let projectID = projects.project(id: id)?.id ?? deals.deal(id: id)?.projectID
                if let projectID, let project = projects.project(id: projectID) {
                    if sure && !(notFor[link.id] ?? []).contains(projectID) {
                        fileOnProject(link, projectID, deals: deals, projects: projects)
                        return nil
                    }
                    // Not sure: Lens asks, with this project as its best guess.
                    suggestion.targetProjectID = project.id
                    suggestion.targetName = project.name
                    return suggestion
                }
                if let deal = deals.deal(id: id) {
                    suggestion.targetDealID = deal.id
                    suggestion.targetName = deal.title
                    return suggestion
                }
                if let project = projects.project(id: id) {
                    suggestion.targetProjectID = project.id
                    suggestion.targetName = project.name
                    return suggestion
                }
                return nil
            default: return nil
            }
        }
    }

    // MARK: the user's choices

    /// Adds the suggestion where it belongs. Returns the new deal or project, so the screen can open it.
    @discardableResult
    func add(_ s: EmailSuggestion) -> UUID? {
        guard let deals, let projects else { return nil }
        suggestions.removeAll { $0.id == s.id }
        defer { save() }
        let name = s.client.isEmpty ? s.person : s.client
        switch s.kind {
        case .inquiry:
            var deal = Deal(client: name.isEmpty ? "New client" : name, title: s.displayTitle, source: s.source, stage: .inquiry,
                            contacts: s.email.isEmpty ? [] : [Contact(name: s.person.isEmpty ? s.email : s.person, role: "", email: s.email)],
                            location: s.location, eventDate: s.eventDate, budgetHint: s.budget, callNotes: s.wants,
                            lastTouch: s.thread.lastDate, createdAt: Date())
            deal.events = [ProjectEvent(text: "Inquiry came in by \(s.source == "Email" ? "email" : s.source)")]
            deal.options = [ScopeOption.starter()]
            deal.emails = [s.thread]
            deals.add(deal)
            return deal.id
        case .project:
            var project = Project(name: s.displayTitle, client: name, shootDate: s.eventDate, location: s.location, stage: .booked)
            project.events = [ProjectEvent(text: "Added from your email: \(s.thread.subject)")]
            project.emails = [s.thread]
            projects.add(project)
            return project.id
        case .attach:
            if let id = s.targetDealID { deals.attachEmail(s.thread, to: id); return id }
            if let id = s.targetProjectID { projects.attachEmail(s.thread, to: id); return id }
            return nil
        }
    }

    /// the user answered "Which project is this for?". The email goes there (and on its deal), and Lens
    /// remembers the people in it for next time.
    func file(_ s: EmailSuggestion, into projectID: UUID) {
        guard let deals, let projects else { return }
        suggestions.removeAll { $0.id == s.id }
        projects.attachEmail(s.thread, to: projectID)
        if let deal = deals.deals.first(where: { $0.projectID == projectID }) { deals.attachEmail(s.thread, to: deal.id) }
        notFor[s.id]?.removeAll { $0 == projectID }
        for e in Self.emails(in: s.thread) { remembered["person:" + e] = projectID }
        save()
    }

    /// A new project for booked work Lens spotted, filled in with what the email says.
    func draft(for s: EmailSuggestion) -> Project {
        let name = s.client.isEmpty ? s.person : s.client
        var p = Project(name: s.displayTitle, client: name, shootDate: s.eventDate, location: s.location, stage: .booked)
        p.events = [ProjectEvent(text: "Added from your email: \(s.thread.subject)")]
        var people: [ProjectPerson] = []
        var seen = Set<String>()
        if s.email.contains("@") {
            seen.insert(s.email.lowercased())
            people.append(ProjectPerson(name: s.person.isEmpty ? s.email : s.person, email: s.email.lowercased(), role: "Client"))
        }
        for raw in s.thread.people ?? [] {
            let a = GmailAPI.parseAddress(raw)
            guard a.email.contains("@"), !PeopleStore.isAutomated(a.email), seen.insert(a.email).inserted else { continue }
            people.append(ProjectPerson(name: a.name, email: a.email, role: ""))
        }
        p.people = people.isEmpty ? nil : people
        return p
    }

    /// A project was just made: emails waiting for an answer from the same people go on it by themselves.
    func refile(into projectID: UUID) {
        guard let deals, let projects, let project = projects.project(id: projectID) else { return }
        let people = Set((project.people ?? []).map { $0.email.lowercased() }.filter { $0.contains("@") })
        guard !people.isEmpty else { return }
        for s in suggestions where s.kind == .project || (s.kind == .attach && (s.targetProjectID != nil || s.targetDealID == nil)) {
            guard !(notFor[s.id] ?? []).contains(projectID),
                  !people.isDisjoint(with: Self.emails(in: s.thread) + [s.email.lowercased()]) else { continue }
            fileOnProject(s.thread, projectID, deals: deals, projects: projects)
        }
        save()
    }

    /// From "Filed automatically": Lens put this email on the wrong project. Take it off there (and its
    /// deal), forget what pointed there, and ask "Which project is this for?" again.
    func notThisProject(_ threadID: String, from projectID: UUID) {
        guard let thread = unfile(threadID, from: projectID) else { return }
        notFor[threadID, default: []].append(projectID)
        if !suggestions.contains(where: { $0.id == threadID }) {
            suggestions.insert(EmailSuggestion(kind: .attach, person: thread.from, email: "", client: "", title: "", wants: "",
                                               eventDate: nil, location: "", budget: "", source: "Email", thread: thread), at: 0)
        }
        save()
    }

    /// From "Filed automatically": put this email on another project instead. Lens remembers.
    func move(_ threadID: String, from: UUID, to: UUID) {
        guard let thread = unfile(threadID, from: from) else { return }
        notFor[threadID, default: []].append(from)
        file(EmailSuggestion(kind: .attach, person: thread.from, email: "", client: "", title: "", wants: "",
                             eventDate: nil, location: "", budget: "", source: "Email", thread: thread), into: to)
    }

    private func unfile(_ threadID: String, from projectID: UUID) -> EmailThread? {
        guard let deals, let projects else { return nil }
        projects.dropAutoFiled(.email, itemID: threadID, from: projectID)
        guard let thread = projects.project(id: projectID)?.emails?.first(where: { $0.id == threadID }) else { return nil }
        projects.removeEmail(threadID, from: projectID)
        for d in deals.deals where d.projectID == projectID { deals.removeEmail(threadID, from: d.id) }
        for e in Self.emails(in: thread) where remembered["person:" + e] == projectID { remembered.removeValue(forKey: "person:" + e) }
        return thread
    }

    func ignore(_ s: EmailSuggestion) {
        suggestions.removeAll { $0.id == s.id }
        ignored.insert(s.id)
        save()
    }

    // MARK: Saving (gmail.json; only thread ids and what the user will see, never passwords)

    private struct Saved: Codable {
        var suggestions: [EmailSuggestion]?
        var ignored: [String]?
        var seen: [String: String]?
        var lastChecked: Date?
        var remembered: [String: UUID]?
        var notFor: [String: [UUID]]?
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: DealStore.url("gmail.json")),
              let saved = try? decoder.decode(Saved.self, from: data) else { return }
        suggestions = saved.suggestions ?? []
        ignored = Set(saved.ignored ?? [])
        seen = saved.seen ?? [:]
        lastChecked = saved.lastChecked
        remembered = saved.remembered ?? [:]
        notFor = saved.notFor ?? [:]
    }

    private func save() {
        // Gmail only searches the last three weeks, so older bookkeeping can go once the lists get long.
        if seen.count > 3000 { seen = [:] }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let saved = Saved(suggestions: suggestions, ignored: Array(ignored.suffix(3000)), seen: seen, lastChecked: lastChecked,
                          remembered: remembered, notFor: notFor)
        if let data = try? encoder.encode(saved) { try? data.write(to: DealStore.url("gmail.json"), options: .atomic) }
    }
}
