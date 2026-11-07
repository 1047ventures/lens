import Foundation
import AppKit

/// The books: transactions, balances, money owed, gear. Works out the three statements
/// for any period, imports bank/card/Venmo/PayPal CSV statements, and learns how to sort
/// transactions from Emma's corrections.
@MainActor
final class MoneyStore: ObservableObject {
    @Published private(set) var data = MoneyData()

    init() { load() }

    var txns: [Txn] { data.txns }
    var gear: [GearItem] { data.gear }
    var receivables: [Receivable] { data.receivables }

    // MARK: - Periods

    enum Period: String, CaseIterable, Identifiable {
        case thisMonth = "This month", lastMonth = "Last month", thisYear = "This year", all = "All time"
        var id: String { rawValue }

        func range(now: Date = Date()) -> (start: Date, end: Date) {
            let cal = Calendar.current
            let month = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            switch self {
            case .thisMonth: return (month, cal.date(byAdding: .month, value: 1, to: month)!)
            case .lastMonth: return (cal.date(byAdding: .month, value: -1, to: month)!, month)
            case .thisYear:
                let year = cal.date(from: cal.dateComponents([.year], from: now))!
                return (year, cal.date(byAdding: .year, value: 1, to: year)!)
            case .all: return (.distantPast, .distantFuture)
            }
        }
    }

    func txns(in period: Period) -> [Txn] {
        let r = period.range()
        return data.txns.filter { $0.date >= r.start && $0.date < r.end }.sorted { $0.date > $1.date }
    }

    // MARK: - Statements

    struct Line: Identifiable {
        let id = UUID()
        let label: String
        let amount: Double
    }

    struct Income {
        let revenue: [Line]; let direct: [Line]; let overhead: [Line]
        var totalRevenue: Double { revenue.reduce(0) { $0 + $1.amount } }
        var totalDirect: Double { direct.reduce(0) { $0 + $1.amount } }
        var totalOverhead: Double { overhead.reduce(0) { $0 + $1.amount } }
        var gross: Double { totalRevenue - totalDirect }
        var net: Double { gross - totalOverhead }
    }

    /// Did I make money? Revenue and costs by category (costs as positive numbers).
    func income(_ period: Period) -> Income {
        let list = txns(in: period)
        func lines(_ group: MoneyCategory.Group, sign: Double) -> [Line] {
            MoneyCategory.allCases.filter { $0.group == group }.compactMap { cat in
                let total = list.filter { $0.category == cat }.reduce(0) { $0 + $1.amount } * sign
                return abs(total) < 0.005 ? nil : Line(label: cat.label, amount: total)
            }.sorted { $0.amount > $1.amount }
        }
        return Income(revenue: lines(.income, sign: 1), direct: lines(.direct, sign: -1), overhead: lines(.overhead, sign: -1))
    }

    struct CashFlow {
        let start: Double, end: Double
        let clientsPaid: Double, projectCosts: Double, runningCosts: Double
        let cardAndTransfers: Double, gear: Double, owner: Double, taxes: Double, unsorted: Double
    }

    /// Where did the cash go? Only accounts that hold cash; ties out start to end exactly.
    func cashFlow(_ period: Period) -> CashFlow {
        let r = period.range()
        let list = data.txns.filter { $0.account.isCash && $0.date >= r.start && $0.date < r.end }
        func sum(_ groups: Set<MoneyCategory.Group>) -> Double {
            list.filter { groups.contains($0.category.group) }.reduce(0) { $0 + $1.amount }
        }
        let start = cashBalance(before: r.start)
        return CashFlow(start: start, end: start + list.reduce(0) { $0 + $1.amount },
                        clientsPaid: sum([.income]), projectCosts: sum([.direct]), runningCosts: sum([.overhead]),
                        cardAndTransfers: sum([.transfer]), gear: sum([.capital]), owner: sum([.owner]),
                        taxes: sum([.taxes]), unsorted: sum([.unsorted]))
    }

    struct Balance {
        let cash: [Line]; let owed: Double; let gear: Double; let card: Double
        var totalCash: Double { cash.reduce(0) { $0 + $1.amount } }
        var assets: Double { totalCash + owed + gear }
        var worth: Double { assets - card }
    }

