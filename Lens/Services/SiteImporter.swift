import Foundation
import WebKit

/// Pulls every photo (and any video file) off a website, like an old Squarespace site, into a
/// folder Emma picks, one folder per page. The site then shows up in Library like a drive.
/// It reads the site's page list, visits each page and saves the full-size pictures it finds.
/// Videos hosted on Vimeo or YouTube are listed in a note so she can fetch them later.
@MainActor
final class SiteImporter: ObservableObject {
    static let shared = SiteImporter()

    struct Job {
        var host: String
        var pagesDone = 0
        var pagesTotal = 0
        var saved = 0
        var bytes: Int64 = 0
        var videoLinks: Set<String> = []
        var finished = false
        var problem: String?
        var folder: URL
    }

    @Published private(set) var jobs: [String: Job] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    static let mediaExtensions: Set<String> = CatalogKind.photoExtensions.union(FileScanner.videoExtensions).union(["gif", "webp"])

    /// Where imports go unless she picks somewhere else: a plugged-in drive if there is one,
    /// so her Mac doesn't fill up, otherwise her Pictures folder.
    static func suggestedFolder() -> URL {
        let catalog = DriveCatalog.shared
        if let drive = catalog.outside.first(where: { catalog.mounted[$0.id] != nil }), let root = catalog.mounted[drive.id] {
            return root.appendingPathComponent("Lens Imports", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Lens Imports", isDirectory: true)
    }

    static func siteURL(_ text: String) -> URL? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if !t.lowercased().hasPrefix("http") { t = "https://" + t }
        guard let url = URL(string: t), let host = url.host, host.contains(".") else { return nil }
        return URL(string: "https://\(host)")
    }

    func cancel(_ host: String) {
        tasks[host]?.cancel()
        jobs[host]?.finished = true
        jobs[host]?.problem = "Stopped. What was saved so far is kept."
    }

    func start(site: URL, into parent: URL) {
        guard let host = site.host, tasks[host] == nil || jobs[host]?.finished == true else { return }
        let folder = parent.appendingPathComponent(host, isDirectory: true)
        jobs[host] = Job(host: host, folder: folder)
        tasks[host] = Task { [weak self] in
            await self?.run(site: site, host: host, folder: folder)
        }
    }

    // MARK: The work

    private func run(site: URL, host: String, folder: URL) async {
        // Use whatever she logged in with in the Lens browser window (a site password, say).
        let config = URLSessionConfiguration.default
        let cookies = HTTPCookieStorage()
        for cookie in await WKWebsiteDataStore.default().httpCookieStore.allCookies() where host.hasSuffix(cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
            cookies.setCookie(cookie)
        }
        config.httpCookieStorage = cookies
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"]
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config)

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            finish(host, problem: "Lens couldn't make a folder there. Pick another spot.")
            return
        }

        // 1. Every page on the site, from its page list (Squarespace always has one).
        var pages = await sitemapPages(site, session: session)
        if pages.isEmpty { pages = [site] }
        pages = Array(pages.prefix(1500))
        jobs[host]?.pagesTotal = pages.count

        // 2. Visit each page and save the pictures on it.
        var seen = Set<String>()
        for page in pages {
            if Task.isCancelled { return }
            guard let html = await text(page, session: session) else { jobs[host]?.pagesDone += 1; continue }
            let media = Self.mediaURLs(in: html, page: page).filter { seen.insert($0.absoluteString).inserted }
            for link in Self.videoLinks(in: html) { jobs[host]?.videoLinks.insert(link) }
            let pageFolder = folder.appendingPathComponent(Self.folderName(for: page), isDirectory: true)
            for url in media {
                if Task.isCancelled { return }
                if let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
                   free < 2_000_000_000 {
                    finish(host, problem: "Stopped: the drive is almost full. Pick a drive with more room and start again; Lens skips what's already saved.")
                    return
                }
                if let size = await download(url, into: pageFolder, session: session) {
                    jobs[host]?.saved += 1
                    jobs[host]?.bytes += size
                }
            }
            jobs[host]?.pagesDone += 1
        }

        // 3. Note the videos that live on Vimeo or YouTube.
        if let links = jobs[host]?.videoLinks, !links.isEmpty {
            let note = "Videos on this site are hosted elsewhere. Open each link to download it, or connect Vimeo in Lens later.\n\n"
                + links.sorted().joined(separator: "\n") + "\n"
            try? note.write(to: folder.appendingPathComponent("Videos hosted elsewhere.txt"), atomically: true, encoding: .utf8)
        }

