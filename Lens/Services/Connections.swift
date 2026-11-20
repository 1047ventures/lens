import Foundation
import AppKit
import EventKit
import Network
import CryptoKit

// MARK: - Keychain

/// Secrets (Google sign-in tokens, the OAuth client) live in the Mac's Keychain, never in Lens's JSON files.
enum Keychain {
    private static let service = "Lens"
    /// Each saved key is read from the Mac's password store once per launch, then remembered,
    /// so the Mac asks at most once (and never again after "Always Allow").
    private static var cache: [String: String?] = [:]
    private static let lock = NSLock()

    static func set(_ value: String, for key: String) {
        delete(key)
        lock.lock(); cache[key] = value; lock.unlock()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let value = read(key)
        cache[key] = value
        return value
    }

    private static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        lock.lock(); cache[key] = .some(nil); lock.unlock()
    }
}

// MARK: - Google sign-in

/// Google's sign-in for desktop apps: Lens opens Google's own page in the browser, the user signs in
/// there, and Google hands back a code on a one-time local address. Lens never sees her password.
enum GoogleAuth {
    /// Only what Lens uses: read mail (inquiries, Zoom summaries, payment notices), write drafts for
    /// her to send, create project folders, and read the intake form's answer sheet.
    static let scopes = [
        "openid", "email",
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.compose",
        "https://www.googleapis.com/auth/drive.file",
        "https://www.googleapis.com/auth/spreadsheets.readonly",
        "https://www.googleapis.com/auth/calendar.readonly",
    ]

    static let calendarScope = "https://www.googleapis.com/auth/calendar.readonly"

    /// `message` is already plain English for the user; `code` keeps Google's own wording for Get help.
    struct Failure: LocalizedError {
        let message: String
        var code: String? = nil
        var errorDescription: String? { message }
    }

    /// One plain sentence plus the one thing to try, for any error that can come out of Google sign-in.
    static func explain(code: String, description: String? = nil) -> Failure {
        // Google's "being tested" or "not verified" refusal: the saved setup belongs to an older Google project.
        if code == "access_denied", let text = description?.lowercased(),
           ["being tested", "testing", "test user", "verification"].contains(where: text.contains) {
            return Failure(message: "Google is still using an older setup. Download the Google file again into Downloads and click Sign in again.")
        }
        switch code {
        case "access_denied":
            return Failure(message: "Google didn't let Lens in. If Google said Lens is \"being tested\", Lens is still using an older Google setup: ask Claude to download the Google file again into Downloads, then click Sign in with Google. Otherwise, click Sign in with Google and press Allow on every screen.", code: code)
        case "invalid_client", "unauthorized_client", "deleted_client":
            return Failure(message: "Lens's Google setup isn't working. Ask Claude to set up Google for Lens again.", code: code)
        case "redirect_uri_mismatch", "invalid_request", "state_mismatch":
            return Failure(message: "Google's reply didn't make it back to Lens. Click Sign in with Google and try once more.", code: code)
        case "timeout":
            return Failure(message: "Lens stopped waiting for Google. Click Sign in with Google and finish signing in within a few minutes.", code: code)
        case "invalid_grant":
            return Failure(message: "Your Google sign-in has expired. Click Sign in with Google to connect again.", code: code)
        case "no_refresh_token":
            return Failure(message: "Google didn't give Lens lasting access. Remove Lens at myaccount.google.com/permissions, then sign in again.", code: code)
        case "network":
            return Failure(message: "Lens couldn't reach Google. Check your internet connection, then try again.", code: code)
        default:
            return Failure(message: "Google sign-in didn't work this time. Try again, or tap Get help.", code: code)
        }
    }

    static func explain(_ error: Error) -> Failure {
        if let failure = error as? Failure { return failure }
        if error is URLError { return explain(code: "network") }
        return explain(code: "unknown")
    }

    /// A short-lived access token for Google's APIs, made from the saved refresh token. Cached until it nearly expires.
    private static var cachedToken: (token: String, expires: Date)?

