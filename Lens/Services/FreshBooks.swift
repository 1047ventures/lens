import Foundation
import AppKit

/// Reads Emma's FreshBooks invoices and estimates (read only). Invoices become money owed in Money (marked
/// paid when FreshBooks says so) and show on the matching project; estimates go into Past quotes.
///
/// FreshBooks only sends people back to secure web addresses, which a Mac app doesn't have, so connecting
/// is: paste the app's two keys once, click Connect, press Allow in FreshBooks, then copy the address of
/// the page that doesn't load and paste it into Lens. Keys and the sign-in live in the Keychain.
@MainActor
final class FreshBooksSync: ObservableObject {
    @Published private(set) var problem: String?
    @Published private(set) var lastSync: Date?
    @Published private(set) var busy = false
    @Published private(set) var report: String?

    static let redirect = "https://localhost:8765/freshbooks"
    private static let idKey = "freshbooks.clientID", secretKey = "freshbooks.clientSecret", refreshKey = "freshbooks.refreshToken"

    private var accessToken: String?
    private var accessExpires = Date.distantPast
    private var loop: Task<Void, Never>?
    private weak var money: MoneyStore?
    private weak var quotes: QuoteStore?
    private weak var projects: ProjectStore?

    var hasKeys: Bool { !(Keychain.get(Self.idKey) ?? "").isEmpty && !(Keychain.get(Self.secretKey) ?? "").isEmpty }
    var isConnected: Bool { !(Keychain.get(Self.refreshKey) ?? "").isEmpty && accountID != nil }
    var accountID: String? { UserDefaults.standard.string(forKey: "freshbooks.accountID") }
    var businessName: String? { UserDefaults.standard.string(forKey: "freshbooks.business") }

    func attach(money: MoneyStore, quotes: QuoteStore, projects: ProjectStore) {
        self.money = money
        self.quotes = quotes
        self.projects = projects
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                if self?.isConnected == true { await self?.sync() }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func saveKeys(id: String, secret: String) {
        Keychain.set(id.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.idKey)
        Keychain.set(secret.trimmingCharacters(in: .whitespacesAndNewlines), for: Self.secretKey)
        problem = nil
        objectWillChange.send()
    }

    /// Opens FreshBooks' Allow page in the browser.
    func openAllowPage() {
        guard let id = Keychain.get(Self.idKey) else { return }
        var c = URLComponents(string: "https://auth.freshbooks.com/oauth/authorize/")!
        c.queryItems = [URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "client_id", value: id),
                        URLQueryItem(name: "redirect_uri", value: Self.redirect)]
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    /// Emma pasted the address of the page FreshBooks sent her to (or just the code in it).
    func finish(pasted: String) async {
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        var code = text
        if let c = URLComponents(string: text), let found = c.queryItems?.first(where: { $0.name == "code" })?.value { code = found }
        code = code.replacingOccurrences(of: "#_", with: "")
        guard !code.isEmpty else { problem = "Paste the whole address from the top of the browser."; return }
        busy = true
        defer { busy = false }
        do {
            try await token(["grant_type": "authorization_code", "code": code])
            let me = try await call("https://api.freshbooks.com/auth/api/v1/users/me")
            let memberships = ((me["response"] as? [String: Any])?["business_memberships"] as? [[String: Any]]) ?? []
            guard let business = memberships.compactMap({ $0["business"] as? [String: Any] }).first(where: { $0["account_id"] != nil }),
                  let account = business["account_id"] as? String else {
                throw Failure("FreshBooks didn't say which business to read. Make sure you signed in as the owner.")
            }
            UserDefaults.standard.set(account, forKey: "freshbooks.accountID")
            UserDefaults.standard.set((business["name"] as? String) ?? "FreshBooks", forKey: "freshbooks.business")
            problem = nil
            objectWillChange.send()
            await sync()
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "That didn't work. Click Connect FreshBooks and try again."
        }
    }

    func disconnect() {
        Keychain.delete(Self.refreshKey)
        UserDefaults.standard.removeObject(forKey: "freshbooks.accountID")
        UserDefaults.standard.removeObject(forKey: "freshbooks.business")
        accessToken = nil
        report = nil
        objectWillChange.send()
    }

    // MARK: Reading invoices and estimates

    func sync() async {
        guard let account = accountID, let money else { return }
        busy = true
        defer { busy = false }
        do {
            let invoices = try await list("https://api.freshbooks.com/accounting/account/\(account)/invoices/invoices", key: "invoices")
            var map = UserDefaults.standard.dictionary(forKey: "freshbooks.invoiceMap") as? [String: String] ?? [:]
            var owed = 0.0, open = 0
            for inv in invoices {
                let status = ((inv["v3_status"] as? String) ?? "").lowercased()
                guard status != "draft", (inv["vis_state"] as? Int ?? 0) == 0, let id = inv["invoiceid"].map({ "\($0)" }) else { continue }
                let total = Self.money(inv["amount"])
                let outstanding = Self.money(inv["outstanding"])
                let paid = status == "paid" || (total > 0 && outstanding <= 0.005)
                let paidOn = Self.day(inv["date_paid"]) ?? Date()
                if let rid = map[id].flatMap(UUID.init(uuidString:)), let r = money.receivables.first(where: { $0.id == rid }) {
                    if paid && r.paidOn == nil { money.markPaid(r, on: paidOn) }
                } else if total > 0 {
                    let client = Self.client(inv)
                    let number = (inv["invoice_number"] as? String) ?? id
                    let receivable = Receivable(projectID: projects?.projects.first(where: { $0.stage != .archived && $0.matches(client) })?.id,
                                                client: client, label: "FreshBooks invoice \(number)", amount: total,
                                                due: Self.day(inv["due_date"]) ?? Self.day(inv["create_date"]) ?? Date(),
                                                paidOn: paid ? paidOn : nil)
                    money.addReceivable(receivable)
                    map[id] = receivable.id.uuidString
                }
                if !paid { owed += outstanding > 0 ? outstanding : total; open += 1 }
            }
            UserDefaults.standard.set(map, forKey: "freshbooks.invoiceMap")

            var estimateCount = 0
            if let quotes {
                let estimates = (try? await list("https://api.freshbooks.com/accounting/account/\(account)/estimates/estimates", key: "estimates")) ?? []
                for est in estimates {
                    guard (est["vis_state"] as? Int ?? 0) == 0, let id = est["estimateid"].map({ "\($0)" }) else { continue }
                    let location = "freshbooks:estimate:\(id)"
                    let state = ((est["ui_status"] as? String) ?? (est["display_status"] as? String) ?? "").lowercased()
                    let status = state.contains("accept") || state.contains("invoiced") ? "Accepted"
                        : state.contains("declin") ? "Declined" : state == "draft" ? "" : "Sent"
                    if var existing = quotes.quotes.first(where: { $0.location == location }) {
                        if existing.status != status && !status.isEmpty { existing.status = status; quotes.update(existing) }
                        continue
                    }
                    guard state != "draft" else { continue }
                    var q = Quote(date: Self.day(est["create_date"]) ?? Date(), client: Self.client(est),
                                  title: "Estimate " + ((est["estimate_number"] as? String) ?? id))
                    let total = Self.money(est["amount"])
                    q.amount = total > 0 ? total : nil
                    q.status = status
                    q.source = "FreshBooks"
                    q.location = location
                    q.notes = (est["notes"] as? String) ?? ""
                    q.projectID = projects?.projects.first(where: { $0.matches(q.client) })?.id
                    quotes.add(q)
                    estimateCount += 1
                }
            }
            report = open == 0 ? "\(invoices.count) invoices read, nothing owed"
                               : "\(open) unpaid invoice\(open == 1 ? "" : "s"), \(Money.string(owed)) owed"
            lastSync = Date()
            problem = nil
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "Lens couldn't read FreshBooks just now. It tries again within the hour."
        }
    }

    /// Every page of a FreshBooks list (up to 1,000 items).
    private func list(_ base: String, key: String) async throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        var page = 1
        while page <= 10 {
            let json = try await call(base + "?per_page=100&page=\(page)")
            let result = ((json["response"] as? [String: Any])?["result"] as? [String: Any]) ?? [:]
            let items = result[key] as? [[String: Any]] ?? []
            out += items
            let pages = (result["pages"] as? Int) ?? 1
            if items.isEmpty || page >= pages { break }
            page += 1
        }
        return out
    }

