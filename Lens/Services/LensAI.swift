import Foundation
import AppKit

/// Ask Lens: Claude inside the app. It reads Lens's own data through tools, proposes changes
/// that Emma approves one tap at a time, learns from what she tells it, and turns bigger wishes
/// into change requests for Sean. Talks to the Claude API directly over HTTPS (there is no
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
    private var messages: [[String: Any]] = []
    private var decisions: [String: CheckedContinuation<Bool, Never>] = [:]
    private var spend = Spend()

    init() { load() }

    func attach(deals: DealStore, projects: ProjectStore, navigator: Navigator, money: MoneyStore) {
        self.money = money
        self.deals = deals
        self.projects = projects
        self.navigator = navigator
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

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !busy else { return }
        guard let key = Keychain.get("anthropic.apiKey"), !key.isEmpty else {
            items.append(Item(kind: .error, text: "Connect Claude in Log-ins first (it needs an API key)."))
            return
        }
        items.append(Item(kind: .user, text: trimmed))
        messages.append(["role": "user", "content": [["type": "text", "text": "<screen>\(screenContext())</screen>\n\n\(trimmed)"]]])
        busy = true
        defer { busy = false }

        do {
            for _ in 0..<12 {   // at most 12 tool rounds per question
                let response = try await call(key: key)
                let content = response["content"] as? [[String: Any]] ?? []
                messages.append(["role": "assistant", "content": content])
                for block in content where block["type"] as? String == "text" {
                    if let t = block["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        items.append(Item(kind: .assistant, text: t))
                    }
                }
                let stop = response["stop_reason"] as? String
                if stop == "refusal" {
                    items.append(Item(kind: .info, text: "Claude declined that one. Try rephrasing it."))
                    return
                }
                guard stop == "tool_use" else { return }

                var results: [[String: Any]] = []
                for block in content where block["type"] as? String == "tool_use" {
                    guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
                    let input = block["input"] as? [String: Any] ?? [:]
                    let (text, isError) = await runTool(id: id, name: name, input: input)
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

    private func call(key: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")

        var system: [[String: Any]] = [["type": "text", "text": Self.systemPrompt, "cache_control": ["type": "ephemeral"]]]
        if !notes.isEmpty {
            system.append(["type": "text", "text": "What Emma has taught you (follow these):\n" +
                notes.map { "- [\($0.id.uuidString.prefix(8))] \($0.text)" }.joined(separator: "\n")])
        }
        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 16000,
            "system": system,
            "tools": Self.tools,
            "messages": messages,
            "output_config": ["effort": "medium"],
            "cache_control": ["type": "ephemeral"],
            // If Claude declines on a safety classifier, the API retries on a suitable model.
            "fallbacks": "default",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
            switch status {
            case 401: throw AIError("The Claude API key isn't valid. Check it in Log-ins.")
            case 429: throw AIError("Claude is busy or the monthly limit was hit. Try again in a minute.")
            case 529, 500...599: throw AIError("Claude is having a moment. Try again shortly.")
            default: throw AIError("Claude couldn't answer: \(message)")
            }
        }
        if let usage = json["usage"] as? [String: Any] { record(usage) }
        return json
    }

    struct AIError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
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
        let cost = n("input_tokens") * 4 / 1e6 + n("output_tokens") * 20 / 1e6
            + n("cache_read_input_tokens") * 0.2 / 1e6 + n("cache_creation_input_tokens") * 5 / 1e6
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
        case "list_deals":
            let stage = str("stage")
            let list = deals.deals.filter { stage.isEmpty || stageKey($0.stage) == stage }
            return (json(list.map { dealSummary($0) }), false)
        case "get_deal":
            guard let deal = findDeal(str("deal_id")) else { return ("No deal with that id.", true) }
            return (json(dealDetail(deal)), false)
        case "list_projects":
            return (json(projects.projects.map { projectSummary($0) }), false)
        case "get_project":
            guard let p = projects.projects.first(where: { $0.id.uuidString == str("project_id") }) else { return ("No project with that id.", true) }
            var d = projectSummary(p)
            d["history"] = p.events.map { "\($0.date.formatted(date: .abbreviated, time: .omitted)): \($0.text)" }
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

        // ---- Showing things (harmless)
        case "open_screen":
            if let deal = findDeal(str("deal_id")) { navigator?.openDeal(deal.id) }
            else if let p = projects.projects.first(where: { $0.id.uuidString == str("project_id") }) { navigator?.openProject(p.id) }
            else if let section = SidebarSection.allCases.first(where: { $0.rawValue.lowercased() == str("section").lowercased() }) { navigator?.open(section) }
            else { return ("Nothing to open with that.", true) }
            return ("Opened.", false)
        case "draft_email":
            items.append(Item(kind: .draft, text: "", draft: Draft(to: str("to"), subject: str("subject"), body: str("body"))))
            return ("The draft is shown to Emma with Copy and Open in Mail buttons. Nothing was sent.", false)

        // ---- Changes (each one waits for Emma's tap)
        case "create_inquiry":
            let summary = "Add a new inquiry: \(str("title")) for \(str("client"))"
            guard await ask(id: id, tool: name, summary: summary) else { return ("Emma skipped this.", false) }
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
            guard await ask(id: id, tool: name, summary: summary) else { return ("Emma skipped this.", false) }
            for (key, path) in changes { deal.disc[keyPath: path] = str(key) }
            if let goLive { deal.disc.goLive = goLive }
            deals.update(deal)
            return ("Updated.", false)
        case "log_follow_up":
            guard let deal = findDeal(str("deal_id")) else { return ("No deal with that id.", true) }
            guard await ask(id: id, tool: name, summary: "Log on \(deal.title): \(str("note"))") else { return ("Emma skipped this.", false) }
            deals.logTouch(str("note"), for: deal)
            return ("Logged.", false)
        case "set_deal_stage":
            guard let deal = findDeal(str("deal_id")) else { return ("No deal with that id.", true) }
            let map: [String: DealStage] = ["inquiry": .inquiry, "proposal_out": .proposalOut, "talking": .talking, "lost": .lost]
            guard let stage = map[str("stage")] else { return ("Use inquiry, proposal_out, talking or lost. Winning a deal is done with the Mark won button so she picks the option.", true) }
            guard await ask(id: id, tool: name, summary: "Move \(deal.title) to \(stage.label)") else { return ("Emma skipped this.", false) }
            if stage == .lost { deals.markLost(deal, reason: str("reason")) } else { deals.setStage(stage, for: deal) }
            return ("Done.", false)
        case "update_rate":
            let field = str("field")
            guard let value = input["value"] as? Double ?? (input["value"] as? Int).map(Double.init),
                  let path = Self.rateFields[field] else { return ("Unknown rate field. Use get_rates to see them.", true) }
            let old = deals.rates[keyPath: path]
            guard await ask(id: id, tool: name, summary: "Change \(field.replacingOccurrences(of: "_", with: " ")) from \(format(old)) to \(format(value))") else { return ("Emma skipped this.", false) }
            deals.rates[keyPath: path] = value
            return ("Saved.", false)
        case "remember":
            let note = str("note")
            guard !note.isEmpty else { return ("Empty note.", true) }
            guard await ask(id: id, tool: name, summary: "Remember: \(note)") else { return ("Emma skipped this.", false) }
            notes.append(Note(text: note))
            save()
            return ("Saved to what Lens has learned.", false)
        case "forget":
            guard let note = notes.first(where: { $0.id.uuidString.hasPrefix(str("note_id")) && !str("note_id").isEmpty }) else { return ("No note with that id.", true) }
            guard await ask(id: id, tool: name, summary: "Forget: \(note.text)") else { return ("Emma skipped this.", false) }
            forget(note)
            return ("Forgotten.", false)
        case "request_app_change":
            let title = str("title"), details = str("details")
            guard await ask(id: id, tool: name, summary: "Send Sean a change request: \(title)") else { return ("Emma skipped this.", false) }
            var request = ChangeRequest(title: title, details: details)
            request.link = await fileRequest(request)
            requests.append(request)
            save()
            return (request.link.map { "Sent: \($0)" } ?? "Saved, and an email to Sean was opened for Emma to send.", false)
        default:
            return ("Unknown tool \(name).", true)
        }
    }

    /// Shows an approval card and waits for Emma's tap.
    private func ask(id: String, tool: String, summary: String) async -> Bool {
        items.append(Item(kind: .action, text: summary, action: Action(id: id, tool: tool, summary: summary)))
        return await withCheckedContinuation { decisions[id] = $0 }
    }

    /// Change requests become GitHub issues on Lens's private repo when a token is set up,
    /// otherwise an email to Sean that Emma sends herself.
    private func fileRequest(_ request: ChangeRequest) async -> String? {
        let body = "\(request.details)\n\n_From Emma via Ask Lens, \(request.created.formatted(date: .abbreviated, time: .shortened)). Lens \(Updater.shared.currentVersion)._"
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
        if navigator.section == .pipeline, let deal = deals?.deal(id: navigator.dealID) {
            parts.append("Looking at deal \"\(deal.title)\" (deal_id \(deal.id.uuidString))")
            if navigator.builderDealID == deal.id { parts.append("in the proposal builder") }
        }
        if navigator.section == .projects, let p = projects?.project(id: navigator.projectID) {
            parts.append("Looking at project \"\(p.name)\" (project_id \(p.id.uuidString))")
        }
        parts.append("Today is \(Date().formatted(date: .complete, time: .shortened))")
        return parts.joined(separator: ". ")
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
            return ["name": o.name, "tagline": o.tagline, "local_days": o.localDays, "travel_days": o.travelDays,
                    "crew": o.localCrew, "interviewees": o.interviewees, "film_minutes": o.filmMinutes,
                    "revisions": o.revisionRounds, "extras": o.extras.map(\.label),
                    "price": Money.string(e.total), "at_her_rates": Money.string(e.calculated),
                    "she_keeps": Money.string(e.takeHome), "per_hour": Money.string(e.takeHomePerHour)]
        }
        out["milestones"] = d.milestones.map { "\($0.phase): \($0.when)" }
        out["next_steps"] = d.nextSteps.map { ($0.done ? "[done] " : "") + $0.text }
        out["proposal_sections_done"] = "\(BuilderStep.progress(d)) of \(BuilderStep.allCases.count)"
        out["history"] = d.events.map { "\($0.date.formatted(date: .abbreviated, time: .omitted)): \($0.text)" }
        return out
    }

    private func projectSummary(_ p: Project) -> [String: Any] {
        ["project_id": p.id.uuidString, "name": p.name, "client": p.client, "stage": p.stage.label,
         "shoot_date": p.shootDate?.formatted(date: .abbreviated, time: .shortened) ?? "", "location": p.location]
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
    You are Lens, the assistant built into Emma's business app. Emma Pion-Berlin is a videographer and \
    photographer in Colorado (Visual Storytelling). Lens runs her pipeline (inquiries to booked gigs), \
    proposals, projects, footage, money and log-ins. Sean built Lens for her.

    How to work:
    - Look things up with the tools instead of guessing. Never invent clients, numbers or dates.
    - You can change things only through tools. Each change shows Emma an Approve button; say what you're \
    proposing in one line and let the card do the rest. Don't say something is done until the tool result says so.
    - Keep replies short and plain: a sentence or two, or a short list. No jargon. Money in dollars.
    - When Emma corrects you, states a preference, or explains how she likes to work, offer to remember it with \
    the remember tool, phrased as a short rule.
    - Prices: protect the price, scale the scope. If she wants to go cheaper, suggest what to cut before discounting.
    - Drafting emails: write in her warm, direct voice, short paragraphs, and use draft_email. You never send email.
    - If she asks for something Lens can't do (a new screen, a new button, a different layout, a connection that \
    doesn't exist), say so and offer request_app_change with a clear title and a write-up Sean can build from: \
    what she wants, why, and an example.
    - The <screen> tag at the start of her message says what she is looking at; "this deal" means that one.
    """

    static let tools: [[String: Any]] = [
        tool("list_deals", "List potential gigs in the pipeline. Optional stage filter: inquiry, proposal_out, talking, won, lost.",
             ["stage": ["type": "string"]], []),
        tool("get_deal", "Everything about one deal: discovery answers, options with prices and what Emma keeps, timeline, history.",
             ["deal_id": ["type": "string"]], ["deal_id"]),
        tool("list_projects", "List booked projects with stage, shoot date and location.", [:], []),
        tool("get_project", "One project's details and history.", ["project_id": ["type": "string"]], ["project_id"]),
        tool("get_money", "The books for a period (This month, Last month, This year, All time): revenue and costs by category, what she kept, cash in and out, who owes her, gear value, what the business is worth.",
             ["period": ["type": "string"]], []),
        tool("get_rates", "Emma's rate card: day rates, hourly rates, deposit percent, target take-home per hour.", [:], []),
        tool("open_screen", "Show something in Lens: a deal, a project, or a section (Today, Pipeline, Projects, Footage, Gear, Money, Log-ins).",
             ["deal_id": ["type": "string"], "project_id": ["type": "string"], "section": ["type": "string"]], []),
        tool("draft_email", "Show Emma an email draft she can copy or open in Mail. Never sends anything.",
             ["to": ["type": "string"], "subject": ["type": "string"], "body": ["type": "string"]], ["subject", "body"]),
        tool("create_inquiry", "Add a new inquiry to the pipeline (for example from a pasted DM or email). Emma approves first.",
             ["client": ["type": "string"], "title": ["type": "string", "description": "What the job is"],
              "source": ["type": "string", "description": "Email, Website form, Instagram, Referral, Phone, The Knot…"],
              "location": ["type": "string"], "budget_hint": ["type": "string"], "event_date": ["type": "string", "description": "YYYY-MM-DD"],
              "notes": ["type": "string"]], ["client"]),
        tool("update_discovery", "Fill in a deal's discovery answers (only the fields given change). Emma approves first.",
             ["deal_id": ["type": "string"], "goal": ["type": "string"], "audience": ["type": "string"],
              "where_watched": ["type": "string"], "on_camera": ["type": "string"], "locations": ["type": "string"],
              "formats": ["type": "string"], "go_live": ["type": "string", "description": "YYYY-MM-DD"]], ["deal_id"]),
        tool("log_follow_up", "Record a touchpoint on a deal (a call, an email sent, a reply received). Emma approves first.",
             ["deal_id": ["type": "string"], "note": ["type": "string"]], ["deal_id", "note"]),
        tool("set_deal_stage", "Move a deal to inquiry, proposal_out, talking or lost (with a reason). Emma approves first.",
             ["deal_id": ["type": "string"], "stage": ["type": "string"], "reason": ["type": "string"]], ["deal_id", "stage"]),
        tool("update_rate", "Change one number on Emma's rate card. Field names come from get_rates. Emma approves first.",
             ["field": ["type": "string"], "value": ["type": "number"]], ["field", "value"]),
        tool("remember", "Save a short rule about how Emma works or what she prefers. Used in every future conversation. Emma approves first.",
             ["note": ["type": "string"]], ["note"]),
        tool("forget", "Remove something Lens learned, by the id shown in brackets. Emma approves first.",
             ["note_id": ["type": "string"]], ["note_id"]),
        tool("request_app_change", "Send Sean a request to change Lens itself (new feature, screen or fix). Emma approves first.",
             ["title": ["type": "string"], "details": ["type": "string", "description": "What she wants, why, and an example"]],
             ["title", "details"]),
    ]

    private static func tool(_ name: String, _ description: String, _ props: [String: Any], _ required: [String]) -> [String: Any] {
        ["name": name, "description": description,
         "input_schema": ["type": "object", "properties": props, "required": required]]
    }
}