    static func accessToken(clientID: String, clientSecret: String, refreshToken: String) async throws -> String {
        if let cached = cachedToken, cached.expires > Date().addingTimeInterval(60) { return cached.token }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "client_id": clientID, "client_secret": clientSecret,
            "refresh_token": refreshToken, "grant_type": "refresh_token",
        ])
        let data: Data
        do { (data, _) = try await URLSession.shared.data(for: request) } catch { throw explain(error) }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let token = json["access_token"] as? String else {
            throw explain(code: (json["error"] as? String) ?? "unknown")
        }
        let lifetime = (json["expires_in"] as? Double) ?? 3000
        cachedToken = (token, Date().addingTimeInterval(lifetime))
        return token
    }

    static func clearCachedToken() { cachedToken = nil }

    static func signIn(clientID: String, clientSecret: String) async throws -> (email: String, refreshToken: String, scope: String) {
        let verifier = randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = randomString(24)

        let receiver: LoopbackReceiver
        do { receiver = try await LoopbackReceiver.start() } catch { throw explain(code: "redirect_uri_mismatch") }
        let redirect = "http://127.0.0.1:\(receiver.port)"
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        guard let url = components.url else { throw Failure(message: "Couldn't build the Google sign-in address.") }
        _ = await MainActor.run { NSWorkspace.shared.open(url) }

        let query = try await receiver.waitForRedirect()
        if let error = query["error"] { throw explain(code: error, description: query["error_description"]) }
        guard query["state"] == state, let code = query["code"] else { throw explain(code: "state_mismatch") }

        // Swap the one-time code for tokens
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "code": code, "client_id": clientID, "client_secret": clientSecret,
            "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier,
        ])
        let data: Data
        do { (data, _) = try await URLSession.shared.data(for: request) } catch { throw explain(error) }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let access = json["access_token"] as? String else {
            throw explain(code: (json["error"] as? String) ?? "unknown")
        }
        guard let refresh = json["refresh_token"] as? String else { throw explain(code: "no_refresh_token") }
        let granted = (json["scope"] as? String) ?? ""
        clearCachedToken()

        // Which account just signed in
        var who = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        who.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let info: Data
        do { (info, _) = try await URLSession.shared.data(for: who) } catch { throw explain(error) }
        let email = ((try? JSONSerialization.jsonObject(with: info) as? [String: Any])?["email"] as? String) ?? "Google account"
        return (email, refresh, granted)
    }

    /// Tells Google to forget Lens's access. Best effort: the local tokens are removed either way.
    static func revoke(_ token: String) async {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
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
        return Data(bytes).base64URL
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Reads the user's Google Calendar (read-only) through Google's Calendar API.
enum GoogleCalendarAPI {
    struct Calendar { let id: String; let name: String }

    private static func get(_ path: String, query: [URLQueryItem] = [], token: String) async throws -> [String: Any] {
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/" + path)!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data: Data
        do { (data, _) = try await URLSession.shared.data(for: request) } catch { throw GoogleAuth.explain(error) }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if json["error"] != nil { throw GoogleAuth.explain(code: "calendar_unavailable") }
        return json
    }

    static func calendars(token: String) async throws -> [Calendar] {
        let json = try await get("users/me/calendarList", query: [URLQueryItem(name: "minAccessRole", value: "reader")], token: token)
        let items = json["items"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let id = item["id"] as? String, (item["selected"] as? Bool) ?? true else { return nil }
            return Calendar(id: id, name: (item["summaryOverride"] as? String) ?? (item["summary"] as? String) ?? id)
        }
    }

    static func events(calendar: Calendar, from: Date, to: Date, token: String) async throws -> [LensCalendarEvent] {
        let iso = ISO8601DateFormatter()
        let json = try await get("calendars/\(calendar.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendar.id)/events", query: [
            URLQueryItem(name: "timeMin", value: iso.string(from: from)),
            URLQueryItem(name: "timeMax", value: iso.string(from: to)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "250"),
        ], token: token)
        let dayFormat = DateFormatter()
        dayFormat.dateFormat = "yyyy-MM-dd"
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        func parse(_ block: [String: Any]?) -> (Date, Bool)? {
            if let text = block?["dateTime"] as? String, let date = iso.date(from: text) { return (date, false) }
            if let text = block?["date"] as? String, let date = dayFormat.date(from: text) { return (date, true) }
            return nil
        }
        return (json["items"] as? [[String: Any]] ?? []).compactMap { item in
            guard (item["status"] as? String) != "cancelled",
                  let start = parse(item["start"] as? [String: Any]),
                  let end = parse(item["end"] as? [String: Any]) else { return nil }
            return LensCalendarEvent(id: (item["id"] as? String) ?? UUID().uuidString,
                                     title: (item["summary"] as? String) ?? "Busy",
                                     start: start.0, end: end.0, allDay: start.1, calendar: calendar.name,
                                     location: item["location"] as? String)
        }
    }
}

/// One calendar event, from Google or (as a fallback) the Mac's Calendar app.
struct LensCalendarEvent: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let calendar: String
    let location: String?
}