        // 4. Remember it in Library like a drive.
        let summary = await Task.detached(priority: .utility) { Self.catalog(folder: folder, host: host) }.value
        DriveCatalog.shared.merge([summary])
        finish(host, problem: nil)
    }

    private func finish(_ host: String, problem: String?) {
        jobs[host]?.finished = true
        jobs[host]?.problem = problem
        tasks[host] = nil
    }

    private func text(_ url: URL, session: URLSession) async -> String? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode ?? 0 < 400 else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private func sitemapPages(_ site: URL, session: URLSession) async -> [URL] {
        guard let xml = await text(site.appendingPathComponent("sitemap.xml"), session: session) else { return [] }
        var pages: [URL] = []
        for loc in Self.matches(#"<loc>\s*([^<\s]+)\s*</loc>"#, in: xml) {
            let clean = loc.replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: clean) else { continue }
            if url.pathExtension.lowercased() == "xml" {
                // A list of lists: open the inner ones too.
                if let inner = await text(url, session: session) {
                    pages += Self.matches(#"<loc>\s*([^<\s]+)\s*</loc>"#, in: inner).compactMap { URL(string: $0.replacingOccurrences(of: "&amp;", with: "&")) }
                }
            } else {
                pages.append(url)
            }
        }
        var seen = Set<String>()
        return pages.filter { seen.insert($0.absoluteString).inserted }
    }

    /// Saves one file. Returns its size, or nil if it was skipped or failed. Files already saved are skipped.
    private func download(_ url: URL, into folder: URL, session: URLSession) async -> Int64? {
        var name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        if name.isEmpty || name == "/" { return nil }
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "+", with: " ")
        // Squarespace calls lots of pictures "image-asset.jpeg"; give each its own name from its address.
        let stem = (name as NSString).deletingPathExtension.lowercased()
        if ["image-asset", "image", "img", "photo", "asset"].contains(stem) {
            let tag = url.deletingLastPathComponent().lastPathComponent.split(separator: "-").last.map(String.init) ?? ""
            name = "\(stem)-\(tag.prefix(10)).\(url.pathExtension)"
        }
        let dest = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) { return nil }
        guard let (temp, response) = try? await session.download(from: url),
              let http = response as? HTTPURLResponse, http.statusCode < 400 else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do { try FileManager.default.moveItem(at: temp, to: dest) } catch { return nil }
        return Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    // MARK: Reading pages

    nonisolated static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            $0.numberOfRanges > 1 ? Range($0.range(at: 1), in: text).map { String(text[$0]) } : nil
        }
    }

    /// Full-size photo and video files referenced on a page. Squarespace pictures are asked for
    /// at their original size rather than the shrunk copies the page shows.
    nonisolated static func mediaURLs(in html: String, page: URL) -> [URL] {
        var found: [String] = []
        found += matches(#"((?:https?:)?//images\.squarespace-cdn\.com/[^"'\s)<>]+)"#, in: html)
        found += matches(#"((?:https?:)?//static1\.squarespace\.com/static/[^"'\s)<>]+)"#, in: html)
        found += matches(#"(?:src|data-src|data-image|href|content)=["']([^"']+)["']"#, in: html)
        var result: [URL] = []
        var seen = Set<String>()
        for raw in found {
            var s = raw.replacingOccurrences(of: "&amp;", with: "&")
            if s.hasPrefix("//") { s = "https:" + s }
            guard let url = URL(string: s, relativeTo: page)?.absoluteURL else { continue }
            let ext = url.pathExtension.lowercased()
            guard mediaExtensions.contains(ext) else { continue }
            // Drop size requests (?format=500w) so the original comes back.
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
            parts?.query = nil
            parts?.fragment = nil
            guard let clean = parts?.url, seen.insert(clean.absoluteString).inserted else { continue }
            result.append(clean)
        }
        return result
    }

    nonisolated static func videoLinks(in html: String) -> [String] {
        var links = Set<String>()
        for id in matches(#"(?:player\.)?vimeo\.com/(?:video/)?(\d{6,})"#, in: html) { links.insert("https://vimeo.com/\(id)") }
        for id in matches(#"(?:youtube\.com/(?:embed/|watch\?v=)|youtu\.be/)([A-Za-z0-9_-]{11})"#, in: html) { links.insert("https://www.youtube.com/watch?v=\(id)") }
        return Array(links)
    }

    /// "/weddings/hartley-and-sam" becomes "weddings - hartley and sam"; the home page is "Home".
    nonisolated static func folderName(for page: URL) -> String {
        let bits = page.pathComponents.filter { $0 != "/" }
        guard !bits.isEmpty else { return "Home" }
        return bits.map { ($0.removingPercentEncoding ?? $0).replacingOccurrences(of: "-", with: " ") }.joined(separator: " - ")
    }

    // MARK: Library memory

    /// Lists what was saved so the site appears in Library, searchable like a drive.
    nonisolated static func catalog(folder: URL, host: String) -> CatalogDrive {
        let id = "web-\(host)"
        let out = DriveCatalog.folder.appendingPathComponent("\(id).tsv")
        try? FileManager.default.createDirectory(at: DriveCatalog.folder, withIntermediateDirectories: true)
        var lines = ""
        var photos = 0, videos = 0
        var photoBytes: Int64 = 0, videoBytes: Int64 = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        if let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let file as URL in walker {
                guard let kind = CatalogKind.of(file.pathExtension.lowercased()) ?? (["gif", "webp"].contains(file.pathExtension.lowercased()) ? .photo : nil),
                      kind != .project else { continue }
                let v = try? file.resourceValues(forKeys: Set(keys))
                let size = Int64(v?.fileSize ?? 0)
                let rel = String(file.path.dropFirst(folder.path.count + 1))
                lines += "\(rel)\t\(size)\t\(Int((v?.contentModificationDate ?? Date()).timeIntervalSince1970))\t\(kind.rawValue)\n"
                if kind == .video { videos += 1; videoBytes += size } else { photos += 1; photoBytes += size }
            }
        }
        try? lines.write(to: out, atomically: true, encoding: .utf8)
        return CatalogDrive(id: id, name: host, isMac: false, total: 0, free: 0, lastSeen: Date(), lastScanned: Date(),
                            videoCount: videos, videoBytes: videoBytes, photoCount: photos, photoBytes: photoBytes,
                            projectCount: 0, source: "web", basePath: folder.path)
    }
}
