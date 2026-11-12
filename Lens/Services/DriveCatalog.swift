import Foundation
import AppKit

/// Lens's memory of every drive Emma owns, including her Mac, so she can see and search all of
/// them even when they're unplugged in a drawer. It keeps only a light list per drive (each
/// photo and video file's folder, name, size and date): no footage, no thumbnails.
struct CatalogDrive: Codable, Identifiable, Hashable {
    /// The volume's own ID, so a drive is recognised whatever port or name it has.
    var id: String
    /// What Emma calls it.
    var name: String
    var isMac: Bool
    var total: Int64
    var free: Int64
    var lastSeen: Date
    var lastScanned: Date?
    var videoCount: Int
    var videoBytes: Int64
    var photoCount: Int
    var photoBytes: Int64
    var projectCount: Int

    var fractionUsed: Double { total > 0 ? Double(max(0, total - free)) / Double(total) : 0 }
}

/// One folder that matched a search, with the files in it that matched.
struct CatalogHit: Identifiable {
    let driveID: String
    let folder: String          // relative to the drive
    let files: Int
    let bytes: Int64
    let sample: String          // one matching file name
    var id: String { driveID + "|" + folder }
}

enum CatalogKind: String {
    case video = "v", photo = "p", project = "j"

    static let photoExtensions: Set<String> = [
        "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "dng", "3fr", "iiq",
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "psd", "psb"
    ]
    static let projectExtensions: Set<String> = ["prproj", "lrcat", "aep"]

    static func of(_ ext: String) -> CatalogKind? {
        if FileScanner.videoExtensions.contains(ext) { return .video }
        if photoExtensions.contains(ext) { return .photo }
        if projectExtensions.contains(ext) { return .project }
        return nil
    }
}

/// Writes the light file lists while a scan walks a drive. Each drive's list is written to a
/// temporary file as it goes (nothing piles up in memory) and swapped in when the scan finishes.
final class CatalogWriter {
    final class Session {
        let drive: CatalogDrive
        let volumeRoot: String
        let handle: FileHandle
        let tempURL: URL
        var buffer = Data()
        var video = 0, photo = 0, project = 0
        var videoBytes: Int64 = 0, photoBytes: Int64 = 0

        init(drive: CatalogDrive, volumeRoot: String, handle: FileHandle, tempURL: URL) {
            self.drive = drive; self.volumeRoot = volumeRoot; self.handle = handle; self.tempURL = tempURL
        }
    }

    private var sessions: [String: Session] = [:]
    /// Only the Mac scan writes the Mac's list, so a footage folder on the Mac can't replace it.
    private let includeMac: Bool

    init(includeMac: Bool = false) { self.includeMac = includeMac }

    /// Starts (or continues) the list for the drive this folder lives on.
    func begin(root: URL) -> Session? {
        guard let info = DriveCatalog.volume(for: root), includeMac || !info.drive.isMac else { return nil }
        if let existing = sessions[info.drive.id] { return existing }
        let temp = DriveCatalog.folder.appendingPathComponent("\(info.drive.id).tsv.tmp")
        try? FileManager.default.createDirectory(at: DriveCatalog.folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: temp) else { return nil }
        let session = Session(drive: info.drive, volumeRoot: info.root, handle: handle, tempURL: temp)
        sessions[info.drive.id] = session
        return session
    }

    func add(_ session: Session, path: String, size: Int64, modified: Date, kind: CatalogKind) {
        var rel = path.hasPrefix(session.volumeRoot) ? String(path.dropFirst(session.volumeRoot.count)) : path
        if rel.hasPrefix("/") { rel.removeFirst() }
        let clean = rel.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        session.buffer.append(Data("\(clean)\t\(size)\t\(Int(modified.timeIntervalSince1970))\t\(kind.rawValue)\n".utf8))
        switch kind {
        case .video: session.video += 1; session.videoBytes += size
        case .photo: session.photo += 1; session.photoBytes += size
        case .project: session.project += 1
        }
        if session.buffer.count > 256 * 1024 { flush(session) }
    }

