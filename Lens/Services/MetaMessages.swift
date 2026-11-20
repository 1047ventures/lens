import Foundation

/// Reads Emma's Instagram DMs and Facebook Page messages straight from Meta, so new inquiries there land
/// in Pipeline like email ones. Read only: Lens never sends, deletes or marks anything as read.
///
/// Meta only allows this for professional accounts, through a small private Meta app on Emma's own
/// account (set up once, see META-SETUP.md). Its two tokens live in the Keychain: an Instagram token
/// (good for 60 days, Lens renews it by itself) and a Facebook Page token.
enum MetaMessages {
    enum Site: String, CaseIterable {
        case instagram = "Instagram", facebook = "Facebook"

        var keychainKey: String { self == .instagram ? "meta.instagramToken" : "meta.pageToken" }
        var host: String { self == .instagram ? "https://graph.instagram.com/v27.0/" : "https://graph.facebook.com/v27.0/" }
        /// Where Emma reads and answers these messages.
        var inbox: String {
            self == .instagram ? "https://www.instagram.com/direct/inbox/" : "https://business.facebook.com/latest/inbox/all"
        }
    }

    struct Message {
        let fromName: String
        let handle: String       // Instagram username, when there is one
        let mine: Bool
        let text: String
        let date: Date
    }

    struct Conversation {
        let id: String
        let site: Site
        let updated: String      // changes whenever a new message arrives
        let messages: [Message]  // oldest first
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func token(_ site: Site) -> String? {
        let t = (Keychain.get(site.keychainKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func isConnected(_ site: Site) -> Bool { token(site) != nil }

    /// Checks a pasted token and saves it. Returns the account's name ("@emmapion" or the Page's name).
    static func connect(_ site: Site, token raw: String) async throws -> String {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw Failure(message: "Paste the token first.") }
        let name = try await accountName(site, token: token)
        Keychain.set(token, for: site.keychainKey)
        UserDefaults.standard.set(name, forKey: "meta.name.\(site.rawValue)")
        if site == .instagram { UserDefaults.standard.set(Date(), forKey: "meta.instagramRenewed") }
        return name
    }

    static func disconnect(_ site: Site) {
        Keychain.delete(site.keychainKey)
        UserDefaults.standard.removeObject(forKey: "meta.name.\(site.rawValue)")
    }

    static func accountName(_ site: Site) -> String? { UserDefaults.standard.string(forKey: "meta.name.\(site.rawValue)") }

    private static func accountName(_ site: Site, token: String) async throws -> String {
        switch site {
        case .instagram:
            let json = try await get(site, "me", ["fields": "user_id,username"], token: token)
            let user = (json["username"] as? String) ?? ""
            return user.isEmpty ? "Instagram" : "@" + user
        case .facebook:
            let json = try await get(site, "me", ["fields": "id,name"], token: token)
            return (json["name"] as? String) ?? "Facebook Page"
        }
    }

    /// The newest conversations (up to 25) with their latest messages.
    static func conversations(_ site: Site) async throws -> [Conversation] {
        guard var token = token(site) else { return [] }
        if site == .instagram { token = await renewIfNeeded(token) }
        let me = try await get(site, "me", ["fields": site == .instagram ? "user_id,username" : "id,name"], token: token)
        let myIDs = Set([me["id"], me["user_id"]].compactMap { $0.map { "\($0)" } })
        var query = ["fields": "id,updated_time,messages.limit(10){id,created_time,from,to,message}", "limit": "25"]
        if site == .instagram { query["platform"] = "instagram" }
        let json = try await get(site, "me/conversations", query, token: token)
        var out: [Conversation] = []
        for c in json["data"] as? [[String: Any]] ?? [] {
            guard let id = c["id"] as? String else { continue }
            var messages: [Message] = []
            for m in (c["messages"] as? [String: Any])?["data"] as? [[String: Any]] ?? [] {
                var item = m
                // Some answers leave out the text; ask for that one message on its own.
                if item["message"] == nil, let mid = m["id"] as? String,
                   let full = try? await get(site, mid, ["fields": "id,created_time,from,to,message"], token: token) {
                    item = full
                }
                let from = item["from"] as? [String: Any] ?? [:]
                let fromID = from["id"].map { "\($0)" } ?? ""
                let handle = (from["username"] as? String) ?? ""
                let name = (from["name"] as? String) ?? handle
                let text = ((item["message"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                messages.append(Message(fromName: name, handle: handle, mine: myIDs.contains(fromID),
                                        text: text, date: date(item["created_time"]) ?? Date()))
            }
            guard !messages.isEmpty else { continue }
            let updated = c["updated_time"].map { "\($0)" } ?? "\(messages.map(\.date).max()?.timeIntervalSince1970 ?? 0)"
            out.append(Conversation(id: id, site: site, updated: updated, messages: messages.sorted { $0.date < $1.date }))
        }
        return out
    }

    /// Instagram tokens last 60 days. Renew it every week so it never runs out.
    private static func renewIfNeeded(_ token: String) async -> String {
        let last = UserDefaults.standard.object(forKey: "meta.instagramRenewed") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 7 * 86400 else { return token }
        guard var c = URLComponents(string: "https://graph.instagram.com/refresh_access_token") else { return token }
        c.queryItems = [URLQueryItem(name: "grant_type", value: "ig_refresh_token"), URLQueryItem(name: "access_token", value: token)]
        guard let url = c.url, let result = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
              let fresh = json["access_token"] as? String, !fresh.isEmpty else { return token }
        Keychain.set(fresh, for: Site.instagram.keychainKey)
        UserDefaults.standard.set(Date(), forKey: "meta.instagramRenewed")
        return fresh
    }

    private static func get(_ site: Site, _ path: String, _ query: [String: String], token: String) async throws -> [String: Any] {
        guard var c = URLComponents(string: site.host + path) else { throw Failure(message: "Lens couldn't reach \(site.rawValue).") }
        c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } + [URLQueryItem(name: "access_token", value: token)]
        guard let url = c.url else { throw Failure(message: "Lens couldn't reach \(site.rawValue).") }
        let data: Data
        do { (data, _) = try await URLSession.shared.data(from: url) } catch {
            throw Failure(message: "Lens couldn't reach \(site.rawValue) just now. It tries again within the hour.")
        }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if let error = json["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? 0
            if code == 190 {
                throw Failure(message: "\(site.rawValue) needs a new token. Make one in your Meta app and paste it here again.")
            }
            if code == 10 || code == 200 || code == 3 {
                throw Failure(message: "\(site.rawValue) isn't letting Lens read messages yet. Check the message permission in your Meta app.")
            }
            throw Failure(message: "\(site.rawValue) said: \((error["message"] as? String) ?? "something went wrong").")
        }
        return json
    }

    private static func date(_ value: Any?) -> Date? {
        if let n = value as? Double { return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }
        if let n = value as? Int { return Date(timeIntervalSince1970: Double(n)) }
        guard let s = value as? String else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd'T'HH:mm:ss.SSSZ"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}
