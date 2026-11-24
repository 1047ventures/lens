import Foundation
import SwiftUI

// MARK: - Everything Lens remembers, file by file

/// One photo or video Lens remembers, on any drive, with what's known about it.
struct LibraryItem: Identifiable, Hashable {
    let driveID: String
    /// Where it is on its drive.
    let path: String
    /// What it's grouped under: its folder on the drive, or for the Photos app, the day it was taken.
    let folder: String
    let size: Int64
    let modified: Date
    let kind: CatalogKind
    let assetID: String?
    let camera: String?
    let taken: Date?
    let place: String?
    let lat: Double?
    let lon: Double?

    var id: String { driveID + "|" + path + "|" + (assetID ?? "") }
    var name: String { (path as NSString).lastPathComponent }
    /// When it was shot, or failing that when the file was last changed.
    var date: Date { taken ?? modified }
}

/// A folder's worth of photos and video on one drive (for the Photos app, one day's worth).
struct LibraryFolder: Identifiable, Hashable {
    let driveID: String
    let folder: String
    var items: [Int] = []
    var photos = 0, videos = 0
    var bytes: Int64 = 0
    var first = Date.distantFuture
    var last = Date.distantPast

    var id: String { driveID + "|" + folder }
    var isPhotosDay: Bool { driveID == PhotosLibrary.driveID }
    var name: String {
        if isPhotosDay { return "Photos app, " + first.formatted(.dateTime.month(.wide).day().year()) }
        return folder.isEmpty ? "Top of the drive" : (folder as NSString).lastPathComponent
    }
    var parent: String { isPhotosDay ? "" : (folder as NSString).deletingLastPathComponent }
}

/// Lens's memory of every drive, read into one list so the Library can show it by shoot. Built in
/// the background from each drive's file list and saved details; rebuilt when a drive is read again.
@MainActor
final class LibraryIndex: ObservableObject {
    static let shared = LibraryIndex()

    @Published private(set) var items: [LibraryItem] = []
    @Published private(set) var folders: [LibraryFolder] = []
    @Published private(set) var loading = false
    /// Goes up every time the lists change, so views can tell.
    @Published private(set) var version = 0

    private var pending: Task<Void, Never>?
    private var loadedOnce = false

    private init() {}

    /// Reads everything the first time the Library opens.
    func start() {
        guard !loadedOnce else { return }
        loadedOnce = true
        reload(after: 0)
    }

    func catalogChanged() { if loadedOnce { reload(after: 0.5) } }
    func factsChanged() { if loadedOnce { reload(after: 1.5) } }