/// Finds the Google client file Claude downloads for Lens, keeps its two values in the Keychain, and trashes the file.
enum GoogleClientFile {
    @discardableResult
    static func importIfNeeded() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = [home.appendingPathComponent("Downloads"), home.appendingPathComponent("Library/Application Support/Lens")]
        for folder in folders {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
            for name in names where name.hasPrefix("client_secret_") && name.hasSuffix(".json") {
                let url = folder.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let block = json["installed"] as? [String: Any],
                      let id = (block["client_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty,
                      let secret = (block["client_secret"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !secret.isEmpty
                else { continue }
                Keychain.set(id, for: "google.clientID")
                Keychain.set(secret, for: "google.clientSecret")
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
                return true
            }
        }
        return false
    }
}

/// The Google client that ships inside Lens (added when GitHub builds it, never in the code),
/// so anyone can click Sign in with Google without setting anything up.
enum BuiltInGoogleClient {
    static let pair: (id: String, secret: String)? = {
        guard let data = NSDataAsset(name: "GoogleClient")?.data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let block = json["installed"] as? [String: Any],
              let id = block["client_id"] as? String, !id.isEmpty,
              let secret = block["client_secret"] as? String, !secret.isEmpty
        else { return nil }
        return (id, secret)
    }()
}

/// Listens once on 127.0.0.1 for Google's redirect after sign-in, then shuts down.
final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "lens.oauth.loopback")
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var pending: Result<[String: String], Error>?
    private(set) var port: UInt16 = 0

    private init(listener: NWListener) {
        self.listener = listener
    }

    /// `port` asks for a fixed port first (some services want the exact address they were given);
    /// if it's taken, any free port is used.
    static func start(port fixed: UInt16? = nil, timeout: Error = GoogleAuth.explain(code: "timeout")) async throws -> LoopbackReceiver {
        if let fixed, let nwPort = NWEndpoint.Port(rawValue: fixed),
           let receiver = try? await start(on: nwPort, timeout: timeout) {
            return receiver
        }
        return try await start(on: .any, timeout: timeout)
    }

    private static func start(on port: NWEndpoint.Port, timeout: Error) async throws -> LoopbackReceiver {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        let receiver = LoopbackReceiver(listener: try NWListener(using: params))
        receiver.listener.newConnectionHandler = { [weak receiver] connection in receiver?.handle(connection) }
        receiver.port = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            receiver.listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed { resumed = true; cont.resume(returning: receiver.listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if !resumed { resumed = true; cont.resume(throwing: error) }
                default: break
                }
            }
            receiver.listener.start(queue: receiver.queue)
        }
        // Give up after five minutes so a forgotten browser tab doesn't leave Lens waiting forever.
        receiver.queue.asyncAfter(deadline: .now() + 300) { [weak receiver] in
            receiver?.finish(.failure(timeout))
        }
        return receiver
    }