    private static func client(_ item: [String: Any]) -> String {
        let org = ((item["current_organization"] as? String) ?? (item["organization"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        if !org.isEmpty { return org }
        return [(item["fname"] as? String) ?? "", (item["lname"] as? String) ?? ""].joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func money(_ value: Any?) -> Double {
        if let d = value as? [String: Any] { return Double("\(d["amount"] ?? "0")") ?? 0 }
        return Double("\(value ?? "0")") ?? 0
    }

    private static func day(_ value: Any?) -> Date? {
        guard let s = value as? String, s.count >= 10 else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: String(s.prefix(10)))
    }

    // MARK: Signing in

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private func token(_ fields: [String: String]) async throws {
        guard let id = Keychain.get(Self.idKey), let secret = Keychain.get(Self.secretKey) else {
            throw Failure("Paste your FreshBooks app's Client ID and Client Secret first.")
        }
        var body = fields
        body["client_id"] = id
        body["client_secret"] = secret
        body["redirect_uri"] = Self.redirect
        var request = URLRequest(url: URL(string: "https://api.freshbooks.com/auth/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200, let access = json["access_token"] as? String else {
            if fields["grant_type"] == "refresh_token" {
                Keychain.delete(Self.refreshKey)
                throw Failure("FreshBooks signed Lens out. Click Connect FreshBooks again.")
            }
            throw Failure("FreshBooks didn't accept that. Click Connect FreshBooks, press Allow, and paste the new address straight away.")
        }
        accessToken = access
        accessExpires = Date().addingTimeInterval(((json["expires_in"] as? Double) ?? 3600) - 120)
        // Each refresh key works once; always keep the newest.
        if let refresh = json["refresh_token"] as? String { Keychain.set(refresh, for: Self.refreshKey) }
    }

    private func call(_ url: String) async throws -> [String: Any] {
        if accessToken == nil || Date() > accessExpires {
            guard let refresh = Keychain.get(Self.refreshKey) else { throw Failure("Connect FreshBooks first.") }
            try await token(["grant_type": "refresh_token", "refresh_token": refresh])
        }
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer \(accessToken ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { accessToken = nil; throw Failure("FreshBooks needs Lens to sign in again. Click Connect FreshBooks.") }
        guard (200..<300).contains(status) else { throw Failure("FreshBooks didn't answer just now. Lens tries again within the hour.") }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
