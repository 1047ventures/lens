import Foundation

/// Every potential gig plus Emma's rate card, persisted to Application Support as JSON.
@MainActor
final class DealStore: ObservableObject {
    @Published private(set) var deals: [Deal] = []
    @Published var rates = RateCard() { didSet { saveRates() } }

    init() {
        load()
    }

    func deal(id: UUID?) -> Deal? {
        guard let id else { return nil }
        return deals.first { $0.id == id }
    }

    func deals(in stage: DealStage) -> [Deal] {
        deals.filter { $0.stage == stage }.sorted { $0.lastTouch > $1.lastTouch }
    }

    var open: [Deal] { deals.filter { $0.stage.isOpen } }

    /// Recently closed deals, for the right-hand column of the board.
    var recentlyClosed: [Deal] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -45, to: Date()) ?? .distantPast
        return deals.filter { !$0.stage.isOpen && $0.lastTouch >= cutoff }.sorted { $0.lastTouch > $1.lastTouch }
    }

    func estimate(_ option: ScopeOption) -> Estimate {
        Estimator.estimate(option, rates: rates)
    }

    /// The chosen option's price, or the most expensive one while the client is still deciding.
    func value(of deal: Deal) -> Double? {
        if let chosen = deal.chosenOption { return estimate(chosen).total }
        return deal.options.map { estimate($0).total }.max()
    }

    func valueText(of deal: Deal) -> String {
        let totals = deal.options.map { estimate($0).total }
        if let chosen = deal.chosenOption { return Money.short(estimate(chosen).total) }
        guard let low = totals.min(), let high = totals.max() else { return deal.budgetHint.isEmpty ? "No price yet" : deal.budgetHint }
        return low == high ? Money.short(low) : "\(Money.short(low))–\(Money.short(high))"
    }

    // MARK: - Changes

    func add(_ deal: Deal) {
        deals.append(deal)
        save()
    }

    func update(_ deal: Deal) {
        guard let index = deals.firstIndex(where: { $0.id == deal.id }) else { return }
        deals[index] = deal
        save()
    }

    func delete(_ deal: Deal) {
        deals.removeAll { $0.id == deal.id }
        save()
    }

    func setStage(_ stage: DealStage, for deal: Deal, note: String? = nil) {
        guard var d = self.deal(id: deal.id) else { return }
        d.stage = stage
        d.lastTouch = Date()
        d.events.append(ProjectEvent(text: note ?? stage.label))
        update(d)
    }

    func logTouch(_ text: String, for deal: Deal) {
        guard var d = self.deal(id: deal.id) else { return }
        d.lastTouch = Date()
        d.events.append(ProjectEvent(text: text))
        update(d)
    }

    func markLost(_ deal: Deal, reason: String) {
        guard var d = self.deal(id: deal.id) else { return }
        d.stage = .lost
        d.lostReason = reason
        d.lastTouch = Date()
        d.events.append(ProjectEvent(text: reason.isEmpty ? "Lost" : "Lost: \(reason)"))
        update(d)
    }

    /// Books the gig: the deal becomes a project at "Booked", carrying the chosen option's
    /// price, the milestones and the whole conversation history along with it.
    @discardableResult
    func markWon(_ deal: Deal, option: ScopeOption, projects: ProjectStore) -> UUID {
        guard var d = self.deal(id: deal.id) else { return UUID() }
        let estimate = self.estimate(option)
        var project = Project(name: d.title, client: d.client, shootDate: d.eventDate, location: d.location, stage: .booked)
        project.events = d.events
            + d.milestones.map { ProjectEvent(text: "Planned: \($0.phase) · \($0.when)") }
            + [ProjectEvent(text: "Booked: \(option.name) (\(option.tagline)) at \(Money.string(estimate.total))")]
        projects.add(project)

        d.stage = .won
        d.chosenOptionID = option.id
        d.projectID = project.id
        d.lastTouch = Date()
        d.events.append(ProjectEvent(text: "Won with \(option.name) · \(Money.string(estimate.total))"))
        update(d)
        return project.id
    }

    // MARK: - Persistence

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.url("deals.json")) {
            do { deals = try decoder.decode([Deal].self, from: data) }
            catch { NSLog("Lens: couldn't read deals.json: \(error)") }
        }
        // Merge the saved card over the defaults, so fields added in later versions keep their defaults.
        if let data = try? Data(contentsOf: Self.url("rate_card.json")),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let defaultsData = try? JSONEncoder().encode(RateCard()),
           var merged = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any] {
            merged.merge(saved) { _, new in new }
            if let mergedData = try? JSONSerialization.data(withJSONObject: merged),
               let card = try? decoder.decode(RateCard.self, from: mergedData) {
                rates = card
            }
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(deals) else { return }
        try? data.write(to: Self.url("deals.json"), options: .atomic)
    }

    private func saveRates() {
        guard let data = try? JSONEncoder().encode(rates) else { return }
        try? data.write(to: Self.url("rate_card.json"), options: .atomic)
    }

    static func url(_ name: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lens", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }
}