    func waitForRedirect() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let pending = self.pending {
                    self.pending = nil
                    cont.resume(with: pending)
                } else {
                    self.continuation = cont
                }
            }
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let items = URLComponents(string: "http://localhost" + path)?.queryItems ?? []
            let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            let isRedirect = query["code"] != nil || query["error"] != nil
            let page = isRedirect
                ? "<html><body style='font:16px -apple-system;background:#131211;color:#F1EDE7;display:grid;place-items:center;height:90vh'><div><h2>All set.</h2><p>You can close this tab and go back to Lens.</p></div></body></html>"
                : "Not found"
            let response = "HTTP/1.1 \(isRedirect ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
            if isRedirect { self.finish(.success(query)) }
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        queue.async {
            self.listener.cancel()
            if let cont = self.continuation {
                self.continuation = nil
                cont.resume(with: result)
            } else if self.pending == nil {
                self.pending = result
            }
        }
    }
}

// MARK: - Log-ins

enum LoginID: String, CaseIterable, Identifiable, Codable {
    case google, calendar, drive, zoom, website, social, directories, bank, paypal, venmo, claude, github, homeServer, freshbooks
    var id: String { rawValue }
}

enum LoginStatus {
    case connected(String), partial(String), todo(String), later(String)

    var label: String {
        switch self {
        case .connected: return "Connected"
        case .partial: return "Almost"
        case .todo: return "Not connected"
        case .later: return "Later"
        }
    }

    var detail: String {
        switch self {
        case .connected(let s), .partial(let s), .todo(let s), .later(let s): return s
        }
    }

    var isConnected: Bool { if case .connected = self { return true } else { return false } }
    var isLater: Bool { if case .later = self { return true } else { return false } }
}

/// What the user has connected, and the non-secret answers she gave along the way.
struct LoginState: Codable {
    var confirmed: [String: Bool] = [:]
    var fields: [String: String] = [:]
    var statementsFolder: String?
    var googleEmail: String?
    var googleConnectedAt: Date?
    /// Which permissions Google actually granted at the last sign-in (space separated).
    var googleScopes: String?
    /// The Zoom account Lens reads summaries from, once connected.
    var zoomEmail: String?
    var zoomConnectedAt: Date?
}

@MainActor
final class ConnectionStore: ObservableObject {
    @Published private(set) var state = LoginState()
    @Published private(set) var calendarAccess = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var calendarNames: [String] = []
    @Published var googleBusy = false
    @Published var googleError: String?
    /// Google's own wording for the last error, only passed along to Ask Lens.
    @Published var googleErrorCode: String?
    @Published private(set) var googleCalendarNames: [String] = []
    @Published var zoomBusy = false
    @Published var zoomError: String?
    @Published var zoomErrorCode: String?
    /// "143 summaries read · newest Nov 18", kept up to date by ZoomNotes.
    @Published var zoomReport: String?

    private let eventStore = EKEventStore()

    init() {
        load()
        refreshCalendar()
        Task { await refreshGoogleCalendars() }
    }

    // MARK: Whose accounts

    /// Lens only ever connects to the user's accounts. Anything signed in as someone else on this Mac is ignored.
    static let defaultOwnerEmail = ""

    var ownerEmail: String {
        let saved = field("ownerEmail").trimmingCharacters(in: .whitespaces).lowercased()
        return saved.isEmpty ? Self.defaultOwnerEmail : saved
    }

    /// Until someone signs in, any account is theirs; the first Google sign-in becomes "your account".
    func isOwner(_ email: String) -> Bool { ownerEmail.isEmpty || email.lowercased() == ownerEmail }

    // MARK: Simple answers

    func isConfirmed(_ key: String) -> Bool { state.confirmed[key] ?? false }
    func setConfirmed(_ key: String, _ value: Bool) { state.confirmed[key] = value; save() }
    func field(_ key: String) -> String { state.fields[key] ?? "" }
    func setField(_ key: String, _ value: String) { state.fields[key] = value; save() }

