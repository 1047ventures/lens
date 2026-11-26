import Foundation
import AppKit

/// Ask Lens: Claude inside the app. It reads Lens's own data through tools, proposes changes
/// that the user approves one tap at a time, learns from what she tells it, and turns bigger wishes
/// into change requests for the developer. Talks to the Claude API directly over HTTPS (there is no
/// official Swift SDK); the API key lives in the Keychain.
@MainActor
final class LensAI: ObservableObject {

    // MARK: Public state

    struct Note: Codable, Identifiable, Hashable {
        var id = UUID()
        var text: String
        var added = Date()
    }

    struct ChangeRequest: Codable, Identifiable, Hashable {
        var id = UUID()
        var title: String
        var details: String
        var created = Date()
        var link: String?
    }

    struct Action: Identifiable {
        enum State { case waiting, approved, skipped }
        let id: String          // the tool_use id
        let tool: String
        let summary: String
        var state: State = .waiting
    }

    struct Item: Identifiable {
        enum Kind { case user, assistant, action, info, error, draft }
        let id = UUID()
        let kind: Kind
        var text: String
        var action: Action?
        var draft: Draft?
    }

    struct Draft {
        let to: String
        let subject: String
        let body: String
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var busy = false
    /// What Lens is doing right now ("Searching the web…"), shown while it works.
    @Published private(set) var status: String?
    @Published private(set) var notes: [Note] = []
    @Published private(set) var requests: [ChangeRequest] = []
    @Published private(set) var monthSpend: Double = 0

    static let model = "claude-opus-5-5"
    static let sean = "skellyslife@gmail.com"
    static let issuesRepo = "1047ventures/lens"

    var hasKey: Bool { !(Keychain.get("anthropic.apiKey") ?? "").isEmpty }
    var hasGitHub: Bool { !(Keychain.get("github.issuesToken") ?? "").isEmpty }

    // MARK: Wiring

    private weak var deals: DealStore?
    private weak var projects: ProjectStore?
    private weak var navigator: Navigator?
    private weak var money: MoneyStore?
    private weak var zoom: ZoomNotes?
    private weak var people: PeopleStore?
    private weak var logins: ConnectionStore?
    private weak var quotes: QuoteStore?
    private weak var history: EmailHistory?
    private var messages: [[String: Any]] = []
    private var decisions: [String: CheckedContinuation<Bool, Never>] = [:]
    private var spend = Spend()

    init() { load() }

    func attach(deals: DealStore, projects: ProjectStore, navigator: Navigator, money: MoneyStore, people: PeopleStore? = nil) {
        self.people = people
        self.money = money
        self.deals = deals
        self.projects = projects
        self.navigator = navigator
    }

    func attachZoom(_ zoom: ZoomNotes) { self.zoom = zoom }
    func attachLogins(_ logins: ConnectionStore) { self.logins = logins }
    func attachQuotes(_ quotes: QuoteStore) { self.quotes = quotes }
    func attachHistory(_ history: EmailHistory) { self.history = history }

    /// Works out Emma's current, upcoming and possible jobs from her email summaries and call notes.
    func findWork(_ payload: String) async throws -> [[String: Any]] {
        guard let answer = try await structured(system: Self.workPrompt, schema: Self.workSchema, payload: payload) else {
            throw AIError("Claude's answer about your projects didn't come through. Lens will try again later.")
        }
        return answer["work"] as? [[String: Any]] ?? []
    }

    private static let workPrompt = """
    You help a freelance filmmaker and photographer (Emma) keep her business app (Lens) up to date. You get \
    summaries of her recent work email conversations, her recent call notes, and what's already in Lens \
    (projects, including quotes at the Quoting step, with their people and keywords). List each distinct job she has: one entry \
    per job, merging all the emails and calls about it. Give a short name as she would say it ("CEJ \
    documentary", "Parents Anonymous commercial photography", "Facial Aesthetics", "Jenna Shapiro shoot"), \
    the client, status (booked, ongoing, upcoming, potential, done), any shoot or event dates (YYYY-MM-DD), \
    the people on it with name, email and role (Client, Director, Producer, Crew, Interviewee, Editor, \
    Planning), keywords that show an email or call is about it (the client's name, the film's title, short \
    names like "CEJ" or "OFTV"), and one sentence on why you think so. If the job is already in Lens, set \
    existing_id to its id (still list new people and keywords). sure is true only when the emails or calls \
    clearly show a real job; a single vague mention is not sure. Leave out jobs that are done, and anything in \
    removed_before. Use "" for anything not known.
    """

