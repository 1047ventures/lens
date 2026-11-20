import Foundation
import AppKit
import PDFKit

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
    /// The options offered in the proposal ("Option A, half day, $1,800"), when there were several.
    var packages: [QuotePackage] = []
    /// The package the client went for, by name.
    var chosen: String?

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
        packages = (try? c.decode([QuotePackage].self, forKey: .packages)) ?? []
        chosen = try? c.decode(String.self, forKey: .chosen)
    }

    /// An uploaded file on this Mac that can be opened as the proposal.
    var isFile: Bool { !location.isEmpty && !location.lowercased().hasPrefix("http") && !location.hasPrefix("freshbooks:") }
}

/// One option in a proposal: its name, price and what it includes.
struct QuotePackage: Codable, Hashable {
    var name: String
    var amount: Double?
    var includes: String = ""
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

    /// Opens the proposal for a deal: the one Emma uploaded if there is one, otherwise the one Lens builds.
    func openProposal(for deal: Deal, deals: DealStore, projects: ProjectStore) {
        if let q = uploadedProposal(dealID: deal.id, projectID: deal.projectID),
           FileManager.default.fileExists(atPath: q.location) {
            NSWorkspace.shared.open(URL(fileURLWithPath: q.location))
        } else {
            ProposalRenderer.open(deal, store: deals, projects: projects)
        }
    }

    /// The proposal file Emma uploaded for this deal or project, newest first.
    func uploadedProposal(dealID: UUID?, projectID: UUID?) -> Quote? {
        quotes.first { q in
            q.isFile && ((dealID != nil && q.dealID == dealID) || (projectID != nil && q.projectID == projectID))
        }
    }

    /// Emma typed the price on a quote: it's the real number, so the deal and project use it too.
    func setPrice(_ quote: Quote, _ amount: Double?, deals: DealStore, projects: ProjectStore) {
        var q = quote
        q.amount = amount
        update(q)
        guard let amount, amount > 0 else { return }
        if let dealID = q.dealID, var deal = deals.deal(id: dealID) {
            if let chosen = q.chosen, let i = deal.options.firstIndex(where: { $0.name == chosen }) {
                deal.options[i].quote = amount
            } else {
                var price = q
                price.packages = []
                deal.options = Self.options(from: price)
                deal.chosenOptionID = deal.options.first?.id
            }
            deals.update(deal)
        }
        let projectID = q.projectID ?? q.dealID.flatMap { deals.deal(id: $0)?.projectID }
        if let projectID { projects.edit(projectID) { $0.price = amount } }
    }

    /// Emma says which option the client went for. The quote takes that price, and the deal's options
    /// become the ones she actually offered (so Pipeline, Money and the project show her real numbers).
    func choose(_ name: String, in quote: Quote, deals: DealStore, projects: ProjectStore) {
        var q = quote
        q.chosen = name
        q.status = "Accepted"
        if let p = q.packages.first(where: { $0.name == name }), let amount = p.amount { q.amount = amount }
        update(q)
        if let dealID = q.dealID, var deal = deals.deal(id: dealID) {
            deal.options = Self.options(from: q)
            let chosen = deal.options.first(where: { $0.name == name })
            deal.chosenOptionID = chosen?.id
            deals.update(deal)
            // They said yes to it: book the job and give it a project (with its emails and call notes).
            if deal.stage != .won, deal.projectID == nil, let chosen {
                let projectID = deals.markWon(deal, option: chosen, projects: projects)
                q.projectID = projectID
                update(q)
            }
        }
        if let projectID = q.projectID ?? q.dealID.flatMap({ deals.deal(id: $0)?.projectID }), let amount = q.amount {
            projects.edit(projectID) { $0.price = amount }
        }
    }

    /// The deal's options, rebuilt from what Emma's own proposal offered, at her prices.
    static func options(from q: Quote) -> [ScopeOption] {
        let packages = q.packages.isEmpty
            ? [QuotePackage(name: q.title.isEmpty ? "Proposal" : q.title, amount: q.amount, includes: q.deliverables)]
            : q.packages
        return packages.map { p in
            var o = ScopeOption.starter()
            // Her proposal sets the price; start the dials small instead of documentary-sized.
            o.interviewees = 0
            o.localCrew = 0
            o.filmMinutes = 1
            o.revisionRounds = 1
            o.name = p.name
            o.tagline = ""
            o.pitch = p.includes
            o.quote = p.amount
            o.note = "From your proposal: \(q.title)"
            if let days = q.shootDays { o.localDays = max(0, Int(days.rounded(.down))); o.halfDayCount = days - days.rounded(.down) >= 0.5 ? 1 : 0 }
            return o
        }
    }
    func quotes(forDeal id: UUID) -> [Quote] { quotes.filter { $0.dealID == id } }