    /// What's it all worth? As of the end of the period (or today).
    func balance(_ period: Period) -> Balance {
        let at = min(period.range().end, Date().addingTimeInterval(86400))
        let cash = MoneyAccount.allCases.filter(\.isCash).compactMap { account -> Line? in
            let b = accountBalance(account, before: at)
            return abs(b) < 0.005 && data.openings[account.rawValue] == nil ? nil : Line(label: account.label, amount: b)
        }
        let owed = data.receivables.filter { $0.paidOn == nil || $0.paidOn! >= at }.reduce(0) { $0 + $1.amount }
        let gearValue = data.gear.filter { $0.bought < at }.reduce(0) { $0 + $1.value(at: at) }
        return Balance(cash: cash, owed: owed, gear: gearValue, card: -accountBalance(.card, before: at))
    }

    func accountBalance(_ account: MoneyAccount, before date: Date) -> Double {
        let opening = data.openings[account.rawValue] ?? 0
        let since = data.openingDate ?? .distantPast
        return opening + data.txns.filter { $0.account == account && $0.date >= since && $0.date < date }.reduce(0) { $0 + $1.amount }
    }

    func cashBalance(before date: Date) -> Double {
        MoneyAccount.allCases.filter(\.isCash).reduce(0) { $0 + accountBalance($1, before: date) }
    }

    var unsortedCount: Int { data.txns.filter { $0.category == .uncategorized }.count }

    // MARK: - Changes

    /// Re-sort one transaction, learn the rule, and apply it to similar unsorted ones.
    /// Returns how many others were sorted along with it.
    @discardableResult
    func setCategory(_ txn: Txn, _ category: MoneyCategory) -> Int {
        guard let i = data.txns.firstIndex(where: { $0.id == txn.id }) else { return 0 }
        data.txns[i].category = category
        var others = 0
        if let key = Self.ruleKey(txn.description) {
            data.rules.removeAll { $0.match == key }
            data.rules.append(CategoryRule(match: key, category: category))
            for j in data.txns.indices where data.txns[j].category == .uncategorized && Self.ruleKey(data.txns[j].description) == key {
                data.txns[j].category = category
                others += 1
            }
        }
        save()
        return others
    }

    func setProject(_ txn: Txn, _ projectID: UUID?) {
        guard let i = data.txns.firstIndex(where: { $0.id == txn.id }) else { return }
        data.txns[i].projectID = projectID
        save()
    }

    func markPaid(_ r: Receivable, on date: Date = Date()) {
        guard let i = data.receivables.firstIndex(where: { $0.id == r.id }) else { return }
        data.receivables[i].paidOn = date
        save()
    }

    func addReceivable(_ r: Receivable) {
        data.receivables.append(r)
        save()
    }

    func saveGear(_ item: GearItem) {
        if let i = data.gear.firstIndex(where: { $0.id == item.id }) { data.gear[i] = item } else { data.gear.append(item) }
        save()
    }

    func deleteGear(_ item: GearItem) {
        data.gear.removeAll { $0.id == item.id }
        save()
    }

    // MARK: - Sorting

    /// The word that identifies who a transaction is with ("adobe", "squarespace", "jordan").
    static func ruleKey(_ description: String) -> String? {
        let skip: Set<String> = ["the", "and", "payment", "from", "for", "pos", "debit", "card", "purchase", "online", "ach", "zelle", "venmo", "paypal", "inc", "llc"]
        return description.lowercased()
            .split { !$0.isLetter && $0 != "&" }
            .map(String.init)
            .first { $0.count >= 3 && !skip.contains($0) }
    }

    private static let defaults: [(String, MoneyCategory)] = [
        ("adobe", .software), ("frame.io", .software), ("frameio", .software), ("google", .software), ("notion", .software),
        ("squarespace", .marketing), ("showit", .marketing), ("wix", .marketing), ("instagram", .marketing),
        ("dropbox", .storage), ("backblaze", .storage), ("samsung", .storage), ("sandisk", .storage),
        ("insurance", .insurance), ("hiscox", .insurance), ("next insurance", .insurance),
        ("shell", .travel), ("chevron", .travel), ("exxon", .travel), ("conoco", .travel), ("united", .travel), ("southwest", .travel), ("hotel", .travel), ("airbnb", .travel),
        ("lensrentals", .rentals), ("borrowlenses", .rentals),
        ("artlist", .music), ("musicbed", .music), ("epidemic", .music),
        ("b&h", .gear), ("adorama", .gear),
        ("payment thank you", .transfer), ("transfer", .transfer), ("autopay", .transfer),
        ("paypal fee", .fees), ("stripe fee", .fees), ("fee", .fees),
        ("irs", .taxes), ("dept of revenue", .taxes),
    ]