    /// When transactions last came in from this account's log-in window.
    func lastImport(_ id: LoginID) -> Date? {
        ISO8601DateFormatter().date(from: field("lastImport.\(id.rawValue)"))
    }

    // MARK: Google

    /// Someone's own Google client (from a downloaded file) wins; otherwise the one built into Lens.
    var googleClientID: String { Keychain.get("google.clientID") ?? BuiltInGoogleClient.pair?.id ?? "" }
    var googleClientSecret: String? {
        if Keychain.get("google.clientID") != nil { return Keychain.get("google.clientSecret") }
        return BuiltInGoogleClient.pair?.secret
    }
    var hasGoogleClient: Bool { !googleClientID.isEmpty && googleClientSecret != nil }
    var googleConnected: Bool {
        guard let email = state.googleEmail else { return false }
        return isOwner(email) && Keychain.get("google.refreshToken") != nil
    }

    /// Picks up the client file Claude downloaded, if there is one.
    /// A new file always wins over an older saved setup, and the old sign-in is forgotten with it.
    func importGoogleClient() {
        let before = googleClientID
        guard GoogleClientFile.importIfNeeded() else { return }
        if !before.isEmpty && before != googleClientID {
            if let token = Keychain.get("google.refreshToken") { Task { await GoogleAuth.revoke(token) } }
            forgetGoogleSignIn()
        }
        googleError = nil
        googleErrorCode = nil
        objectWillChange.send()
    }

    private func forgetGoogleSignIn() {
        Keychain.delete("google.refreshToken")
        state.googleEmail = nil
        state.googleConnectedAt = nil
        state.googleScopes = nil
        googleCalendarNames = []
        GoogleAuth.clearCachedToken()
        save()
    }

    /// Forgets the saved Google setup and sign-in, so Google can be set up again from scratch.
    func startGoogleOver() async {
        if let token = Keychain.get("google.refreshToken") { await GoogleAuth.revoke(token) }
        forgetGoogleSignIn()
        Keychain.delete("google.clientID")
        Keychain.delete("google.clientSecret")
        googleError = nil
        googleErrorCode = nil
        objectWillChange.send()
    }

    private func grantedScope(_ suffix: String) -> Bool {
        (state.googleScopes ?? "").split(separator: " ").contains { $0.hasSuffix(suffix) }
    }

    /// What the current sign-in covers. Docs rides on the Drive permission Lens already asks for.
    var googleCovers: [(name: String, on: Bool)] {
        [("Gmail", grantedScope("gmail.readonly")), ("Drive", grantedScope("drive.file")),
         ("Sheets", grantedScope("spreadsheets.readonly")), ("Docs", grantedScope("drive.file")),
         ("Calendar", grantedScope("calendar.readonly"))]
    }

    /// Signed in with permission to read Gmail.
    var gmailReady: Bool { googleConnected && grantedScope("gmail.readonly") }

    var googleCalendarReady: Bool { googleConnected && grantedScope("calendar.readonly") }

    /// Signed in before Calendar was added: Google has to be asked again.
    var googleNeedsNewSignIn: Bool { googleConnected && !grantedScope("calendar.readonly") }

    func signInWithGoogle() async {
        importGoogleClient()
        guard hasGoogleClient, let secret = googleClientSecret else { return }
        googleBusy = true
        googleError = nil
        googleErrorCode = nil
        defer { googleBusy = false }
        do {
            let result = try await GoogleAuth.signIn(clientID: googleClientID, clientSecret: secret)
            guard isOwner(result.email) else {
                await GoogleAuth.revoke(result.refreshToken)
                googleError = "That was \(result.email), but Lens connects to \(ownerEmail). Click Sign in with Google again and pick \(ownerEmail)."
                googleErrorCode = "wrong_account"
                return
            }
            if field("ownerEmail").trimmingCharacters(in: .whitespaces).isEmpty { setField("ownerEmail", result.email.lowercased()) }
            Keychain.set(result.refreshToken, for: "google.refreshToken")
            state.googleEmail = result.email
            state.googleConnectedAt = Date()
            state.googleScopes = result.scope
            save()
            await refreshGoogleCalendars()
        } catch {
            let failure = GoogleAuth.explain(error)
            googleError = failure.message
            googleErrorCode = failure.code
        }
    }