    private static let workSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "work": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string"],
                        "client": ["type": "string"],
                        "status": ["type": "string", "enum": ["booked", "ongoing", "upcoming", "potential", "done"]],
                        "dates": ["type": "array", "items": ["type": "string"]],
                        "people": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": ["name": ["type": "string"], "email": ["type": "string"], "role": ["type": "string"]],
                                "required": ["name", "email", "role"],
                                "additionalProperties": false,
                            ],
                        ],
                        "keywords": ["type": "array", "items": ["type": "string"]],
                        "existing_id": ["type": "string"],
                        "sure": ["type": "boolean"],
                        "why": ["type": "string"],
                    ],
                    "required": ["name", "client", "status", "dates", "people", "keywords", "existing_id", "sure", "why"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["work"],
        "additionalProperties": false,
    ]

    /// Reads a batch of email conversations: is it work, who's the person, what was discussed and decided,
    /// and any prices quoted.
    func readConversations(_ payload: String) async throws -> [[String: Any]] {
        guard let answer = try await structured(system: Self.historyPrompt, schema: Self.historySchema, payload: payload) else {
            throw AIError("Claude's answer about your email didn't come through. Lens will try again later.")
        }
        return answer["threads"] as? [[String: Any]] ?? []
    }

    private static let historyPrompt = """
    You read email conversations of a freelance filmmaker and videographer (Emma, emma_email) to build her \
    business records. For each conversation decide is_work: true when it's about her film or video work \
    (inquiries, clients, collaborators, crew, vendors, bookings, quotes, projects), false for personal mail, \
    newsletters, receipts, logins and admin. For work conversations give: the main other person (name, email, \
    phone, company, role such as Client, Director, Producer, Crew, Vendor) using signatures for phone and \
    company; the client or company the work is for; kind_of_work (Wedding, Documentary, Brand film, Event, \
    Music video, Commercial, Other); a summary of two to four sentences of what was discussed; decisions as \
    short bullet points (dates, scope, price agreed, deliverables, who does what); and every price Emma \
    quoted (amount in dollars, what it was for, date YYYY-MM-DD, status Sent, Accepted or Declined if the \
    replies make it clear, else ""). Also give project_name, a short name for the job as Emma would say it \
    ("CEJ documentary", "Jenna Shapiro shoot"), and work_status: booked (agreed, not started), ongoing (being \
    shot or edited), upcoming (booked with a date ahead), potential (being discussed, not agreed), done \
    (finished and delivered) or other. Leave a field "" when it isn't in the emails. Plain English, no em dashes.
    """

    private static let historySchema: [String: Any] = [
        "type": "object",
        "properties": [
            "threads": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "thread_id": ["type": "string"],
                        "is_work": ["type": "boolean"],
                        "person": [
                            "type": "object",
                            "properties": ["name": ["type": "string"], "email": ["type": "string"], "phone": ["type": "string"],
                                           "company": ["type": "string"], "role": ["type": "string"]],
                            "required": ["name", "email", "phone", "company", "role"],
                            "additionalProperties": false,
                        ],
                        "client": ["type": "string"],
                        "kind_of_work": ["type": "string"],
                        "project_name": ["type": "string"],
                        "work_status": ["type": "string", "enum": ["booked", "ongoing", "upcoming", "potential", "done", "other", ""]],
                        "summary": ["type": "string"],
                        "decisions": ["type": "array", "items": ["type": "string"]],
                        "quotes": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": ["amount": ["type": "number"], "what": ["type": "string"],
                                               "date": ["type": "string"], "status": ["type": "string"]],
                                "required": ["amount", "what", "date", "status"],
                                "additionalProperties": false,
                            ],
                        ],
                    ],
                    "required": ["thread_id", "is_work", "person", "client", "kind_of_work", "project_name", "work_status",
                                 "summary", "decisions", "quotes"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["threads"],
        "additionalProperties": false,
    ]

    /// Said just before the picture of Lens's window in her message, so older pictures can be found and dropped.
    private static let screenMarker = "This is the Lens window as she sees it right now:"

    /// Only the newest picture of her screen is sent; older ones are dropped to keep questions quick and cheap.
    private func dropOldScreens() {
        for i in messages.indices where messages[i]["role"] as? String == "user" {
            guard var content = messages[i]["content"] as? [[String: Any]],
                  let k = content.firstIndex(where: { $0["type"] as? String == "text" && $0["text"] as? String == Self.screenMarker }),
                  k + 1 < content.count, content[k + 1]["type"] as? String == "image" else { continue }
            content.remove(at: k + 1)
            content[k] = ["type": "text", "text": "(A picture of her screen was here.)"]
            messages[i]["content"] = content
        }
    }

    func saveKey(_ key: String) {
        Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: "anthropic.apiKey")
        objectWillChange.send()
    }

    func saveGitHubToken(_ token: String) {
        Keychain.set(token.trimmingCharacters(in: .whitespacesAndNewlines), for: "github.issuesToken")
        objectWillChange.send()
    }

    /// A tiny request to confirm the key works. Returns nil on success, or what went wrong.
    func testKey() async -> String? {
        guard let key = Keychain.get("anthropic.apiKey"), !key.isEmpty else { return "No key saved yet." }
        let saved = messages
        messages = [["role": "user", "content": "Reply with just: OK"]]
        defer { messages = saved }
        do { _ = try await call(key: key); return nil } catch { return error.localizedDescription }
    }

    /// Sorts recent Gmail conversations for the email suggestions (Pipeline and Projects).
    /// One request, separate from the Ask Lens chat; the answer comes back as JSON matching `emailSchema`.
    /// Nothing is changed here. GmailSync files a conversation by itself only when Claude is sure it belongs
    /// to a project already in Lens; everything else waits for the user.
    func sortEmails(_ payload: String) async throws -> [[String: Any]] {
        guard let answer = try await structured(system: Self.emailPrompt, schema: Self.emailSchema, payload: payload) else {
            throw AIError("Claude's answer about your email didn't come through. Lens will try again later.")
        }
        return answer["threads"] as? [[String: Any]] ?? []
    }

    /// Picks the project each Zoom summary belongs to, from the user's open projects (or none).
    /// One request, separate from the Ask Lens chat. Nothing is changed here: ZoomNotes only
    /// places a note when Claude is sure, and otherwise lists it first when it asks the user which project it's for.
    func placeNotes(_ payload: String) async throws -> [[String: Any]] {
        guard let answer = try await structured(system: Self.notesPrompt, schema: Self.notesSchema, payload: payload) else {
            throw AIError("Claude's answer about your Zoom notes didn't come through. Lens will try again later.")
        }
        return answer["notes"] as? [[String: Any]] ?? []
    }

    /// A summary of a call from its transcript, laid out like a Zoom AI summary. Used for calls Emma
    /// recorded with Zoom My Notes when Zoom didn't write notes for them.
    func summarizeCall(title: String, transcript: String) async throws -> (overview: String, sections: [MeetingNoteSection], nextSteps: [String])? {
        let payload = "Call: \(title)\n\nTranscript:\n" + String(transcript.prefix(150_000))
        guard let answer = try await structured(system: Self.callPrompt, schema: Self.callSchema, payload: payload) else { return nil }
        let overview = (answer["overview"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let sections: [MeetingNoteSection] = (answer["sections"] as? [[String: Any]] ?? []).compactMap { s in
            let text = (s["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : MeetingNoteSection(title: s["title"] as? String ?? "", text: text)
        }
        let steps = (answer["next_steps"] as? [String] ?? []).filter { !$0.isEmpty }
        guard !overview.isEmpty || !sections.isEmpty else { return nil }
        return (overview, sections, steps)
    }

    /// The short summary at the top of a project page: what it is, how it came in, where it stands.
    /// Nil when there isn't enough to say.
    func summarizeProject(_ facts: String) async throws -> String? {
        guard let answer = try await structured(system: Self.projectSummaryPrompt, schema: Self.projectSummarySchema, payload: facts) else { return nil }
        let parts = ["what", "how_it_came", "where_it_stands"]
            .map { (answer[$0] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.replacingOccurrences(of: " — ", with: ", ").replacingOccurrences(of: "—", with: ", ") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static let projectSummaryPrompt = """
    You write the short summary at the top of one project's page in a freelance filmmaker's business app. \
    The owner of the business reads it; write to them as "you". It answers, in this order: what the project is \
    (who the client is and the cool thing they want to make, in plain words), how it came to them (a referral \
    and who referred them, an email, a website form, someone they met), and where it stands right now (dates \
    set or not yet, what's been sent, what they're waiting on, like a budget being approved). \
    One sentence for each, short and warm, like a friend catching them up. Name the people who matter by first \
    name. Use real dates and facts from what you're given; never invent any. If you don't know how it came in, \
    leave how_it_came empty. No em dashes, no jargon, no prices unless the budget is the point. Today's date is \
    given so you can say "next week" or "in March".
    """

    private static let projectSummarySchema: [String: Any] = [
        "type": "object",
        "properties": [
            "what": ["type": "string"],
            "how_it_came": ["type": "string"],
            "where_it_stands": ["type": "string"],
        ],
        "required": ["what", "how_it_came", "where_it_stands"],
        "additionalProperties": false,
    ]

    /// Reads a proposal or quote file: who it's for, the total, line items and what it covered.
    func readQuote(_ blocks: [[String: Any]]) async throws -> [String: Any]? {
        let content = blocks + [["type": "text", "text": "Read this proposal or quote."]]
        return try await structured(system: Self.quotePrompt, schema: Self.quoteSchema, payload: content)
    }

    private static let quotePrompt = """
    You read a proposal or quote that a freelance filmmaker and videographer (Emma) sent to a client. Pull out: \
    the client's name, a short title for the job, the date it was written (YYYY-MM-DD, or "" if not shown), the \
    total price in dollars (the main or recommended package if there are several; 0 if no price), each line item \
    with its price, every option or package offered (name, price, and one sentence on what it includes; empty \
    when there is only one), the kind of work (Wedding, Documentary, Brand film, Event, Music video, Commercial, \
    Other), the number of shoot days (0 if not stated), and the deliverables in one short sentence. Only use \
    what's in the document.
    """

    private static let quoteSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "client": ["type": "string"],
            "title": ["type": "string"],
            "date": ["type": "string"],
            "total": ["type": "number"],
            "items": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": ["name": ["type": "string"], "amount": ["type": "number"]],
                    "required": ["name", "amount"],
                    "additionalProperties": false,
                ],
            ],
            "packages": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": ["name": ["type": "string"], "price": ["type": "number"], "includes": ["type": "string"]],
                    "required": ["name", "price", "includes"],
                    "additionalProperties": false,
                ],
            ],
            "kind_of_work": ["type": "string"],
            "shoot_days": ["type": "number"],
            "deliverables": ["type": "string"],
        ],
        "required": ["client", "title", "date", "total", "items", "packages", "kind_of_work", "shoot_days", "deliverables"],
        "additionalProperties": false,
    ]

    private static let callPrompt = """
    You summarize a call for a freelance filmmaker and videographer (Emma) from its transcript, the way Zoom's AI \
    summary would. Write an overview of two to four sentences, then a few titled sections covering what was \
    discussed and decided (creative direction, schedule, people, budget, logistics), then next steps as short \
    action items with who does them. Use the speakers' names when the transcript gives them. Plain English, \
    no em dashes. Only include what was actually said.
    """

    private static let callSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "overview": ["type": "string"],
            "sections": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": ["title": ["type": "string"], "text": ["type": "string"]],
                    "required": ["title", "text"],
                    "additionalProperties": false,
                ],
            ],
            "next_steps": ["type": "array", "items": ["type": "string"]],
        ],
        "required": ["overview", "sections", "next_steps"],
        "additionalProperties": false,
    ]

    /// One request that answers in JSON matching `schema`. Nil when the answer can't be read.
    private func structured(system: String, schema: [String: Any], payload: Any) async throws -> [String: Any]? {
        guard let key = Keychain.get("anthropic.apiKey"), !key.isEmpty else { throw AIError("Connect Claude in Log-ins first.") }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 16000,
            "system": [["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": payload]],
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": schema]],
            "fallbacks": "default",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw failure(status: status, json: json) }
        if let usage = json["usage"] as? [String: Any] { record(usage) }
        guard (json["stop_reason"] as? String) != "refusal" else { return [:] }
        let text = (json["content"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
        return try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    private static let notesPrompt = """
    You help a freelance filmmaker and videographer file the Zoom AI summaries of their calls in their business app (Lens).
    You get new call summaries and her open projects. Each project has a name, client, keywords, the people on it
    (with roles like Director, Interviewee, Producer) and the titles of calls already filed there.
    For every summary, pick the one project it is about, or "" when it is about none of them (personal calls,
    other businesses, a brand-new client, workshops or classes she ran or took, and Zoom's own emails). Use who was on the call, the people and places mentioned, the meeting
    title, the project names and keywords, and earlier calls in the same series.
    sure: true only when the summary clearly belongs to that project and to no other. When two projects fit,
    or the link is a guess, set sure to false. Never invent ids: project_id must be one of the ids given, or "".
    """

    private static let notesSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "notes": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "note_id": ["type": "string"],
                        "project_id": ["type": "string"],
                        "sure": ["type": "boolean"],
                    ],
                    "required": ["note_id", "project_id", "sure"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["notes"],
        "additionalProperties": false,
    ]

    private static let emailPrompt = """
    You help a freelance filmmaker and videographer (the owner) keep their business app (Lens) in step with their email and Instagram and Facebook messages.
    You get recent email conversations plus the quotes (possible gigs, projects at the Quoting step) and projects (booked gigs) already in Lens.
    Sort every conversation into exactly one kind:
    - "inquiry": someone new asking about hiring the owner (a shoot, a film, a video, availability, a quote). Website
      contact-form emails and lead emails from directories (The Knot, WeddingWire, Thumbtack, Zola, Yelp, Google
      Business Profile) count, even when they come from a no-reply address: take the real person's name and email
      from the message body or Reply-To.
    - "project": booked or clearly agreed work she is actively emailing about (planning a shoot, delivering a film,
      invoices for a job) that is not already in Lens.
    - "existing": about a deal or project already in Lens. Put its id in existing_id.
      sure: true only when it clearly belongs to that one deal or project and to no other. When two could fit,
      or the link is a guess, set sure to false. For every other kind, sure is false.
    - "other": everything else (newsletters, receipts, personal mail, notifications, spam, her own reminders).
    When unsure between inquiry or project and other, choose other. Never invent details: use "" when unknown.
    emma_rules are things the owner told Lens; follow them over your own judgement. emma_past_choices show what Lens \
    did (lens_guessed) and what she said (she): added, ignored, right, or a correction such as "said it is not work" or \
    "said it belongs to X", with her reason or note when she gave one. Never repeat a mistake she corrected, and treat \
    similar conversations the same way (same sender, same kind of sender, same kind of request).
    title: a short name for the job, like "Hartley wedding film" or "Bloom Co. brand video".
    client: the person or organisation. wants: one or two plain sentences on what they want.
    event_date: the shoot or event date as YYYY-MM-DD, or "". source: one of Email, Website form, The Knot,
    WeddingWire, Thumbtack, Zola, Yelp, Google, Referral, Instagram.
    """

    private static let emailSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "threads": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "thread_id": ["type": "string"],
                        "kind": ["type": "string", "enum": ["inquiry", "project", "existing", "other"]],
                        "existing_id": ["type": "string"],
                        "sure": ["type": "boolean"],
                        "person": ["type": "string"],
                        "email": ["type": "string"],
                        "client": ["type": "string"],
                        "title": ["type": "string"],
                        "wants": ["type": "string"],
                        "event_date": ["type": "string"],
                        "location": ["type": "string"],
                        "budget": ["type": "string"],
                        "source": ["type": "string"],
                    ],
                    "required": ["thread_id", "kind", "existing_id", "sure", "person", "email", "client", "title", "wants",
                                 "event_date", "location", "budget", "source"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["threads"],
        "additionalProperties": false,
    ]

    func newConversation() {
        guard !busy else { return }
        items = []
        messages = []
    }

    // MARK: Approvals

    func decide(_ actionID: String, approve: Bool) {
        if let i = items.firstIndex(where: { $0.action?.id == actionID }) {
            items[i].action?.state = approve ? .approved : .skipped
        }
        decisions.removeValue(forKey: actionID)?.resume(returning: approve)
    }

    func forget(_ note: Note) {
        notes.removeAll { $0.id == note.id }
        save()
    }

    func editNote(_ note: Note, text: String) {
        guard let i = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[i].text = text
        save()
    }

    // MARK: Conversation

    func send(_ text: String, attachments: [URL] = []) async {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && !attachments.isEmpty { trimmed = "Take a look at this." }
        guard !trimmed.isEmpty, !busy else { return }
        guard let key = Keychain.get("anthropic.apiKey"), !key.isEmpty else {
            items.append(Item(kind: .error, text: "Connect Claude in Log-ins first (it needs an API key)."))
            return
        }
        let shown = attachments.isEmpty ? trimmed : trimmed + "\n" + attachments.map { "📎 " + $0.lastPathComponent }.joined(separator: "\n")
        items.append(Item(kind: .user, text: shown))
        let (fileBlocks, skipped) = await Task.detached { Attachments.blocks(for: attachments) }.value
        if !skipped.isEmpty {
            items.append(Item(kind: .info, text: "Couldn't read \(skipped.joined(separator: ", ")). Photos, PDFs and text files work."))
        }
        dropOldScreens()
        var screenBlocks: [[String: Any]] = []
        if let picture = LensScreen.snapshot() {
            screenBlocks = [["type": "text", "text": Self.screenMarker],
                            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": picture]]]
        }
        messages.append(["role": "user", "content": screenBlocks + fileBlocks + [["type": "text", "text": "<screen>\(screenContext())</screen>\n\n\(trimmed)"]]])
        busy = true
        defer { busy = false; status = nil }

        do {
            for _ in 0..<12 {   // at most 12 rounds of looking things up per question
                let (content, stop) = try await streamRecovering(key: key)
                messages.append(["role": "assistant", "content": content])
                status = nil
                if stop == "refusal" {
                    items.append(Item(kind: .info, text: "Claude declined that one. Try rephrasing it."))
                    return
                }
                if stop == "pause_turn" { continue }   // a long web search: let it carry on
                guard stop == "tool_use" else { return }

                var results: [[String: Any]] = []
                for block in content where block["type"] as? String == "tool_use" {
                    guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                    let input = block["input"] as? [String: Any] ?? [:]
                    let (text, isError): (String, Bool)
                    if input["_invalid"] != nil {
                        (text, isError) = ("INVALID_JSON: the tool input was cut off or malformed. Try again.", true)
                    } else {
                        status = Self.statusText(for: name)
                        (text, isError) = await runTool(id: id, name: name, input: input)
                    }
                    var result: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": text]
                    if isError { result["is_error"] = true }
                    results.append(result)
                }
                messages.append(["role": "user", "content": results])
            }
            items.append(Item(kind: .info, text: "That took a lot of steps, so I stopped. Ask again if you want me to keep going."))
        } catch {
            items.append(Item(kind: .error, text: error.localizedDescription))
            // Drop the unanswered turn so the next question starts clean.
            if let last = messages.last, last["role"] as? String == "user" { messages.removeLast() }
        }
    }

    // MARK: API call

    private func request(key: String, stream: Bool) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        // thinking-binding-controls lets the API skip earlier reasoning it can't verify instead of failing the question.
        request.setValue("server-side-fallback-2026-07-01,thinking-binding-controls-2026-08-01", forHTTPHeaderField: "anthropic-beta")

        var system: [[String: Any]] = [["type": "text", "text": Self.systemPrompt, "cache_control": ["type": "ephemeral"]]]
        if let about = aboutOwner() { system.append(["type": "text", "text": about]) }
        if !notes.isEmpty {
            system.append(["type": "text", "text": "What the user has taught you (follow these):\n" +
                notes.map { "- [\($0.id.uuidString.prefix(8))] \($0.text)" }.joined(separator: "\n")])
        }
        var body: [String: Any] = [
            "model": Self.model,
            "max_tokens": stream ? 32000 : 16000,
            "system": system,
            "tools": Self.tools,
            "messages": messages,
            "output_config": ["effort": "high"],
            // Earlier reasoning that no longer matches the chat is dropped, not turned into an error for the user.
            "thinking": ["type": "adaptive", "block_binding": ["prefix_mismatch_behavior": "drop_block"]],
            "cache_control": ["type": "ephemeral"],
            // If Claude declines on a safety classifier, the API retries on a suitable model.
            "fallbacks": "default",
        ]
        if stream { body["stream"] = true }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func failure(status: Int, json: [String: Any]) -> AIError {
        let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
        switch status {
        case 401: return AIError("The Claude API key isn't valid. Check it in Log-ins.")
        case 429: return AIError("Claude is busy or the monthly limit was hit. Try again in a minute.")
        case 529, 500...599: return AIError("Claude is having a moment. Try again shortly.")
        case 400 where message.lowercased().contains("credit balance") || message.lowercased().contains("credits"):
            return AIError("Your Claude account is out of credit. Add credit at console.anthropic.com (Settings, then Billing), then try again.")
        case 400 where message.contains("`thinking` block") || message.contains("block_binding"):
            return AIError("Ask Lens lost track of its earlier answers in this chat.", staleThinking: true)
        default: return AIError("Claude couldn't answer: \(message)")
        }
    }

    /// Streams one turn. If Claude rejects reasoning from earlier in this chat, Lens forgets that
    /// reasoning (removing all of it is always allowed) and asks once more, so the user just gets her answer.
    private func streamRecovering(key: String) async throws -> (content: [[String: Any]], stop: String?) {
        do {
            return try await stream(key: key)
        } catch let error as AIError where error.staleThinking {
            messages = messages.map { message in
                guard message["role"] as? String == "assistant", let content = message["content"] as? [[String: Any]] else { return message }
                var copy = message
                copy["content"] = content.filter { !["thinking", "redacted_thinking"].contains($0["type"] as? String ?? "") }
                return copy
            }
            return try await stream(key: key)
        }
    }

    /// One-shot call, used for the key test.
    private func call(key: String) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request(key: key, stream: false))
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw failure(status: status, json: json) }
        if let usage = json["usage"] as? [String: Any] { record(usage) }
        return json
    }

    /// Streams one turn: text appears in the panel word by word, and each step shows as it
    /// starts. Rebuilds the full content blocks (thinking, tool calls, search results) so they
    /// go back to the API unchanged next turn.
    private func stream(key: String) async throws -> (content: [[String: Any]], stop: String?) {
        let (bytes, response) = try await URLSession.shared.bytes(for: request(key: key, stream: true))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw failure(status: code, json: (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
        }

        var blocks: [Int: [String: Any]] = [:]
        var partialJSON: [Int: String] = [:]
        var liveItems: [Int: UUID] = [:]
        var usage: [String: Any] = [:]
        var stop: String?

        for try await line in bytes.lines {
            guard line.hasPrefix("data: "),
                  let event = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any],
                  let type = event["type"] as? String else { continue }
            let index = event["index"] as? Int ?? 0
            switch type {
            case "message_start":
                if let u = (event["message"] as? [String: Any])?["usage"] as? [String: Any] { usage.merge(u) { _, new in new } }
            case "content_block_start":
                var block = event["content_block"] as? [String: Any] ?? [:]
                switch block["type"] as? String {
                case "text":
                    block["text"] = block["text"] as? String ?? ""
                    let item = Item(kind: .assistant, text: block["text"] as? String ?? "")
                    items.append(item)
                    liveItems[index] = item.id
                case "tool_use", "server_tool_use":
                    partialJSON[index] = ""
                    if let name = block["name"] as? String { status = Self.statusText(for: name) }
                default: break
                }
                blocks[index] = block
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any], var block = blocks[index] else { continue }
                switch delta["type"] as? String {
                case "text_delta":
                    let piece = delta["text"] as? String ?? ""
                    block["text"] = (block["text"] as? String ?? "") + piece
                    if let id = liveItems[index], let i = items.firstIndex(where: { $0.id == id }) { items[i].text += piece }
                case "input_json_delta":
                    partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
                case "thinking_delta":
                    block["thinking"] = (block["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
                case "signature_delta":
                    block["signature"] = delta["signature"]
                case "citations_delta":
                    var list = block["citations"] as? [Any] ?? []
                    if let c = delta["citation"] { list.append(c) }
                    block["citations"] = list
                default: break
                }
                blocks[index] = block
            case "content_block_stop":
                if let json = partialJSON[index] {
                    if json.isEmpty { blocks[index]?["input"] = [String: Any]() }
                    else if let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] { blocks[index]?["input"] = obj }
                    else { blocks[index]?["input"] = ["_invalid": json] }
                }
            case "message_delta":
                if let reason = (event["delta"] as? [String: Any])?["stop_reason"] as? String { stop = reason }
                if let u = event["usage"] as? [String: Any] { usage.merge(u) { _, new in new } }
            case "error":
                let message = ((event["error"] as? [String: Any])?["message"] as? String) ?? "the connection dropped"
                throw AIError("Claude stopped partway: \(message)")
            default: break
            }
        }
        record(usage)
        // Drop text blocks that stayed empty (the API rejects them when sent back) and their empty bubbles.
        let content = blocks.keys.sorted().compactMap { i -> [String: Any]? in
            let block = blocks[i]!
            if block["type"] as? String == "text", (block["text"] as? String ?? "").isEmpty { return nil }
            return block
        }
        items.removeAll { item in item.kind == .assistant && item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && liveItems.values.contains(item.id) }
        return (content, stop)
    }

    static func statusText(for tool: String) -> String {
        switch tool {
        case "web_search": return "Searching the web…"
        case "web_fetch": return "Reading a web page…"
        case "list_deals", "get_deal": return "Looking through your quotes…"
        case "list_projects", "get_project": return "Checking projects…"
        case "get_money": return "Checking the books…"
        case "get_gear": return "Checking your gear…"
        case "get_library", "search_library": return "Looking through your drives…"
        case "get_rates": return "Checking your rates…"
        case "list_quotes": return "Looking through your past quotes…"
        case "search_email_history": return "Reading your email history…"
        case "list_people", "get_person": return "Looking through People…"
        case "draft_email": return "Drafting the email…"
        case "open_screen": return "Opening it…"
        case "search_meeting_notes", "get_meeting_note": return "Reading your meeting notes…"
        default: return "Getting that ready…"
        }
    }

    struct AIError: LocalizedError {
        let message: String
        /// Claude refused older reasoning from this chat; safe to retry without it.
        var staleThinking = false
        init(_ message: String, staleThinking: Bool = false) { self.message = message; self.staleThinking = staleThinking }
        var errorDescription: String? { message }
    }

    // MARK: Spending (shown in the panel so there are no surprises)

    private struct Spend: Codable {
        var month = ""
        var dollars = 0.0
    }

    private func record(_ usage: [String: Any]) {
        func n(_ k: String) -> Double { Double((usage[k] as? Int) ?? 0) }
        // Claude Opus 5.5: $4 / M input, $20 / M output, cache reads $0.20 / M, cache writes 1.25×.
        let searches = Double(((usage["server_tool_use"] as? [String: Any])?["web_search_requests"] as? Int) ?? 0)
        // Web searches are $10 per 1,000.
        let cost = n("input_tokens") * 4 / 1e6 + n("output_tokens") * 20 / 1e6
            + n("cache_read_input_tokens") * 0.2 / 1e6 + n("cache_creation_input_tokens") * 5 / 1e6 + searches * 0.01
        let month = Date().formatted(.dateTime.year().month(.twoDigits))
        if spend.month != month { spend = Spend(month: month, dollars: 0) }
        spend.dollars += cost
        monthSpend = spend.dollars
        save()
    }

    // MARK: Tools

    private func runTool(id: String, name: String, input: [String: Any]) async -> (String, Bool) {
        func str(_ k: String) -> String { (input[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        guard let deals, let projects else { return ("Lens isn't ready yet.", true) }

        switch name {
        // ---- Reading (no approval needed)
        case "get_gear":
            guard let money else { return ("Gear isn't ready.", true) }
            return (json(money.gear.map { g -> [String: Any] in
                var d: [String: Any] = ["name": g.name, "type": g.kind.label, "bought": day(g.bought), "paid": g.paid, "life_years": g.lifeYears]
                if let s = g.serial { d["serial"] = s }
                if let s = g.lastService { d["last_service"] = day(s) }
                if let s = g.serviceNote { d["service_note"] = s }
                if let s = g.shoots { d["shoots"] = s }
                return d
            }), false)
        case "get_library":
            return (json(DriveCatalog.shared.drives.map { d -> [String: Any] in
                var r: [String: Any] = ["name": d.name, "kind": d.isPhotos ? "Photos app" : d.isWebsite ? "website" : d.isMac ? "this Mac" : "drive",
                    "plugged_in": DriveCatalog.shared.isPlugged(d), "size": ByteFormat.string(d.total), "free": ByteFormat.string(d.free),
                    "videos": d.videoCount, "video_size": ByteFormat.string(d.videoBytes), "photos": d.photoCount,
                    "photo_size": ByteFormat.string(d.photoBytes), "edit_projects": d.projectCount, "last_seen": day(d.lastSeen)]
                if let s = d.lastScanned { r["last_scanned"] = day(s) }
                return r
            }), false)
        case "search_library":
            let query = str("query"), drives = DriveCatalog.shared.drives
            let names = Dictionary(drives.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            let hits = await Task.detached { DriveCatalog.search(query, drives: drives) }.value
            if hits.isEmpty { return ("Nothing matched \"\(query)\".", false) }
            return (json(hits.prefix(40).map { ["drive": names[$0.driveID] ?? $0.driveID, "folder": $0.folder, "matching_files": $0.files,
                                                "size": ByteFormat.string($0.bytes), "example": $0.sample] as [String: Any] }), false)
        case "search_meeting_notes":
            let notes = allMeetingNotes(deals: deals, projects: projects)
            if notes.isEmpty { return ("No meeting notes yet. Connect Zoom in Log-ins to bring them in.", false) }
            let words = str("query").lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "@" && $0 != "." })
                .map(String.init).filter { $0.count > 2 && !Self.stopWords.contains($0) }
            let limit = min(max((input["limit"] as? Int) ?? 6, 1), 20)
            let scored: [(MeetingNote, String, Int)] = notes.map { item in
                let text = (item.note.title + "\n" + item.note.fullText).lowercased()
                let score = words.reduce(0) { $0 + (text.contains($1) ? (item.note.title.lowercased().contains($1) ? 3 : 1) : 0) }
                return (item.note, item.place, score)
            }
            let hits = words.isEmpty ? scored.sorted { $0.0.date > $1.0.date }
                                     : scored.filter { $0.2 > 0 }.sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0.date > $1.0.date }
            if hits.isEmpty { return ("No meeting notes mention \"\(str("query"))\". \(notes.count) notes were searched.", false) }
            // The best few in full, the rest as a list to open with get_meeting_note.
            var out: [[String: Any]] = []
            for (i, hit) in hits.prefix(words.isEmpty ? 30 : 20).enumerated() {
                var d = meetingNoteHeader(hit.0, place: hit.1)
                if i < limit && !words.isEmpty { d["summary"] = String(hit.0.fullText.prefix(8000)) }
                out.append(d)
            }
            return (json(["notes_searched": notes.count, "matches": hits.count, "notes": out]), false)
        case "get_meeting_note":
            guard let hit = allMeetingNotes(deals: deals, projects: projects).first(where: { $0.note.id == str("note_id") }) else {
                return ("No meeting note with that id.", true)
            }
            var d = meetingNoteHeader(hit.note, place: hit.place)
            d["summary"] = String(hit.note.fullText.prefix(20000))
            return (json(d), false)
        case "list_deals":
            let stage = str("stage")
            let list = deals.deals.filter { stage.isEmpty || stageKey($0.stage) == stage }
            return (json(list.map { dealSummary($0) }), false)
        case "get_deal":
            guard let deal = findDeal(str("deal_id")) else { return ("No deal with that id.", true) }
            return (json(dealDetail(deal)), false)
        case "list_projects":
            return (json(projects.projects.map { projectSummary($0) }), false)
        case "list_quotes":
            let words = str("query").lowercased().split(separator: " ").map(String.init).filter { $0.count >= 3 }
            let all = quotes?.history(deals: deals) ?? []
            let hits = words.isEmpty ? all : all.filter { q in
                let text = [q.client, q.title, q.kind, q.deliverables, q.items.map(\.name).joined(separator: " ")].joined(separator: " ").lowercased()
                return words.contains(where: text.contains)
            }
            let list: [[String: Any]] = hits.prefix(60).map { q in
                var d: [String: Any] = ["date": day(q.date), "client": q.client, "title": q.title, "status": q.status.isEmpty ? "Unknown" : q.status,
                                        "source": q.source]
                if let a = q.amount { d["total"] = Money.string(a) }
                if !q.kind.isEmpty { d["kind"] = q.kind }
                if let days = q.shootDays { d["shoot_days"] = days }
                if !q.deliverables.isEmpty { d["deliverables"] = q.deliverables }
                if !q.items.isEmpty { d["items"] = q.items.map { item in item.amount.map { a in "\(item.name): \(Money.string(a))" } ?? item.name } }
                return d
            }
            return (json(["quotes_found": hits.count, "quotes": list]), false)
        case "search_email_history":
            guard let history else { return ("Lens hasn't read your email history yet.", false) }
            let words = str("query").lowercased().split(separator: " ").map(String.init).filter { $0.count >= 3 }
            // Subjects and people come from the conversations already on deals, projects and people.
            var links: [String: EmailThread] = [:]
            let dealThreads: [EmailThread] = deals.deals.flatMap { $0.emails ?? [] }
            let projectThreads: [EmailThread] = projects.projects.flatMap { $0.emails ?? [] }
            let personThreads: [EmailThread] = people?.people.flatMap { $0.threads } ?? []
            for t in dealThreads { links[t.id] = t }
            for t in projectThreads { links[t.id] = t }
            for t in personThreads { links[t.id] = t }
            var hits: [[String: Any]] = []
            for (id, s) in history.summaries where !s.summary.isEmpty {
                let link = links[id]
                let subject: String = link?.subject ?? ""
                let names: String = (link?.people ?? []).joined(separator: " ")
                let parts: [String] = [s.summary, subject, names] + s.decisions
                let text = parts.joined(separator: " ").lowercased()
                guard words.isEmpty || words.contains(where: text.contains) else { continue }
                var d: [String: Any] = ["summary": s.summary, "decisions": s.decisions]
                if let link {
                    d["subject"] = link.subject
                    d["people"] = link.people ?? []
                    d["last_message"] = day(link.lastDate)
                }
                hits.append(d)
            }
            hits.sort { a, b in
                let x: String = (a["last_message"] as? String) ?? ""
                let y: String = (b["last_message"] as? String) ?? ""
                return x > y
            }
            return (json(["read": history.workCount, "matches": hits.count, "conversations": Array(hits.prefix(25))]), false)
        case "get_project":
            guard let p = projects.projects.first(where: { $0.id.uuidString == str("project_id") }) else { return ("No project with that id.", true) }
            var d = projectSummary(p)
            d.merge(projectBooks(p)) { _, new in new }
            d["history"] = p.events.map { "\($0.date.formatted(date: .abbreviated, time: .omitted)): \($0.text)" }
            if let people = p.people, !people.isEmpty {
                d["people"] = people.map { "\($0.name) (\($0.role.isEmpty ? "no role set" : $0.role)) \($0.email)" }
            }
            if let keywords = p.keywords, !keywords.isEmpty { d["keywords"] = keywords }
            // Every call on the project, so questions across all of it ("what did the directors ask for?") can be answered.
            if let notes = p.meetingNotes, !notes.isEmpty { d["meeting_notes"] = meetingNotes(notes, limit: 40, length: 3000) }
            if let emails = p.emails, !emails.isEmpty {
                d["emails"] = emails.map { "\($0.lastDate.formatted(date: .abbreviated, time: .omitted)) \($0.subject) (latest from \($0.from)): \($0.snippet)" }
            }
            if let files = p.documents, !files.isEmpty {
                d["files"] = files.map { "\($0.kind): \($0.name) (\($0.location))" }
            }
            if let deal = deals.deals.first(where: { $0.projectID == p.id }) {
                var proposal = dealDetail(deal)
                proposal.removeValue(forKey: "meeting_notes")   // already listed above
                proposal.removeValue(forKey: "emails")
                proposal["headline"] = deal.story.headline
                proposal["logline"] = deal.story.logline
                proposal["why"] = deal.story.why
                proposal["pillars"] = deal.story.pillars.map { "\($0.title): \($0.text)" }
                d["proposal_deal"] = proposal
            }
            if let money {
                let txns = money.txns.filter { $0.projectID == p.id }
                if !txns.isEmpty {
                    d["money_in"] = Money.string(txns.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount })
                    d["money_out"] = Money.string(-txns.filter { $0.amount < 0 }.reduce(0) { $0 + $1.amount })
                }
                let owed = money.receivables.filter { $0.projectID == p.id && $0.paidOn == nil }
                if !owed.isEmpty { d["still_owed"] = owed.map { "\($0.label) \(Money.string($0.amount)) due \(day($0.due))" } }
            }
            return (json(d), false)
        case "get_money":
            guard let money else { return ("Money isn't ready.", true) }
            let period = MoneyStore.Period.allCases.first { $0.rawValue.lowercased() == str("period").lowercased() } ?? .thisYear
            let inc = money.income(period), cash = money.cashFlow(period), bal = money.balance(period)
            let open = money.receivables.filter { $0.paidOn == nil }.map { "\($0.client): \($0.label) \(Money.string($0.amount)) due \($0.due.formatted(date: .abbreviated, time: .omitted))" }
            return (json([
                "period": period.rawValue,
                "revenue": inc.revenue.map { "\($0.label): \(Money.string($0.amount))" }, "total_revenue": Money.string(inc.totalRevenue),
                "project_costs": inc.direct.map { "\($0.label): \(Money.string($0.amount))" },
                "overhead": inc.overhead.map { "\($0.label): \(Money.string($0.amount))" },
                "kept": Money.string(inc.net),
                "cash_start": Money.string(cash.start), "cash_end": Money.string(cash.end), "paid_to_emma": Money.string(-cash.owner),
                "cash_on_hand": Money.string(bal.totalCash), "clients_owe": open, "gear_worth": Money.string(bal.gear),
                "card_balance": Money.string(bal.card), "business_worth": Money.string(bal.worth),
                "unsorted_transactions": money.unsortedCount,
            ]), false)
        case "get_rates":
            return (json(rateValues(deals.rates)), false)
        case "list_people":
            guard let people else { return ("People isn't ready.", true) }
            let tag = str("tag"), query = str("query"), on = str("on")
            var list = people.search(query)
            // Also find people whose emails or Zoom notes mention the words ("the festival").
            if !query.isEmpty {
                for p in people.sorted where !list.contains(where: { $0.id == p.id }) {
                    let hit = people.meetingNotes(for: p).contains { $0.title.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query) }
                        || people.emails(for: p).contains { $0.subject.localizedCaseInsensitiveContains(query) || $0.snippet.localizedCaseInsensitiveContains(query) }
                    if hit { list.append(p) }
                }
            }
            if !tag.isEmpty { list = list.filter { p in p.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } } }
            if !on.isEmpty {
                list = list.filter { p in
                    people.deals(for: p).contains { $0.title.localizedCaseInsensitiveContains(on) || $0.client.localizedCaseInsensitiveContains(on) }
                        || people.projects(for: p).contains { $0.name.localizedCaseInsensitiveContains(on) || $0.client.localizedCaseInsensitiveContains(on) }
                }
            }
            if let quiet = input["quiet_days"] as? Int ?? (input["quiet_days"] as? Double).map(Int.init) {
                list = list.filter { (people.daysQuiet($0) ?? Int.max) >= quiet }
            }
            if input["follow_up_due"] as? Bool == true { list = list.filter { $0.isFollowUpDue() } }
            return (json(list.prefix(80).map { personSummary($0, people) }), false)
        case "get_person":
            guard let people, let p = findPerson(str("person_id")) else { return ("No person with that id.", true) }
            var d = personSummary(p, people)
            d["phone"] = p.phone
            d["link"] = p.link
            d["notes"] = p.notes
            d["deals"] = people.deals(for: p).map { "\($0.title) (\(stageKey($0.stage)), deal_id \($0.id.uuidString))" }
            d["projects"] = people.projects(for: p).map { "\($0.name) (\($0.stage.label), project_id \($0.id.uuidString))" }
            d["paid"] = people.payments(for: p).map { "\(day($0.date)) \(Money.string($0.amount)) \($0.label)" }
            d["timeline"] = people.timeline(for: p).prefix(40).map { "\(day($0.date)) \($0.title): \($0.detail.prefix(300))" }
            let notes = people.meetingNotes(for: p)
            if !notes.isEmpty { d["meeting_notes"] = meetingNotes(notes) }
            return (json(d), false)

        // ---- Showing things (harmless)
        case "open_screen":
            if let person = findPerson(str("person_id")) { navigator?.openPerson(person.id) }
            else if let deal = findDeal(str("deal_id")) { navigator?.openDeal(deal.id) }
            else if let p = projects.projects.first(where: { $0.id.uuidString == str("project_id") }) { navigator?.openProject(p.id) }
            else if let section = SidebarSection.allCases.first(where: { $0.rawValue.lowercased() == str("section").lowercased() }) { navigator?.open(section) }
            else { return ("Nothing to open with that.", true) }
            return ("Opened.", false)
        case "draft_email":
            items.append(Item(kind: .draft, text: "", draft: Draft(to: str("to"), subject: str("subject"), body: str("body"))))
            return ("The draft is shown to the user with Copy and Open in Mail buttons. Nothing was sent.", false)

        // ---- Changes (each one waits for the user's tap)
        case "create_inquiry":
            let summary = "Add a new inquiry: \(str("title")) for \(str("client"))"
            guard await ask(id: id, tool: name, summary: summary) else { return ("The user skipped this.", false) }
            var deal = Deal(client: str("client"), title: str("title").isEmpty ? str("client") : str("title"),
                            source: str("source").isEmpty ? "Email" : str("source"), stage: .inquiry,
                            location: str("location"), eventDate: date(str("event_date")), budgetHint: str("budget_hint"),
                            callNotes: str("notes"), lastTouch: Date(), createdAt: Date())
            deal.events = [ProjectEvent(text: "Inquiry added by Ask Lens (\(deal.source.lowercased()))")]
            deals.add(deal)
            return ("Created. deal_id \(deal.id.uuidString)", false)
        case "update_discovery":
            guard var deal = findDeal(str("deal_id")) else { return ("No deal with that id.", true) }
            let fields: [(String, WritableKeyPath<Discovery, String>)] = [
                ("goal", \.goal), ("audience", \.audience), ("where_watched", \.whereWatched),
                ("on_camera", \.onCamera), ("locations", \.locations), ("formats", \.formats)]
            let changes = fields.filter { !str($0.0).isEmpty }
            let goLive = date(str("go_live"))
            guard !changes.isEmpty || goLive != nil else { return ("Nothing to update.", true) }
            let summary = "Fill in discovery for \(deal.title): " + (changes.map { $0.0.replacingOccurrences(of: "_", with: " ") } + (goLive == nil ? [] : ["go-live date"])).joined(separator: ", ")
            guard await ask(id: id, tool: name, summary: summary) else { return ("The user skipped this.", false) }
            for (key, path) in changes { deal.disc[keyPath: path] = str(key) }
            if let goLive { deal.disc.goLive = goLive }
            deals.update(deal)
            return ("Updated.", false)
        case "log_follow_up":
            guard let deal = findDeal(str("deal_id")) else { return ("No deal with that id.", true) }
            guard await ask(id: id, tool: name, summary: "Log on \(deal.title): \(str("note"))") else { return ("The user skipped this.", false) }
            deals.logTouch(str("note"), for: deal)
            return ("Logged.", false)
        case "set_deal_stage":
            guard let deal = findDeal(str("deal_id")) else { return ("No deal with that id.", true) }
            let map: [String: DealStage] = ["inquiry": .inquiry, "proposal_out": .proposalOut, "talking": .talking, "lost": .lost]
            guard let stage = map[str("stage")] else { return ("Use inquiry, proposal_out, talking or lost. Winning a deal is done with the Mark won button so she picks the option.", true) }
            guard await ask(id: id, tool: name, summary: "Move \(deal.title) to \(stage.label)") else { return ("The user skipped this.", false) }
            if stage == .lost { deals.markLost(deal, reason: str("reason")) } else { deals.setStage(stage, for: deal) }
            return ("Done.", false)
        case "update_rate":
            let field = str("field")
            guard let value = input["value"] as? Double ?? (input["value"] as? Int).map(Double.init),
                  let path = Self.rateFields[field] else { return ("Unknown rate field. Use get_rates to see them.", true) }
            let old = deals.rates[keyPath: path]
            guard await ask(id: id, tool: name, summary: "Change \(field.replacingOccurrences(of: "_", with: " ")) from \(format(old)) to \(format(value))") else { return ("The user skipped this.", false) }
            deals.rates[keyPath: path] = value
            return ("Saved.", false)
        case "add_person":
            guard let people else { return ("People isn't ready.", true) }
            let personName = str("name")
            guard !personName.isEmpty else { return ("A name is needed.", true) }
            var p = Person(name: personName, emails: str("email").isEmpty ? [] : [str("email").lowercased()])
            p.phone = str("phone"); p.company = str("company"); p.role = str("role"); p.link = str("link")
            p.met = str("met"); p.notes = str("notes")
            p.tags = (input["tags"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let extra = [p.subtitle, p.tags.joined(separator: ", ")].filter { !$0.isEmpty }.joined(separator: " · ")
            guard await ask(id: id, tool: name, summary: "Add \(personName) to People" + (extra.isEmpty ? "" : " (\(extra))")) else { return ("The user skipped this.", false) }
            people.add(p)
            return ("Added. person_id \(p.id.uuidString)", false)
        case "update_person":
            guard let people, var p = findPerson(str("person_id")) else { return ("No person with that id.", true) }
            let fields: [(String, WritableKeyPath<Person, String>)] = [
                ("name", \.name), ("phone", \.phone), ("company", \.company), ("role", \.role), ("link", \.link), ("met", \.met)]
            var changes: [String] = []
            for (key, path) in fields where !str(key).isEmpty { p[keyPath: path] = str(key); changes.append(key) }
            if !str("add_email").isEmpty, !p.emails.contains(str("add_email").lowercased()) { p.emails.append(str("add_email").lowercased()); changes.append("email") }
            for t in input["add_tags"] as? [String] ?? [] where !t.isEmpty { p.addTag(t); changes.append("tag \(t)") }
            for t in input["remove_tags"] as? [String] ?? [] { p.tags.removeAll { $0.caseInsensitiveCompare(t) == .orderedSame }; changes.append("remove tag \(t)") }
            if !str("add_note").isEmpty { p.notes = p.notes.isEmpty ? str("add_note") : p.notes + "\n\n" + str("add_note"); changes.append("note") }
            guard !changes.isEmpty else { return ("Nothing to update.", true) }
            guard await ask(id: id, tool: name, summary: "Update \(p.name): \(changes.joined(separator: ", "))") else { return ("The user skipped this.", false) }
            people.update(p)
            return ("Updated.", false)
        case "set_follow_up":
            guard let people, let p = findPerson(str("person_id")) else { return ("No person with that id.", true) }
            let clear = input["clear"] as? Bool == true
            guard clear || date(str("date")) != nil else { return ("Give a date as YYYY-MM-DD, or clear: true.", true) }
            let when = date(str("date"))
            let summary = clear ? "Clear the follow-up for \(p.name)"
                : "Follow up with \(p.name) on \(when!.formatted(date: .abbreviated, time: .omitted))" + (str("note").isEmpty ? "" : ": \(str("note"))")
            guard await ask(id: id, tool: name, summary: summary) else { return ("The user skipped this.", false) }
            people.setFollowUp(clear ? nil : when, note: str("note"), for: p)
            return ("Done.", false)
        case "log_person_touch":
            guard let people, let p = findPerson(str("person_id")) else { return ("No person with that id.", true) }
            guard await ask(id: id, tool: name, summary: "Log with \(p.name): \(str("note"))") else { return ("The user skipped this.", false) }
            people.logTouch(str("note"), for: p)
            return ("Logged.", false)
        case "remember":
            let note = str("note")
            guard !note.isEmpty else { return ("Empty note.", true) }
            guard await ask(id: id, tool: name, summary: "Remember: \(note)") else { return ("The user skipped this.", false) }
            notes.append(Note(text: note))
            save()
            return ("Saved to what Lens has learned.", false)
        case "forget":
            guard let note = notes.first(where: { $0.id.uuidString.hasPrefix(str("note_id")) && !str("note_id").isEmpty }) else { return ("No note with that id.", true) }
            guard await ask(id: id, tool: name, summary: "Forget: \(note.text)") else { return ("The user skipped this.", false) }
            forget(note)
            return ("Forgotten.", false)
        case "request_app_change":
            let title = str("title"), details = str("details")
            guard await ask(id: id, tool: name, summary: "Send the developer a change request: \(title)") else { return ("The user skipped this.", false) }
            var request = ChangeRequest(title: title, details: details)
            request.link = await fileRequest(request)
            requests.append(request)
            save()
            return (request.link.map { "Sent: \($0)" } ?? "Saved, and an email to the developer was opened for the user to send.", false)
        default:
            return ("Unknown tool \(name).", true)
        }
    }

    /// Shows an approval card and waits for the user's tap.
    private func ask(id: String, tool: String, summary: String) async -> Bool {
        items.append(Item(kind: .action, text: summary, action: Action(id: id, tool: tool, summary: summary)))
        return await withCheckedContinuation { decisions[id] = $0 }
    }

    /// Change requests become GitHub issues on Lens's private repo when a token is set up,
    /// otherwise an email to the developer that the user sends herself.
    private func fileRequest(_ request: ChangeRequest) async -> String? {
        let body = "\(request.details)\n\n_From the user via Ask Lens, \(request.created.formatted(date: .abbreviated, time: .shortened)). Lens \(Updater.shared.currentVersion)._"
        if let token = Keychain.get("github.issuesToken"), !token.isEmpty {
            var http = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.issuesRepo)/issues")!)
            http.httpMethod = "POST"
            http.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            http.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            http.setValue("Lens", forHTTPHeaderField: "User-Agent")
            http.httpBody = try? JSONSerialization.data(withJSONObject: ["title": "[Emma] \(request.title)", "body": body])
            if let (data, response) = try? await URLSession.shared.data(for: http),
               (response as? HTTPURLResponse)?.statusCode == 201,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let link = json["html_url"] as? String {
                return link
            }
        }
        var mail = URLComponents()
        mail.scheme = "mailto"
        mail.path = Self.sean
        mail.queryItems = [URLQueryItem(name: "subject", value: "Lens change request: \(request.title)"),
                           URLQueryItem(name: "body", value: body)]
        if let url = mail.url { NSWorkspace.shared.open(url) }
        return nil
    }

    // MARK: Data shapes for Claude

    private func screenContext() -> String {
        guard let navigator else { return "" }
        var parts = ["Section: \(navigator.section?.rawValue ?? "Today")"]
        var openDeal: Deal? = nil
        if navigator.section == .projects, let pid = navigator.projectID {
            openDeal = deals?.deals.first { $0.projectID == pid }
        } else if navigator.section == .pipeline {
            openDeal = deals?.deal(id: navigator.dealID)
        }
        if let deal = openDeal {
            parts.append("Looking at the quote \"\(deal.title)\" (deal_id \(deal.id.uuidString))")
            if navigator.builderDealID == deal.id { parts.append("in the proposal builder") }
        }
        if navigator.section == .people, let person = people?.person(id: navigator.personID) {
            parts.append("Looking at \(person.name) in People (person_id \(person.id.uuidString))")
        }
        if navigator.section == .projects, let p = projects?.project(id: navigator.projectID) {
            parts.append("Looking at project \"\(p.name)\" (project_id \(p.id.uuidString))")
        }
        switch navigator.section {
        case .footage: parts.append("The Library lists her drives, Mac and Photos; use get_library and search_library for what's there")
        case .gear: parts.append("Gear lists her kit; use get_gear")
        case .money: parts.append("Money shows her books; use get_money")
        case .logins: parts.append("Log-ins is where she connects email, calendar, bank and Claude")
        default: break
        }
        if let logins {
            let list = LoginID.allCases.map { id -> String in
                let s = logins.status(id)
                return "\(id.rawValue): \(s.label)\(s.detail.isEmpty ? "" : " (\(s.detail))")"
            }
            parts.append("Her log-ins: " + list.joined(separator: "; "))
        }
        parts.append("Today is \(Date().formatted(date: .complete, time: .shortened))")
        return parts.joined(separator: ". ")
    }

    private func findPerson(_ id: String) -> Person? {
        guard !id.isEmpty, let people else { return nil }
        return people.people.first { $0.id.uuidString == id }
            ?? people.people.first { $0.name.localizedCaseInsensitiveCompare(id) == .orderedSame || $0.emails.contains(id.lowercased()) }
    }

    private func personSummary(_ p: Person, _ people: PeopleStore) -> [String: Any] {
        var d: [String: Any] = ["person_id": p.id.uuidString, "name": p.name, "emails": p.emails, "company": p.company,
                                "role": p.role, "tags": p.tags, "met": p.met]
        if let last = people.lastInTouch(p) { d["last_in_touch"] = day(last) }
        if let f = p.followUp { d["follow_up"] = day(f) + (p.followUpNote.isEmpty ? "" : ": \(p.followUpNote)") }
        let open = people.deals(for: p).filter { $0.stage.isOpen }.map(\.title)
        if !open.isEmpty { d["open_deals"] = open }
        let projects = people.projects(for: p).map(\.name)
        if !projects.isEmpty { d["projects"] = projects }
        let paid = people.totalPaid(by: p)
        if paid > 0 { d["paid_total"] = Money.string(paid) }
        return d
    }

    private func findDeal(_ id: String) -> Deal? {
        deals?.deals.first { $0.id.uuidString == id } ?? deals?.deals.first { $0.title.localizedCaseInsensitiveContains(id) && !id.isEmpty }
    }

    private func stageKey(_ s: DealStage) -> String {
        switch s {
        case .inquiry: return "inquiry"
        case .proposalOut: return "proposal_out"
        case .talking: return "talking"
        case .won: return "won"
        case .lost: return "lost"
        }
    }

    private func dealSummary(_ d: Deal) -> [String: Any] {
        ["deal_id": d.id.uuidString, "client": d.client, "title": d.title, "stage": stageKey(d.stage),
         "value": deals?.valueText(of: d) ?? "", "next_move": DealCard.nextMove(d), "days_since_contact": d.daysSinceTouch()]
    }

    private func dealDetail(_ d: Deal) -> [String: Any] {
        var out = dealSummary(d)
        out["source"] = d.source
        out["location"] = d.location
        out["budget_hint"] = d.budgetHint
        out["call_notes"] = d.callNotes
        out["contacts"] = d.contacts.map { "\($0.name) (\($0.role)) \($0.email)" }
        let disc = d.disc
        out["discovery"] = ["goal": disc.goal, "audience": disc.audience, "where_watched": disc.whereWatched,
                            "on_camera": disc.onCamera, "locations": disc.locations, "formats": disc.formats,
                            "go_live": disc.goLive?.formatted(date: .abbreviated, time: .omitted) ?? ""]
        out["options"] = d.options.map { o -> [String: Any] in
            let e = deals!.estimate(o)
            var row: [String: Any] = ["name": o.name, "tagline": o.tagline, "local_days": o.localDays, "travel_days": o.travelDays,
                                      "crew": o.localCrew, "interviewees": o.interviewees, "film_minutes": o.filmMinutes,
                                      "revisions": o.revisionRounds, "extras": o.extras.map(\.label)]
            row["half_days"] = o.halfDayCount
            row["filming_hours"] = o.hourCount
            row["deliverable"] = o.footageOnly ? "Edited images and B-roll only, no final film" : "Finished film"
            row["chosen_by_client"] = d.chosenOptionID == o.id
            row["price"] = Money.string(e.total)
            row["at_her_rates"] = Money.string(e.calculated)
            row["she_keeps"] = Money.string(e.takeHome)
            row["per_hour"] = Money.string(e.takeHomePerHour)
            if !o.pitch.isEmpty { row["includes"] = o.pitch }
            return row
        }
        out["milestones"] = d.milestones.map { "\($0.phase): \($0.when)" }
        out["next_steps"] = d.nextSteps.map { ($0.done ? "[done] " : "") + $0.text }
        out["proposal_sections_done"] = "\(BuilderStep.progress(d)) of \(BuilderStep.allCases.count)"
        out["history"] = d.events.map { "\($0.date.formatted(date: .abbreviated, time: .omitted)): \($0.text)" }
        if let notes = d.meetingNotes, !notes.isEmpty { out["meeting_notes"] = meetingNotes(notes) }
        if let emails = d.emails, !emails.isEmpty {
            out["emails"] = emails.map { "\($0.lastDate.formatted(date: .abbreviated, time: .omitted)) \($0.subject) (latest from \($0.from)): \($0.snippet)" }
        }
        return out
    }

    /// Zoom AI summaries of calls, newest first, so Ask Lens can answer "what did they want on our call?".
    private func meetingNotes(_ notes: [MeetingNote], limit: Int = 8, length: Int = 4000) -> [String] {
        notes.prefix(limit).map { "[\($0.id)] \($0.date.formatted(date: .abbreviated, time: .omitted)) Zoom call \"\($0.title)\": \($0.fullText.prefix(length))" }
    }

    /// Every meeting note Lens has, with where it lives ("Deal: Smith · Wedding film", "Not placed").
    private func allMeetingNotes(deals: DealStore, projects: ProjectStore) -> [(note: MeetingNote, place: String)] {
        var out: [(note: MeetingNote, place: String)] = []
        var seen = Set<String>()
        for p in projects.projects {
            for n in p.meetingNotes ?? [] where seen.insert(n.id).inserted { out.append((n, "Project: \(p.client.isEmpty ? p.name : "\(p.client) · \(p.name)") (project_id \(p.id.uuidString))")) }
        }
        for d in deals.deals {
            for n in d.meetingNotes ?? [] where seen.insert(n.id).inserted { out.append((n, "Deal: \(d.client) · \(d.title) (deal_id \(d.id.uuidString))")) }
        }
        for n in zoom?.unmatched ?? [] where seen.insert(n.id).inserted { out.append((n, "Not placed yet (in Unmatched notes)")) }
        for n in zoom?.kept ?? [] where seen.insert(n.id).inserted { out.append((n, "Not on a deal or project")) }
        return out
    }

    private func meetingNoteHeader(_ note: MeetingNote, place: String) -> [String: Any] {
        var d: [String: Any] = ["note_id": note.id, "title": note.title,
                                "date": note.date.formatted(date: .abbreviated, time: .shortened),
                                "where": place, "from": note.fromZoom ? "Zoom" : "Gmail summary email"]
        if let people = note.people, !people.isEmpty {
            d["people"] = people.map { $0.email.isEmpty ? $0.name : "\($0.name) <\($0.email)>" }
        }
        return d
    }

    private static let stopWords: Set<String> = ["the", "and", "what", "did", "say", "said", "about", "with", "for", "from",
                                                 "that", "this", "was", "were", "our", "call", "meeting", "zoom", "who", "when", "how"]

    private func projectSummary(_ p: Project) -> [String: Any] {
        var d: [String: Any] = ["project_id": p.id.uuidString, "name": p.name, "client": p.client, "stage": p.stage.label,
                                "shoot_date": p.shootDate?.formatted(date: .abbreviated, time: .shortened) ?? "", "location": p.location,
                                "hours_total": (p.totalHours * 10).rounded() / 10]
        if p.isTiming { d["timer_running"] = true }
        if let money, let deals {
            let b = ProjectBooks.make(p, money: money, deals: deals)
            d["spent"] = b.spent
            if let price = b.price { d["price"] = price }
            if let keep = b.keep { d["what_she_keeps"] = keep }
        }
        return d
    }

    /// Hours and money for one project, for questions like "how many hours on X?" or "what have I spent on it?".
    private func projectBooks(_ p: Project) -> [String: Any] {
        var time: [String: Any] = ["total_hours": (p.totalHours * 10).rounded() / 10,
                                   "this_week_hours": (p.hoursThisWeek * 10).rounded() / 10,
                                   "by_type": Dictionary(uniqueKeysWithValues: p.hoursByKind.map { ($0.kind.label, ($0.hours * 10).rounded() / 10) }),
                                   "entries": p.times.prefix(40).map { "\(day($0.date)) \($0.kind.label) \(format($0.hours)) h\($0.note.map { ": \($0)" } ?? "")" }]
        if let started = p.timerStartedAt { time["timer_running_since"] = started.formatted(date: .abbreviated, time: .shortened) }
        guard let money, let deals else { return ["time": time] }
        let b = ProjectBooks.make(p, money: money, deals: deals)
        var m: [String: Any] = ["spent": b.spent, "received": b.received,
                                "expenses": b.expenses.map { "\(day($0.date)) \($0.description) (\($0.category.label)) \(Money.string(-$0.amount))" }]
        if let price = b.price { m["price"] = price }
        if let keep = b.keep { m["what_she_keeps"] = keep }
        if let perHour = b.perHour { m["kept_per_hour_so_far"] = (perHour * 100).rounded() / 100 }
        return ["time": time, "money": m]
    }

    static let rateFields: [String: WritableKeyPath<RateCard, Double>] = [
        "emma_day_rate": \.emmaDayRate, "collaborator_day_rate": \.collaboratorDayRate,
        "collaborator_day_cost": \.collaboratorDayCost, "planning_hourly": \.planningHourly,
        "edit_hourly": \.editHourly, "media_hourly": \.mediaHourly, "target_hourly": \.targetHourly,
        "deposit_percent": \.depositPercent, "edit_hours_per_film_minute": \.editPerFilmMinute,
        "edit_hours_per_revision": \.editPerRevisionRound,
    ]

    private func rateValues(_ r: RateCard) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: Self.rateFields.map { ($0.key, r[keyPath: $0.value]) })
    }

    private func day(_ d: Date) -> String { d.formatted(.iso8601.year().month().day()) }

    private func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    private func date(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.date(from: String(s.prefix(10)))
    }

    private func format(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }

    // MARK: Persistence

    private struct Saved: Codable {
        var notes: [Note]
        var requests: [ChangeRequest]
        var spend: Spend
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: DealStore.url("ask_lens.json")),
              let saved = try? decoder.decode(Saved.self, from: data) else { return }
        notes = saved.notes
        requests = saved.requests
        spend = saved.spend
        monthSpend = spend.month == Date().formatted(.dateTime.year().month(.twoDigits)) ? spend.dollars : 0
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(Saved(notes: notes, requests: requests, spend: spend)) {
            try? data.write(to: DealStore.url("ask_lens.json"), options: .atomic)
        }
    }

    // MARK: Prompt and tools (kept byte-for-byte stable so they cache)

    static let systemPrompt = """
    You are Lens, the assistant built into the owner's business app. The owner is a videographer and \
    photographer. Lens runs their projects (inquiries start at the Quoting step and move to booked gigs), \
    proposals, projects, people (their clients, directors, interviewees, crew, vendors and leads), footage, money \
    and log-ins.

    How to work:
    - Look things up with the tools instead of guessing. Never invent clients, numbers or dates.
    - You can change things only through tools. Each change shows the user an Approve button; say what you're \
    proposing in one line and let the card do the rest. Don't say something is done until the tool result says so.
    - Keep replies short and plain: a sentence or two, or a short list. No jargon. Money in dollars.
    - When the user corrects you, states a preference, or explains how they like to work, offer to remember it with \
    the remember tool, phrased as a short rule.
    - Rules you remember about which emails and messages matter (who is a client, which senders to skip) are also \
    used when Lens sorts her email, Instagram and Facebook messages. When she says things like "emails from X aren't \
    clients" or "ignore anything about Y", offer to remember it as a short rule.
    - FreshBooks setup, one step at a time: (1) sign in at my.freshbooks.com and open the developer page \
    (my.freshbooks.com/#/developer); (2) Create an app: name Lens, application type Private app, website \
    https://localhost, redirect URI exactly https://localhost:8765/freshbooks, scopes user:profile:read, \
    user:invoices:read, user:estimates:read, user:clients:read; save; (3) copy the Client ID and Client Secret \
    into Lens, Log-ins, FreshBooks, and click Save keys; (4) click Connect FreshBooks, press Allow; (5) the next \
    page won't load, which is expected: copy its whole address and paste it in Lens, then click Finish. Menus \
    may be named a little differently: ask what she sees. Never ask her to paste the keys into the chat.
    - Quotes come in many sizes: full local days, half days, hours of filming, and either a finished film or \
    edited images and B-roll only (no final film edit). Offer the size that fits the job instead of defaulting to \
    full documentary days, and when she uploaded her own proposal, use its options and the one the client chose.
    - Pricing a new job or writing a quote: look at list_quotes for similar past work (same kind, similar days \
    and deliverables) and get_rates, then suggest a price with a short reason ("your last two brand films with \
    2 shoot days were $6,500 and $7,200"). Say which past quotes were accepted or declined.
    - Prices: protect the price, scale the scope. If she wants to go cheaper, suggest what to cut before discounting.
    - Drafting emails: write in her warm, direct voice, short paragraphs, and use draft_email. You never send email.
    - If she asks for something Lens can't do (a new screen, a new button, a different layout, a connection that \
    doesn't exist), offer request_app_change with a clear title and a full write-up to build from: \
    what she wants, why, and an example. Once she approves, it is built and published automatically: Lens \
    offers the update (Update ready, top right) usually within an hour. Tell her that. If it can't be built, the Lens developer follows up.
    - She can attach photos, PDFs and files, or paste a link. Read them directly (use web_fetch for links). \
    Photos of gear, receipts, contracts, shot lists, client briefs: work from what's actually in them.
    - Hours and spending on a project ("how many hours on the CU documentary?", "what have I spent on it?"): \
    find it with list_projects, then get_project and answer from its time and money.
    - You can see her screen. Each message comes with a picture of the Lens window as she sees it right now \
    (the screen she's on, its buttons and what's listed), plus a <screen> tag naming what she is looking at and \
    which log-ins are connected. "This deal" or "this page" means what's on screen. Never ask her for a \
    screenshot or to tell you what she sees: look at the picture. You can only see Lens, not other apps. \
    - Website forms and bookings (Squarespace, Acuity Scheduling, Wix, Showit, HoneyBook and others) need no \
    separate connection: they email her, and Lens reads those emails in Gmail and turns each one into an inquiry \
    in Projects at Quoting and a person in People. All she needs is the form or booking notifications going to her Gmail.
    - Instagram DMs and Facebook Page messages: Lens reads them through a small private Meta app on her own \
    account. Setup, one step at a time: (1) developers.facebook.com/apps, sign in, register as a developer if \
    asked; (2) Create app, use case Other, type Business, name it Lens; (3) add the Instagram product, choose \
    API setup with Instagram login, under Generate access tokens click Add account, log in to Instagram, accept \
    the tester invite if asked (Instagram: Settings, Apps and websites, Tester invites), click Generate token \
    and Copy, then paste it in Lens, Log-ins, Instagram + Facebook, and click Connect Instagram; (4) add the \
    Messenger product, in Messenger API settings connect her Facebook Page, click Generate and Copy, paste it \
    in Lens and click Connect Facebook. No App Review or webhooks needed. Meta renames menus often: ask what \
    she sees and adapt. Never ask her to paste a code into the chat. If Meta only offers Instagram "Unified login" \
    or "Facebook login", skip Instagram's own code: add Messenger, then in the Graph API Explorer get a Page access \
    token for Lens with pages_show_list, pages_messaging, pages_read_engagement, pages_manage_metadata, \
    instagram_basic, instagram_manage_messages and business_management, extend it in the Access Token Tool, and \
    paste her Page's token from me/accounts as the Facebook Page code. It reads Instagram DMs too.
    - Directories (The Knot, WeddingWire, Thumbtack, Google…) and Google reviews need no setup: Lens reads the \
    emails they send. For review emails, she turns on Customer reviews in Google Business Profile, Settings, \
    Notifications.
    - You can search the web for public information: a client's website, a venue, a company, a fellowship's \
    history. Use it to prepare for calls and proposals, and say briefly where a fact came from.
    - People: list_people and get_person know everyone she works with, when she was last in touch, their deals, \
    projects, emails, Zoom notes and what they've paid. For a check-in to several people, write one draft_email each.
    """

    static let tools: [[String: Any]] = [
        ["type": "web_search_20260209", "name": "web_search", "max_uses": 5],
        ["type": "web_fetch_20260209", "name": "web_fetch", "max_uses": 5],
        tool("get_gear", "the owner's gear: every item with type, when bought, what they paid, serial, last service and how many shoots.", [:], []),
        tool("get_library", "Every drive, the Mac and the Photos app Lens knows: size, free space, how many videos, photos and edit projects, when last seen and scanned.", [:], []),
        tool("search_library", "Find folders on the owner's drives whose names or files match some words (a client, a place, a date like 2024-06). Works on unplugged drives too.",
             ["query": ["type": "string"]], ["query"]),
        tool("search_meeting_notes", "Search every Zoom meeting summary Lens has (on deals, on projects, and not placed): overview, each topic, next steps and who was there. Give a few key words (a name, a topic like \"shoot schedule\"). The best matches come back in full; open others with get_meeting_note. With no query, lists the newest.",
             ["query": ["type": "string"], "limit": ["type": "integer", "description": "How many matches to return in full (default 6)"]], []),
        tool("get_meeting_note", "One meeting summary in full, by its note_id.", ["note_id": ["type": "string"]], ["note_id"]),
        tool("list_deals", "List quotes, the possible gigs (projects at the Quoting step). Optional stage filter: inquiry, proposal_out, talking, won, lost.",
             ["stage": ["type": "string"]], []),
        tool("get_deal", "Everything about one deal: discovery answers, options with prices and what the owner keeps, timeline, history, emails and Zoom call summaries (meeting_notes).",
             ["deal_id": ["type": "string"]], ["deal_id"]),
        tool("list_quotes", "Emma's past quotes and proposals (uploaded files, ones found in email, and proposals made in Lens) with date, client, total, line items, kind of work, shoot days, deliverables and whether it was accepted. Use it whenever she prices a new job: compare with similar past work.",
             ["query": ["type": "string", "description": "Optional words to match (client, kind of work, deliverable). Empty for all."]], []),
        tool("search_email_history", "Summaries of Emma's past work email conversations (what was discussed and decided, going back three years). Search by a person, client, company or topic.",
             ["query": ["type": "string", "description": "Words to match: a name, company, project or topic."]], ["query"]),
        tool("list_projects", "List booked projects with stage, shoot date, location, hours logged, money spent and what the owner keeps.", [:], []),
        tool("get_project", "Everything in one project: details, history, the people on it with their roles (director, interviewee…), every Zoom call summary (meeting_notes), emails, the proposal from its deal (proposal_deal), attached files, time (hours in total, by type and this week, every entry) and money (price, received, every expense, what she keeps, per hour). Use it for questions across a whole project.", ["project_id": ["type": "string"]], ["project_id"]),
        tool("get_money", "The books for a period (This month, Last month, This year, All time): revenue and costs by category, what she kept, cash in and out, who owes her, gear value, what the business is worth.",
             ["period": ["type": "string"]], []),
        tool("get_rates", "the owner's rate card: day rates, hourly rates, deposit percent, target take-home per hour.", [:], []),
        tool("open_screen", "Show something in Lens: a person, a quote (opens its project), a project, or a section (Today, People, Projects, Library, Gear, Money, Log-ins).",
             ["person_id": ["type": "string"], "deal_id": ["type": "string"], "project_id": ["type": "string"], "section": ["type": "string"]], []),
        tool("list_people", "Everyone in People with tags, company, last time in touch, follow-up date, open deals and projects. All filters optional: query matches names, companies, notes, and also email subjects and Zoom notes (\"the festival\"); tag (Client, Director, Interviewee, Crew, Vendor, Lead); on = a deal or project name; quiet_days = not in touch for at least that many days; follow_up_due.",
             ["query": ["type": "string"], "tag": ["type": "string"], "on": ["type": "string"],
              "quiet_days": ["type": "integer"], "follow_up_due": ["type": "boolean"]], []),
        tool("get_person", "Everything about one person: details, notes, deals, projects, what they've paid, Zoom notes and their whole timeline.",
             ["person_id": ["type": "string"]], ["person_id"]),
        tool("add_person", "Add someone to People. The user approves first.",
             ["name": ["type": "string"], "email": ["type": "string"], "phone": ["type": "string"], "company": ["type": "string"],
              "role": ["type": "string"], "link": ["type": "string", "description": "Instagram or website"],
              "met": ["type": "string", "description": "How she met them: Referral, Website, Instagram, Email, Event…"],
              "tags": ["type": "array", "items": ["type": "string"]], "notes": ["type": "string"]], ["name"]),
        tool("update_person", "Change a person's details, add an email, add or remove tags, or add a note. Only the fields given change. The user approves first.",
             ["person_id": ["type": "string"], "name": ["type": "string"], "phone": ["type": "string"], "company": ["type": "string"],
              "role": ["type": "string"], "link": ["type": "string"], "met": ["type": "string"], "add_email": ["type": "string"],
              "add_tags": ["type": "array", "items": ["type": "string"]], "remove_tags": ["type": "array", "items": ["type": "string"]],
              "add_note": ["type": "string"]], ["person_id"]),
        tool("set_follow_up", "Set (or clear) the date to follow up with someone; it shows on Today when due. The user approves first.",
             ["person_id": ["type": "string"], "date": ["type": "string", "description": "YYYY-MM-DD"], "note": ["type": "string"],
              "clear": ["type": "boolean"]], ["person_id"]),
        tool("log_person_touch", "Record that the user was in touch with someone (a call, coffee, a chat at an event). The user approves first.",
             ["person_id": ["type": "string"], "note": ["type": "string"]], ["person_id", "note"]),
        tool("draft_email", "Show the user an email draft they can copy or open in Mail. Never sends anything.",
             ["to": ["type": "string"], "subject": ["type": "string"], "body": ["type": "string"]], ["subject", "body"]),
        tool("create_inquiry", "Add a new inquiry as a project at Quoting (for example from a pasted DM or email). The user approves first.",
             ["client": ["type": "string"], "title": ["type": "string", "description": "What the job is"],
              "source": ["type": "string", "description": "Email, Website form, Instagram, Referral, Phone, The Knot…"],
              "location": ["type": "string"], "budget_hint": ["type": "string"], "event_date": ["type": "string", "description": "YYYY-MM-DD"],
              "notes": ["type": "string"]], ["client"]),
        tool("update_discovery", "Fill in a deal's discovery answers (only the fields given change). The user approves first.",
             ["deal_id": ["type": "string"], "goal": ["type": "string"], "audience": ["type": "string"],
              "where_watched": ["type": "string"], "on_camera": ["type": "string"], "locations": ["type": "string"],
              "formats": ["type": "string"], "go_live": ["type": "string", "description": "YYYY-MM-DD"]], ["deal_id"]),
        tool("log_follow_up", "Record a touchpoint on a deal (a call, an email sent, a reply received). The user approves first.",
             ["deal_id": ["type": "string"], "note": ["type": "string"]], ["deal_id", "note"]),
        tool("set_deal_stage", "Move a deal to inquiry, proposal_out, talking or lost (with a reason). The user approves first.",
             ["deal_id": ["type": "string"], "stage": ["type": "string"], "reason": ["type": "string"]], ["deal_id", "stage"]),
        tool("update_rate", "Change one number on the owner's rate card. Field names come from get_rates. The user approves first.",
             ["field": ["type": "string"], "value": ["type": "number"]], ["field", "value"]),
        tool("remember", "Save a short rule about how the user works or what they prefer. Used in every future conversation. The user approves first.",
             ["note": ["type": "string"]], ["note"]),
        tool("forget", "Remove something Lens learned, by the id shown in brackets. The user approves first.",
             ["note_id": ["type": "string"]], ["note_id"]),
        tool("request_app_change", "Send the Lens developer a request to change Lens itself (new feature, screen or fix). The user approves first.",
             ["title": ["type": "string"], "details": ["type": "string", "description": "What she wants, why, and an example"]],
             ["title", "details"]),
    ]

    private static func tool(_ name: String, _ description: String, _ props: [String: Any], _ required: [String]) -> [String: Any] {
        ["name": name, "description": description, "eager_input_streaming": true,
         "input_schema": ["type": "object", "properties": props, "required": required]]
    }
}


