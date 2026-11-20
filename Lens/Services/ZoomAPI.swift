import Foundation
import AppKit
import CryptoKit

// MARK: - Zoom sign-in

/// Zoom's own sign-in, the same way as Google: Lens opens Zoom's page in the browser, the user signs in
/// there and presses Allow, and Zoom hands back a code on a one-time local address. Lens never sees
/// her password. The Zoom app Lens uses only has read permissions (see ZOOM-SETUP.md).
enum ZoomAuth {
    /// The address registered on the Zoom app. Zoom ignores the port for 127.0.0.1, but Lens
    /// tries this exact port first anyway.
    static let redirectPort: UInt16 = 8765
    static let redirectPath = "/zoom"

    struct Failure: LocalizedError {
        let message: String
        var code: String? = nil
        var errorDescription: String? { message }
    }

    /// One plain sentence plus the one thing to try.
    static func explain(code: String) -> Failure {
        switch code {
        case "access_denied":
            return Failure(message: "Zoom didn't let Lens in. Click Connect Zoom and press Allow.", code: code)
        case "invalid_client", "unauthorized_client":
            return Failure(message: "Lens's Zoom setup isn't working. Ask Claude to set up Zoom for Lens again.", code: code)
        case "redirect_uri_mismatch", "invalid_request", "state_mismatch":
            return Failure(message: "Zoom's reply didn't make it back to Lens. Click Connect Zoom and try once more.", code: code)
        case "timeout":
            return Failure(message: "Lens stopped waiting for Zoom. Click Connect Zoom and finish signing in within a few minutes.", code: code)
        case "invalid_grant", "not_connected":
            return Failure(message: "Your Zoom sign-in has expired. Click Connect Zoom to connect again.", code: code)
        case "missing_scope":
            return Failure(message: "Zoom isn't letting Lens read your summaries yet. Ask Claude to check the Zoom setup for Lens.", code: code)
        case "rate_limited":
            return Failure(message: "Zoom asked Lens to slow down. Lens will carry on by itself in a little while.", code: code)
        case "network":
            return Failure(message: "Lens couldn't reach Zoom. Check your internet connection, then try again.", code: code)
        default:
            return Failure(message: "Zoom didn't answer the way Lens expected. Try again, or tap Get help.", code: code)
        }
    }

    static func explain(_ error: Error) -> Failure {
        if let failure = error as? Failure { return failure }
        if let google = error as? GoogleAuth.Failure, google.code == "timeout" { return explain(code: "timeout") }
        if error is URLError { return explain(code: "network") }
        return explain(code: "unknown")
    }

    struct Tokens {
        let access: String
        let refresh: String
        let expires: Date
        let scope: String
    }

    static func signIn(clientID: String, clientSecret: String) async throws -> Tokens {
        let verifier = randomString(64)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = randomString(24)

        let receiver: LoopbackReceiver
        do {
            receiver = try await LoopbackReceiver.start(port: redirectPort, timeout: explain(code: "timeout"))
        } catch { throw explain(code: "redirect_uri_mismatch") }
        let redirect = "http://127.0.0.1:\(receiver.port)\(redirectPath)"
        var components = URLComponents(string: "https://zoom.us/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components.url else { throw explain(code: "unknown") }
        _ = await MainActor.run { NSWorkspace.shared.open(url) }

        let query = try await receiver.waitForRedirect()
        if let error = query["error"] { throw explain(code: error) }
        guard query["state"] == state, let code = query["code"] else { throw explain(code: "state_mismatch") }

        return try await token([
            "grant_type": "authorization_code", "code": code,
            "redirect_uri": redirect, "code_verifier": verifier,
        ], clientID: clientID, clientSecret: clientSecret)
    }

    /// A fresh access token. Zoom hands out a new refresh token every time, so the caller must save it.
    static func refresh(_ refreshToken: String, clientID: String, clientSecret: String) async throws -> Tokens {
        try await token(["grant_type": "refresh_token", "refresh_token": refreshToken],
                        clientID: clientID, clientSecret: clientSecret)
    }

    private static func token(_ fields: [String: String], clientID: String, clientSecret: String) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://zoom.us/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic " + Data("\(clientID):\(clientSecret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.httpBody = formBody(fields)
        let data: Data
        do { (data, _) = try await URLSession.shared.data(for: request) } catch { throw explain(error) }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else {
            throw explain(code: (json["error"] as? String) ?? "unknown")
        }
        let lifetime = (json["expires_in"] as? Double) ?? 3000
        return Tokens(access: access, refresh: refresh, expires: Date().addingTimeInterval(lifetime),
                      scope: (json["scope"] as? String) ?? "")
    }