    /// Plain-English question for the Get help button.
    var googleHelpQuestion: String {
        "Google sign-in in Lens isn't working. Lens showed: \"\(googleError ?? "an error")\"" +
        (googleErrorCode.map { " (code: \($0))" } ?? "") + ". What should I do next?"
    }

    func googleAccessToken() async throws -> String {
        guard let secret = googleClientSecret, let refresh = Keychain.get("google.refreshToken") else {
            throw GoogleAuth.explain(code: "invalid_grant")
        }
        return try await GoogleAuth.accessToken(clientID: googleClientID, clientSecret: secret, refreshToken: refresh)
    }

    func disconnectGoogle() async {
        if let token = Keychain.get("google.refreshToken") { await GoogleAuth.revoke(token) }
        Keychain.delete("google.refreshToken")
        state.googleEmail = nil
        state.googleConnectedAt = nil
        state.googleScopes = nil
        googleCalendarNames = []
        GoogleAuth.clearCachedToken()
        save()
    }

    // MARK: Zoom

    var zoomClientID: String { Keychain.get("zoom.clientID") ?? "" }
    var hasZoomClient: Bool { !zoomClientID.isEmpty && Keychain.get("zoom.clientSecret") != nil }
    var zoomConnected: Bool { state.zoomEmail != nil && Keychain.get("zoom.refreshToken") != nil }
    private var zoomToken: (token: String, expires: Date)?
    private var zoomRefreshing: Task<String, Error>?

    /// Picks up the Zoom file Claude put in Downloads, if there is one. A new file replaces the old setup.
    func importZoomClient() {
        let before = zoomClientID
        guard ZoomClientFile.importIfNeeded() else { return }
        if !before.isEmpty && before != zoomClientID { forgetZoomSignIn() }
        zoomError = nil
        zoomErrorCode = nil
        objectWillChange.send()
    }

    private func forgetZoomSignIn() {
        Keychain.delete("zoom.refreshToken")
        state.zoomEmail = nil
        state.zoomConnectedAt = nil
        zoomToken = nil
        zoomReport = nil
        save()
    }

    func connectZoom() async {
        importZoomClient()
        guard hasZoomClient, let secret = Keychain.get("zoom.clientSecret") else { return }
        zoomBusy = true
        zoomError = nil
        zoomErrorCode = nil
        defer { zoomBusy = false }
        do {
            let tokens = try await ZoomAuth.signIn(clientID: zoomClientID, clientSecret: secret)
            Keychain.set(tokens.refresh, for: "zoom.refreshToken")
            zoomToken = (tokens.access, tokens.expires)
            let me = try? await ZoomAPI.me(token: tokens.access)
            state.zoomEmail = (me?.email).flatMap { $0.isEmpty ? nil : $0 } ?? "Zoom account"
            state.zoomConnectedAt = Date()
            save()
        } catch {
            let failure = ZoomAuth.explain(error)
            zoomError = failure.message
            zoomErrorCode = failure.code
        }
    }

    /// A short-lived Zoom access token. Zoom swaps the saved refresh token for a new one each time,
    /// so only one refresh runs at once and the new one is saved straight away.
    func zoomAccessToken() async throws -> String {
        if let cached = zoomToken, cached.expires > Date().addingTimeInterval(60) { return cached.token }
        if let running = zoomRefreshing { return try await running.value }
        guard let secret = Keychain.get("zoom.clientSecret"), let refresh = Keychain.get("zoom.refreshToken") else {
            throw ZoomAuth.explain(code: "not_connected")
        }
        let clientID = zoomClientID
        let task = Task { () throws -> String in
            let tokens = try await ZoomAuth.refresh(refresh, clientID: clientID, clientSecret: secret)
            Keychain.set(tokens.refresh, for: "zoom.refreshToken")
            self.zoomToken = (tokens.access, tokens.expires)
            return tokens.access
        }
        zoomRefreshing = task
        defer { zoomRefreshing = nil }
        do {
            return try await task.value
        } catch {
            // Zoom no longer accepts the saved sign-in: show Connect Zoom again.
            if (error as? ZoomAuth.Failure)?.code == "invalid_grant" || (error as? ZoomAuth.Failure)?.code == "invalid_request" {
                forgetZoomSignIn()
                zoomError = ZoomAuth.explain(code: "invalid_grant").message
                zoomErrorCode = "invalid_grant"
            }
            throw error
        }
    }

