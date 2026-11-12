import SwiftUI
import WebKit

/// Emma logs in to her bank, Venmo or PayPal on their own website, inside Lens. Lens never sees
/// or stores her password: the site keeps her signed in the way a browser would. When she
/// downloads a statement, Lens catches the file and adds it to the books.
struct BankSite {
    let id: LoginID
    let name: String
    let home: URL?
    /// The page with the statement download, when we know it. Saves her hunting for it.
    let statements: URL?
    let accounts: [MoneyAccount]

    @MainActor
    static func site(_ id: LoginID, logins: ConnectionStore) -> BankSite {
        switch id {
        case .venmo:
            return BankSite(id: id, name: "Venmo", home: URL(string: "https://account.venmo.com/"),
                            statements: URL(string: "https://account.venmo.com/statement"), accounts: [.venmo])
        case .paypal:
            return BankSite(id: id, name: "PayPal", home: URL(string: "https://www.paypal.com/myaccount/summary"),
                            statements: URL(string: "https://www.paypal.com/reports/dlog"), accounts: [.paypal])
        default:
            return BankSite(id: id, name: "Bank + card", home: bankURL(logins.field("bankWebsite")),
                            statements: nil, accounts: [.checking, .card])
        }
    }

    /// Turns "chase.com" into a safe https address. Anything that isn't a plain website is refused.
    static func bankURL(_ text: String) -> URL? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if !t.lowercased().hasPrefix("http") { t = "https://" + t }
        guard let url = URL(string: t), url.scheme == "https", let host = url.host, host.contains(".") else { return nil }
        return url
    }

    static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lens/Statements", isDirectory: true)
    }
}

// MARK: - The browser

@MainActor
final class BankBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let webView: WKWebView
    @Published var host = ""
    @Published var secure = true
    @Published var loading = false
    @Published var canGoBack = false
    /// A statement that just finished downloading and is waiting to go into the books.
    @Published var caught: URL?
    @Published var problem: String?

    private let folder: URL
    private var destinations: [ObjectIdentifier: URL] = [:]

    init(folder: URL) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // keeps her signed in between visits, like Safari
        webView = WKWebView(frame: .zero, configuration: config)
        self.folder = folder
        super.init()
        // Some banks turn away browsers they don't recognize, so present as Safari.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func load(_ url: URL) { webView.load(URLRequest(url: url)) }

    /// Signs her out of this site in Lens by clearing what it stored (cookies and the like).
    func forget(_ url: URL?) async {
        guard let host = url?.host else { return }
        let domain = host.split(separator: ".").suffix(2).joined(separator: ".")
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        await store.removeData(ofTypes: types, for: records.filter { $0.displayName.contains(domain) })
    }

    private func refresh() {
        host = webView.url?.host ?? ""
        secure = webView.hasOnlySecureContent
        canGoBack = webView.canGoBack
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.shouldPerformDownload ? .download : .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().contains("attachment") {
            return .download
        }
        return navigationResponse.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loading = true; refresh()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false; refresh()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loading = false; refresh()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loading = false; refresh()
        if (error as NSError).code != NSURLErrorCancelled { problem = "That page didn't load. Check the internet connection and try again." }
    }

    /// Links that open a new window open here instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    // MARK: Downloads

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = suggestedFilename.isEmpty ? "statement.csv" : suggestedFilename
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var dest = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = folder.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        destinations[ObjectIdentifier(download)] = dest
        return dest
    }

    func downloadDidFinish(_ download: WKDownload) {
        caught = destinations.removeValue(forKey: ObjectIdentifier(download))
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        destinations.removeValue(forKey: ObjectIdentifier(download))
        problem = "The download didn't finish. Try it again."
    }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - The window

struct BankLoginView: View {
    @EnvironmentObject private var logins: ConnectionStore
    @EnvironmentObject private var money: MoneyStore
    @Environment(\.dismiss) private var dismiss

    let id: LoginID
    @StateObject private var browser: BankBrowser
    @State private var website = ""
    @State private var account: MoneyAccount
    @State private var chargesPositive = false
    @State private var done: String?

    init(id: LoginID, folder: URL) {
        self.id = id
        _browser = StateObject(wrappedValue: BankBrowser(folder: folder))
        _account = State(initialValue: id == .venmo ? .venmo : id == .paypal ? .paypal : .checking)
    }

