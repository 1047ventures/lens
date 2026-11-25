import Foundation
import ImageIO
import AVFoundation
import CoreLocation

/// What Lens knows about one photo or video beyond its size: the camera, when it was taken, and
/// where. Saved per drive next to the drive's file list (`Catalog/<drive>.facts.tsv`), so a drive
/// in the drawer can still be sorted by camera, date or place. The file list itself is untouched,
/// so older versions of Lens keep reading it.
struct FileFact: Hashable {
    var camera: String?
    var taken: Date?
    var lat: Double?
    var lon: Double?
    var place: String?
    /// The file's modified time when these were read, so a changed file is read again.
    var stamp: Int = 0
    /// Who is in it, only when the file's own notes say so (XMP "person in image", face-region names).
    var people: [String]?
    /// The scene, only from a real scene field (Blackmagic, XMP scene, QuickTime scene).
    var scene: String?
    /// True once people and scene have been looked for (saved lines with 9 columns). Not stored itself.
    var peopleRead = false

    var hasGPS: Bool { lat != nil && lon != nil }
}

enum FileFacts {
    static func url(for driveID: String) -> URL {
        DriveCatalog.folder.appendingPathComponent("\(driveID).facts.tsv")
    }

    // MARK: Saved facts

    /// Every saved fact for a drive, by the file's path on that drive.
    static func load(_ driveID: String) -> [String: FileFact] {
        guard let text = try? String(contentsOf: url(for: driveID), encoding: .utf8) else { return [:] }
        var out: [String: FileFact] = [:]
        text.enumerateLines { line, _ in
            let p = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 7 else { return }
            var fact = FileFact(camera: p[1].isEmpty ? nil : p[1],
                                taken: Double(p[2]).map { Date(timeIntervalSince1970: $0) },
                                lat: Double(p[3]), lon: Double(p[4]),
                                place: p[5].isEmpty ? nil : p[5],
                                stamp: Int(p[6]) ?? 0)
            // Lines saved by older versions have 7 columns: people and scene haven't been read yet.
            if p.count >= 8 {
                let names = p[7].split(separator: "|").map { String($0) }
                fact.people = names.isEmpty ? nil : names
            }
            if p.count >= 9 {
                fact.scene = p[8].isEmpty ? nil : p[8]
                fact.peopleRead = true
            }
            out[p[0]] = fact
        }
        return out
    }

    static func save(_ facts: [String: FileFact], driveID: String) {
        try? FileManager.default.createDirectory(at: DriveCatalog.folder, withIntermediateDirectories: true)
        var text = ""
        text.reserveCapacity(facts.count * 80)
        func clean(_ s: String?) -> String {
            (s ?? "").replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        }
        for (path, f) in facts {
            text += clean(path) + "\t" + clean(f.camera) + "\t"
            text += (f.taken.map { String(Int($0.timeIntervalSince1970)) } ?? "") + "\t"
            text += (f.lat.map { String(format: "%.5f", $0) } ?? "") + "\t"
            text += (f.lon.map { String(format: "%.5f", $0) } ?? "") + "\t"
            text += clean(f.place) + "\t" + String(f.stamp) + "\t"
            text += clean((f.people ?? []).map { $0.replacingOccurrences(of: "|", with: " ") }.joined(separator: "|")) + "\t"
            text += clean(f.scene) + "\n"
        }
        try? text.write(to: url(for: driveID), atomically: true, encoding: .utf8)
    }

    static func forget(_ driveID: String) {
        try? FileManager.default.removeItem(at: url(for: driveID))
    }

    // MARK: Bringing them up to date

    private static let running = RunningSet()

