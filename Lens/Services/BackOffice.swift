import Foundation
import AppKit

// MARK: - What the Helper keeps

/// A brand or organisation Lens found that could be a good fit, with a pitch written for Emma to review.
struct Prospect: Codable, Identifiable, Hashable {
    enum Status: String, Codable { case ready, inGmail, skipped }

    var id = UUID()
    var organization: String
    var website: String
    var contactName: String
    var contactEmail: String
    /// Why they fit, in a sentence or two, from what Lens read about them.
    var why: String
    /// The story or visual idea the pitch leads with.
    var idea: String
    var sources: [String]
    var subject: String
    var body: String
    var found = Date()
    var status: Status = .ready
    var draftID: String? = nil
}

/// A first reply to a new inquiry, drafted for Emma to check before it goes anywhere.
struct InquiryReply: Codable, Identifiable, Hashable {
    var id: String { threadID }
    var threadID: String
    var person: String
    var to: String
    var title: String
    var subject: String
    var body: String
    var made = Date()
    var status: Prospect.Status = .ready
    var draftID: String? = nil
}

/// A Zelle "you received money" email, and what Lens did with it.
struct ZellePayment: Codable, Identifiable, Hashable {
    enum Status: String, Codable { case markedPaid, needsYou, dismissed }

    var id: String          // the Gmail thread id
    var payer: String
    var amount: Double
    var date: Date
    var receivableID: UUID?
    var matchedLabel: String?
    var status: Status
}

private struct HelperData: Codable {
    var prospects: [Prospect] = []
    var replies: [InquiryReply] = []
    var zelle: [ZellePayment] = []
    var zelleSeen: [String] = []
    var lastProspectRun: Date? = nil
    var brief: String? = nil
    var perWeek: Int? = nil
    var weekly: Bool? = nil
}

// MARK: - The Helper

/// Lens's back office. Once an hour while Lens is open it:
/// - drafts a warm first reply to each new inquiry Lens spotted in Gmail,
/// - reads Zelle "you received money" emails and marks the matching invoice paid when it's sure,
/// and once a week it researches a few new prospects and writes a pitch for each.
/// Nothing is ever sent: replies and pitches go to Gmail drafts only when Emma clicks the button.
@MainActor
final class BackOffice: ObservableObject {
    static let shared = BackOffice()

    @Published private(set) var prospects: [Prospect] = []
    @Published private(set) var replies: [InquiryReply] = []
    @Published private(set) var zelle: [ZellePayment] = []
    @Published private(set) var lastProspectRun: Date?
    @Published private(set) var findingProspects = false
    @Published private(set) var drafting = false
    @Published private(set) var checkingZelle = false
    /// A plain sentence when something didn't work.
    @Published private(set) var problem: String?
    @Published var brief: String { didSet { save() } }
    @Published var perWeek: Int { didSet { save() } }
    @Published var weekly: Bool { didSet { save() } }

    static let defaultBrief = """
    Purpose-driven organizations, nonprofits, wellness businesses and founders in Denver, Boulder and the Front Range \
    who would get real value from authentic photo and video storytelling: brand shoots, mission films, event coverage \
    and on-camera confidence. Good signs: a new program, launch, anniversary, event or fundraising campaign coming up, \
    or a website with few real photos of their own people.
    """

    private weak var gmail: GmailSync?
    private weak var deals: DealStore?
    private weak var projects: ProjectStore?
    private weak var people: PeopleStore?
    private weak var money: MoneyStore?
    private weak var logins: ConnectionStore?
    private var zelleSeen: Set<String> = []
    private var loop: Task<Void, Never>?

    private init() {
        let saved = Self.read()
        prospects = saved.prospects
        replies = saved.replies
        zelle = saved.zelle
        zelleSeen = Set(saved.zelleSeen)
        lastProspectRun = saved.lastProspectRun
        brief = saved.brief ?? Self.defaultBrief
        perWeek = saved.perWeek ?? 5
        weekly = saved.weekly ?? true
    }

    func attach(gmail: GmailSync, deals: DealStore, projects: ProjectStore, people: PeopleStore, money: MoneyStore, logins: ConnectionStore) {
        self.gmail = gmail
        self.deals = deals
        self.projects = projects
        self.people = people
        self.money = money
        self.logins = logins
    }

    /// Starts after Gmail has had a moment to look, then runs every hour while Lens is open.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            while !Task.isCancelled {
                await self?.runOnce()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func runOnce() async {
        await checkZelle()
        await draftReplies()
        if weekly, prospectsDue { await findProspects() }
    }