    func disconnectZoom() async {
        if let token = Keychain.get("zoom.refreshToken"), let secret = Keychain.get("zoom.clientSecret") {
            await ZoomAuth.revoke(token, clientID: zoomClientID, clientSecret: secret)
        }
        forgetZoomSignIn()
        zoomError = nil
        zoomErrorCode = nil
    }

    /// Plain-English question for the Get help button.
    var zoomHelpQuestion: String {
        "Connecting Zoom in Lens isn't working. Lens showed: \"\(zoomError ?? "an error")\"" +
        (zoomErrorCode.map { " (code: \($0))" } ?? "") + ". What should I do next?"
    }

    // MARK: Calendar

    func requestCalendar() async {
        _ = try? await eventStore.requestFullAccessToEvents()
        refreshCalendar()
    }

    func refreshGoogleCalendars() async {
        guard googleCalendarReady, let token = try? await googleAccessToken(),
              let calendars = try? await GoogleCalendarAPI.calendars(token: token) else { return }
        googleCalendarNames = calendars.map(\.name).sorted()
    }

    /// Her events between two dates. Uses Google Calendar when signed in; the Mac's Calendar app only otherwise.
    func calendarEvents(from: Date, to: Date) async -> [LensCalendarEvent] {
        if googleCalendarReady, let token = try? await googleAccessToken(),
           let calendars = try? await GoogleCalendarAPI.calendars(token: token) {
            var all: [LensCalendarEvent] = []
            for calendar in calendars.prefix(10) {
                all += (try? await GoogleCalendarAPI.events(calendar: calendar, from: from, to: to, token: token)) ?? []
            }
            return all.sorted { $0.start < $1.start }
        }
        guard calendarAccess == .fullAccess else { return [] }
        let predicate = eventStore.predicateForEvents(withStart: from, end: to, calendars: nil)
        return eventStore.events(matching: predicate).map {
            LensCalendarEvent(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "Busy", start: $0.startDate,
                              end: $0.endDate, allDay: $0.isAllDay, calendar: $0.calendar.title, location: $0.location)
        }.sorted { $0.start < $1.start }
    }

    func refreshCalendar() {
        calendarAccess = EKEventStore.authorizationStatus(for: .event)
        calendarNames = calendarAccess == .fullAccess ? eventStore.calendars(for: .event).map(\.title).sorted() : []
    }

    // MARK: Drive for desktop

    /// Google Drive for desktop mounts each signed-in account under ~/Library/CloudStorage.
    var driveAccounts: [(email: String, url: URL)] {
        allDriveAccounts.filter { isOwner($0.email) }
    }

    /// Accounts Drive for desktop is signed into on this Mac that aren't the user's (ignored by Lens).
    var otherDriveAccounts: [String] {
        allDriveAccounts.map(\.email).filter { !isOwner($0) }
    }