    func categorize(_ description: String, amount: Double) -> MoneyCategory {
        let d = description.lowercased()
        if let key = Self.ruleKey(description), let rule = data.rules.first(where: { $0.match == key }) { return rule.category }
        if let hit = Self.defaults.first(where: { d.contains($0.0) }) { return hit.1 }
        return .uncategorized
    }

    // MARK: - Import

    /// Reads a CSV statement (bank, card, Venmo or PayPal export). Skips anything already in
    /// the books. Returns (added, skipped as duplicates).
    func importCSV(_ url: URL, account: MoneyAccount, chargesArePositive: Bool = false) throws -> (Int, Int) {
        let text = try String(contentsOf: url, encoding: .utf8)
        let rows = Self.parseCSV(text).filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard let headerIndex = rows.firstIndex(where: { row in row.contains { $0.lowercased().contains("date") } }) else {
            throw ImportError("Couldn't find a Date column in that file.")
        }
        let header = rows[headerIndex].map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        func col(_ names: [String]) -> Int? { header.firstIndex { h in names.contains { h.contains($0) } } }
        guard let dateCol = col(["date"]) else { throw ImportError("Couldn't find a Date column.") }
        let descCol = col(["description", "memo", "note", "name", "payee", "details", "merchant"])
        let amountCol = col(["amount (total)", "amount", "total", "net"])
        let debitCol = col(["debit", "withdrawal"]), creditCol = col(["credit", "deposit"])
        guard amountCol != nil || debitCol != nil || creditCol != nil else { throw ImportError("Couldn't find an Amount column.") }

        var added = 0, skipped = 0
        for row in rows[(headerIndex + 1)...] {
            func cell(_ i: Int?) -> String { guard let i, i < row.count else { return "" }; return row[i] }
            guard let date = Self.parseDate(cell(dateCol)) else { continue }
            var amount: Double?
            if let a = Self.parseAmount(cell(amountCol)) { amount = a }
            else {
                let debit = Self.parseAmount(cell(debitCol)) ?? 0, credit = Self.parseAmount(cell(creditCol)) ?? 0
                if debit != 0 || credit != 0 { amount = credit - abs(debit) }
            }
            guard var value = amount, value != 0 else { continue }
            // Some card exports list charges as positive numbers; flip them so charges are money out.
            if chargesArePositive { value = -value }
            let description = cell(descCol).isEmpty ? "Transaction" : cell(descCol)
            let duplicate = data.txns.contains {
                $0.account == account && abs($0.amount - value) < 0.005 && Calendar.current.isDate($0.date, inSameDayAs: date)
            }
            if duplicate { skipped += 1; continue }
            data.txns.append(Txn(date: date, amount: value, description: description, account: account,
                                 category: categorize(description, amount: value)))
            added += 1
        }
        if data.openingDate == nil { data.openingDate = data.txns.map(\.date).min() }
        save()
        return (added, skipped)
    }

    struct ImportError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n")).makeIterator()
        while let c = chars.next() {
            if quoted {
                if c == "\"" {
                    if let next = chars.next() {
                        if next == "\"" { field.append("\"") } else {
                            quoted = false
                            if next == "," { row.append(field); field = "" } else if next == "\n" { row.append(field); rows.append(row); row = []; field = "" } else { field.append(next) }
                        }
                    } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { row.append(field); field = "" }
            else if c == "\n" { row.append(field); rows.append(row); row = []; field = "" }
            else { field.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func parseDate(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        for format in ["MM/dd/yyyy", "M/d/yyyy", "M/d/yy", "yyyy-MM-dd", "yyyy-MM-dd'T'HH:mm:ss", "MMM d, yyyy", "dd MMM yyyy"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            if let d = f.date(from: String(t.prefix(format.count + 2)).trimmingCharacters(in: .whitespaces)) ?? f.date(from: t) { return d }
        }
        return ISO8601DateFormatter().date(from: t)
    }

    static func parseAmount(_ s: String) -> Double? {
        var t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let negative = t.hasPrefix("-") || t.hasPrefix("(") || t.hasPrefix("- ")
        t = t.filter { $0.isNumber || $0 == "." }
        guard let v = Double(t) else { return nil }
        return negative ? -v : v
    }

    // MARK: - Persistence

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let raw = try? Data(contentsOf: DealStore.url("money.json")) else { return }
        do { data = try decoder.decode(MoneyData.self, from: raw) }
        catch { NSLog("Lens: couldn't read money.json: \(error)") }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let raw = try? encoder.encode(data) { try? raw.write(to: DealStore.url("money.json"), options: .atomic) }
    }
}