    // MARK: What needs her

    var readyReplies: [InquiryReply] { replies.filter { $0.status == .ready } }
    var readyProspects: [Prospect] { prospects.filter { $0.status == .ready } }
    var paymentsNeedingYou: [ZellePayment] { zelle.filter { $0.status == .needsYou } }
    /// Paid automatically in the last three days, so she hears about it once.
    var recentlyMatched: [ZellePayment] {
        zelle.filter { $0.status == .markedPaid && $0.date > Date().addingTimeInterval(-3 * 86400) }
    }
    var waitingCount: Int { readyReplies.count + readyProspects.count + paymentsNeedingYou.count }

    var hasClaude: Bool { !(Keychain.get("anthropic.apiKey") ?? "").isEmpty }
    var gmailReady: Bool { logins?.gmailReady ?? false }
    var canDraft: Bool { logins?.gmailCanDraft ?? false }
    var openInvoices: [Receivable] { (money?.receivables ?? []).filter { $0.paidOn == nil } }

    private var prospectsDue: Bool {
        guard let last = lastProspectRun else { return true }
        return Date().timeIntervalSince(last) > 7 * 86400
    }

    // MARK: Replies to new inquiries

    /// A first reply for each new inquiry Lens spotted in Gmail (a few at a time).
    func draftReplies() async {
        guard !drafting, hasClaude, gmailReady, let gmail, let logins else { return }
        let known = Set(replies.map(\.threadID))
        let fresh = gmail.suggestions.filter { $0.kind == .inquiry && !known.contains($0.thread.id) }
            .filter { $0.thread.lastDate > Date().addingTimeInterval(-14 * 86400) }
        guard !fresh.isEmpty else { return }
        drafting = true
        defer { drafting = false }
        do {
            let token = try await logins.googleAccessToken()
            for s in fresh.prefix(3) {
                let thread = try await GmailAPI.thread(s.thread.id, token: token)
                let conversation = thread.messages.suffix(6).map {
                    "From: \($0.from)\nDate: \($0.date.formatted(date: .abbreviated, time: .omitted))\nSubject: \($0.subject)\n\n\(String($0.text.prefix(3000)))"
                }.joined(separator: "\n\n---\n\n")
                let payload = """
                \(ownerFacts())
                Today is \(Date().formatted(date: .complete, time: .omitted)).

                What Lens understood: \(s.person) (\(s.client)) wants: \(s.wants)
                Date: \(s.eventDate.map { $0.formatted(date: .long, time: .omitted) } ?? "not given"). Location: \(s.location.isEmpty ? "not given" : s.location). Budget: \(s.budget.isEmpty ? "not given" : s.budget). Came from: \(s.source).

                The conversation, oldest first:
                \(conversation)
                """
                guard let answer = try await HelperAI.structured(system: Self.replyPrompt, schema: Self.replySchema, payload: payload),
                      let body = answer["body"] as? String, !body.isEmpty else { continue }
                let subject = (answer["subject"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (s.thread.subject.lowercased().hasPrefix("re:") ? s.thread.subject : "Re: \(s.thread.subject)")
                let to = s.email.isEmpty ? (s.senderEmail ?? "") : s.email
                replies.insert(InquiryReply(threadID: s.thread.id, person: s.person.isEmpty ? (s.senderName ?? to) : s.person,
                                            to: to, title: s.displayTitle, subject: subject, body: Self.clean(body)), at: 0)
                save()
            }
            problem = nil
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "Lens couldn't draft replies just now. It tries again within the hour."
        }
    }

    func putInGmail(_ reply: InquiryReply, subject: String, body: String) async {
        guard let i = replies.firstIndex(where: { $0.id == reply.id }) else { return }
        replies[i].subject = subject
        replies[i].body = body
        save()
        do {
            let id = try await makeDraft(to: reply.to, subject: subject, body: body, threadID: reply.threadID)
            replies[i].draftID = id
            replies[i].status = .inGmail
            problem = nil
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "Lens couldn't put that in Gmail just now."
        }
        save()
    }

    func skip(_ reply: InquiryReply) {
        guard let i = replies.firstIndex(where: { $0.id == reply.id }) else { return }
        replies[i].status = .skipped
        save()
    }

    // MARK: Prospects and pitches

    /// Researches a few new prospects on the web and writes a pitch for each.
    func findProspects() async {
        guard !findingProspects else { return }
        guard hasClaude else { problem = "Connect Claude in Log-ins so Lens can look for prospects."; return }
        findingProspects = true
        defer { findingProspects = false }
        var names: Set<String> = Set(prospects.map(\.organization))
        for p in projects?.projects ?? [] { names.insert(p.client) }
        for person in people?.people ?? [] { names.insert(person.company) }
        let avoid: [String] = names.filter { !$0.isEmpty }.sorted()
        let payload = """
        \(ownerFacts())
        Today is \(Date().formatted(date: .complete, time: .omitted)).

        Who to look for (in Emma's words):
        \(brief)

        Find \(max(1, min(perWeek, 10))) new prospects.
        Already a client, a contact or pitched before, so skip these: \(avoid.isEmpty ? "none yet" : avoid.joined(separator: "; "))
        """
        do {
            let text = try await HelperAI.research(system: Self.prospectPrompt, payload: payload)
            guard let list = Self.prospectList(in: text), !list.isEmpty else {
                problem = "Lens looked, but didn't come back with prospects this time. Try again in a bit."
                return
            }
            let taken = Set(prospects.map { $0.organization.lowercased() })
            var added = 0
            for p in list where !taken.contains(p.organization.lowercased()) {
                prospects.insert(p, at: 0)
                added += 1
            }
            lastProspectRun = Date()
            problem = added == 0 ? "Lens only found organizations you've already seen this time." : nil
            save()
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "Lens couldn't look for prospects just now."
        }
    }

    func putInGmail(_ prospect: Prospect, to: String, subject: String, body: String) async {
        guard let i = prospects.firstIndex(where: { $0.id == prospect.id }) else { return }
        prospects[i].contactEmail = to
        prospects[i].subject = subject
        prospects[i].body = body
        save()
        do {
            let id = try await makeDraft(to: to, subject: subject, body: body, threadID: nil)
            prospects[i].draftID = id
            prospects[i].status = .inGmail
            problem = nil
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "Lens couldn't put that in Gmail just now."
        }
        save()
    }

    func skip(_ prospect: Prospect) {
        guard let i = prospects.firstIndex(where: { $0.id == prospect.id }) else { return }
        prospects[i].status = .skipped
        save()
    }

    // MARK: Zelle

    /// Reads recent Zelle emails. A payment that clearly matches one open invoice (same client, same amount)
    /// marks it paid; anything less certain waits for her under Zelle payments.
    func checkZelle() async {
        guard !checkingZelle, hasClaude, gmailReady, let logins, let money else { return }
        checkingZelle = true
        defer { checkingZelle = false }
        do {
            let token = try await logins.googleAccessToken()
            let found = try await GmailAPI.threadIDs(
                matching: "newer_than:45d zelle -in:sent -in:spam -in:trash", max: 25, token: token)
            let fresh = found.filter { !zelleSeen.contains($0.id) }
            guard !fresh.isEmpty else { return }
            var emails: [[String: Any]] = []
            for item in fresh.prefix(15) {
                let thread = try await GmailAPI.thread(item.id, token: token)
                guard let m = thread.messages.first else { zelleSeen.insert(item.id); continue }
                emails.append(["email_id": item.id, "from": m.from, "subject": m.subject,
                               "date": m.date.formatted(.iso8601.year().month().day()), "text": String(m.text.prefix(1500))])
            }
            let open = money.receivables.filter { $0.paidOn == nil }
            let invoices: [[String: Any]] = open.map { r in
                var row: [String: Any] = ["invoice_id": r.id.uuidString, "client": r.client, "label": r.label,
                                          "amount": r.amount, "due": r.due.formatted(.iso8601.year().month().day())]
                if let p = projects?.project(id: r.projectID) { row["project"] = p.name; row["project_client"] = p.client }
                return row
            }
            let payload = Self.json(["emails": emails, "open_invoices": invoices])
            guard let answer = try await HelperAI.structured(system: Self.zellePrompt, schema: Self.zelleSchema, payload: payload) else { return }
            let byID = Dictionary(emails.compactMap { e -> (String, [String: Any])? in
                guard let id = e["email_id"] as? String else { return nil }; return (id, e) }, uniquingKeysWith: { a, _ in a })
            for row in answer["emails"] as? [[String: Any]] ?? [] {
                guard let id = row["email_id"] as? String, byID[id] != nil else { continue }
                zelleSeen.insert(id)
                guard row["received_payment"] as? Bool == true else { continue }
                let amount = (row["amount"] as? Double) ?? Double((row["amount"] as? Int) ?? 0)
                guard amount > 0, !zelle.contains(where: { $0.id == id }) else { continue }
                let payer = (row["payer"] as? String) ?? ""
                let date = (row["date"] as? String).flatMap(Self.day) ?? Date()
                let invoiceID = (row["invoice_id"] as? String).flatMap(UUID.init(uuidString:))
                let sure = row["sure"] as? Bool == true
                var payment = ZellePayment(id: id, payer: payer, amount: amount, date: date, receivableID: nil, matchedLabel: nil, status: .needsYou)
                if sure, let invoiceID, let r = open.first(where: { $0.id == invoiceID }), abs(r.amount - amount) < 0.01 {
                    markPaid(r, on: date, payment: &payment)
                }
                zelle.insert(payment, at: 0)
            }
            for item in fresh.prefix(15) { zelleSeen.insert(item.id) }
            zelle.sort { $0.date > $1.date }
            save()
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "Lens couldn't check Zelle payments just now."
        }
    }

    /// She picked the invoice a payment was for.
    func match(_ payment: ZellePayment, to receivableID: UUID) {
        guard let i = zelle.firstIndex(where: { $0.id == payment.id }),
              let r = money?.receivables.first(where: { $0.id == receivableID }) else { return }
        var updated = zelle[i]
        markPaid(r, on: payment.date, payment: &updated)
        zelle[i] = updated
        save()
    }

    /// Takes back a payment Lens matched: the invoice is open again.
    func undo(_ payment: ZellePayment) {
        guard let i = zelle.firstIndex(where: { $0.id == payment.id }) else { return }
        if let rid = payment.receivableID, let r = money?.receivables.first(where: { $0.id == rid }) {
            money?.markUnpaid(r)
        }
        zelle[i].status = .needsYou
        zelle[i].receivableID = nil
        zelle[i].matchedLabel = nil
        save()
    }

    func dismiss(_ payment: ZellePayment) {
        guard let i = zelle.firstIndex(where: { $0.id == payment.id }) else { return }
        zelle[i].status = .dismissed
        save()
    }

    private func markPaid(_ r: Receivable, on date: Date, payment: inout ZellePayment) {
        money?.markPaid(r, on: date)
        payment.status = .markedPaid
        payment.receivableID = r.id
        payment.matchedLabel = "\(r.client), \(r.label)"
        // A delivered job that's now paid moves on to Paid.
        if let projects, let p = projects.project(id: r.projectID), p.stage == .delivered {
            projects.setStage(.paid, for: p, note: "Paid by Zelle, \(Money.string(payment.amount))")
        }
    }

    // MARK: Gmail drafts

    private func makeDraft(to: String, subject: String, body: String, threadID: String?) async throws -> String {
        guard let logins else { throw HelperAI.Failure("Lens isn't ready yet. Try again in a moment.") }
        guard logins.gmailCanDraft else {
            throw HelperAI.Failure("Lens needs permission to make Gmail drafts. In Log-ins, click Sign in with Google again and allow it.")
        }
        let token = try await logins.googleAccessToken()
        return try await GmailAPI.createDraft(to: to, subject: subject, body: body, threadID: threadID, token: token)
    }

    static func openGmailDrafts() {
        if let url = URL(string: "https://mail.google.com/mail/u/0/#drafts") { NSWorkspace.shared.open(url) }
    }

    // MARK: Prompts

    /// Her name, business and website from the rate card, so the writing sounds like her.
    private func ownerFacts() -> String {
        let r = deals?.rates
        var parts: [String] = []
        if let r, !r.ownerName.isEmpty { parts.append("The owner is \(r.ownerName).") }
        if let r, !r.businessName.isEmpty { parts.append("Business: \(r.businessName).") }
        if let r, !r.website.isEmpty { parts.append("Website: \(r.website).") }
        if let r, !r.email.isEmpty { parts.append("Email: \(r.email).") }
        return parts.isEmpty ? "The owner is Emma Pion-Berlin, a Denver photographer, videographer and visual storyteller." : parts.joined(separator: " ")
    }

    private static let voice = """
    Write in Emma's voice: warm, sincere, plain-spoken and curious, first person, short paragraphs. \
    Sound like a real person, not marketing. No hype, no corporate jargon, no airy or spiritual business language, \
    no exaggerated claims, no exclamation-mark gushing, no em dashes. Never invent facts, results, testimonials \
    or anything the other person said. Sign off with her first name only.
    """

    private static let replyPrompt = """
    You draft the first reply to a new inquiry for a Denver photographer, videographer and visual storyteller \
    who works with purpose-driven organizations, nonprofits, wellness businesses and founders. She reviews it \
    before it goes anywhere. \(voice)
    The reply: thank them by first name, show you understood what they want in one specific sentence, ask the \
    two or three questions that matter most for scoping (what it's for and where it will be used, the date or \
    timeline, the budget range if they didn't give one), and invite a short call to talk it through. \
    Don't quote prices or promise availability. Under 150 words. subject: keep their subject with "Re: " in front.
    """

    private static let replySchema: [String: Any] = [
        "type": "object",
        "properties": ["subject": ["type": "string"], "body": ["type": "string"]],
        "required": ["subject", "body"],
        "additionalProperties": false,
    ]

    private static let prospectPrompt = """
    You research new client prospects for a Denver photographer, videographer and visual storyteller, and write \
    a first pitch email to each for her to review. She never sends anything without reading it first.
    Use web search and fetch to find real, currently active organizations that match who she's looking for. \
    For each, read their own website. Prefer ones with a concrete reason to need visuals now (a launch, anniversary, \
    event, campaign, new location or program) and say what it is. Find a contact on their own site when you can: \
    a named person in marketing, communications, development or the founder, and a public email address. \
    If you can't find an email, leave it "". Never guess an address.
    The pitch: \(voice) 90 to 150 words. Open with something specific and true about them from your research, \
    connect it to one concrete idea for photo or video she could make with them, say in a line who she is, and \
    end with a soft, low-pressure ask for a short call. No prices.
    When you're done, reply with only this, with nothing before or after:
    <prospects>[{"organization": "", "website": "", "contact_name": "", "contact_email": "", "why": "one or two \
    sentences on why they fit, with the timely reason", "idea": "the one idea the pitch leads with", \
    "sources": ["urls you read"], "subject": "", "body": ""}]</prospects>
    """

    private static let zellePrompt = """
    You read a freelance photographer's Zelle emails from her bank and match money she received to her open invoices.
    For every email: received_payment is true only when it says she received money by Zelle (not money she sent, \
    not requests, not enrollment or security notices, not marketing). payer is the sender's name as the email gives it. \
    amount is the dollar amount received. date is YYYY-MM-DD. invoice_id is the one open invoice this payment is for, \
    or "" when none fits. sure is true only when the payer clearly is that invoice's client (or someone at that \
    client) and the amount equals the invoice amount. When in doubt, sure is false. Never invent ids.
    """

    private static let zelleSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "emails": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "email_id": ["type": "string"],
                        "received_payment": ["type": "boolean"],
                        "payer": ["type": "string"],
                        "amount": ["type": "number"],
                        "date": ["type": "string"],
                        "invoice_id": ["type": "string"],
                        "sure": ["type": "boolean"],
                    ],
                    "required": ["email_id", "received_payment", "payer", "amount", "date", "invoice_id", "sure"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["emails"],
        "additionalProperties": false,
    ]

    // MARK: Reading answers

    static func prospectList(in text: String) -> [Prospect]? {
        var raw = text
        if let start = text.range(of: "<prospects>"), let end = text.range(of: "</prospects>", range: start.upperBound..<text.endIndex) {
            raw = String(text[start.upperBound..<end.lowerBound])
        } else if let open = text.firstIndex(of: "["), let close = text.lastIndex(of: "]"), open < close {
            raw = String(text[open...close])
        }
        guard let rows = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            func s(_ k: String) -> String { ((row[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !s("organization").isEmpty, !s("body").isEmpty else { return nil }
            let email = s("contact_email")
            return Prospect(organization: s("organization"), website: s("website"), contactName: s("contact_name"),
                            contactEmail: email.contains("@") ? email : "", why: clean(s("why")), idea: clean(s("idea")),
                            sources: (row["sources"] as? [String]) ?? [], subject: clean(s("subject")), body: clean(s("body")))
        }
    }

    /// No em dashes in anything she sends.
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: " — ", with: ", ").replacingOccurrences(of: "—", with: ", ")
    }

    private static func day(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    private static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Saving

    private static var fileURL: URL { DealStore.url("helper.json") }

    private static func read() -> HelperData {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let raw = try? Data(contentsOf: fileURL) else { return HelperData() }
        do { return try decoder.decode(HelperData.self, from: raw) }
        catch { NSLog("Lens: couldn't read helper.json: \(error)"); return HelperData() }
    }

    private func save() {
        // Keep the lists from growing forever: the newest 200 of each.
        let data = HelperData(prospects: Array(prospects.prefix(200)), replies: Array(replies.prefix(200)),
                              zelle: Array(zelle.prefix(200)), zelleSeen: Array(zelleSeen.suffix(1000)),
                              lastProspectRun: lastProspectRun, brief: brief, perWeek: perWeek, weekly: weekly)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let raw = try? encoder.encode(data) { try? raw.write(to: Self.fileURL, options: .atomic) }
    }
}

// MARK: - Claude, for the Helper

/// The Helper's own calls to Claude: one that answers in JSON, and one that can search the web.
enum HelperAI {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static func post(_ body: [String: Any]) async throws -> [String: Any] {
        guard let key = Keychain.get("anthropic.apiKey"), !key.isEmpty else { throw Failure("Connect Claude in Log-ins first.") }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw Failure("Lens couldn't reach Claude just now. It tries again within the hour.") }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
            switch status {
            case 401: throw Failure("The Claude API key isn't valid. Check it in Log-ins.")
            case 429: throw Failure("Claude is busy or the monthly limit was hit. Lens will try again later.")
            case 529, 500...599: throw Failure("Claude is having a moment. Lens will try again shortly.")
            default:
                if message.lowercased().contains("credit") {
                    throw Failure("Your Claude account is out of credit. Add credit at console.anthropic.com, then try again.")
                }
                throw Failure("Claude couldn't answer: \(message)")
            }
        }
        return json
    }

    private static func text(_ content: [[String: Any]]) -> String {
        content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
    }

    /// One request that answers in JSON matching `schema`. Nil when the answer can't be read.
    static func structured(system: String, schema: [String: Any], payload: String) async throws -> [String: Any]? {
        let body: [String: Any] = [
            "model": LensAI.model,
            "max_tokens": 16000,
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": payload]],
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": schema]],
            "fallbacks": "default",
        ]
        let json = try await post(body)
        guard (json["stop_reason"] as? String) != "refusal" else { return nil }
        let answer = text(json["content"] as? [[String: Any]] ?? [])
        return try? JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [String: Any]
    }

    /// A request that can search and read the web, carrying on through long searches. Returns all the text it wrote.
    static func research(system: String, payload: String) async throws -> String {
        var messages: [[String: Any]] = [["role": "user", "content": payload]]
        var written = ""
        for _ in 0..<6 {
            let body: [String: Any] = [
                "model": LensAI.model,
                "max_tokens": 32000,
                "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
                "messages": messages,
                "tools": [["type": "web_search_20260209", "name": "web_search", "max_uses": 15],
                          ["type": "web_fetch_20260209", "name": "web_fetch", "max_uses": 12]],
                "output_config": ["effort": "medium"],
                "fallbacks": "default",
            ]
            let json = try await post(body)
            let content = json["content"] as? [[String: Any]] ?? []
            written += text(content)
            guard (json["stop_reason"] as? String) == "pause_turn" else { break }
            messages.append(["role": "assistant", "content": content])
        }
        return written
    }
}

// MARK: - Gmail drafts

extension GmailAPI {
    /// Puts an email in Gmail drafts (never sends). With a thread id, it sits in that conversation as a reply.
    /// Returns the draft's id.
    static func createDraft(to: String, subject: String, body: String, threadID: String?, token: String) async throws -> String {
        func encodedHeader(_ s: String) -> String {
            s.allSatisfy(\.isASCII) ? s : "=?UTF-8?B?\(Data(s.utf8).base64EncodedString())?="
        }
        var lines: [String] = []
        if !to.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("To: \(to)") }
        lines += [
            "Subject: \(encodedHeader(subject))",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: base64",
            "",
            Data(body.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]),
        ]
        let raw = Data(lines.joined(separator: "\r\n").utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var message: [String: Any] = ["raw": raw]
        if let threadID, !threadID.isEmpty { message["threadId"] = threadID }

        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/drafts")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["message": message])
        let data: Data
        let response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) } catch { throw GoogleAuth.explain(error) }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403 {
            throw HelperAI.Failure("Lens needs permission to make Gmail drafts. In Log-ins, click Sign in with Google again and allow it.")
        }
        guard status == 200, let id = json["id"] as? String else {
            throw HelperAI.Failure("Gmail didn't take the draft just now. Try again in a moment.")
        }
        return id
    }
}