    private var allDriveAccounts: [(email: String, url: URL)] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasPrefix("GoogleDrive-") }.sorted().map {
            (String($0.dropFirst("GoogleDrive-".count)), root.appendingPathComponent($0))
        }
    }

    // MARK: Statements

    func chooseStatementsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use this folder"
        panel.message = "Pick (or create) the folder where monthly bank, card, PayPal and Venmo statements get saved."
        if let drive = driveAccounts.first {
            panel.directoryURL = drive.url.appendingPathComponent("My Drive")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.statementsFolder = url.path
        save()
    }

    // MARK: Status of each log-in

    func status(_ id: LoginID) -> LoginStatus {
        let gmail = googleConnected ? state.googleEmail : nil
        switch id {
        case .google:
            if googleNeedsNewSignIn { return .partial("Sign in again to add Calendar") }
            if googleConnected { return .connected(gmail ?? "") }
            return hasGoogleClient ? .todo("Ready to sign in") : .todo("Not set up on this Mac yet")
        case .calendar:
            if googleCalendarReady {
                let n = googleCalendarNames.count
                return .connected(n > 0 ? "\(n) calendar\(n == 1 ? "" : "s") from Google" : "From Google")
            }
            if googleNeedsNewSignIn { return .partial("Sign in with Google again") }
            if googleConnected { return .partial("Sign in with Google again") }
            switch calendarAccess {
            case .fullAccess: return .connected("\(calendarNames.count) calendar\(calendarNames.count == 1 ? "" : "s")")
            case .denied, .restricted: return .todo("Blocked in System Settings")
            default: return .todo("Needs permission")
            }
        case .drive:
            if let account = driveAccounts.first { return .connected(account.email) }
            return otherDriveAccounts.isEmpty ? .todo("Google Drive for desktop isn't installed")
                                              : .todo("Not signed in with your account on this Mac")
        case .zoom:
            if zoomConnected { return .connected(zoomReport ?? "Reading your summaries") }
            if isConfirmed("zoom") { return gmail != nil ? .partial("Emailed summaries only. Connect Zoom for all of them") : .partial("Waiting on Google") }
            return .todo(hasZoomClient ? "Ready to connect" : "Not connected yet")
        case .website:
            if isConfirmed("website") { return gmail != nil ? .connected(field("website").isEmpty ? "Form emails arrive in Gmail" : field("website")) : .partial("Waiting on Google") }
            return .todo("Point form emails at Gmail")
        case .social:
            let on = MetaMessages.Site.allCases.filter(MetaMessages.isConnected).map(\.rawValue)
            if on.count == 2 { return .connected("Instagram and Facebook messages") }
            if let one = on.first { return .partial("\(one) connected") }
            return .todo("One-time setup, then messages come in")
        case .directories:
            return gmail != nil ? .connected("Leads and reviews arrive through Gmail") : .partial("Waiting on Google")
        case .freshbooks:
            let connected = UserDefaults.standard.string(forKey: "freshbooks.accountID") != nil
                && !(Keychain.get("freshbooks.refreshToken") ?? "").isEmpty
            if connected { return .connected(UserDefaults.standard.string(forKey: "freshbooks.business") ?? "Invoices and estimates") }
            return .todo("One-time setup, then invoices come in")
        case .bank, .paypal, .venmo:
            if let last = lastImport(id) { return .connected("Updated \(last.formatted(.dateTime.month().day()))") }
            if isConfirmed(id.rawValue) { return .connected("Monthly statements") }
            if id == .bank && field("bankWebsite").isEmpty { return .todo("Add her bank's website") }
            return .todo("Log in once to pull transactions")
        case .claude:
            return (Keychain.get("anthropic.apiKey") ?? "").isEmpty ? .todo("Needs an API key") : .connected("Ask Lens is on")
        case .github:
            return (Keychain.get("github.issuesToken") ?? "").isEmpty ? .partial("Requests go by email for now") : .connected("Requests go to GitHub")
        case .homeServer:
            return .later("Once the home server is set up")
        }
    }

    var progress: (done: Int, total: Int) {
        let counted = LoginID.allCases.map(status).filter { !$0.isLater }
        return (counted.filter(\.isConnected).count, counted.count)
    }

    // MARK: Persistence

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: DealStore.url("logins.json")),
           let saved = try? decoder.decode(LoginState.self, from: data) {
            state = saved
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(state) { try? data.write(to: DealStore.url("logins.json"), options: .atomic) }
    }
}