    private func flush(_ session: Session) {
        try? session.handle.write(contentsOf: session.buffer)
        session.buffer.removeAll(keepingCapacity: true)
    }

    /// Swaps in the finished lists and returns each drive's updated summary.
    func finish() -> [CatalogDrive] {
        var result: [CatalogDrive] = []
        for session in sessions.values {
            flush(session)
            try? session.handle.close()
            let final = DriveCatalog.folder.appendingPathComponent("\(session.drive.id).tsv")
            _ = try? FileManager.default.replaceItemAt(final, withItemAt: session.tempURL)
            if !FileManager.default.fileExists(atPath: final.path) {
                try? FileManager.default.moveItem(at: session.tempURL, to: final)
            }
            var drive = session.drive
            drive.lastScanned = Date()
            drive.videoCount = session.video; drive.videoBytes = session.videoBytes
            drive.photoCount = session.photo; drive.photoBytes = session.photoBytes
            drive.projectCount = session.project
            result.append(drive)
        }
        sessions.removeAll()
        return result
    }
}

@MainActor
final class DriveCatalog: ObservableObject {
    static let shared = DriveCatalog()

    @Published private(set) var drives: [CatalogDrive] = []
    /// IDs of the drives plugged in right now, with where each is mounted.
    @Published private(set) var mounted: [String: URL] = [:]
    /// An outside drive that's plugged in but Lens hasn't met yet.
    @Published private(set) var newDrive: URL?
    @Published private(set) var macScanning = false
    /// Called when a drive Lens already knows is plugged back in, so it can be read again.
    var onKnownDrivePlugged: ((URL) -> Void)?

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lens/Catalog", isDirectory: true)
    }
    private static var storeURL: URL { folder.appendingPathComponent("drives.json") }

    /// The folders on her Mac where shoots tend to pile up.
    nonisolated static var macFolders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Desktop", "Downloads", "Documents", "Movies", "Pictures"].map { home.appendingPathComponent($0) }
    }

    private var observers: [NSObjectProtocol] = []

    private init() {
        load()
        refreshMounted()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshMounted() }
            })
        }
    }

    var mac: CatalogDrive? { drives.first(where: \.isMac) }
    var outside: [CatalogDrive] { drives.filter { !$0.isMac }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    func isPlugged(_ drive: CatalogDrive) -> Bool { drive.isMac || mounted[drive.id] != nil }

    // MARK: Drives coming and going

    func refreshMounted() {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        var found: [String: URL] = [:]
        var unknown: URL?
        for url in urls {
            guard let info = Self.volume(for: url), !info.drive.isMac else { continue }
            found[info.drive.id] = url
            if let i = drives.firstIndex(where: { $0.id == info.drive.id }) {
                drives[i].free = info.drive.free
                drives[i].total = info.drive.total
                drives[i].lastSeen = Date()
            } else if Self.looksLikeHerDrive(url) {
                unknown = url
            }
        }
        let known = Set(drives.map(\.id))
        let arrived = found.filter { mounted[$0.key] == nil && known.contains($0.key) }
        mounted = found
        newDrive = unknown
        for url in arrived.values { onKnownDrivePlugged?(url) }
        save()
    }

    /// Big outside drives only: not the Mac, not an installer or a camera's tiny boot volume.
    private static func looksLikeHerDrive(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeIsReadOnlyKey, .volumeIsInternalKey])
        guard values?.volumeIsReadOnly != true, values?.volumeIsInternal != true else { return false }
        return (values?.volumeTotalCapacity ?? 0) > 60_000_000_000
    }

    func dismissNewDrive() { newDrive = nil }

    func rename(_ id: String, to name: String) {
        guard let i = drives.firstIndex(where: { $0.id == id }) else { return }
        drives[i].name = name
        save()
    }

    func forget(_ id: String) {
        drives.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent("\(id).tsv"))
        save()
    }

    /// Takes in the summaries a scan produced. A drive's name is kept if Emma already set one.
    func merge(_ updated: [CatalogDrive]) {
        for var drive in updated {
            if let i = drives.firstIndex(where: { $0.id == drive.id }) {
                drive.name = drives[i].name
                drives[i] = drive
            } else {
                drives.append(drive)
            }
        }
        refreshMounted()
        save()
    }

    // MARK: Her Mac

    /// Reads the usual folders on her Mac into the catalog. Lists only; nothing is moved or changed.
    func scanMac() {
        guard !macScanning else { return }
        macScanning = true
        let roots = Self.macFolders.filter { FileManager.default.fileExists(atPath: $0.path) }
        Task.detached(priority: .utility) {
            let writer = CatalogWriter(includeMac: true)
            _ = FileScanner.scan(roots: roots, catalog: writer)
            let updated = writer.finish()
            await MainActor.run {
                DriveCatalog.shared.merge(updated)
                DriveCatalog.shared.macScanning = false
            }
        }
    }

    // MARK: Search

    /// Finds folders and files whose path contains every word typed, on every drive, plugged in
    /// or not. Results are grouped by folder so a whole shoot shows as one line.
    nonisolated static func search(_ query: String, drives: [CatalogDrive]) -> [CatalogHit] {
        let words = query.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        var groups: [String: (drive: String, folder: String, files: Int, bytes: Int64, sample: String)] = [:]
        for drive in drives {
            autoreleasepool {
                guard let text = try? String(contentsOf: folder.appendingPathComponent("\(drive.id).tsv"), encoding: .utf8) else { return }
                text.enumerateLines { line, _ in
                    let lower = line.lowercased()
                    guard let tab = lower.firstIndex(of: "\t") else { return }
                    let path = lower[..<tab]
                    guard words.allSatisfy({ path.contains($0) }) else { return }
                    let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                    guard parts.count >= 2 else { return }
                    let full = String(parts[0])
                    let folderPath = (full as NSString).deletingLastPathComponent
                    let key = drive.id + "|" + folderPath
                    var g = groups[key] ?? (drive.id, folderPath, 0, 0, (full as NSString).lastPathComponent)
                    g.files += 1
                    g.bytes += Int64(parts[1]) ?? 0
                    groups[key] = g
                }
            }
        }
        return groups.values
            .map { CatalogHit(driveID: $0.drive, folder: $0.folder, files: $0.files, bytes: $0.bytes, sample: $0.sample) }
            .sorted { $0.bytes > $1.bytes }
            .prefix(60)
            .map { $0 }
    }

    // MARK: Volumes

    /// The drive a folder lives on. Every folder on the Mac's own disk counts as "This Mac".
    nonisolated static func volume(for url: URL) -> (drive: CatalogDrive, root: String)? {
        let keys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeNameKey, .volumeURLKey, .volumeIsInternalKey,
                                         .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? url.resourceValues(forKeys: keys), let root = v.volume else { return nil }
        let isMac = v.volumeIsInternal ?? false
        let id = isMac ? "this-mac" : (v.volumeUUIDString ?? (v.volumeName ?? root.lastPathComponent))
        let drive = CatalogDrive(
            id: id, name: isMac ? "This Mac" : (v.volumeName ?? "Drive"), isMac: isMac,
            total: Int64(v.volumeTotalCapacity ?? 0), free: v.volumeAvailableCapacityForImportantUsage ?? 0,
            lastSeen: Date(), lastScanned: nil,
            videoCount: 0, videoBytes: 0, photoCount: 0, photoBytes: 0, projectCount: 0)
        return (drive, root.path)
    }

    // MARK: Persistence

    private func load() {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.storeURL), let saved = try? decoder.decode([CatalogDrive].self, from: data) {
            drives = saved
        }
    }

    private func save() {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = .prettyPrinted
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        if let data = try? encoder.encode(drives) { try? data.write(to: Self.storeURL, options: .atomic) }
    }
}
