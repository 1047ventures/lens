import Foundation

/// Turns her own Zoom recordings into meeting notes, for calls that were recorded without an AI summary.
/// Lens looks in Documents › Zoom (where Zoom's "Record on this computer" saves) and in any folder she
/// picks, and in her Zoom cloud once Zoom is connected. It listens to each recording on this Mac with
/// Apple speech recognition (or uses Zoom's own transcript for a cloud recording when there is one),
/// sends only the words to Claude to write the note, and hands the note to ZoomNotes, which files it on
/// the right project the same way as a Zoom summary. Each recording is only ever read once.
@MainActor
final class RecordingNotes: ObservableObject {
    /// "Listening to your recordings… 3 of 12" while Lens works.
    @Published private(set) var progress: String?
    @Published private(set) var working = false
    @Published private(set) var problem: String?
    /// Other folders she asked Lens to look in.
    @Published private(set) var folders: [String] = []
    @Published private(set) var lastChecked: Date?
    /// How many recordings Lens has written up.
    @Published private(set) var written = 0
    /// Heard, but waiting for Claude to write them up.
    var waitingCount: Int { heard.count }

    private weak var zoom: ZoomNotes?
    private weak var logins: ConnectionStore?
    private weak var ai: LensAI?
    /// Recordings already read (or with nothing in them), so they're never read twice.
    private var done: Set<String> = []
    /// Recordings already listened to, waiting to be written up (for example, Claude wasn't connected yet).
    private var heard: [String: Heard] = [:]
    private var lastCloudSync: Date?
    private var cloudDone = false
    private var loop: Task<Void, Never>?
    private var again = false
    private var stopped = false

