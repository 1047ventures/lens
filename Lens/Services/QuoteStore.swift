import Foundation
import AppKit

/// A quote or proposal Emma sent: uploaded from a file, found in an email, or made in Lens.
struct Quote: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var client: String
    var title: String
    /// The total, when the quote has one.
    var amount: Double?
    var items: [QuoteItem] = []
    /// "Wedding", "Documentary", "Brand film"…
    var kind: String = ""
    var shootDays: Double?
    var deliverables: String = ""
    /// "Sent", "Accepted", "Declined", or "" when unknown.
    var status: String = ""
    /// "Uploaded", "Email".
    var source: String = "Uploaded"
    /// Where it lives: a file on the Mac or a web link.
    var location: String = ""
    var projectID: UUID?
    var dealID: UUID?
    var notes: String = ""

    init(date: Date, client: String, title: String) {
        self.date = date
        self.client = client
        self.title = title
    }

    // Tolerant: every field but the basics may be missing in older saved quotes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        date = (try? c.decode(Date.self, forKey: .date)) ?? Date()
        client = (try? c.decode(String.self, forKey: .client)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        amount = try? c.decode(Double.self, forKey: .amount)
        items = (try? c.decode([QuoteItem].self, forKey: .items)) ?? []
        kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
        shootDays = try? c.decode(Double.self, forKey: .shootDays)
        deliverables = (try? c.decode(String.self, forKey: .deliverables)) ?? ""
        status = (try? c.decode(String.self, forKey: .status)) ?? ""
        source = (try? c.decode(String.self, forKey: .source)) ?? "Uploaded"
        location = (try? c.decode(String.self, forKey: .location)) ?? ""
        projectID = try? c.decode(UUID.self, forKey: .projectID)
        dealID = try? c.decode(UUID.self, forKey: .dealID)
        notes = (try? c.decode(String.self, forKey: .notes)) ?? ""
    }
}

struct QuoteItem: Codable, Hashable {
    var name: String
    var amount: Double?
}

/// Every quote and proposal Emma has sent, so pricing a new job can start from what she charged before.
/// Saved in quotes.json.
@MainActor
final class QuoteStore: ObservableObject {
    @Published private(set) var quotes: [Quote] = []
    /// Set while Lens reads an uploaded file.
    @Published private(set) var reading: String?
    @Published var problem: String?

    init() { load() }

    func add(_ quote: Quote) {
        quotes.removeAll { $0.id == quote.id }
        quotes.append(quote)
        quotes.sort { $0.date > $1.date }
        save()
    }

    func update(_ quote: Quote) { add(quote) }

    func remove(_ quote: Quote) {
        quotes.removeAll { $0.id == quote.id }
        save()
    }

    func quotes(forProject id: UUID) -> [Quote] { quotes.filter { $0.projectID == id } }
    func quotes(forDeal id: UUID) -> [Quote] { quotes.filter { $0.dealID == id } }