extension LensAI {
    /// Who you're talking to, from their own rate card (name, business, website), so Ask Lens
    /// uses their name instead of "the user". Sent after the cached instructions so caching still works.
    func aboutOwner() -> String? {
        guard let r = deals?.rates else { return nil }
        var parts: [String] = []
        if !r.ownerName.isEmpty { parts.append("The person using Lens is \(r.ownerName). Call them by their first name.") }
        if !r.businessName.isEmpty { parts.append("Their business is \(r.businessName).") }
        if !r.website.isEmpty { parts.append("Website: \(r.website).") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

// MARK: - Lens drafts a proposal

extension LensAI {
    /// What came back from drafting: the deal with its blanks filled in, and a sentence on the price.
    struct ProposalDraft {
        let deal: Deal
        let priceNote: String
    }

    /// Drafts a proposal for one inquiry from what Lens knows about it (emails, Zoom calls, call notes,
    /// the budget they mentioned) and Emma's past quotes. Claude only sizes the job (days, crew, film length,
    /// extras) and writes the words; every price comes from her rate card through the Estimator, so it
    /// matches her usual pricing. Only blank parts are filled in: anything she already wrote stays.
    func draftProposal(_ deal: Deal, history: [Quote]) async throws -> ProposalDraft {
        guard let deals else { throw AIError("Lens isn't ready yet. Try again in a moment.") }
        let past: [[String: Any]] = history.filter { ($0.amount ?? 0) > 0 && $0.dealID != deal.id }.prefix(40).map { q -> [String: Any] in
            var row: [String: Any] = ["client": q.client, "title": q.title, "kind": q.kind, "price": q.amount ?? 0,
                                      "status": q.status, "what_it_covered": q.deliverables]
            if let days = q.shootDays { row["shoot_days"] = days }
            if !q.packages.isEmpty { row["options"] = q.packages.map { "\($0.name): \($0.amount.map { Money.string($0) } ?? "") \($0.includes)" } }
            return row
        }
        let facts: [String: Any] = ["this_inquiry": dealDetail(deal), "past_quotes": past, "her_rates": rateValues(deals.rates)]
        let data = try JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys])
        guard let a = try await structured(system: Self.draftPrompt, schema: Self.draftSchema,
                                           payload: String(decoding: data, as: UTF8.self)), !a.isEmpty else {
            throw AIError("Claude's draft didn't come through. Try again in a moment.")
        }
        func s(_ k: String) -> String { ((a[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func n(_ k: String, _ low: Int, _ high: Int) -> Int { min(max(Int(((a[k] as? Double) ?? Double((a[k] as? Int) ?? low)).rounded()), low), high) }

        var d = deal
        // The discovery answers: only where she hasn't written one.
        var disc = d.disc
        if disc.goal.isEmpty { disc.goal = s("goal") }
        if disc.audience.isEmpty { disc.audience = s("audience") }
        if disc.whereWatched.isEmpty { disc.whereWatched = s("where_watched") }
        if disc.onCamera.isEmpty { disc.onCamera = s("on_camera") }
        if disc.locations.isEmpty { disc.locations = s("locations") }
        if disc.formats.isEmpty { disc.formats = s("formats") }
        d.discovery = disc
        // The opening words.
        if d.story.isEmpty {
            d.story.headline = s("headline")
            d.story.logline = s("logline")
            d.story.why = (a["why"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        // The scope: only when there are no options yet. Prices come from her rate card.
        if d.options.isEmpty {
            var o = ScopeOption.starter()
            o.localDays = n("local_days", 0, 30)
            o.halfDayCount = n("half_days", 0, 10)
            o.hourCount = n("shoot_hours", 0, 12)
            if o.localDays == 0 && o.halfDayCount == 0 && o.hourCount == 0 { o.localDays = 1 }
            o.travelDays = n("travel_days", 0, 30)
            o.travelPlaces = o.travelDays > 0 ? s("travel_places") : ""
            o.localCrew = n("crew", 0, 6)
            o.travelCrew = o.localCrew
            o.interviewees = n("interviewees", 0, 30)
            o.filmMinutes = n("film_minutes", 1, 60)
            o.revisionRounds = n("revision_rounds", 1, 5)
            o.extras = (a["extras"] as? [String] ?? []).compactMap(Extra.init(rawValue:))
            o.footageOnly = (a["footage_only"] as? Bool) ?? false
            o.pitch = s("pitch")
            d.options = ((a["three_options"] as? Bool) ?? true) ? o.threeWays() : [o]
        }
        let prices = d.options.map { deals.estimate($0).total }
        var note = prices.count > 1
            ? "Priced from your rate card: \(prices.map { Money.string($0) }.joined(separator: ", ")) for the three options."
            : prices.first.map { "Priced from your rate card: \(Money.string($0))." } ?? ""
        let compare = s("similar_jobs")
        if !compare.isEmpty { note += " " + compare }
        return ProposalDraft(deal: d, priceNote: note)
    }

    private static let draftPrompt = """
    You draft a proposal for a freelance filmmaker and videographer (Emma) in her business app, Lens. You get \
    one inquiry (the client, their emails, Zoom call summaries, her call notes, any budget they mentioned), \
    her past quotes, and her rate card. Size the job the way she usually would for work like this: shoot days \
    (or half days or hours for small shoots), travel days, how many collaborators beside her, interviewees, \
    the length of the main film, revision rounds and extras. Use her past quotes for similar work as the guide \
    to how she scopes, and keep the size realistic for any budget the client mentioned. Do not set prices: Lens \
    works them out from her rate card. Fill in the discovery answers only from what the client actually said \
    (leave a field "" when it wasn't said). Write a headline, a one-sentence logline and two or three reasons \
    this film matters to them, opening with their goal, not with Emma. pitch: one sentence on what the main \
    option includes. three_options: true for most jobs (full vision, close to it, bare bones); false for a \
    small, simple job. extras: only from trailer, socialCut, verticalCut, stills, interviewLibrary, rawFootage. \
    similar_jobs: one short sentence naming up to three similar past jobs and what she charged, or "" if none. \
    Plain English, no em dashes, no jargon.
    """

    private static let draftSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "goal": ["type": "string"], "audience": ["type": "string"], "where_watched": ["type": "string"],
            "on_camera": ["type": "string"], "locations": ["type": "string"], "formats": ["type": "string"],
            "headline": ["type": "string"], "logline": ["type": "string"],
            "why": ["type": "array", "items": ["type": "string"]],
            "local_days": ["type": "number"], "half_days": ["type": "number"], "shoot_hours": ["type": "number"],
            "travel_days": ["type": "number"], "travel_places": ["type": "string"],
            "crew": ["type": "number"], "interviewees": ["type": "number"], "film_minutes": ["type": "number"],
            "revision_rounds": ["type": "number"],
            "extras": ["type": "array", "items": ["type": "string",
                       "enum": ["trailer", "socialCut", "verticalCut", "stills", "interviewLibrary", "rawFootage"]]],
            "footage_only": ["type": "boolean"],
            "pitch": ["type": "string"], "three_options": ["type": "boolean"], "similar_jobs": ["type": "string"],
        ],
        "required": ["goal", "audience", "where_watched", "on_camera", "locations", "formats", "headline", "logline",
                     "why", "local_days", "half_days", "shoot_hours", "travel_days", "travel_places", "crew",
                     "interviewees", "film_minutes", "revision_rounds", "extras", "footage_only", "pitch",
                     "three_options", "similar_jobs"],
        "additionalProperties": false,
    ]
}