    /// Asks Emma for proposal or quote files, keeps them on the project (or deal), and reads each one
    /// with Claude so its price and what it covered go into her quote history.
    func upload(projectID: UUID?, dealID: UUID?, client: String, ai: LensAI, projects: ProjectStore, deals: DealStore) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Pick your proposal or quote: PDF, Word, Pages, Keynote, a photo or text."
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
                var read: [String: Any]? = nil
                var why = ""
                if !blocks.isEmpty {
                    do { read = try await ai.readQuote(blocks) } catch { why = (error as? LocalizedError)?.errorDescription ?? "" }
                }
                // Second try: the PDF's text on its own.
                if read == nil, let text = await Task.detached(operation: { Self.pdfText(url) }).value {
                    read = try? await ai.readQuote([["type": "text", "text": "<file name=\"\(url.lastPathComponent)\">\n\(text)\n</file>"]])
                }
                if let read {
                    quote = Self.merge(read, into: quote)
                } else if blocks.isEmpty {
                    problem = "Lens kept \(url.lastPathComponent) but can't read that kind of file. Save it as a PDF and upload that."
                } else {
                    problem = "Lens kept \(url.lastPathComponent) but couldn't read the price in it" + (why.isEmpty ? "." : ": \(why)")
                        + " Click Read again, or type the price in."
                }
            }
            add(quote)
            // Emma's own proposal replaces the options Lens worked out, so the deal shows what she really offered.
            if let dealID, var deal = deals.deal(id: dealID), quote.amount != nil || !quote.packages.isEmpty {
                deal.options = Self.options(from: quote)
                deal.chosenOptionID = deal.options.count == 1 ? deal.options.first?.id : nil
                deals.update(deal)
            }
            // A project without a deal takes its price from the proposal she uploaded: one option, or the one
            // she already said the client chose. With several options, Lens asks which one they chose.
            if let projectID, deals.deals.first(where: { $0.projectID == projectID }) == nil {
                let single = quote.packages.count <= 1 ? quote.amount : nil
                if let amount = single { projects.edit(projectID) { $0.price = amount } }
                if quote.shootDays != nil || !quote.deliverables.isEmpty {
                    projects.edit(projectID) { p in
                        var words = p.keywords ?? []
                        if !quote.kind.isEmpty, !words.contains(where: { $0.lowercased() == quote.kind.lowercased() }) { words.append(quote.kind) }
                        p.keywords = words.isEmpty ? nil : words
                    }
                }
            }
        }
        reading = nil
    }

    /// Reads a quote's file again (for example after an update that reads more kinds of files).
    func reread(_ quote: Quote, ai: LensAI, projects: ProjectStore, deals: DealStore) async {
        guard quote.isFile else { return }
        remove(quote)
        await read([URL(fileURLWithPath: quote.location)], projectID: quote.projectID, dealID: quote.dealID,
                   client: quote.client, ai: ai, projects: projects, deals: deals)
    }

    /// The text of a PDF, for when Claude can't take the PDF itself (too big, scanned oddly, or locked).
    nonisolated static func pdfText(_ url: URL) -> String? {
        guard url.pathExtension.lowercased() == "pdf", let doc = PDFDocument(url: url), let text = doc.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return String(text.prefix(200_000))
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
            var amount: Double? = nil
            if let d = i["amount"] as? Double { amount = d } else if let n = i["amount"] as? Int { amount = Double(n) }
            if let a = amount, a <= 0 { amount = nil }
            return QuoteItem(name: name, amount: amount)
        }
        q.packages = (read["packages"] as? [[String: Any]] ?? []).compactMap { p in
            let name = ((p["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            var amount: Double? = nil
            if let d = p["price"] as? Double { amount = d } else if let n = p["price"] as? Int { amount = Double(n) }
            if let a = amount, a <= 0 { amount = nil }
            return QuotePackage(name: name, amount: amount, includes: ((p["includes"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
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
