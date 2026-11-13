import SwiftUI
import AppKit
import WebKit

/// "Add a website": Emma types her old site's address, picks where the photos go, and Lens
/// brings them in. If some pages are behind a password, she can log in first.
struct SiteImportView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var importer = SiteImporter.shared
    @State private var address = ""
    @State private var folder = SiteImporter.suggestedFolder()
    @State private var loggingIn = false
    @State private var host: String?

    private var site: URL? { SiteImporter.siteURL(address) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Bring in a website").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
            if let host, let job = importer.jobs[host] {
                progress(job)
            } else {
                form
            }
        }
        .padding(26)
        .frame(width: 520)
        .background(Theme.ground)
        .sheet(isPresented: $loggingIn) {
            if let site { SiteLoginView(site: site) }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Lens saves every photo on the site, one folder per page, and adds it to your Library. Nothing on the site changes.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Website").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text3)
                TextField("emmapionberlin.com", text: $address).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Save the photos in").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text3)
                HStack {
                    Text(folder.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Change") { pickFolder() }.buttonStyle(SecondaryButtonStyle())
                }
            }
            HStack(spacing: 6) {
                Text("Some pages need a password?").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Button("Log in first") { loggingIn = true }.buttonStyle(.link).font(.system(size: 12)).disabled(site == nil)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button("Bring it in") {
                    guard let site else { return }
                    importer.start(site: site, into: folder)
                    host = site.host
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(site == nil)
            }
        }
    }

    private func progress(_ job: SiteImporter.Job) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(job.host).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            if job.pagesTotal > 0 {
                ProgressView(value: Double(job.pagesDone), total: Double(max(job.pagesTotal, 1)))
            } else if !job.finished {
                ProgressView().controlSize(.small)
            }
            Text(statusLine(job)).font(.system(size: 13)).foregroundStyle(Theme.text2)
            if !job.videoLinks.isEmpty {
                Text("\(job.videoLinks.count) video\(job.videoLinks.count == 1 ? " is" : "s are") hosted on Vimeo or YouTube. Lens lists them in a note in the folder so you can grab them.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if let problem = job.problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if !job.finished {
                    Text("You can close this. It keeps going.").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Spacer()
                    Button("Stop") { importer.cancel(job.host) }.buttonStyle(SecondaryButtonStyle())
                } else {
                    Spacer()
                }
                Button(job.finished ? "Done" : "Close") { dismiss() }.buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private func statusLine(_ job: SiteImporter.Job) -> String {
        let saved = "\(job.saved) file\(job.saved == 1 ? "" : "s") saved (\(ByteFormat.string(job.bytes)))"
        if job.finished { return "Finished. \(saved). It's in your Library now." }
        if job.pagesTotal == 0 { return "Finding every page…" }
        return "Page \(job.pagesDone) of \(job.pagesTotal) · \(saved)"
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save here"
        panel.message = "Pick where the website's photos go. A drive with plenty of room is best."
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }
}

/// The site, opened inside Lens, so Emma can enter a page password or log in. Lens never sees
/// what she types; it only reuses the logged-in session to read the pages.
private struct SiteLoginView: View {
    let site: URL
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = BankBrowser(folder: FileManager.default.temporaryDirectory)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { browser.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(SecondaryButtonStyle()).disabled(!browser.canGoBack)
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").foregroundStyle(Theme.teal)
                    Text(browser.host.isEmpty ? (site.host ?? "") : browser.host)
                        .font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.text2)
                    if browser.loading { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.raised).clipShape(RoundedRectangle(cornerRadius: 7))
                Text("Log in, then tap Done").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
            }
            .padding(12)
            .background(Theme.panel)
            SiteWebView(webView: browser.webView)
        }
        .frame(minWidth: 860, minHeight: 600)
        .onAppear { browser.load(site) }
    }
}

private struct SiteWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