    /// Tells Zoom to forget Lens's access. Best effort: the local tokens are removed either way.
    static func revoke(_ token: String, clientID: String, clientSecret: String) async {
        var request = URLRequest(url: URL(string: "https://zoom.us/oauth/revoke")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic " + Data("\(clientID):\(clientSecret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.httpBody = formBody(["token": token])
        _ = try? await URLSession.shared.data(for: request)
    }

    private static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8) ?? Data()
    }

    private static func randomString(_ length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Finds the small Zoom file Claude puts in Downloads while setting Zoom up (the Zoom app's
/// Client ID and Client Secret), keeps both in the Keychain, and trashes the file.
enum ZoomClientFile {
    @discardableResult
    static func importIfNeeded() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = [home.appendingPathComponent("Downloads"), home.appendingPathComponent("Library/Application Support/Lens")]
        for folder in folders {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            for name in names where name.lowercased().hasSuffix(".json")
                && (name.hasPrefix("lens_zoom") || name.hasPrefix("zoom_client")) {
                let url = folder.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let block = (json["installed"] as? [String: Any]) ?? json
                guard let id = (block["client_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
                      let secret = (block["client_secret"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty
                else { continue }
                Keychain.set(id, for: "zoom.clientID")
                Keychain.set(secret, for: "zoom.clientSecret")
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                return true
            }
        }
        return false
    }
}

// MARK: - Zoom API (read only)

/// Reads the user's Zoom AI Companion meeting summaries. Nothing here changes anything in Zoom.
enum ZoomAPI {
    /// One meeting that has a summary (or might have one).
    struct Ref {
        let uuid: String
        let meetingID: String
        let topic: String
        let start: Date?
    }

    struct Summary {
        let title: String
        let date: Date
        let overview: String
        let sections: [MeetingNoteSection]
        let nextSteps: [String]
        let link: String?
        let hostEmail: String?
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        if let d = iso.date(from: text) { return d }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return frac.date(from: text)
    }

    /// Meeting uuids can contain "/" and "="; Zoom wants them encoded, and encoded twice when
    /// they start with "/" or contain "//".
    static func encodeUUID(_ uuid: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let once = uuid.addingPercentEncoding(withAllowedCharacters: allowed) ?? uuid
        if uuid.hasPrefix("/") || uuid.contains("//") {
            return once.addingPercentEncoding(withAllowedCharacters: allowed) ?? once
        }
        return once
    }

    /// GET a Zoom API path. Returns nil when Zoom has nothing there (no summary for that meeting).
    private static func get(_ path: String, query: [URLQueryItem] = [], token: String) async throws -> [String: Any]? {
        var text = "https://api.zoom.us/v2/" + path
        if !query.isEmpty {
            var c = URLComponents()
            c.queryItems = query
            text += "?" + (c.percentEncodedQuery ?? "")
        }
        guard let url = URL(string: text) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) } catch { throw ZoomAuth.explain(error) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let code = json["code"] as? Int
        if status == 429 { throw ZoomAuth.explain(code: "rate_limited") }
        if status == 401 { throw ZoomAuth.explain(code: code == 4711 ? "missing_scope" : "invalid_grant") }
        if code == 4711 || code == 4700 || status == 403 { throw ZoomAuth.explain(code: "missing_scope") }
        if status == 404 || code == 3001 || code == 3322 || code == 1001 { return nil }
        guard (200..<300).contains(status) else {
            // Some meetings simply have no summary (for example, AI Companion was off that day).
            if status == 400 { return nil }
            throw ZoomAuth.explain(code: "unknown")
        }
        return json
    }

    /// Who is signed in.
    static func me(token: String) async throws -> (email: String, name: String) {
        let json = try await get("users/me", token: token) ?? [:]
        let name = [(json["first_name"] as? String) ?? "", (json["last_name"] as? String) ?? ""]
            .joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return ((json["email"] as? String) ?? "", name.isEmpty ? ((json["display_name"] as? String) ?? "") : name)
    }

    private static func utc(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: date)
    }

    /// Every AI Companion summary in her Zoom account between two dates (one page).
    static func summaries(from: Date, to: Date, pageToken: String?, token: String) async throws -> (refs: [Ref], next: String?) {
        var query = [URLQueryItem(name: "page_size", value: "300"),
                     URLQueryItem(name: "from", value: utc(from)),
                     URLQueryItem(name: "to", value: utc(to))]
        if let pageToken, !pageToken.isEmpty { query.append(URLQueryItem(name: "next_page_token", value: pageToken)) }
        let json = try await get("meetings/meeting_summaries", query: query, token: token) ?? [:]
        let refs: [Ref] = (json["summaries"] as? [[String: Any]] ?? []).compactMap { item in
            guard let uuid = item["meeting_uuid"] as? String else { return nil }
            return Ref(uuid: uuid, meetingID: "\(item["meeting_id"] ?? "")",
                       topic: (item["meeting_topic"] as? String) ?? "",
                       start: date(item["meeting_start_time"]) ?? date(item["summary_start_time"]))
        }
        let next = json["next_page_token"] as? String
        return (refs, (next?.isEmpty ?? true) ? nil : next)
    }

    /// Her past meetings (one page). Used when the Zoom app can only see her own meetings.
    static func pastMeetings(pageToken: String?, token: String) async throws -> (refs: [Ref], next: String?) {
        var query = [URLQueryItem(name: "type", value: "previous_meetings"), URLQueryItem(name: "page_size", value: "300")]
        if let pageToken, !pageToken.isEmpty { query.append(URLQueryItem(name: "next_page_token", value: pageToken)) }
        let json = try await get("users/me/meetings", query: query, token: token) ?? [:]
        let refs: [Ref] = (json["meetings"] as? [[String: Any]] ?? []).compactMap { item in
            let id = "\(item["id"] ?? "")"
            let uuid = (item["uuid"] as? String) ?? id
            guard !uuid.isEmpty else { return nil }
            return Ref(uuid: uuid, meetingID: id, topic: (item["topic"] as? String) ?? "", start: date(item["start_time"]))
        }
        let next = json["next_page_token"] as? String
        return (refs, (next?.isEmpty ?? true) ? nil : next)
    }

    /// The full AI Companion summary of one meeting, or nil if it doesn't have one.
    static func summary(_ ref: Ref, token: String) async throws -> Summary? {
        guard let json = try await get("meetings/\(encodeUUID(ref.uuid))/meeting_summary", token: token) else { return nil }
        // the user's own edits win over what the AI wrote.
        let edited = json["edited_summary"] as? [String: Any] ?? [:]
        func text(_ key: String) -> String {
            let e = (edited[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return e.isEmpty ? ((json[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") : e
        }
        func details(_ block: [String: Any]) -> [MeetingNoteSection] {
            (block["summary_details"] as? [[String: Any]] ?? []).compactMap { d in
                let body = ((d["summary"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { return nil }
                return MeetingNoteSection(title: ((d["label"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines), text: body)
            }
        }
        func steps(_ block: [String: Any]) -> [String] {
            (block["next_steps"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }

        var overview = text("summary_overview")
        var sections = details(edited).isEmpty ? details(json) : details(edited)
        var nextSteps = steps(edited).isEmpty ? steps(json) : steps(edited)

        // Newer summaries put everything in one Markdown text instead.
        let content = ((json["summary_content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty {
            let parsed = parseMarkdown(content)
            if overview.isEmpty { overview = parsed.overview }
            if sections.isEmpty { sections = parsed.sections }
            if nextSteps.isEmpty { nextSteps = parsed.nextSteps }
        }
        guard !overview.isEmpty || !sections.isEmpty || !nextSteps.isEmpty else { return nil }

        let title = [(json["meeting_topic"] as? String), (json["summary_title"] as? String), ref.topic]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "Zoom call"
        let when = date(json["meeting_start_time"]) ?? date(json["summary_start_time"]) ?? ref.start ?? Date()
        return Summary(title: title, date: when, overview: overview, sections: sections, nextSteps: nextSteps,
                       link: json["summary_doc_url"] as? String, hostEmail: json["meeting_host_email"] as? String)
    }

    /// Who was in a meeting (best effort: Zoom only shows emails for people who were signed in).
    static func people(_ ref: Ref, token: String) async -> [MeetingPerson] {
        guard let json = try? await get("past_meetings/\(encodeUUID(ref.uuid))/participants",
                                        query: [URLQueryItem(name: "page_size", value: "300")], token: token) else { return [] }
        var seen = Set<String>()
        return (json["participants"] as? [[String: Any]] ?? []).compactMap { p in
            let name = ((p["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let email = ((p["user_email"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let key = email.isEmpty ? name.lowercased() : email
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return MeetingPerson(name: name.isEmpty ? email : name, email: email)
        }
    }

    // MARK: Cloud recordings

    /// One call recorded to her Zoom cloud: Zoom's transcript file when there is one, and the audio.
    struct CloudRecording: Sendable {
        let uuid: String
        let topic: String
        let start: Date
        let transcriptURL: String?
        /// The audio-only file, or the video when there's no audio-only one.
        let audioURL: String?
        let audioExtension: String
        let shareURL: String?
    }

    private static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Her cloud recordings between two dates (one page; Zoom allows up to a month at a time).
    static func recordings(from: Date, to: Date, pageToken: String?, token: String) async throws -> (items: [CloudRecording], next: String?) {
        var query = [URLQueryItem(name: "page_size", value: "300"),
                     URLQueryItem(name: "from", value: day(from)),
                     URLQueryItem(name: "to", value: day(to))]
        if let pageToken, !pageToken.isEmpty { query.append(URLQueryItem(name: "next_page_token", value: pageToken)) }
        let json = try await get("users/me/recordings", query: query, token: token) ?? [:]
        let items: [CloudRecording] = (json["meetings"] as? [[String: Any]] ?? []).compactMap { m in
            guard let uuid = m["uuid"] as? String else { return nil }
            let files = (m["recording_files"] as? [[String: Any]] ?? []).filter { ($0["status"] as? String ?? "completed") == "completed" }
            func file(_ type: String) -> [String: Any]? { files.first { ($0["file_type"] as? String)?.uppercased() == type } }
            let transcript = file("TRANSCRIPT")
            let audio = file("M4A") ?? file("MP4")
            guard transcript != nil || audio != nil else { return nil }
            return CloudRecording(uuid: uuid, topic: (m["topic"] as? String) ?? "Zoom call",
                                  start: date(m["start_time"]) ?? Date(),
                                  transcriptURL: transcript?["download_url"] as? String,
                                  audioURL: audio?["download_url"] as? String,
                                  audioExtension: ((audio?["file_extension"] as? String) ?? (audio?["file_type"] as? String) ?? "m4a").lowercased(),
                                  shareURL: m["share_url"] as? String)
        }
        let next = json["next_page_token"] as? String
        return (items, (next?.isEmpty ?? true) ? nil : next)
    }

    /// Downloads one recording file from her Zoom cloud to a file on this Mac.
    static func download(_ link: String, to file: URL, token: String) async throws {
        guard var c = URLComponents(string: link) else { throw ZoomAuth.explain(code: "unknown") }
        // Zoom accepts the sign-in on the address too, which survives its redirect to the file.
        c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "access_token", value: token)]
        guard let url = c.url else { throw ZoomAuth.explain(code: "unknown") }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 600
        let temp: URL, response: URLResponse
        do { (temp, response) = try await URLSession.shared.download(for: request) } catch { throw ZoomAuth.explain(error) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 { throw ZoomAuth.explain(code: "rate_limited") }
        if status == 401 || status == 403 { throw ZoomAuth.explain(code: "missing_scope") }
        guard (200..<300).contains(status) else { throw ZoomAuth.explain(code: "unknown") }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: temp, to: file)
    }

    /// Zoom's transcript file (WebVTT) as plain lines: "[03:12] Sarah Lee: we could shoot on the quad".
    static func transcriptText(_ vtt: String) -> String {
        var out: [String] = []
        var stamp: String?
        for raw in vtt.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == "WEBVTT" || Int(line) != nil { continue }
            if line.contains("-->") {
                let start = line.components(separatedBy: "-->").first?.trimmingCharacters(in: .whitespaces) ?? ""
                let parts = start.split(separator: ":").map(String.init)
                if parts.count == 3, let h = Int(parts[0]), let m = Int(parts[1]) {
                    let sec = Int(Double(parts[2]) ?? 0)
                    stamp = h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
                }
                continue
            }
            out.append(stamp.map { "[\($0)] " + line } ?? line)
            stamp = nil
        }
        return out.joined(separator: "\n")
    }

    /// Splits a Markdown summary into the opening overview, titled sections, and next steps.
    static func parseMarkdown(_ text: String) -> (overview: String, sections: [MeetingNoteSection], nextSteps: [String]) {
        var overview: [String] = []
        var sections: [MeetingNoteSection] = []
        var nextSteps: [String] = []
        var current: (title: String, lines: [String])?

        func heading(_ line: String) -> String? {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") { return t.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces) }
            if t.hasPrefix("**"), t.hasSuffix("**"), t.count > 4, !t.dropFirst(2).dropLast(2).contains("**") {
                return String(t.dropFirst(2).dropLast(2)).trimmingCharacters(in: CharacterSet(charactersIn: " :"))
            }
            return nil
        }
        func flush() {
            guard let c = current else { return }
            let body = c.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if c.title.lowercased().contains("next step") || c.title.lowercased().contains("action item") {
                nextSteps += c.lines.map { $0.trimmingCharacters(in: .whitespaces) }
                    .map { $0.replacingOccurrences(of: "^([-*•]|\\d+[.)])\\s*", with: "", options: .regularExpression) }
                    .filter { !$0.isEmpty }
            } else if c.title.lowercased().contains("overview") || c.title.lowercased().contains("quick recap") {
                if !body.isEmpty { overview.append(body) }
            } else if !body.isEmpty {
                sections.append(MeetingNoteSection(title: c.title, text: body))
            }
        }
        for line in text.components(separatedBy: .newlines) {
            if let h = heading(line) {
                flush()
                current = (h, [])
            } else if current != nil {
                current?.lines.append(line)
            } else {
                overview.append(line)
            }
        }
        flush()
        return (overview.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), sections, nextSteps)
    }
}