    /// Reads camera, date taken and GPS for every photo and video on a drive that Lens hasn't read
    /// yet (or that changed), names the places, and saves it all. `known` holds videos the scan just
    /// read in full, by full path, so they aren't opened twice. Runs in the background; a drive that
    /// is already being read is skipped.
    static func update(drive: CatalogDrive, base: String, known: [String: MediaFile] = [:]) async {
        guard await running.start(drive.id) else { return }
        defer { Task { await running.finish(drive.id) } }

        let rows = DriveCatalog.rows(on: drive)
        var facts = load(drive.id)
        let listed = Set(rows.map(\.path))
        // Files no longer on the drive drop out.
        facts = facts.filter { listed.contains($0.key) }

        var fresh = 0
        for row in rows where row.kind != .project {
            // Read again when the file changed, or when it was saved before people and scene were read.
            if let f = facts[row.path], f.stamp == row.modified, f.peopleRead { continue }
            let full = base.hasSuffix("/") ? base + row.path : base + "/" + row.path
            var fact: FileFact
            if let m = known[full] {
                fact = FileFact(camera: m.cameraModel, taken: m.captureDate, lat: m.gpsLatitude, lon: m.gpsLongitude,
                                place: m.locationLabel)
                let extra = await readVideoExtras(URL(fileURLWithPath: full))
                fact.people = extra.people
                fact.scene = extra.scene
            } else if row.kind == .photo {
                fact = autoreleasepool { readPhoto(URL(fileURLWithPath: full)) }
            } else {
                fact = await readVideo(URL(fileURLWithPath: full))
            }
            fact.stamp = row.modified
            fact.peopleRead = true
            facts[row.path] = fact
            fresh += 1
            // Save as it goes, so a big drive shows its details bit by bit.
            if fresh % 2000 == 0 {
                save(facts, driveID: drive.id)
                await LibraryIndex.shared.factsChanged()
            }
        }
        if fresh > 0 { save(facts, driveID: drive.id) }
        let named = await namePlaces(&facts)
        if named { save(facts, driveID: drive.id) }
        if fresh > 0 || named { await LibraryIndex.shared.factsChanged() }
    }

    /// Fills in place names for files that have GPS but no place yet. Asks Apple's map service a
    /// little at a time (it limits how often apps can ask) and remembers every answer on disk.
    static func namePlaces(_ facts: inout [String: FileFact], limit: Int = 150) async -> Bool {
        var changed = false
        var asked = 0
        for (path, f) in facts where f.place == nil && f.hasGPS {
            guard let lat = f.lat, let lon = f.lon else { continue }
            if let label = PlaceBook.shared.cached(lat, lon) {
                facts[path]?.place = label
                changed = true
                continue
            }
            if PlaceBook.shared.known(lat, lon) { continue }
            guard asked < limit else { continue }
            asked += 1
            if let label = await PlaceBook.shared.label(lat, lon) {
                facts[path]?.place = label
                changed = true
            }
        }
        return changed
    }

    // MARK: Reading one file

