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

/// Google's sign-in for desktop apps: Lens opens Google's own page in the browser, Emma signs in
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
    ]

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func signIn(clientID: String, clientSecret: String) async throws -> (email: String, refreshToken: String) {
        let verifier = randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = randomString(24)

        let receiver = try await LoopbackReceiver.start()
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
        if let error = query["error"] {
            throw Failure(message: error == "access_denied" ? "Sign-in was cancelled." : "Google said: \(error)")
        }
        guard query["state"] == state, let code = query["code"] else {
            throw Failure(message: "Google's reply didn't match this sign-in. Try again.")
        }

        // Swap the one-time code for tokens
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "code": code, "client_id": clientID, "client_secret": clientSecret,
            "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier,
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let access = json["access_token"] as? String else {
            let reason = (json["error_description"] as? String) ?? (json["error"] as? String) ?? "no details"
            throw Failure(message: "Google didn't accept the sign-in (\(reason)). Check the client ID and secret.")
        }
        guard let refresh = json["refresh_token"] as? String else {
            throw Failure(message: "Google didn't grant lasting access. Remove Lens at myaccount.google.com/permissions and try again.")
        }

        // Which account just signed in
        var who = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        who.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let (info, _) = try await URLSession.shared.data(for: who)
        let email = ((try? JSONSerialization.jsonObject(with: info) as? [String: Any])?["email"] as? String) ?? "Google account"
        return (email, refresh)
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

    static func start() async throws -> LoopbackReceiver {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
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
            receiver?.finish(.failure(GoogleAuth.Failure(message: "Sign-in timed out. Try again.")))
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
    case google, calendar, drive, zoom, website, social, directories, bank, paypal, venmo, claude, github, homeServer
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

/// What Emma has connected, and the non-secret answers she gave along the way.
struct LoginState: Codable {
    var confirmed: [String: Bool] = [:]
    var fields: [String: String] = [:]
    var statementsFolder: String?
    var googleEmail: String?
    var googleConnectedAt: Date?
}

@MainActor
final class ConnectionStore: ObservableObject {
    @Published private(set) var state = LoginState()
    @Published private(set) var calendarAccess = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var calendarNames: [String] = []
    @Published var googleBusy = false
    @Published var googleError: String?

    private let eventStore = EKEventStore()

    init() {
        load()
        refreshCalendar()
    }

    // MARK: Whose accounts

    /// Lens only ever connects to Emma's accounts. Anything signed in as someone else on this Mac is ignored.
    static let defaultOwnerEmail = "emmapionberlin@gmail.com"

    var ownerEmail: String {
        let saved = field("ownerEmail").trimmingCharacters(in: .whitespaces).lowercased()
        return saved.isEmpty ? Self.defaultOwnerEmail : saved
    }

    func isOwner(_ email: String) -> Bool { email.lowercased() == ownerEmail }

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

    var googleClientID: String { Keychain.get("google.clientID") ?? "" }
    var hasGoogleClient: Bool { !googleClientID.isEmpty && Keychain.get("google.clientSecret") != nil }
    var googleConnected: Bool {
        guard let email = state.googleEmail else { return false }
        return isOwner(email) && Keychain.get("google.refreshToken") != nil
    }

    func saveGoogleClient(id: String, secret: String) {
        Keychain.set(id.trimmingCharacters(in: .whitespacesAndNewlines), for: "google.clientID")
        Keychain.set(secret.trimmingCharacters(in: .whitespacesAndNewlines), for: "google.clientSecret")
        objectWillChange.send()
    }

    func signInWithGoogle() async {
        guard let secret = Keychain.get("google.clientSecret") else { return }
        googleBusy = true
        googleError = nil
        defer { googleBusy = false }
        do {
            let result = try await GoogleAuth.signIn(clientID: googleClientID, clientSecret: secret)
            guard isOwner(result.email) else {
                await GoogleAuth.revoke(result.refreshToken)
                googleError = "That was \(result.email). Lens only connects to \(ownerEmail). Sign in again as Emma."
                return
            }
            Keychain.set(result.refreshToken, for: "google.refreshToken")
            state.googleEmail = result.email
            state.googleConnectedAt = Date()
            save()
        } catch {
            googleError = error.localizedDescription
        }
    }

    func disconnectGoogle() async {
        if let token = Keychain.get("google.refreshToken") { await GoogleAuth.revoke(token) }
        Keychain.delete("google.refreshToken")
        state.googleEmail = nil
        state.googleConnectedAt = nil
        save()
    }

    // MARK: Calendar

    func requestCalendar() async {
        _ = try? await eventStore.requestFullAccessToEvents()
        refreshCalendar()
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

    /// Accounts Drive for desktop is signed into on this Mac that aren't Emma's (ignored by Lens).
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
            if googleConnected { return .connected(gmail ?? "") }
            return hasGoogleClient ? .partial("Ready to sign in") : .todo("One-time setup, then sign in")
        case .calendar:
            switch calendarAccess {
            case .fullAccess: return .connected("\(calendarNames.count) calendar\(calendarNames.count == 1 ? "" : "s")")
            case .denied, .restricted: return .todo("Blocked in System Settings")
            default: return .todo("Needs permission")
            }
        case .drive:
            if let account = driveAccounts.first { return .connected(account.email) }
            return otherDriveAccounts.isEmpty ? .todo("Google Drive for desktop isn't installed")
                                              : .todo("Not signed in as Emma on this Mac")
        case .zoom:
            if isConfirmed("zoom") { return gmail != nil ? .connected("Summaries arrive in Gmail") : .partial("Waiting on Google") }
            return .todo("Turn on emailed AI summaries")
        case .website:
            if isConfirmed("website") { return gmail != nil ? .connected(field("website").isEmpty ? "Form emails arrive in Gmail" : field("website")) : .partial("Waiting on Google") }
            return .todo("Point form emails at Gmail")
        case .social:
            return isConfirmed("social") ? .partial("Paste DMs for now; direct link later") : .todo("Switch to a professional account")
        case .directories:
            let listed = field("directories").split(separator: ",").count
            if isConfirmed("directories") { return gmail != nil ? .connected("\(listed) listing\(listed == 1 ? "" : "s"), leads via Gmail") : .partial("Waiting on Google") }
            return .todo("Pick where she's listed")
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
