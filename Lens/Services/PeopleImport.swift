import Foundation

/// Reads the data downloads LinkedIn and Meta (Facebook, Instagram) give Emma, and turns them into
/// people. Nothing here changes Emma's data: PeopleStore.bringIn does that once she picks a file.
enum PeopleImport {

    struct Failure: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    enum Kind: Identifiable {
        case linkedIn, meta

        var id: Self { self }

        var title: String {
            switch self {
            case .linkedIn: return "Bring in LinkedIn"
            case .meta: return "Bring in Facebook and Instagram"
            }
        }
    }

    // MARK: Finding the download

    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    /// The newest LinkedIn or Meta download in Downloads (a file, a zip, or the folder a zip opened into).
    static func findInDownloads(_ kind: Kind) -> URL? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let items = try? fm.contentsOfDirectory(at: downloads, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
        let matches = items.filter { url in
            let name = url.lastPathComponent.lowercased()
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            switch kind {
            case .linkedIn:
                if name == "connections.csv" { return true }
                if name.contains("linkedin") && (name.hasSuffix(".zip") || isFolder) { return true }
                return isFolder && fm.fileExists(atPath: url.appendingPathComponent("Connections.csv").path)
            case .meta:
                return (name.hasPrefix("facebook-") || name.hasPrefix("instagram-") || name.hasPrefix("meta-"))
                    && (name.hasSuffix(".zip") || isFolder)
            }
        }
        return matches.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }

    /// Opens a zip into a temporary folder, taking only the files that match `patterns`.
    private static func unzip(_ zip: URL, only patterns: [String]) throws -> URL {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("LensImport-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-qq", "-o", zip.path] + patterns + ["-d", out.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { throw Failure("Lens couldn't open that zip file. Double-click it in Finder, then pick the folder it makes.") }
        task.waitUntilExit()
        return out
    }

    /// Every file under `folder` that passes `match`.
    private static func files(in folder: URL, where match: (URL) -> Bool) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in walker where match(url) { out.append(url) }
        return out
    }

    private static func isZip(_ url: URL) -> Bool { url.pathExtension.lowercased() == "zip" }

    // MARK: LinkedIn (Connections.csv)

    /// Everyone in LinkedIn's Connections.csv: name, company, title, email when they share it, and the day they connected.
    static func linkedIn(_ url: URL) throws -> [Person] {
        var csv = url
        var cleanup: URL?
        defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }
        if isZip(url) {
            let folder = try unzip(url, only: ["*Connections.csv"])
            cleanup = folder
            guard let found = files(in: folder, where: { $0.lastPathComponent.lowercased() == "connections.csv" }).first else {
                throw Failure("That LinkedIn download doesn't have your connections in it. Ask LinkedIn for a copy that includes Connections.")
            }
            csv = found
        } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            guard let found = files(in: url, where: { $0.lastPathComponent.lowercased() == "connections.csv" }).first else {
                throw Failure("Lens couldn't find Connections.csv in that folder.")
            }
            csv = found
        }
        guard let data = try? Data(contentsOf: csv),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw Failure("Lens couldn't read that file.")
        }
        let rows = parseCSV(text)
        // LinkedIn puts a few lines of notes above the real header.
        guard let headerIndex = rows.firstIndex(where: { row in
            row.contains { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("First Name") == .orderedSame }
        }) else { throw Failure("That doesn't look like LinkedIn's Connections file.") }
        let header = rows[headerIndex].map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func column(_ name: String) -> Int? { header.firstIndex(of: name) }
        let first = column("first name"), last = column("last name"), email = column("email address"),
            company = column("company"), position = column("position"), profile = column("url"), connected = column("connected on")

        var people: [Person] = []
        for row in rows[(headerIndex + 1)...] {
            func value(_ i: Int?) -> String {
                guard let i, i < row.count else { return "" }
                return row[i].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let name = [value(first), value(last)].filter { !$0.isEmpty }.joined(separator: " ")
            guard !name.isEmpty else { continue }
            let mail = value(email).lowercased()
            var p = Person(name: name, emails: mail.contains("@") ? [mail] : [])
            p.company = value(company)
            p.role = value(position)
            p.link = value(profile)
            p.met = "LinkedIn"
            p.addedFrom = "LinkedIn"
            p.connectedOn = date(value(connected))
            people.append(p)
        }
        if people.isEmpty { throw Failure("There's no one in that LinkedIn file yet.") }
        return people
    }

    private static func date(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["dd MMM yyyy", "d MMM yyyy", "yyyy-MM-dd", "MM/dd/yy", "MM/dd/yyyy"] {
            f.dateFormat = format
            if let d = f.date(from: text) { return d }
        }
        return nil
    }

    /// A small CSV reader: commas, quoted fields, quotes inside quotes and line breaks inside quotes.
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": quoted = true
                case ",": row.append(field); field = ""
                case "\n", "\r": row.append(field); field = ""; rows.append(row); row = []
                default: field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    // MARK: Facebook and Instagram ("Download your information", JSON)

    /// Everyone Emma messaged with, from the inbox folders of a Facebook or Instagram download.
    static func meta(_ url: URL) throws -> [Person] {
        var folder = url
        var cleanup: URL?
        defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }
        if isZip(url) {
            folder = try unzip(url, only: ["*inbox/*message_1.json"])
            cleanup = folder
        } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            folder = url.deletingLastPathComponent()
        }
        let found = files(in: folder) { $0.lastPathComponent == "message_1.json" && $0.path.contains("/inbox/") }
        if found.isEmpty {
            throw Failure("Lens couldn't find any messages in that download. Make sure you picked Messages and the JSON format when you asked for it.")
        }
        struct Thread { let names: [String]; let site: String }
        var threads: [Thread] = []
        for file in found {
            guard let data = try? Data(contentsOf: file),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let names = (json["participants"] as? [[String: Any]] ?? []).compactMap { ($0["name"] as? String).map(fixText) }
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let site = (url.path + file.path).lowercased().contains("instagram") ? "Instagram" : "Facebook"
            threads.append(Thread(names: names, site: site))
        }
        // Emma is in every conversation: the name that shows up most is her.
        var counts: [String: Int] = [:]
        for t in threads { for n in Set(t.names) { counts[n, default: 0] += 1 } }
        let me = threads.count > 1 ? counts.max { $0.value < $1.value }?.key : nil
        let placeholders: Set<String> = ["facebook user", "instagram user", "facebook-nutzer", "utilisateur de facebook"]

        var seen = Set<String>()
        var people: [Person] = []
        // Group chats with lots of people are skipped: those are rarely people she works with one-on-one.
        for t in threads where t.names.count <= 8 {
            for name in t.names where name != me && !placeholders.contains(name.lowercased()) {
                guard seen.insert(Person.nameKey(name) + "|" + t.site).inserted else { continue }
                var p = Person(name: name)
                p.met = t.site
                p.addedFrom = t.site
                people.append(p)
            }
        }
        if people.isEmpty { throw Failure("There's no one to bring in from that download.") }
        return people
    }

    /// Meta writes names as Latin-1 bytes of UTF-8 ("JosÃ©" for "José"). This puts them back.
    static func fixText(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard scalars.allSatisfy({ $0.value < 256 }), scalars.contains(where: { $0.value >= 0x80 }) else { return s }
        return String(bytes: scalars.map { UInt8($0.value) }, encoding: .utf8) ?? s
    }
}