    /// Two at a time: quick enough, and the Mac stays responsive.
    private static let atOnce = 2
    /// Zoom's cloud recordings: nothing older than this to look for.
    private static let oldest = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2020, month: 1, day: 1).date!

    /// Where Zoom's "Record on this computer" saves: ~/Documents/Zoom.
    nonisolated static var zoomFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Zoom", isDirectory: true)
    }

    init() { load() }

    func attach(zoom: ZoomNotes, logins: ConnectionStore, ai: LensAI) {
        self.zoom = zoom
        self.logins = logins
        self.ai = ai
    }

    /// Looks shortly after Lens opens, then every hour while it's open.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    // MARK: Folders

    func addFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !folders.contains(path), path != Self.zoomFolder.standardizedFileURL.path else { return }
        folders.append(path)
        save()
        Task { await check() }
    }

    func removeFolder(_ path: String) {
        folders.removeAll { $0 == path }
        save()
    }

    // MARK: Checking

    func check() async {
        guard let zoom, let ai else { return }
        if working { again = true; return }
        working = true
        defer { working = false; progress = nil }
        repeat {
            again = false
            await run(zoom: zoom, ai: ai)
        } while again
        lastChecked = Date()
        save()
    }

    private func run(zoom: ZoomNotes, ai: LensAI) async {
        problem = nil
        stopped = false
        let roots = [Self.zoomFolder] + folders.map { URL(fileURLWithPath: $0, isDirectory: true) }
        var found = await Task.detached { Self.findOnMac(in: roots) }.value
        found += await findInCloud()

        var todo: [Recording] = []
        var seen = Set<String>()
        for r in found where !done.contains(r.key) && heard[r.key] == nil && seen.insert(r.key).inserted {
            // Zoom already wrote a summary of this call, or Lens already has this recording from elsewhere.
            if zoom.hasNote(zoomUUID: r.zoomUUID, title: r.title, date: r.date)
                || todo.contains(where: { Self.sameCall($0, r) })
                || heard.values.contains(where: { Self.sameCall($0.title, $0.date, r.title, r.date) }) {
                done.insert(r.key)
                continue
            }
            todo.append(r)
        }
        save()
        let waiting = Array(heard.keys)
        let total = todo.count + waiting.count
        guard total > 0 else { return }

        var finished = 0
        progress = "Listening to your recordings… \(finished) of \(total)"
        for key in waiting {
            await writeUp(key, zoom: zoom, ai: ai)
            finished += 1
            progress = "Listening to your recordings… \(finished) of \(total)"
        }
        // Oldest first, so the notes arrive in order.
        todo.sort { $0.date < $1.date }
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func more() {
                guard next < todo.count else { return }
                let r = todo[next]
                next += 1
                group.addTask { await self.process(r, zoom: zoom, ai: ai) }
            }
            for _ in 0..<Self.atOnce { more() }
            while await group.next() != nil {
                finished += 1
                progress = "Listening to your recordings… \(finished) of \(total)"
                if !stopped { more() }
            }
        }
    }

    /// Listens to one recording, then has it written up and filed.
    private func process(_ r: Recording, zoom: ZoomNotes, ai: LensAI) async {
        guard !stopped else { return }
        do {
            let words = try await listen(r).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else {
                // Nothing anyone said: no note, and no need to listen again.
                done.insert(r.key)
                save()
                return
            }
            heard[r.key] = Heard(title: r.title, date: r.date, link: r.link, transcript: words, people: r.people)
            save()
            await writeUp(r.key, zoom: zoom, ai: ai)
        } catch let failure as Transcriber.Failure where failure.message == Transcriber.denied.message
                    || failure.message == Transcriber.notOnThisMac.message {
            problem = failure.message
            stopped = true
        } catch let failure as Transcriber.Failure {
            // This file can't be opened as a recording; don't keep trying it.
            problem = "Lens couldn't listen to \"\(r.title)\". \(failure.message)"
            done.insert(r.key)
            save()
        } catch {
            problem = "Lens couldn't listen to \"\(r.title)\" just now. It will try again later."
        }
    }

    /// Claude writes the note from the words, then ZoomNotes files it.
    private func writeUp(_ key: String, zoom: ZoomNotes, ai: LensAI) async {
        guard let h = heard[key] else { return }
        guard ai.hasKey else {
            problem = "Connect Claude in Log-ins so Lens can write up your recordings. \(heard.count) \(heard.count == 1 ? "is" : "are") ready."
            return
        }
        do {
            let s = try await ai.summarizeRecording(title: h.title, date: h.date, transcript: h.transcript)
            var people = h.people ?? []
            for name in s.speakers where !people.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                people.append(MeetingPerson(name: name, email: ""))
            }
            let short = s.overview.isEmpty ? (s.sections.first?.text ?? "") : s.overview
            let note = MeetingNote(id: "recording:" + key, title: h.title, date: h.date, summary: short, link: h.link,
                                   source: "recording", zoomMeetingID: nil,
                                   overview: s.overview, sections: s.sections, nextSteps: s.nextSteps,
                                   people: people.isEmpty ? nil : people, transcript: h.transcript)
            await zoom.fileRecording(note)
            heard.removeValue(forKey: key)
            done.insert(key)
            written += 1
            save()
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? "Claude couldn't write up your recordings just now. Lens will try again later."
        }
    }

    /// The words in one recording.
    private func listen(_ r: Recording) async throws -> String {
        switch r.from {
        case .file(let url):
            guard await Transcriber.allowed() else { throw Transcriber.denied }
            return try await Transcriber.transcribe(url)
        case .cloud(let c):
            guard let logins else { return "" }
            let token = try await logins.zoomAccessToken()
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("lens-recording-\(UUID().uuidString)")
            // Zoom's own transcript, when it made one: no listening needed.
            if let link = c.transcriptURL {
                let file = temp.appendingPathExtension("vtt")
                defer { try? FileManager.default.removeItem(at: file) }
                try await ZoomAPI.download(link, to: file, token: token)
                let text = ZoomAPI.transcriptText((try? String(contentsOf: file, encoding: .utf8)) ?? "")
                if !text.isEmpty { return text }
            }
            guard let link = c.audioURL else { return "" }
            guard await Transcriber.allowed() else { throw Transcriber.denied }
            let file = temp.appendingPathExtension(c.audioExtension.isEmpty ? "m4a" : c.audioExtension)
            defer { try? FileManager.default.removeItem(at: file) }
            try await ZoomAPI.download(link, to: file, token: try await logins.zoomAccessToken())
            return try await Transcriber.transcribe(file)
        }
    }

    // MARK: In the Zoom cloud

    private func findInCloud() async -> [Recording] {
        guard let logins, logins.zoomConnected else { return [] }
        let now = Date()
        let since = max((lastCloudSync ?? now.addingTimeInterval(-30 * 86400)).addingTimeInterval(-3 * 86400), Self.oldest)
        var windows = [(since, now)]
        if !cloudDone {
            // First time: back through her recordings a month at a time.
            var cursor = since
            while cursor > Self.oldest {
                let from = max(cursor.addingTimeInterval(-30 * 86400), Self.oldest)
                windows.append((from, cursor))
                cursor = from
            }
        }
        var out: [Recording] = []
        do {
            for (from, to) in windows {
                var page: String?
                repeat {
                    let result = try await ZoomAPI.recordings(from: from, to: to, pageToken: page, token: try await logins.zoomAccessToken())
                    for c in result.items {
                        let key = "zoom:" + c.uuid
                        guard !done.contains(key), heard[key] == nil else { continue }
                        out.append(Recording(key: key, title: c.topic, date: c.start, link: c.shareURL ?? "https://zoom.us/recording",
                                             zoomUUID: c.uuid, people: nil, from: .cloud(c)))
                    }
                    page = result.next
                    try? await Task.sleep(for: .milliseconds(200))   // gentle on Zoom
                } while page != nil
            }
            lastCloudSync = now
            cloudDone = true
        } catch let failure as ZoomAuth.Failure where failure.code == "missing_scope" {
            // The Zoom app doesn't have the recording permissions yet. Recordings on the Mac still work.
            return []
        } catch {
            return out
        }
        // Who was on each call, so the note can find its project.
        let me = logins.ownerEmail
        for i in out.indices {
            guard case .cloud(let c) = out[i].from else { continue }
            let ref = ZoomAPI.Ref(uuid: c.uuid, meetingID: "", topic: c.topic, start: c.start)
            let people = await ZoomAPI.people(ref, token: (try? await logins.zoomAccessToken()) ?? "")
                .filter { $0.email.isEmpty || $0.email != me }
            out[i].people = people.isEmpty ? nil : people
        }
        return out
    }

    // MARK: On this Mac

    struct Recording: Sendable {
        enum From: Sendable {
            case file(URL)
            case cloud(ZoomAPI.CloudRecording)
        }
        let key: String
        let title: String
        let date: Date
        let link: String
        let zoomUUID: String?
        var people: [MeetingPerson]?
        let from: From
    }

    private static func sameCall(_ a: Recording, _ b: Recording) -> Bool { sameCall(a.title, a.date, b.title, b.date) }

    /// The same call recorded twice (on the Mac and in the cloud): same name, within a few hours.
    nonisolated private static func sameCall(_ t1: String, _ d1: Date, _ t2: String, _ d2: Date) -> Bool {
        func normal(_ t: String) -> String { String(t.lowercased().filter { $0.isLetter || $0.isNumber }) }
        return normal(t1) == normal(t2) && abs(d1.timeIntervalSince(d2)) < 3 * 3600
    }

    private static let audioTypes: Set<String> = ["m4a", "mp3", "wav", "aac", "caf", "aiff"]

    /// Every recording in these folders. A Zoom recording folder ("2026-10-14 15.03.22 CU Boulder check-in")
    /// counts once, using its audio file (or the video when there's only that). In a folder she picked,
    /// loose audio files count too. Looks up to three folders deep.
    nonisolated static func findOnMac(in roots: [URL]) -> [Recording] {
        var out: [Recording] = []
        let fm = FileManager.default
        func look(_ dir: URL, depth: Int) {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey],
                                                          options: [.skipsHiddenFiles]) else { return }
            let files = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
            let dirs = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
            let name = dir.lastPathComponent
            let parsed = zoomName(name)
            let zoomAudio = files.filter { $0.pathExtension.lowercased() == "m4a" && $0.lastPathComponent.lowercased().hasPrefix("audio") }
            let isZoom = parsed != nil || !zoomAudio.isEmpty || files.contains { $0.lastPathComponent == "recording.conf" }
            if isZoom {
                let video = files.filter { ["mp4", "mov"].contains($0.pathExtension.lowercased()) }
                let other = files.filter { $0.pathExtension.lowercased() == "m4a" }
                if let pick = (zoomAudio.max { size($0) < size($1) }) ?? (other.max { size($0) < size($1) }) ?? (video.max { size($0) < size($1) }) {
                    let date = parsed?.date ?? (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                    out.append(Recording(key: "mac:" + name + "/" + pick.lastPathComponent, title: parsed?.title ?? name, date: date,
                                         link: pick.absoluteString, zoomUUID: nil, people: nil, from: .file(pick)))
                }
                return   // its "Audio Record" folder (one file per person) is the same call
            }
            for f in files where audioTypes.contains(f.pathExtension.lowercased()) {
                let title = f.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "[_]+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                let date = (try? f.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                out.append(Recording(key: "mac:" + name + "/" + f.lastPathComponent + ":\(size(f))", title: title.isEmpty ? "Recording" : title,
                                     date: date, link: f.absoluteString, zoomUUID: nil, people: nil, from: .file(f)))
            }
            if depth < 3 { for d in dirs { look(d, depth: depth + 1) } }
        }
        for root in roots { look(root, depth: 0) }
        return out
    }

    /// "2026-10-14 15.03.22 CU Boulder check-in 81234567890" → the date and "CU Boulder check-in".
    nonisolated static func zoomName(_ folder: String) -> (date: Date, title: String)? {
        let pattern = "^(\\d{4})-(\\d{2})-(\\d{2}) (\\d{2})\\.(\\d{2})\\.(\\d{2}) (.+)$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: folder, range: NSRange(folder.startIndex..., in: folder)) else { return nil }
        func part(_ i: Int) -> String { Range(m.range(at: i), in: folder).map { String(folder[$0]) } ?? "" }
        var c = DateComponents()
        c.year = Int(part(1)); c.month = Int(part(2)); c.day = Int(part(3))
        c.hour = Int(part(4)); c.minute = Int(part(5)); c.second = Int(part(6))
        guard let date = Calendar.current.date(from: c) else { return nil }
        let title = part(7)
            .replacingOccurrences(of: "\\s+\\d{9,11}$", with: "", options: .regularExpression)   // the meeting ID Zoom adds
            .trimmingCharacters(in: .whitespaces)
        return (date, title.isEmpty ? "Zoom call" : title)
    }

    // MARK: Saving (recordings.json)

    private struct Heard: Codable {
        var title: String
        var date: Date
        var link: String
        var transcript: String
        var people: [MeetingPerson]?
    }

    private struct Saved: Codable {
        var done: [String]?
        var heard: [String: Heard]?
        var folders: [String]?
        var lastChecked: Date?
        var lastCloudSync: Date?
        var cloudDone: Bool?
        var written: Int?
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: DealStore.url("recordings.json")),
              let saved = try? decoder.decode(Saved.self, from: data) else { return }
        done = Set(saved.done ?? [])
        heard = saved.heard ?? [:]
        folders = saved.folders ?? []
        lastChecked = saved.lastChecked
        lastCloudSync = saved.lastCloudSync
        cloudDone = saved.cloudDone ?? false
        written = saved.written ?? 0
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let saved = Saved(done: Array(done), heard: heard, folders: folders, lastChecked: lastChecked,
                          lastCloudSync: lastCloudSync, cloudDone: cloudDone, written: written)
        if let data = try? encoder.encode(saved) { try? data.write(to: DealStore.url("recordings.json"), options: .atomic) }
    }
}