    private var site: BankSite { BankSite.site(id, logins: logins) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.line)
            if site.home == nil {
                askWebsite
            } else {
                WebViewHost(webView: browser.webView)
                    .overlay(alignment: .bottom) { footer }
            }
        }
        .frame(minWidth: 900, idealWidth: 1060, minHeight: 640, idealHeight: 780)
        .background(Theme.ground)
        .onAppear { if let home = site.home { browser.load(home) } }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(SecondaryButtonStyle()).disabled(!browser.canGoBack)
            Button { browser.webView.reload() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(SecondaryButtonStyle())
            // The real address, so she can always see she's on her bank's own site.
            HStack(spacing: 6) {
                Image(systemName: browser.secure ? "lock.fill" : "lock.open")
                    .foregroundStyle(browser.secure ? Theme.teal : Theme.amber)
                Text(browser.host.isEmpty ? site.name : browser.host)
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.text2).lineLimit(1)
                if browser.loading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.raised).clipShape(RoundedRectangle(cornerRadius: 7))
            if let statements = site.statements {
                Button("Go to statements") { browser.load(statements) }.buttonStyle(SecondaryButtonStyle())
            }
            Menu {
                if id == .bank {
                    Button("Change bank website") { logins.setField("bankWebsite", ""); website = "" }
                }
                Button("Sign out of \(site.name) in Lens") {
                    Task { await browser.forget(site.home); if let home = site.home { browser.load(home) } }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
        }
        .padding(12)
        .background(Theme.panel)
    }

    private var askWebsite: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Which bank?").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
            Text("Type the website you use for online banking. Lens opens it here so you can log in like normal.")
                .font(.system(size: 14)).foregroundStyle(Theme.muted)
            TextField("e.g. chase.com", text: $website)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                .onSubmit(saveWebsite)
            Button("Open it", action: saveWebsite)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(BankSite.bankURL(website) == nil)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func saveWebsite() {
        guard let url = BankSite.bankURL(website) else { return }
        logins.setField("bankWebsite", url.absoluteString)
        browser.load(url)
    }

    // MARK: Footer: what to do, and the statement once it arrives

    @ViewBuilder
    private var footer: some View {
        Group {
            if let file = browser.caught {
                caughtPanel(file)
            } else if let problem = browser.problem {
                strip(problem, color: Theme.coral) { browser.problem = nil }
            } else if let done {
                strip(done, color: Theme.teal) { self.done = nil }
            } else {
                strip(hint, color: Theme.text2, close: nil)
            }
        }
        .padding(14)
    }

    private var hint: String {
        switch id {
        case .venmo: return "Log in, then tap Go to statements and download the CSV. Lens adds it to Money."
        case .paypal: return "Log in, then tap Go to statements, pick CSV and download. Lens adds it to Money."
        default: return "Log in like normal, find Statements or Download transactions, and choose CSV. Lens adds it to Money."
        }
    }

    private func strip(_ text: String, color: Color, close: (() -> Void)?) -> some View {
        HStack(spacing: 10) {
            Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(color)
            if let close {
                Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThickMaterial).clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.line))
    }

    private func caughtPanel(_ file: URL) -> some View {
        let ext = file.pathExtension.lowercased()
        let readable = ["csv", "txt"].contains(ext)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Got \(file.lastPathComponent)").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
            if !readable {
                Text("That's a .\(ext) file, which Lens can't read yet. In the download options pick CSV (sometimes called Excel or spreadsheet) and download again.")
                    .font(.system(size: 12)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("OK") { browser.caught = nil }.buttonStyle(SecondaryButtonStyle()) }
            } else {
                if site.accounts.count > 1 {
                    Picker("Which account is this?", selection: $account) {
                        ForEach(site.accounts) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 320)
                }
                if account == .card {
                    Toggle("Charges show as positive numbers in this file", isOn: $chargesPositive).toggleStyle(.checkbox)
                }
                HStack {
                    Button("Skip") { browser.caught = nil }.buttonStyle(SecondaryButtonStyle())
                    Spacer()
                    Button("Add to the books") { addToBooks(file) }.buttonStyle(PrimaryButtonStyle())
                }
            }
        }
        .padding(16)
        .frame(width: 420, alignment: .leading)
        .background(.ultraThickMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
    }

    private func addToBooks(_ file: URL) {
        do {
            let (added, skipped) = try money.importCSV(file, account: account, chargesArePositive: chargesPositive)
            logins.setField("lastImport.\(id.rawValue)", ISO8601DateFormatter().string(from: Date()))
            done = "Added \(added) transaction\(added == 1 ? "" : "s") to \(account.label)"
                + (skipped > 0 ? ", skipped \(skipped) already there" : "")
        } catch {
            browser.problem = "Lens couldn't read that file. Try downloading it as CSV again."
        }
        browser.caught = nil
    }
}