    private func reload(after delay: Double) {
        pending?.cancel()
        let drives = DriveCatalog.shared.drives
        loading = true
        pending = Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            let built = await Task.detached(priority: .userInitiated) { Self.build(drives) }.value
            guard !Task.isCancelled else { return }
            items = built.items
            folders = built.folders
            version += 1
            loading = false
        }
    }

    nonisolated private static func build(_ drives: [CatalogDrive]) -> (items: [LibraryItem], folders: [LibraryFolder]) {
        var items: [LibraryItem] = []
        var byKey: [String: LibraryFolder] = [:]
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        for drive in drives {
            autoreleasepool {
                let facts = FileFacts.load(drive.id)
                for row in DriveCatalog.rows(on: drive) where row.kind != .project {
                    let fact = facts[row.path]
                    var place = fact?.place
                    if place == nil, let lat = fact?.lat, let lon = fact?.lon { place = PlaceBook.shared.cached(lat, lon) }
                    let modified = Date(timeIntervalSince1970: TimeInterval(row.modified))
                    let taken = fact?.taken
                    let folder = drive.isPhotos
                        ? "Photos app/" + day.string(from: taken ?? modified)
                        : (row.path as NSString).deletingLastPathComponent
                    let item = LibraryItem(driveID: drive.id, path: row.path, folder: folder, size: row.size,
                                           modified: modified, kind: row.kind, assetID: row.assetID,
                                           camera: fact?.camera, taken: taken, place: place,
                                           lat: fact?.lat, lon: fact?.lon)
                    let key = drive.id + "|" + folder
                    var f = byKey[key] ?? LibraryFolder(driveID: drive.id, folder: folder)
                    f.items.append(items.count)
                    if row.kind == .video { f.videos += 1 } else { f.photos += 1 }
                    f.bytes += row.size
                    f.first = min(f.first, item.date)
                    f.last = max(f.last, item.date)
                    byKey[key] = f
                    items.append(item)
                }
            }
        }
        return (items, Array(byKey.values))
    }

    // MARK: Which shoot each folder belongs to

    private var shelfCache: (key: Int, shelf: Shelf)?

    /// Every folder, sorted onto its project or into the "not sorted yet" pile.
    func shelf(projects: [Project], links: LibraryLinks, catalog: DriveCatalog) -> Shelf {
        var hasher = Hasher()
        hasher.combine(version)
        hasher.combine(links.version)
        for p in projects { hasher.combine(p.id); hasher.combine(p.folderPath); hasher.combine(p.archivedPath) }
        for d in catalog.drives { hasher.combine(d.id); hasher.combine(catalog.base(of: d)) }
        let key = hasher.finalize()
        if let cached = shelfCache, cached.key == key { return cached.shelf }
        let shelf = Shelf.make(folders: folders, projects: projects, links: links.data.links,
                               bases: Dictionary(uniqueKeysWithValues: catalog.drives.map { ($0.id, catalog.base(of: $0)) }))
        shelfCache = (key, shelf)
        return shelf
    }
}

/// The result of sorting folders onto projects.
struct Shelf {
    /// Project → the folders (positions in `LibraryIndex.folders`) that hold its footage.
    var byProject: [UUID: [Int]] = [:]
    /// Folders that belong to no project yet.
    var unsorted: [Int] = []
    /// Folder id → its project.
    var owner: [String: UUID] = [:]

    static func make(folders: [LibraryFolder], projects: [Project], links: [FolderLink], bases: [String: String?]) -> Shelf {
        // A project's footage folder, and where it went on the server, both count as its folders.
        var prefixes: [(path: String, id: UUID)] = []
        for p in projects {
            for raw in [p.folderPath, p.archivedPath].compactMap({ $0 }) where !raw.isEmpty {
                var path = raw
                while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
                prefixes.append((path, p.id))
            }
        }
        let projectIDs = Set(projects.map(\.id))
        var shelf = Shelf()
        for (i, f) in folders.enumerated() {
            var best: (length: Int, id: UUID)?
            if let base = bases[f.driveID] ?? nil, !f.isPhotosDay {
                let full = join(base, f.folder)
                for (path, id) in prefixes where full == path || full.hasPrefix(path == "/" ? "/" : path + "/") {
                    if path.count > (best?.length ?? -1) { best = (path.count, id) }
                }
            }
            // A folder she matched by hand. Counted as a deeper match than any footage folder above it.
            for link in links where link.driveID == f.driveID && projectIDs.contains(link.projectID)
                && (f.folder == link.folder || f.folder.hasPrefix(link.folder + "/")) {
                let length = 10_000 + link.folder.count
                if length > (best?.length ?? -1) { best = (length, link.projectID) }
            }
            if let best {
                shelf.byProject[best.id, default: []].append(i)
                shelf.owner[f.id] = best.id
            } else {
                shelf.unsorted.append(i)
            }
        }
        return shelf
    }

    static func join(_ base: String, _ rel: String) -> String {
        if rel.isEmpty { return base }
        return base.hasSuffix("/") ? base + rel : base + "/" + rel
    }
}

// MARK: - Folders matched by hand