    /// Asks Emma for proposal or quote files, keeps them on the project (or deal), and reads each one
    /// with Claude so its price and what it covered go into her quote history.
    func upload(projectID: UUID?, dealID: UUID?, client: String, ai: LensAI, projects: ProjectStore, deals: DealStore) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Pick your proposal or quote (PDF, Word, Pages export, photo or text)."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        if let projectID {
            projects.edit(projectID) { p in
                p.documents = (p.documents ?? []) + urls.map { ProjectFile(name: $0.lastPathComponent, kind: "Proposal", location: $0.path) }
            }
        }
        Task { await read(urls, projectID: projectID, dealID: dealID, client: client, ai: ai, projects: projects, deals: deals) }
    }

    func read(_ urls: [URL], projectID: UUID?, dealID: UUID?, client: String, ai: LensAI,
              projects: ProjectStore, deals: DealStore) async {
        problem = nil
        for url in urls {
            reading = "Reading \(url.lastPathComponent)…"
            var quote = Quote(date: (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date(),
                              client: client, title: url.deletingPathExtension().lastPathComponent)
            quote.location = url.path
            quote.projectID = projectID
            quote.dealID = dealID
            if let deal = dealID.flatMap({ deals.deal(id: $0) }) {
                quote.status = deal.stage == .won ? "Accepted" : deal.stage == .lost ? "Declined" : "Sent"
            } else if projectID != nil {
                quote.status = "Accepted"   // on a booked project, so it went ahead
            }
            if ai.hasKey {
                let (blocks, _) = await Task.detached { Attachments.blocks(for: [url]) }.value
                if !blocks.isEmpty {
                    do {
                        if let read = try await ai.readQuote(blocks) { quote = Self.merge(read, into: quote) }
                    } catch {
                        problem = "Lens kept the file but couldn't read the price in it just now."
                    }
                } else {
                    problem = "Lens kept \(url.lastPathComponent) but can't read that kind of file. A PDF works best."
                }
            }
            add(quote)
            // A project without a price takes it from its proposal.
            if let projectID, let amount = quote.amount, projects.project(id: projectID)?.price == nil,
               deals.deals.first(where: { $0.projectID == projectID }) == nil {
                projects.edit(projectID) { $0.price = amount }
            }
        }
        reading = nil
    }

    /// What Claude read from a quote, on top of what Lens already knew.
    static func merge(_ read: [String: Any], into quote: Quote) -> Quote {
        var q = quote
        func s(_ k: String) -> String { ((read[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        if !s("client").isEmpty && q.client.isEmpty { q.client = s("client") }
        if !s("title").isEmpty { q.title = s("title") }
        if let total = read["total"] as? Double, total > 0 { q.amount = total }
        else if let total = read["total"] as? Int, total > 0 { q.amount = Double(total) }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.locale = Locale(identifier: "en_US_POSIX")
        if let d = day.date(from: s("date")) { q.date = d }
        q.kind = s("kind_of_work")
        if let days = read["shoot_days"] as? Double, days > 0 { q.shootDays = days }
        else if let days = read["shoot_days"] as? Int, days > 0 { q.shootDays = Double(days) }
        q.deliverables = s("deliverables")
        q.items = (read["items"] as? [[String: Any]] ?? []).compactMap { i in
            let name = ((i["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let amount = (i["amount"] as? Double) ?? (i["amount"] as? Int).map(Double.init)
            return QuoteItem(name: name, amount: (amount ?? 0) > 0 ? amount : nil)
        }
        if q.amount == nil {
            let sum = q.items.compactMap(\.amount).reduce(0, +)
            if sum > 0 { q.amount = sum }
        }
        return q
    }

    /// Everything Emma has quoted, including proposals made in Lens, newest first. For the history and Ask Lens.
    func history(deals: DealStore) -> [Quote] {
        var all = quotes
        for deal in deals.deals where deal.stage != .inquiry {
            guard let value = deals.value(of: deal), value > 0,
                  !quotes.contains(where: { $0.dealID == deal.id && $0.source == "Uploaded" }) else { continue }
            var q = Quote(date: deal.events.last { $0.text.localizedCaseInsensitiveContains("proposal sent") }?.date
                            ?? deal.events.first?.date ?? Date(),
                          client: deal.client, title: deal.title)
            q.id = deal.id
            q.amount = value
            q.status = deal.stage == .won ? "Accepted" : deal.stage == .lost ? "Declined" : "Sent"
            q.source = "Lens proposal"
            q.dealID = deal.id
            q.projectID = deal.projectID
            if let option = deal.chosenOption ?? deal.options.first { q.deliverables = option.name + (option.tagline.isEmpty ? "" : ", " + option.tagline) }
            all.append(q)
        }
        return all.sorted { $0.date > $1.date }
    }

    private static var fileURL: URL { DealStore.url("quotes.json") }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: Self.fileURL),
              let saved = try? decoder.decode([Quote].self, from: data) else { return }
        quotes = saved.sorted { $0.date > $1.date }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(quotes) { try? data.write(to: Self.fileURL, options: .atomic) }
    }
}