    /// Camera, date taken and GPS from a photo's EXIF (RAW files included). Reads only the header.
    static func readPhoto(_ url: URL) -> FileFact {
        var fact = FileFact()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any]
        else { return fact }

        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            fact.camera = cameraName(make: tiff[kCGImagePropertyTIFFMake] as? String,
                                     model: tiff[kCGImagePropertyTIFFModel] as? String)
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            let raw = (exif[kCGImagePropertyExifDateTimeOriginal] as? String)
                ?? (exif[kCGImagePropertyExifDateTimeDigitized] as? String)
            fact.taken = raw.flatMap(exifDate)
        }
        if fact.taken == nil, let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            fact.taken = (tiff[kCGImagePropertyTIFFDateTime] as? String).flatMap(exifDate)
        }
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String
            let la = latRef == "S" ? -abs(lat) : lat
            let lo = lonRef == "W" ? -abs(lon) : lon
            if !(la == 0 && lo == 0) { fact.lat = la; fact.lon = lo }
        }
        if let md = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            let found = xmpPeopleAndScene(md)
            fact.people = found.people
            fact.scene = found.scene
        }
        return fact
    }

    /// People and scene from a photo's XMP: PersonInImage, face-region names (MWG), and xmpDM:scene.
    /// Nothing else counts (no headline, no file names).
    static func xmpPeopleAndScene(_ md: CGImageMetadata) -> (people: [String]?, scene: String?) {
        var names: [String] = []
        var scene: String?
        func add(_ s: String?) {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
                  !names.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { return }
            names.append(t)
        }
        func text(_ tag: CGImageMetadataTag) -> String? { CGImageMetadataTagCopyValue(tag) as? String }
        func strings(_ tag: CGImageMetadataTag) -> [String] {
            let v = CGImageMetadataTagCopyValue(tag)
            if let s = v as? String { return [s] }
            if let arr = v as? [Any] {
                return arr.compactMap { el -> String? in
                    if let str = el as? String { return str }
                    let ref = el as CFTypeRef
                    return CFGetTypeID(ref) == CGImageMetadataTagGetTypeID() ? text(unsafeBitCast(ref, to: CGImageMetadataTag.self)) : nil
                }
            }
            return []
        }
        CGImageMetadataEnumerateTagsUsingBlock(md, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { path, tag in
            let p = path as String
            let name = (CGImageMetadataTagCopyName(tag) as String?) ?? ""
            if p.hasPrefix("Iptc4xmpExt:PersonInImage") && name == "PersonInImage" {
                strings(tag).forEach { add($0) }
            } else if p.hasPrefix("mwg-rs:Regions") && name == "Name" && (p.hasSuffix(".Name") || p.hasSuffix("/mwg-rs:Name")) {
                add(text(tag))
            } else if p == "xmpDM:scene" {
                if scene == nil, let t = text(tag)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { scene = t }
            }
            return true
        }
        return (names.isEmpty ? nil : names, scene)
    }

    /// Camera, date taken and GPS from a video's own notes, without reading its picture.
    static func readVideo(_ url: URL) async -> FileFact {
        var fact = FileFact()
        let asset = AVURLAsset(url: url)
        if let created = try? await asset.load(.creationDate), let date = try? await created.load(.dateValue) {
            fact.taken = date
        }
        guard let metadata = try? await asset.load(.metadata) else { return fact }
        var make: String?, model: String?
        for item in metadata {
            if item.commonKey == .commonKeyMake { make = try? await item.load(.stringValue) }
            if item.commonKey == .commonKeyModel { model = try? await item.load(.stringValue) }
            if VideoMetadataService.isLocation(item), let value = try? await item.load(.stringValue),
               let coords = VideoMetadataService.parseISO6709(value) {
                fact.lat = coords.lat
                fact.lon = coords.lon
            }
        }
        fact.camera = cameraName(make: make, model: model)
        let extra = await readVideoExtras(url, asset: asset)
        fact.people = extra.people
        fact.scene = extra.scene
        if fact.camera == nil || fact.taken == nil {
            let note = cameraNote(for: url)
            fact.camera = fact.camera ?? note.camera
            fact.taken = fact.taken ?? note.taken
        }
        return fact
    }

    /// Scene and people from the notes AVFoundation shows for a video. Unknown keys are ignored.
    /// Scene: Blackmagic keys (with take, "Scene 3, take 2"), xmpDM:scene, com.apple.quicktime.scene.
    /// People: XMP "person in image" if it is embedded.
    static func readVideoExtras(_ url: URL, asset: AVURLAsset? = nil) async -> (people: [String]?, scene: String?) {
        let asset = asset ?? AVURLAsset(url: url)
        var items: [AVMetadataItem] = []
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for f in formats { if let m = try? await asset.loadMetadata(for: f) { items += m } }
        }
        if items.isEmpty, let m = try? await asset.load(.metadata) { items = m }

        var people: [String] = []
        func addPerson(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, !people.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) { people.append(t) }
        }
        var scene: String?, take: String?, bmScene: String?, xmpScene: String?, qtScene: String?
        for item in items {
            func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
            let id = squash(item.identifier?.rawValue ?? "")
            let key = squash((item.key as? String) ?? "")
            let both = id + " " + key
            var text = try? await item.load(.stringValue)
            if text == nil, let n = try? await item.load(.numberValue) { text = n.stringValue }
            guard let v = text?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { continue }
            if both.contains("blackmagic") && both.contains("scene") { bmScene = bmScene ?? v }
            else if both.contains("blackmagic") && both.contains("take") { take = take ?? v }
            else if both.contains("xmpdm") && both.contains("scene") { xmpScene = xmpScene ?? v }
            else if both.contains("quicktime") && both.contains("scene") { qtScene = qtScene ?? v }
            else if both.contains("personinimage") {
                if v.contains("<") {
                    xmlItems(v, tag: "rdf:li").forEach(addPerson)
                } else {
                    v.split(whereSeparator: { "|;\n".contains($0) }).forEach { addPerson(String($0)) }
                }
            }
            // A whole XMP packet kept as a note.
            if v.contains("<x:xmpmeta") || v.contains("<rdf:RDF") {
                if let r = v.range(of: "PersonInImage") {
                    xmlItems(String(v[r.upperBound...].prefix(2000)), tag: "rdf:li").forEach(addPerson)
                }
                if xmpScene == nil, let s = xmlItems(v, tag: "xmpDM:scene").first { xmpScene = s }
            }
        }
        if let b = bmScene {
            scene = (take?.isEmpty == false) ? "Scene \(b.replacingOccurrences(of: "Scene ", with: "")), take \(take!)" : b
        } else {
            scene = xmpScene ?? qtScene
        }
        return (people.isEmpty ? nil : people, scene)
    }

    /// Text inside each <tag>…</tag> (simple, for small XMP snippets).
    private static func xmlItems(_ s: String, tag: String) -> [String] {
        var out: [String] = []
        var rest = Substring(s)
        while let a = rest.range(of: "<\(tag)"), let gt = rest[a.upperBound...].firstIndex(of: ">"),
              let end = rest[gt...].range(of: "</\(tag)>") {
            let t = rest[rest.index(after: gt)..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(t) }
            rest = rest[end.upperBound...]
        }
        return out
    }

    /// Sony cameras (FX3, FX6, A7 series) keep the camera model in a small notes file beside each
    /// clip ("C0001M01.XML"), not inside the video. Reads that when it's there.
    static func cameraNote(for video: URL) -> (camera: String?, taken: Date?) {
        let base = video.deletingPathExtension()
        for ext in ["XML", "xml"] {
            let note = base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + "M01." + ext)
            guard let text = try? String(contentsOf: note, encoding: .utf8) else { continue }
            func attribute(_ tag: String, _ name: String) -> String? {
                guard let tagRange = text.range(of: "<\(tag) ") else { return nil }
                let rest = text[tagRange.upperBound...].prefix(600)
                guard let r = rest.range(of: name + "=\""), let end = rest[r.upperBound...].firstIndex(of: "\"") else { return nil }
                return String(rest[r.upperBound..<end])
            }
            let camera = cameraName(make: attribute("Device", "manufacturer"), model: attribute("Device", "modelName"))
            let taken = attribute("CreationDate", "value").flatMap { ISO8601DateFormatter().date(from: $0) }
            return (camera, taken)
        }
        return (nil, nil)
    }

    /// "Sony ILME-FX3", without saying the maker twice ("Canon Canon EOS R5" → "Canon EOS R5").
    static func cameraName(make: String?, model: String?) -> String? {
        let make = make?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let model = model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard let model else { return make.map(tidyMaker) }
        guard let make else { return model }
        let maker = tidyMaker(make)
        if model.lowercased().hasPrefix(maker.lowercased()) || model.lowercased().hasPrefix(make.lowercased()) { return model }
        return "\(maker) \(model)"
    }

    /// "NIKON CORPORATION" → "Nikon", "SONY" → "Sony".
    private static func tidyMaker(_ make: String) -> String {
        let first = make.split(separator: " ").first.map(String.init) ?? make
        return first.count <= 3 ? first.uppercased() : first.capitalized
    }

    private static func exifDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: s)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Keeps two reads of the same drive from running at once.