/// A folder Emma said belongs to a project (or doesn't).
struct FolderLink: Codable, Hashable {
    var driveID: String
    var folder: String
    var projectID: UUID
}

struct LibraryLinksData: Codable {
    var links: [FolderLink] = []
    /// "No, it isn't that one", so Lens doesn't ask again.
    var notThis: [FolderLink] = []
}

/// Folders she matched to a project in the Library, when the project already has a footage folder
/// (or the folder is in the Photos app, or is a whole Mac folder like Downloads). Saved in
/// `library-links.json`; a project's own footage folder stays on the project.
@MainActor
final class LibraryLinks: ObservableObject {
    static let shared = LibraryLinks()

    @Published private(set) var data = LibraryLinksData()
    private(set) var version = 0

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lens", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library-links.json")
    }

    private init() {
        if let raw = try? Data(contentsOf: Self.url), let saved = try? JSONDecoder().decode(LibraryLinksData.self, from: raw) {
            data = saved
        }
    }

    func link(_ folder: LibraryFolder, to projectID: UUID) {
        data.links.removeAll { $0.driveID == folder.driveID && $0.folder == folder.folder }
        data.links.append(FolderLink(driveID: folder.driveID, folder: folder.folder, projectID: projectID))
        save()
    }

    func notThis(_ folder: LibraryFolder, _ projectID: UUID) {
        data.notThis.append(FolderLink(driveID: folder.driveID, folder: folder.folder, projectID: projectID))
        save()
    }

    func unlink(_ folder: LibraryFolder) {
        data.links.removeAll { $0.driveID == folder.driveID && $0.folder == folder.folder }
        save()
    }

    func isRejected(_ folder: LibraryFolder, _ projectID: UUID) -> Bool {
        data.notThis.contains { $0.driveID == folder.driveID && $0.folder == folder.folder && $0.projectID == projectID }
    }

    private func save() {
        version += 1
        if let raw = try? JSONEncoder().encode(data) { try? raw.write(to: Self.url, options: .atomic) }
    }
}

// MARK: - Guessing the project

@MainActor
enum ShootGuess {
    /// The project a loose folder most likely belongs to: a name in the folder's path, or a shoot
    /// date within a few days of when its photos and videos were taken.
    static func project(for folder: LibraryFolder, among projects: [Project], links: LibraryLinks) -> Project? {
        let text = folder.folder.lowercased()
        var best: (score: Int, days: Int, project: Project)?
        for p in projects where !links.isRejected(folder, p.id) {
            var score = 0
            let named = p.matches(text)
            if named { score += 10 }
            var days = Int.max
            if let shoot = p.shootDate, folder.first != .distantFuture {
                let cal = Calendar.current
                let a = cal.startOfDay(for: shoot), b = cal.startOfDay(for: folder.first)
                days = abs(cal.dateComponents([.day], from: a, to: b).day ?? Int.max)
                if days == 0 { score += 6 } else if days <= 1 { score += 5 } else if days <= 3 { score += 3 }
                else if days <= 7 && named { score += 1 }
            }
            guard score >= 3 else { continue }
            if best == nil || score > best!.score || (score == best!.score && days < best!.days) {
                best = (score, days, p)
            }
        }
        return best?.project
    }
}

// MARK: - Places

/// A place split into town and state: "Austin, TX", "Austin Texas" and "austin, texas" all become
/// Austin / Texas. Outside the US the last part is kept as the region ("Paris, France").
struct PlaceName: Hashable {
    var city: String?
    var state: String?

    static func parse(_ raw: String?) -> PlaceName? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts.count >= 2 {
            let last = parts[parts.count - 1]
            // "Austin, TX 78701": drop a zip code.
            let lastWords = last.split(separator: " ").map(String.init).filter { Int($0) == nil }
            let tail = lastWords.joined(separator: " ")
            if let s = state(named: tail) { return PlaceName(city: tidy(parts[parts.count - 2]), state: s) }
            if isCountry(tail) { return PlaceName(city: tidy(parts[parts.count - 2]), state: tidy(tail)) }
            // "Chautauqua Park, Boulder": a spot, then the town.
            return parse(last).map { PlaceName(city: $0.city, state: $0.state) } ?? PlaceName(city: tidy(last), state: nil)
        }

        // No comma: "Austin Texas", "New York NY", "Texas", or just "Austin".
        if let whole = state(named: text) { return PlaceName(city: nil, state: whole) }
        let words = text.split(separator: " ").map(String.init)
        for take in stride(from: min(3, words.count - 1), through: 1, by: -1) {
            let tail = words.suffix(take).joined(separator: " ")
            let isAbbreviation = take == 1 && tail.count == 2
            // Two letters only count when written as capitals ("TX", not "in").
            if isAbbreviation && tail != tail.uppercased() { continue }
            if let s = state(named: tail) {
                return PlaceName(city: tidy(words.dropLast(take).joined(separator: " ")), state: s)
            }
        }
        return PlaceName(city: tidy(text), state: nil)
    }

    /// Fills in the state from another reading of the same place (Apple's map service, or the
    /// photos' GPS) when the project only names the town.
    func filled(from other: PlaceName?) -> PlaceName {
        guard state == nil, let other, other.state != nil else { return self }
        if city == nil || other.city == nil || city?.lowercased() == other.city?.lowercased() {
            return PlaceName(city: city ?? other.city, state: other.state)
        }
        return self
    }

    private static let countries: Set<String> = {
        var names: Set<String> = ["usa", "us", "united states", "uk", "england", "scotland", "wales"]
        let english = Locale(identifier: "en_US")
        for region in Locale.Region.isoRegions {
            if let n = english.localizedString(forRegionCode: region.identifier) { names.insert(n.lowercased()) }
        }
        return names
    }()

    private static func isCountry(_ s: String) -> Bool { countries.contains(s.lowercased()) }

    /// The most common place among a shoot's photos and videos.
    static func common(_ places: [String: Int]) -> PlaceName? {
        places.max { $0.value < $1.value }.flatMap { parse($0.key) }
    }

    var label: String { [city, state].compactMap { $0 }.joined(separator: ", ") }

    private static func tidy(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return t == t.lowercased() ? t.capitalized : t
    }

    private static func state(named s: String) -> String? {
        let key = s.lowercased().trimmingCharacters(in: .whitespaces)
        if let full = states[key.uppercased()] { return full }
        return states.values.first { $0.lowercased() == key }
    }

    static let states: [String: String] = [
        "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas", "CA": "California", "CO": "Colorado",
        "CT": "Connecticut", "DE": "Delaware", "FL": "Florida", "GA": "Georgia", "HI": "Hawaii", "ID": "Idaho",
        "IL": "Illinois", "IN": "Indiana", "IA": "Iowa", "KS": "Kansas", "KY": "Kentucky", "LA": "Louisiana",
        "ME": "Maine", "MD": "Maryland", "MA": "Massachusetts", "MI": "Michigan", "MN": "Minnesota",
        "MS": "Mississippi", "MO": "Missouri", "MT": "Montana", "NE": "Nebraska", "NV": "Nevada",
        "NH": "New Hampshire", "NJ": "New Jersey", "NM": "New Mexico", "NY": "New York", "NC": "North Carolina",
        "ND": "North Dakota", "OH": "Ohio", "OK": "Oklahoma", "OR": "Oregon", "PA": "Pennsylvania",
        "RI": "Rhode Island", "SC": "South Carolina", "SD": "South Dakota", "TN": "Tennessee", "TX": "Texas",
        "UT": "Utah", "VT": "Vermont", "VA": "Virginia", "WA": "Washington", "WV": "West Virginia",
        "WI": "Wisconsin", "WY": "Wyoming", "DC": "Washington DC"
    ]
}