private actor RunningSet {
    private var ids: Set<String> = []
    func start(_ id: String) -> Bool { ids.insert(id).inserted }
    func finish(_ id: String) { ids.remove(id) }
}

// MARK: - Place names

/// Turns GPS into "Austin, TX" and remembers every answer on disk (`Catalog/places.json`), so a
/// place is only ever looked up once. Lookups are spaced out, because Apple's map service turns
/// away apps that ask too often; when it does, Lens waits a few minutes before asking again.
final class PlaceBook: @unchecked Sendable {
    static let shared = PlaceBook()

    private let lock = NSLock()
    /// Rounded coordinate → place. An empty string means "looked, nothing there" (out at sea, say).
    private var places: [String: String] = [:]
    private var pausedUntil = Date.distantPast
    private let gate = PlaceGate()

    private static var fileURL: URL { DriveCatalog.folder.appendingPathComponent("places.json") }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            places = saved
        }
    }

    /// About a kilometre across: close enough for a town name.
    static func key(_ lat: Double, _ lon: Double) -> String { String(format: "%.2f,%.2f", lat, lon) }

    /// The place, if Lens already knows it.
    func cached(_ lat: Double, _ lon: Double) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let p = places[Self.key(lat, lon)], !p.isEmpty else { return nil }
        return p
    }

    /// True once Lens has asked about this spot (whether or not there was an answer).
    func known(_ lat: Double, _ lon: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return places[Self.key(lat, lon)] != nil
    }

    /// Looks the place up (or returns what's remembered). Never takes more than a few seconds per
    /// spot and returns nil when offline or turned away, without remembering that as "nowhere".
    func label(_ lat: Double, _ lon: Double) async -> String? {
        if let p = cached(lat, lon) { return p }
        if known(lat, lon) { return nil }
        return await gate.run { [self] in
            // Another lookup may have answered this while we waited our turn.
            if let p = cached(lat, lon) { return p }
            if known(lat, lon) { return nil }
            if isPaused() { return nil }
            let result = await Self.reverseGeocode(lat, lon)
            remember(result, lat, lon)
            if case .found(let label) = result { return label }
            return nil
        }
    }

    // MARK: A project's place, as typed

    private static func textKey(_ text: String) -> String { "text:" + text.lowercased().trimmingCharacters(in: .whitespaces) }

    /// "Boulder, CO" for a typed place like "Chautauqua Park, Boulder", if Lens has looked it up.
    func cached(text: String) -> String? {
        lock.withLock {
            guard let p = places[Self.textKey(text)], !p.isEmpty else { return nil }
            return p
        }
    }

    func known(text: String) -> Bool { lock.withLock { places[Self.textKey(text)] != nil } }

    /// Where a typed place is on the map, if Lens has looked it up. Kept so the Library map can
    /// place a shoot whose photos have no GPS without asking the map service at every launch.
    func position(text: String) -> (lat: Double, lon: Double)? {
        lock.withLock {
            guard let raw = places["pos:" + Self.textKey(text)] else { return nil }
            let parts = raw.split(separator: ",").compactMap { Double($0) }
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
    }

    /// True when the typed place still needs looking up: never asked, asked before positions were kept,
    /// or not found before Lens knew to try just the town ("Planet Bluegrass, Lyons" → "Lyons").
    func needsLookup(text: String) -> Bool {
        lock.withLock {
            let key = Self.textKey(text)
            guard let label = places[key] else { return true }
            if label.isEmpty { return places["town:" + key] == nil }
            return places["pos:" + key] == nil
        }
    }

    /// Near the places Lens already knows, so "Lyons" means the one down the road, not the one in France.
    private func nearby() -> CLCircularRegion? {
        let spots: [(Double, Double)] = lock.withLock {
            places.compactMap { k, v in
                guard k.hasPrefix("pos:") else { return nil }
                let parts = v.split(separator: ",").compactMap { Double($0) }
                return parts.count == 2 ? (parts[0], parts[1]) : nil
            }
        }
        guard !spots.isEmpty else { return nil }
        let lat = spots.map(\.0).reduce(0, +) / Double(spots.count)
        let lon = spots.map(\.1).reduce(0, +) / Double(spots.count)
        return CLCircularRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lon), radius: 400_000, identifier: "nearby")
    }

    /// Looks up a typed place on Apple's map service to find its town and state. Remembered on disk.
    func label(text: String) async -> String? {
        if !needsLookup(text: text) { return cached(text: text) }
        return await gate.run { [self] in
            if !needsLookup(text: text) { return cached(text: text) }
            if isPaused() { return nil }
            var spot: CLLocationCoordinate2D?
            let near = nearby()
            var result = await Self.geocode(text, near: near) { spot = $0 }
            // A venue the map service doesn't know ("Planet Bluegrass, Lyons"): try the town after the comma.
            if case .nowhere = result, let comma = text.firstIndex(of: ",") {
                let town = text[text.index(after: comma)...].trimmingCharacters(in: .whitespaces)
                if !town.isEmpty { result = await Self.geocode(town, near: near) { spot = $0 } }
            }
            let key = Self.textKey(text)
            let snapshot: [String: String]? = lock.withLock {
                switch result {
                case .found(let label):
                    places[key] = label
                    if let spot { places["pos:" + key] = String(format: "%.5f,%.5f", spot.latitude, spot.longitude) }
                case .nowhere: places[key] = ""; places["town:" + key] = "1"
                case .turnedAway: pausedUntil = Date().addingTimeInterval(180); return nil
                case .failed: return nil
                }
                return places
            }
            if let snapshot { Self.write(snapshot) }
            if case .found(let label) = result { return label }
            return nil
        }
    }

    @MainActor
    private static func geocode(_ text: String, near: CLRegion? = nil, timeout: TimeInterval = 5,
                                at spot: @escaping (CLLocationCoordinate2D) -> Void) async -> Answer {
        let geocoder = CLGeocoder()
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { geocoder.cancelGeocode() }
        return await withCheckedContinuation { continuation in
            geocoder.geocodeAddressString(text, in: near) { placemarks, error in
                if let c = placemarks?.first?.location?.coordinate { spot(c) }
                continuation.resume(returning: answer(placemarks, error))
            }
        }
    }

    private static func answer(_ placemarks: [CLPlacemark]?, _ error: Error?) -> Answer {
        if let error = error as? CLError {
            switch error.code {
            case .network: return .turnedAway
            case .geocodeFoundNoResult, .geocodeFoundPartialResult: return .nowhere
            default: return .failed
            }
        }
        guard let mark = placemarks?.first else { return .nowhere }
        let city = mark.locality ?? mark.subAdministrativeArea
        let region = mark.administrativeArea ?? mark.country
        let label = [city, region].compactMap { $0 }.joined(separator: ", ")
        return label.isEmpty ? .nowhere : .found(label)
    }

    private func isPaused() -> Bool {
        lock.withLock { pausedUntil > Date() }
    }

    private func remember(_ result: Answer, _ lat: Double, _ lon: Double) {
        let snapshot: [String: String]? = lock.withLock {
            switch result {
            case .found(let label): places[Self.key(lat, lon)] = label
            case .nowhere: places[Self.key(lat, lon)] = ""
            case .turnedAway: pausedUntil = Date().addingTimeInterval(180); return nil
            case .failed: return nil
            }
            return places
        }
        if let snapshot { Self.write(snapshot) }
    }

    private static func write(_ places: [String: String]) {
        try? FileManager.default.createDirectory(at: DriveCatalog.folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(places) { try? data.write(to: fileURL, options: .atomic) }
    }

    private enum Answer { case found(String), nowhere, turnedAway, failed }

    /// CLGeocoder only calls back on a thread with a run loop and can stall when offline, so it runs
    /// on the main thread and gives up after a few seconds.
    @MainActor
    private static func reverseGeocode(_ lat: Double, _ lon: Double, timeout: TimeInterval = 5) async -> Answer {
        let geocoder = CLGeocoder()
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { geocoder.cancelGeocode() }
        return await withCheckedContinuation { continuation in
            geocoder.reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon)) { placemarks, error in
                continuation.resume(returning: answer(placemarks, error))
            }
        }
    }
}

/// Place lookups start at least a second apart.
private actor PlaceGate {
    private var last = Date.distantPast

    func run(_ work: @escaping () async -> String?) async -> String? {
        // Book the next slot before waiting, so calls that arrive together still go one by one.
        let slot = max(Date(), last.addingTimeInterval(1.1))
        last = slot
        let wait = slot.timeIntervalSinceNow
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        return await work()
    }
}
