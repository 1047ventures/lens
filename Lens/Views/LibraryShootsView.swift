import SwiftUI
import AppKit
import CoreLocation

// MARK: - A shoot, as the Library shows it

/// One project's photos and videos, wherever they are, with what the Library sorts by.
struct Shoot: Identifiable {
    let project: Project
    var folders: [Int] = []
    var photos = 0, videos = 0
    var bytes: Int64 = 0
    var first: Date?
    var cameras: [String: Int] = [:]
    var places: [String: Int] = [:]
    var drives: [String: Int] = [:]
    /// A few items to show as pictures on the card (positions in `LibraryIndex.items`).
    var sample: [Int] = []
    var price: Double?
    var paid = false
    /// Where it goes on the map: where most of its photos were taken, or else the project's place.
    var spot: CLLocationCoordinate2D?

    var id: UUID { project.id }
    var date: Date? { project.shootDate ?? first }
    /// The project's own place (with the state filled in from the map service or the photos' GPS
    /// when she only typed the town), or else where most of its photos and videos were taken.
    var place: PlaceName? { Self.place(of: project, files: places) }

    /// One place for a project everywhere in the Library: what she typed, read by the map service
    /// when it has no state, or else where most of its photos and videos were taken.
    static func place(of project: Project, files places: [String: Int]) -> PlaceName? {
        let common = PlaceName.common(places)
        guard let typed = PlaceName.parse(project.location) else { return common }
        // When she typed no state, Apple's map service read her words for us ("Boulder Creek" is in Boulder, CO).
        if typed.state == nil, let looked = PlaceBook.shared.cached(text: project.location).flatMap(PlaceName.parse) {
            return looked
        }
        return typed.filled(from: common)
    }
    var isCurrent: Bool { project.stage != .paid && project.stage != .archived }
    var people: [String] {
        var names = (project.people ?? []).map(\.name)
        let client = project.client.trimmingCharacters(in: .whitespaces)
        if !client.isEmpty { names.insert(client, at: 0) }
        var seen = Set<String>()
        return names.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
    var cameraList: [String] { cameras.sorted { $0.value > $1.value }.map(\.key) }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case project, date, place, people, camera, current, price, paid, kind, drive
    var id: String { rawValue }
    var label: String {
        switch self {
        case .project: return "Project"
        case .date: return "Date"
        case .place: return "Place"
        case .people: return "People"
        case .camera: return "Camera"
        case .current: return "Current or past"
        case .price: return "Price"
        case .paid: return "Paid or not"
        case .kind: return "Photo or video"
        case .drive: return "Drive"
        }
    }
}

struct ShootGroup: Identifiable {
    let id: String
    let title: String?
    var shoots: [Shoot]
}

struct ShootSection: Identifiable {
    let id: String
    let title: String?
    var groups: [ShootGroup]
}

// MARK: - The shoots part of the Library

/// The heart of Library: one card per shoot, sorted the way she asks, then the folders that
/// aren't part of any shoot yet, with Lens's best guess for each. Everything adds a list of every file.
struct LibraryShootsView: View {
    let query: String
    /// Opens a shoot or folder in the Library (pins on the map can't hold a navigation link).
    let open: (FootageRoute) -> Void

    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var money: MoneyStore
    @EnvironmentObject private var deals: DealStore
    @EnvironmentObject private var appearance: Appearance
    @EnvironmentObject private var navigator: Navigator
    @ObservedObject private var index = LibraryIndex.shared
    @ObservedObject private var links = LibraryLinks.shared
    @ObservedObject private var catalog = DriveCatalog.shared
    @AppStorage("library.sort") private var sortRaw = LibrarySort.date.rawValue
    /// "map" (the default) or "list".
    @AppStorage("library.view") private var viewRaw = "map"
    @State private var showAllLoose = false
    /// Goes up when the map service names a project's place, so the cards redraw.
    @State private var placesFound = 0

    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .date }

    var body: some View {
        let shelf = index.shelf(projects: projects.projects, links: links, catalog: catalog)
        let shoots = makeShoots(shelf)
        let shown = filtered(shoots)
        let _ = placesFound
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    viewSwitch
                    if viewRaw != "map" { sortBar }
                }
                if viewRaw == "map" && !(index.loading && index.items.isEmpty) {
                    let waiting = waitingProjects(shoots)
                    LibraryMapView(pins: mapPins(shown, waiting, shelf)) { target in
                        switch target {
                        case .library(let route): open(route)
                        case .project(let id): navigator.openProject(id)
                        }
                    }
                    noPlaceStrip(shown, waiting)
                } else if index.loading && index.items.isEmpty {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading your drives…") }
                        .font(Theme.font(size: 13)).foregroundStyle(Theme.muted)
                } else if shoots.isEmpty {
                    emptyShoots
                } else if shown.isEmpty {
                    Text("No shoot matches that.").font(Theme.font(size: 14)).foregroundStyle(Theme.muted).panel(padding: 20)
                } else {
                    ForEach(sections(shown)) { section in sectionView(section) }
                }
            }
            loosePile(shelf)
            if !appearance.simple {
                LibraryFileTable(query: query, shelf: shelf)
            }
        }
        .onAppear { index.start() }
        .task(id: projects.projects.map(\.location).joined(separator: "|")) { await lookUpPlaces() }
    }

    /// Looks up each project's typed place once (town, state and where it is on the map) and
    /// remembers it on disk, so the map never waits on the map service at launch.
    /// Each find shows on the map straight away. Places the map service didn't answer (busy, offline,
    /// asked too often) are tried again a little later, a few times, while the Library is open.
    private func lookUpPlaces() async {
        for attempt in 0..<4 {
            var waiting = false
            for p in projects.projects {
                let text = p.location.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty, PlaceBook.shared.needsLookup(text: text) else { continue }
                if await PlaceBook.shared.label(text: text) != nil { placesFound += 1 }
                if Task.isCancelled { return }
                if PlaceBook.shared.needsLookup(text: text) { waiting = true }
            }
            guard waiting, attempt < 3 else { return }
            try? await Task.sleep(for: .seconds(75))
            if Task.isCancelled { return }
        }
    }

    // MARK: Map or list

    private var viewSwitch: some View {
        HStack(spacing: 2) {
            ForEach([("map", "Map", "map"), ("list", "List", "square.grid.2x2")], id: \.0) { key, title, icon in
                let on = (viewRaw == "map") == (key == "map")
                Button { viewRaw = key } label: {
                    Label(title, systemImage: icon)
                        .font(Theme.font(size: 13, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.onTeal : Theme.text2)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(on ? Theme.teal : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.panel))
        .overlay(Capsule().stroke(Theme.line))
    }

    /// Projects with no footage found yet, which still belong on the map from day one (matching the search).
    private func waitingProjects(_ shoots: [Shoot]) -> [Project] {
        let have = Set(shoots.map(\.id))
        let words = query.lowercased().split(separator: " ").map(String.init)
        return projects.projects.filter { p in
            guard !have.contains(p.id) else { return false }
            let text = [p.name, p.client, p.location].joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    private func placeSpot(_ project: Project) -> CLLocationCoordinate2D? {
        PlaceBook.shared.position(text: project.location).map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    /// Shoots where they happened, projects at their typed place, and loose folders whose photos say where they were taken.
    private func mapPins(_ shoots: [Shoot], _ waiting: [Project], _ shelf: Shelf) -> [MapPin] {
        var pins: [MapPin] = shoots.compactMap { s in
            guard let spot = s.spot else { return nil }
            return MapPin(id: s.id.uuidString, coordinate: spot, title: s.project.name, sample: s.sample.first,
                          target: .library(.shoot(s.id)), isShoot: true,
                          date: s.date, detail: Self.whenWho(s.date, s.project.client),
                          counts: Self.counts(photos: s.photos, videos: s.videos), stage: s.project.stage.label)
        }
        for p in waiting {
            guard let spot = placeSpot(p) else { continue }
            pins.append(MapPin(id: p.id.uuidString, coordinate: spot, title: p.name, sample: nil,
                               target: .library(.shoot(p.id)), isShoot: true,
                               date: p.shootDate, detail: Self.whenWho(p.shootDate, p.client),
                               counts: "No photos or videos found yet", stage: p.stage.label))
        }
        for i in shelf.unsorted where index.folders.indices.contains(i) {
            let f = index.folders[i]
            guard matchesQuery(f) else { continue }
            let items = f.items.compactMap { index.items.indices.contains($0) ? index.items[$0] : nil }
            guard let spot = MapSpot.common(items) else { continue }
            let sample = f.items.first { index.items.indices.contains($0) && index.items[$0].kind == .photo } ?? f.items.first
            pins.append(MapPin(id: f.id, coordinate: spot, title: f.name, sample: sample,
                               target: .library(f.isPhotosDay ? .unsorted(driveID: f.driveID, folder: f.folder)
                                                              : .folder(driveID: f.driveID, path: f.folder)),
                               isShoot: false,
                               date: f.first == .distantFuture ? nil : f.first,
                               detail: Self.whenWho(f.first == .distantFuture ? nil : f.first, driveName(f.driveID)),
                               counts: Self.counts(photos: f.photos, videos: f.videos)))
        }
        return pins
    }

    private static func whenWho(_ date: Date?, _ who: String) -> String {
        var parts: [String] = []
        if let date { parts.append(date.formatted(.dateTime.month(.abbreviated).day().year())) }
        let who = who.trimmingCharacters(in: .whitespaces)
        if !who.isEmpty { parts.append(who) }
        return parts.joined(separator: " · ")
    }

    private static func counts(photos: Int, videos: Int) -> String {
        var parts: [String] = []
        if photos > 0 { parts.append("\(photos.formatted()) photo\(photos == 1 ? "" : "s")") }
        if videos > 0 { parts.append("\(videos.formatted()) video\(videos == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// Shoots Lens can't place yet, so they aren't missing from the map without a word.
    @ViewBuilder
    private func noPlaceStrip(_ shoots: [Shoot], _ waiting: [Project]) -> some View {
        let unplaced: [(id: UUID, name: String, target: MapTarget)] =
            shoots.filter { $0.spot == nil }.sorted(by: newestFirst).map { ($0.id, $0.project.name, .library(.shoot($0.id))) }
            + waiting.filter { placeSpot($0) == nil }.map { ($0.id, $0.name, .library(.shoot($0.id))) }
        if !unplaced.isEmpty {
            HStack(alignment: .center, spacing: 10) {
                Text("No place yet").font(Theme.font(size: 13, weight: .semibold)).foregroundStyle(Theme.text3)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(unplaced, id: \.id) { s in
                            Button {
                                switch s.target {
                                case .library(let route): open(route)
                                case .project(let id): navigator.openProject(id)
                                }
                            } label: {
                                Text(s.name)
                                    .font(Theme.font(size: 13)).foregroundStyle(Theme.text2)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(Capsule().fill(Theme.panel))
                                    .overlay(Capsule().stroke(Theme.line))
                            }
                            .buttonStyle(.plain)
                            .help("Add a place to this project, or photos with GPS, and it shows on the map")
                        }
                    }
                    .padding(1)
                }
            }
        }
    }

    // MARK: Sort bar

    private var sortBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Sort by").font(Theme.font(size: 13, weight: .semibold)).foregroundStyle(Theme.text3)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(LibrarySort.allCases) { option in
                        let on = option == sort
                        Button { sortRaw = option.rawValue } label: {
                            Text(option.label)
                                .font(Theme.font(size: 13, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? Theme.onTeal : Theme.text2)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(on ? Theme.teal : Theme.panel)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(on ? Color.clear : Theme.line))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(1)
            }
        }
    }

    private var emptyShoots: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No shoots in the Library yet").font(Theme.font(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            Text(index.items.isEmpty
                 ? "Add a drive below and Lens will read what's on it. Shoots show up here once a project's footage folder is on a drive Lens knows."
                 : "Your photos and videos are below. Tell Lens which project each folder is from and it becomes a shoot here.")
                .font(Theme.font(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 20)
    }

    private func sectionView(_ section: ShootSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = section.title {
                Text(title).font(Theme.font(size: 18, weight: .bold)).foregroundStyle(Theme.text)
            }
            ForEach(section.groups) { group in
                VStack(alignment: .leading, spacing: 10) {
                    if let title = group.title {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            SectionLabel(title)
                            Text("\(group.shoots.count)").font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
                        }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                        ForEach(group.shoots) { shoot in
                            NavigationLink(value: FootageRoute.shoot(shoot.id)) { ShootCard(shoot: shoot, sort: sort) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: Building the shoots

    private func makeShoots(_ shelf: Shelf) -> [Shoot] {
        var out: [Shoot] = []
        for project in projects.projects {
            guard let folderIDs = shelf.byProject[project.id], !folderIDs.isEmpty else { continue }
            var s = Shoot(project: project, folders: folderIDs)
            var photoSample: [Int] = [], videoSample: [Int] = []
            for fi in folderIDs where index.folders.indices.contains(fi) {
                let f = index.folders[fi]
                s.photos += f.photos; s.videos += f.videos; s.bytes += f.bytes
                s.first = min(s.first ?? f.first, f.first)
                s.drives[f.driveID, default: 0] += f.items.count
                for ii in f.items where index.items.indices.contains(ii) {
                    let item = index.items[ii]
                    if let c = item.camera { s.cameras[c, default: 0] += 1 }
                    if let p = item.place { s.places[p, default: 0] += 1 }
                    if item.kind == .photo, photoSample.count < 3 { photoSample.append(ii) }
                    if item.kind == .video, videoSample.count < 3 { videoSample.append(ii) }
                }
            }
            s.sample = Array((photoSample + videoSample).prefix(3))
            let items = folderIDs.flatMap { fi in index.folders.indices.contains(fi) ? index.folders[fi].items : [] }
                .compactMap { index.items.indices.contains($0) ? index.items[$0] : nil }
            s.spot = MapSpot.common(items)
                ?? PlaceBook.shared.position(text: project.location).map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            s.price = ProjectBooks.make(project, money: money, deals: deals).price
            let bills = money.receivables.filter { $0.projectID == project.id }
            s.paid = project.stage == .paid || project.stage == .archived
                || (!bills.isEmpty && bills.allSatisfy { $0.paidOn != nil })
            out.append(s)
        }
        return out
    }

    /// The search box at the top narrows the shoots too: by name, client, place, people or camera.
    private func filtered(_ shoots: [Shoot]) -> [Shoot] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return shoots }
        return shoots.filter { s in
            let text = ([s.project.name, s.project.client, s.project.location, s.place?.label ?? ""]
                        + s.people + s.cameraList + Array(s.places.keys)).joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    private func newestFirst(_ a: Shoot, _ b: Shoot) -> Bool {
        (a.date ?? .distantPast) > (b.date ?? .distantPast)
    }

    private func grouped(_ shoots: [Shoot], by keys: (Shoot) -> [String], none: String,
                         order: ((String, String) -> Bool)? = nil) -> [ShootGroup] {
        var groups: [String: [Shoot]] = [:]
        for s in shoots {
            let k = keys(s)
            for key in (k.isEmpty ? [none] : k) { groups[key, default: []].append(s) }
        }
        let names = groups.keys.sorted { a, b in
            if a == none { return false }
            if b == none { return true }
            return order?(a, b) ?? (a.localizedStandardCompare(b) == .orderedAscending)
        }
        return names.map { ShootGroup(id: $0, title: $0, shoots: groups[$0]!.sorted(by: newestFirst)) }
    }

    private func sections(_ shoots: [Shoot]) -> [ShootSection] {
        func one(_ groups: [ShootGroup]) -> [ShootSection] { [ShootSection(id: "all", title: nil, groups: groups)] }
        switch sort {
        case .project:
            return one([ShootGroup(id: "all", title: nil, shoots: shoots.sorted {
                $0.project.name.localizedStandardCompare($1.project.name) == .orderedAscending })])
        case .date:
            // A year at a time, newest first. Each card shows its own date.
            let byYear = Dictionary(grouping: shoots) { s in s.date.map { Calendar.current.component(.year, from: $0) } }
            let keys = byYear.keys.sorted { ($0 ?? Int.min) > ($1 ?? Int.min) }
            return one(keys.map { k in
                ShootGroup(id: k.map(String.init) ?? "none", title: k.map(String.init) ?? "No date yet",
                           shoots: byYear[k]!.sorted(by: newestFirst))
            })
        case .place:
            // A state at a time, then town by town. Each card shows its town.
            let none = "Place not known", other = "Other places"
            let byState = Dictionary(grouping: shoots) { $0.place?.state ?? ($0.place?.city == nil ? none : other) }
            let states = byState.keys.sorted { a, b in
                let rank = { (s: String) in s == none ? 2 : s == other ? 1 : 0 }
                if rank(a) != rank(b) { return rank(a) < rank(b) }
                return a.localizedStandardCompare(b) == .orderedAscending
            }
            return one(states.map { state in
                ShootGroup(id: state, title: state, shoots: byState[state]!.sorted { a, b in
                    let ca = a.place?.city ?? "~", cb = b.place?.city ?? "~"
                    if ca != cb { return ca.localizedStandardCompare(cb) == .orderedAscending }
                    return newestFirst(a, b)
                })
            })
        case .people:
            return one(grouped(shoots, by: \.people, none: "No people listed"))
        case .camera:
            return one(grouped(shoots, by: \.cameraList, none: "Camera not known"))
        case .current:
            return one(grouped(shoots, by: { [$0.isCurrent ? "Current" : "Past"] }, none: "",
                               order: { a, _ in a == "Current" }))
        case .price:
            let priced = shoots.filter { $0.price != nil }.sorted { ($0.price ?? 0) > ($1.price ?? 0) }
            let unpriced = shoots.filter { $0.price == nil }.sorted(by: newestFirst)
            var groups = [ShootGroup(id: "priced", title: priced.isEmpty ? nil : "Highest first", shoots: priced)]
            if !unpriced.isEmpty { groups.append(ShootGroup(id: "unpriced", title: "No price yet", shoots: unpriced)) }
            return one(groups.filter { !$0.shoots.isEmpty })
        case .paid:
            return one(grouped(shoots, by: { [$0.paid ? "Paid" : "Not paid yet"] }, none: "",
                               order: { a, _ in a == "Not paid yet" }))
        case .kind:
            let names = ["Photos and video", "Video only", "Photos only"]
            return one(grouped(shoots, by: { s in
                [s.photos > 0 && s.videos > 0 ? names[0] : s.videos > 0 ? names[1] : names[2]]
            }, none: "", order: { a, b in (names.firstIndex(of: a) ?? 9) < (names.firstIndex(of: b) ?? 9) }))
        case .drive:
            return one(grouped(shoots, by: { s in s.drives.keys.map(driveName) }, none: "Drive not known"))
        }
    }

    private func driveName(_ id: String) -> String { catalog.drives.first { $0.id == id }?.name ?? "A drive" }

    // MARK: Not sorted yet

    @ViewBuilder
    private func loosePile(_ shelf: Shelf) -> some View {
        let all = shelf.unsorted.compactMap { index.folders.indices.contains($0) ? index.folders[$0] : nil }
            .filter { matchesQuery($0) }
            .sorted { $0.first > $1.first }
        if !all.isEmpty {
            let limit = showAllLoose ? all.count : 24
            let shown = Array(all.prefix(limit))
            let month = DateFormatter()
            let _ = { month.dateFormat = "MMMM yyyy" }()
            let months = Dictionary(grouping: shown) { month.string(from: $0.first == .distantFuture ? Date.distantPast : $0.first) }
            let order = months.keys.sorted { (months[$0]?.first?.first ?? .distantPast) > (months[$1]?.first?.first ?? .distantPast) }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SectionLabel("Not sorted yet")
                    Text("\(all.count) folder\(all.count == 1 ? "" : "s")").font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
                }
                Text("Photos and videos that aren't part of a project. Say which shoot each folder is from and it joins that shoot.")
                    .font(Theme.font(size: 13)).foregroundStyle(Theme.muted)
                ForEach(order, id: \.self) { m in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(m).font(Theme.font(size: 13, weight: .semibold)).foregroundStyle(Theme.text2)
                            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 6)
                        ForEach(months[m] ?? []) { folder in
                            Divider().overlay(Theme.lineSoft)
                            LooseFolderRow(folder: folder)
                        }
                    }
                    .background(Theme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
                }
                if all.count > limit || showAllLoose {
                    Button(showAllLoose ? "Show fewer" : "Show all \(all.count)") { showAllLoose.toggle() }
                        .buttonStyle(.link).font(Theme.font(size: 13))
                }
            }
        }
    }

    private func matchesQuery(_ f: LibraryFolder) -> Bool {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return true }
        let text = (f.folder + " " + driveName(f.driveID)).lowercased()
        return words.allSatisfy { text.contains($0) }
    }
}

// MARK: - Shoot card

private struct ShootCard: View {
    let shoot: Shoot
    let sort: LibrarySort
    @ObservedObject private var index = LibraryIndex.shared
    @ObservedObject private var catalog = DriveCatalog.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    if i < shoot.sample.count, index.items.indices.contains(shoot.sample[i]) {
                        let item = index.items[shoot.sample[i]]
                        Thumbnail(url: LibraryFiles.url(of: item, catalog: catalog), assetID: item.assetID, kind: item.kind)
                            .frame(maxWidth: .infinity).frame(height: 64)
                            .background(Theme.raised)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        RoundedRectangle(cornerRadius: 6).fill(Theme.raised).frame(maxWidth: .infinity).frame(height: 64)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(shoot.project.name).font(Theme.font(size: 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 6)
                    badge
                }
                Text(whenWhere).font(Theme.font(size: 12)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Text(counts).font(Theme.font(size: 12)).foregroundStyle(Theme.text2).monospacedDigit()
            if let extra { Text(extra).font(Theme.font(size: 12)).foregroundStyle(Theme.muted).lineLimit(1) }
            HStack(spacing: 6) {
                ForEach(shoot.drives.keys.sorted(), id: \.self) { id in driveChip(id) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
        .contentShape(Rectangle())
    }

    private var whenWhere: String {
        var parts: [String] = []
        if let d = shoot.date { parts.append(d.formatted(.dateTime.month(.abbreviated).day().year())) }
        if let p = shoot.place?.label, !p.isEmpty { parts.append(p) }
        if parts.isEmpty, !shoot.project.client.isEmpty { parts.append(shoot.project.client) }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    private var counts: String {
        var parts: [String] = []
        if shoot.photos > 0 { parts.append("\(shoot.photos.formatted()) photo\(shoot.photos == 1 ? "" : "s")") }
        if shoot.videos > 0 { parts.append("\(shoot.videos.formatted()) video\(shoot.videos == 1 ? "" : "s")") }
        parts.append(ByteFormat.string(shoot.bytes))
        return parts.joined(separator: " · ")
    }

    /// One more line that answers the question she sorted by.
    private var extra: String? {
        switch sort {
        case .camera: return shoot.cameraList.isEmpty ? nil : shoot.cameraList.prefix(3).joined(separator: ", ")
        case .people: return shoot.people.isEmpty ? nil : shoot.people.prefix(3).joined(separator: ", ")
        default: return nil
        }
    }

    @ViewBuilder private var badge: some View {
        switch sort {
        case .price:
            Text(shoot.price.map { Money.string($0) } ?? "No price")
                .font(Theme.font(size: 12, weight: .semibold)).foregroundStyle(shoot.price == nil ? Theme.muted : Theme.text2)
        case .paid:
            Text(shoot.paid ? "Paid" : "Not paid yet")
                .font(Theme.font(size: 12, weight: .semibold)).foregroundStyle(shoot.paid ? Theme.chartReady : Theme.amber)
        default:
            Text(shoot.project.stage.label).font(Theme.font(size: 12)).foregroundStyle(Theme.text3)
        }
    }

    private func driveChip(_ id: String) -> some View {
        let drive = catalog.drives.first { $0.id == id }
        let plugged = drive.map { catalog.isPlugged($0) } ?? false
        return HStack(spacing: 4) {
            Image(systemName: drive?.isMac == true ? "laptopcomputer" : drive?.isPhotos == true ? "photo.on.rectangle" : "externaldrive")
            Text(drive?.name ?? "A drive")
        }
        .font(Theme.font(size: 11, weight: .medium))
        .foregroundStyle(plugged ? Theme.text3 : Theme.amber)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Theme.raised)
        .clipShape(Capsule())
        .help(plugged ? "On \(drive?.name ?? "this drive")" : "On \(drive?.name ?? "a drive") in the drawer. Plug it in to open these.")
    }
}

// MARK: - A folder that isn't part of a shoot yet

private struct LooseFolderRow: View {
    let folder: LibraryFolder
    @EnvironmentObject private var projects: ProjectStore
    @ObservedObject private var links = LibraryLinks.shared
    @ObservedObject private var catalog = DriveCatalog.shared

    var body: some View {
        let guess = ShootGuess.project(for: folder, among: projects.projects, links: links)
        HStack(spacing: 14) {
            NavigationLink(value: route) {
                HStack(spacing: 12) {
                    Image(systemName: folder.videos > 0 ? "film" : "photo.on.rectangle")
                        .font(Theme.font(size: 15)).foregroundStyle(Theme.text3).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.name).font(Theme.font(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(detail).font(Theme.font(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let guess {
                Text("Is this \(guess.name)?").font(Theme.font(size: 13)).foregroundStyle(Theme.text2).lineLimit(1)
                Button("Yes") { LibraryFiles.file(folder, under: guess, projects: projects, catalog: catalog) }
                    .buttonStyle(PrimaryButtonStyle())
                Button("No") { links.notThis(folder, guess.id) }
                    .buttonStyle(SecondaryButtonStyle())
            }
            Menu(guess == nil ? "Which project?" : "Another") {
                ForEach(choices) { p in
                    Button(p.name) { LibraryFiles.file(folder, under: p, projects: projects, catalog: catalog) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(Theme.font(size: 13))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var route: FootageRoute {
        folder.isPhotosDay ? .unsorted(driveID: folder.driveID, folder: folder.folder)
                           : .folder(driveID: folder.driveID, path: folder.folder)
    }

    private var detail: String {
        var parts: [String] = []
        if folder.videos > 0 { parts.append("\(folder.videos) video\(folder.videos == 1 ? "" : "s")") }
        if folder.photos > 0 { parts.append("\(folder.photos) photo\(folder.photos == 1 ? "" : "s")") }
        parts.append(ByteFormat.string(folder.bytes))
        parts.append(catalog.drives.first { $0.id == folder.driveID }?.name ?? "")
        if let parent = whereItIs { parts.append(parent) }
        return parts.joined(separator: " · ")
    }

    /// The folder it sits in, the way she'd say it: "Pictures", not the whole path from the top of the Mac.
    private var whereItIs: String? {
        guard !folder.parent.isEmpty else { return nil }
        if catalog.drives.first(where: { $0.id == folder.driveID })?.isMac == true {
            let home = LibraryFiles.plain(FileManager.default.homeDirectoryForCurrentUser.path)
            let full = LibraryFiles.plain("/" + folder.parent)
            if full == home { return "Home folder" }
            if full.hasPrefix(home + "/") { return String(full.dropFirst(home.count + 1)) }
        }
        return folder.parent
    }

    /// Current projects first, newest shoot first, then the rest.
    private var choices: [Project] {
        projects.projects.sorted { a, b in
            let ca = a.stage != .archived && a.stage != .paid, cb = b.stage != .archived && b.stage != .paid
            if ca != cb { return ca }
            return (a.shootDate ?? a.createdAt) > (b.shootDate ?? b.createdAt)
        }
    }
}

// MARK: - Helpers shared by the Library screens

@MainActor
enum LibraryFiles {
    /// Where an item is right now, if its drive is plugged in. Photos app items open by their id instead.
    static func url(of item: LibraryItem, catalog: DriveCatalog) -> URL? {
        guard let drive = catalog.drives.first(where: { $0.id == item.driveID }), !drive.isPhotos,
              catalog.isPlugged(drive), let base = catalog.base(of: drive) else { return nil }
        return URL(fileURLWithPath: Shelf.join(base, item.path))
    }

    /// She said this folder is from that project. The folder becomes the project's footage folder
    /// when it has none yet and the folder is a real shoot folder; otherwise Lens just remembers the match.
    static func file(_ folder: LibraryFolder, under project: Project, projects: ProjectStore, catalog: DriveCatalog) {
        if let full = footageFolder(folder, catalog: catalog), (project.folderPath ?? "").isEmpty {
            projects.edit(project.id) {
                $0.folderPath = full
                $0.events.append(ProjectEvent(text: "Footage folder set from the Library"))
            }
            LibraryLinks.shared.unlink(folder)
        } else {
            LibraryLinks.shared.link(folder, to: project.id)
        }
    }

    /// The folder's full path, if it could be a project's footage folder: on a drive, not the top of
    /// the drive, and not a whole Mac folder like Desktop or Downloads.
    private static func footageFolder(_ folder: LibraryFolder, catalog: DriveCatalog) -> String? {
        guard !folder.isPhotosDay, !folder.folder.isEmpty,
              let drive = catalog.drives.first(where: { $0.id == folder.driveID }), !drive.isWebsite,
              let base = catalog.base(of: drive) else { return nil }
        let full = Shelf.join(base, folder.folder)
        let home = plain(FileManager.default.homeDirectoryForCurrentUser.path)
        let macFolders = DriveCatalog.macFolders.map { plain($0.path) }
        if plain(full) == home || macFolders.contains(plain(full)) { return nil }
        if drive.isMac && !plain(full).hasPrefix(home + "/") { return nil }
        return full
    }

    /// The same folder can be written "/private/tmp/…" or "/tmp/…" on a Mac; this compares them as one.
    static func plain(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }
}

// MARK: - Everything: every file, in a list

/// Every photo and video Lens knows, with columns she can sort by. Shown in Everything.
private struct LibraryFileTable: View {
    let query: String
    let shelf: Shelf

    @EnvironmentObject private var projects: ProjectStore
    @ObservedObject private var index = LibraryIndex.shared
    @ObservedObject private var catalog = DriveCatalog.shared
    @State private var rows: [FileRow] = []
    @State private var total = 0
    @State private var order = [KeyPathComparator(\FileRow.taken, order: .reverse)]
    @State private var selection = Set<FileRow.ID>()

    private static let limit = 2000

    struct FileRow: Identifiable {
        let id: String
        let item: Int
        let name: String
        let shoot: String
        let taken: Date
        let camera: String
        let place: String
        let drive: String
        let kind: String
        let size: Int64
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionLabel("Every file")
                Text(total > rows.count ? "Showing \(rows.count.formatted()) of \(total.formatted()). Type above to narrow it down."
                                        : "\(total.formatted()) file\(total == 1 ? "" : "s")")
                    .font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
            }
            Table(rows, selection: $selection, sortOrder: $order) {
                TableColumn("Name", value: \.name) { Text($0.name).lineLimit(1).truncationMode(.middle) }
                    .width(min: 140, ideal: 200)
                TableColumn("Shoot", value: \.shoot)
                TableColumn("Taken", value: \.taken) { Text($0.taken.formatted(.dateTime.month(.abbreviated).day().year())) }
                    .width(min: 90, ideal: 100)
                TableColumn("Camera", value: \.camera)
                TableColumn("Place", value: \.place)
                TableColumn("Drive", value: \.drive)
                TableColumn("Type", value: \.kind).width(min: 50, ideal: 60)
                TableColumn("Size", value: \.size) { Text(ByteFormat.string($0.size)).monospacedDigit() }
                    .width(min: 60, ideal: 80)
            }
            .font(Theme.font(size: 12))
            .frame(height: 440)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
            .contextMenu(forSelectionType: FileRow.ID.self) { ids in
                if let url = url(ids.first) {
                    Button("Open") { NSWorkspace.shared.open(url) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            } primaryAction: { ids in
                if let url = url(ids.first) { NSWorkspace.shared.open(url) }
            }
        }
        .onAppear(perform: rebuild)
        .onChange(of: index.version) { _, _ in rebuild() }
        .onChange(of: query) { _, _ in rebuild() }
        .onChange(of: order) { _, _ in rebuild() }
        .onChange(of: shelf.owner.count) { _, _ in rebuild() }
    }

    private func url(_ id: FileRow.ID?) -> URL? {
        guard let id, let row = rows.first(where: { $0.id == id }), index.items.indices.contains(row.item) else { return nil }
        return LibraryFiles.url(of: index.items[row.item], catalog: catalog)
    }

    private func rebuild() {
        let names = Dictionary(uniqueKeysWithValues: projects.projects.map { ($0.id, $0.name) })
        let driveNames = Dictionary(uniqueKeysWithValues: catalog.drives.map { ($0.id, $0.name) })
        var owner: [String: String] = [:]
        for f in index.folders { if let id = shelf.owner[f.id] { owner[f.id] = names[id] } }
        let words = query.lowercased().split(separator: " ").map(String.init)
        var all: [FileRow] = []
        all.reserveCapacity(index.items.count)
        for (i, item) in index.items.enumerated() {
            let row = FileRow(id: item.id, item: i, name: item.name,
                              shoot: owner[item.driveID + "|" + item.folder] ?? "",
                              taken: item.date, camera: item.camera ?? "", place: item.place ?? "",
                              drive: driveNames[item.driveID] ?? "", kind: item.kind == .video ? "Video" : "Photo",
                              size: item.size)
            if !words.isEmpty {
                let text = (row.name + " " + row.shoot + " " + row.camera + " " + row.place + " " + row.drive + " " + item.folder).lowercased()
                guard words.allSatisfy({ text.contains($0) }) else { continue }
            }
            all.append(row)
        }
        all.sort(using: order)
        total = all.count
        rows = Array(all.prefix(Self.limit))
    }
}

// MARK: - One shoot's photos and videos

/// Every photo and video in a shoot (or in one loose Photos app day), folder by folder, from
/// Lens's memory, so it opens even when the drives are in the drawer.
struct ShootFilesView: View {
    enum Subject: Hashable {
        case project(UUID)
        case folder(driveID: String, folder: String)
    }
    let subject: Subject

    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var navigator: Navigator
    @ObservedObject private var index = LibraryIndex.shared
    @ObservedObject private var links = LibraryLinks.shared
    @ObservedObject private var catalog = DriveCatalog.shared
    @State private var show: Show = .all
    @State private var selected: String?
    @State private var previewing: FolderItem?

    enum Show: String, CaseIterable { case all = "Everything", video = "Video", photo = "Photos" }

    private var project: Project? {
        if case .project(let id) = subject { return projects.project(id: id) }
        return nil
    }

    private var folders: [LibraryFolder] {
        switch subject {
        case .project(let id):
            let shelf = index.shelf(projects: projects.projects, links: links, catalog: catalog)
            return (shelf.byProject[id] ?? []).compactMap { index.folders.indices.contains($0) ? index.folders[$0] : nil }
                .sorted { $0.first < $1.first }
        case .folder(let driveID, let folder):
            return index.folders.filter { $0.driveID == driveID && $0.folder == folder }
        }
    }

    /// How the photos and videos are grouped. People and Scene only show when the files themselves say who or which.
    enum Arrange: String, CaseIterable, Identifiable {
        case folder = "Folder", day = "Day of shoot", camera = "Camera", place = "Location", people = "Who's in it", scene = "Scene"
        var id: String { rawValue }
    }
    @AppStorage("shoot.arrange") private var arrangeRaw = Arrange.folder.rawValue

    private struct Entry {
        let item: LibraryItem
        let file: FolderItem
        let folder: LibraryFolder
    }

    private struct FileSection: Identifiable {
        let id: String
        let title: String
        let icon: String
        /// Set when the section is one folder on a drive, so it keeps Show in Finder.
        let folder: LibraryFolder?
        let files: [FolderItem]
    }

    /// Every photo and video in this shoot that matches Everything / Video / Photos, oldest first within each folder.
    private var entries: [Entry] {
        folders.flatMap { folder in
            folder.items.compactMap { i -> Entry? in
                guard index.items.indices.contains(i) else { return nil }
                let item = index.items[i]
                switch show {
                case .all: break
                case .video: if item.kind != .video { return nil }
                case .photo: if item.kind != .photo { return nil }
                }
                let file = FolderItem(name: item.name, size: item.size, modified: item.date, kind: item.kind,
                                      url: LibraryFiles.url(of: item, catalog: catalog), assetID: item.assetID, key: item.id)
                return Entry(item: item, file: file, folder: folder)
            }
            .sorted { $0.file.modified < $1.file.modified }
        }
    }

    /// The ways to group that mean something for these files.
    private func choices(_ entries: [Entry]) -> [Arrange] {
        Arrange.allCases.filter { a in
            switch a {
            case .folder, .day: return true
            case .camera: return entries.contains { $0.item.camera != nil }
            case .place: return entries.contains { $0.item.place != nil }
            case .people: return entries.contains { !($0.item.people ?? []).isEmpty }
            case .scene: return entries.contains { !($0.item.scene ?? "").isEmpty }
            }
        }
    }

    private func arrange(_ entries: [Entry]) -> Arrange {
        let saved = Arrange(rawValue: arrangeRaw) ?? .folder
        return choices(entries).contains(saved) ? saved : .folder
    }

    private func sections(_ entries: [Entry]) -> [FileSection] {
        switch arrange(entries) {
        case .folder:
            return folders.compactMap { f in
                let files = entries.filter { $0.folder.id == f.id }.map(\.file)
                return files.isEmpty ? nil : FileSection(id: f.id, title: f.name, icon: "folder.fill", folder: f, files: files)
            }
        case .day:
            let cal = Calendar.current
            let days = Dictionary(grouping: entries) { cal.startOfDay(for: $0.item.date) }
            let keys = days.keys.sorted()
            return keys.enumerated().map { n, day in
                let title = (keys.count > 1 ? "Day \(n + 1) · " : "") + day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
                return FileSection(id: "day-\(Int(day.timeIntervalSince1970))", title: title, icon: "calendar", folder: nil,
                                   files: (days[day] ?? []).map(\.file).sorted { $0.modified < $1.modified })
            }
        case .camera: return labelled(entries, icon: "camera", none: "Camera not known") { $0.camera.map { [$0] } ?? [] }
        case .place: return labelled(entries, icon: "mappin.and.ellipse", none: "Place not known") { $0.place.map { [$0] } ?? [] }
        case .people: return labelled(entries, icon: "person", none: "No one named") { $0.people ?? [] }
        case .scene: return labelled(entries, icon: "film", none: "No scene noted") { $0.scene.map { [$0] } ?? [] }
        }
    }

    /// Groups by a name each file carries. A photo of two people shows under both of them.
    private func labelled(_ entries: [Entry], icon: String, none: String, keys: (LibraryItem) -> [String]) -> [FileSection] {
        var groups: [String: [FolderItem]] = [:]
        var rest: [FolderItem] = []
        for e in entries {
            let names = Set(keys(e.item).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            if names.isEmpty { rest.append(e.file) } else { for n in names { groups[n, default: []].append(e.file) } }
        }
        var out = groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
            FileSection(id: icon + "|" + name, title: name, icon: icon, folder: nil,
                        files: (groups[name] ?? []).sorted { $0.modified < $1.modified })
        }
        if !rest.isEmpty { out.append(FileSection(id: icon + "|none", title: none, icon: icon, folder: nil, files: rest)) }
        return out
    }

    var body: some View {
        let entries = self.entries
        let groups = sections(entries)
        let all = entries.map(\.file)
        VStack(alignment: .leading, spacing: 0) {
            header(all, entries: entries)
            Divider().overlay(Theme.line)
            if groups.isEmpty {
                if let project, !index.loading {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            brief(project)
                            notFound(project)
                        }
                        .padding(24)
                    }
                } else {
                    Text(index.loading ? "Reading your drives…" : "No photos or videos here yet.")
                        .font(Theme.font(size: 14)).foregroundStyle(Theme.muted).padding(40)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if let project { brief(project) }
                        ForEach(groups) { section in
                            VStack(alignment: .leading, spacing: 10) {
                                sectionHeader(section)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                                    ForEach(section.files) { tile($0) }
                                }
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .background(Theme.ground)
        .onAppear { index.start() }
        .sheet(item: $previewing) { item in
            PreviewSheet(items: all.filter(\.canPreview), start: item)
        }
    }

    @ViewBuilder private func sectionHeader(_ section: FileSection) -> some View {
        if let folder = section.folder {
            folderHeader(folder, count: section.files.count)
        } else {
            HStack(spacing: 8) {
                Image(systemName: section.icon).foregroundStyle(Theme.text3)
                Text(section.title).font(Theme.font(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Text("\(section.files.count)").font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
            }
        }
    }

    // MARK: The brief

    /// A few lines on what the project was, how far it got, who was involved and what happened last,
    /// so she knows which shoot she's looking at before the photos. The full story stays on the project page.
    private func brief(_ p: Project) -> some View {
        let people = involved(p)
        let recent = Array(p.events.suffix(3).reversed())
        return VStack(alignment: .leading, spacing: 18) {
            Text(briefSentence(p))
                .font(Theme.font(size: 15)).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 6) {
                ForEach(ProjectStage.allCases) { step in
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule()
                            .fill(step.rawValue < p.stage.rawValue ? Theme.tealDim : step == p.stage ? Theme.teal : Theme.track)
                            .frame(height: 5)
                        Text(step.label)
                            .font(Theme.font(size: 11, weight: step == p.stage ? .semibold : .regular))
                            .foregroundStyle(step.rawValue <= p.stage.rawValue ? Theme.text2 : Theme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(p.stage.rawValue + 1) of 7, \(p.stage.label)")
            if !people.isEmpty || !recent.isEmpty {
                HStack(alignment: .top, spacing: 32) {
                    if !people.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Who was involved").font(Theme.font(size: 13, weight: .semibold)).foregroundStyle(Theme.text3)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10, alignment: .leading)],
                                      alignment: .leading, spacing: 10) {
                                ForEach(people, id: \.name) { person in personChip(person.name, person.role) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !recent.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Lately").font(Theme.font(size: 13, weight: .semibold)).foregroundStyle(Theme.text3)
                            ForEach(recent) { event in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(event.date.formatted(.dateTime.month(.abbreviated).day()))
                                        .font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
                                        .frame(width: 48, alignment: .leading)
                                    Text(event.text).font(Theme.font(size: 13)).foregroundStyle(Theme.text2).lineLimit(2)
                                }
                            }
                        }
                        .frame(width: 300, alignment: .leading)
                    }
                }
            }
        }
        .panel(padding: 20)
    }

    private func personChip(_ name: String, _ role: String) -> some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        return HStack(spacing: 9) {
            Text(initials.uppercased())
                .font(Theme.font(size: 11, weight: .semibold)).foregroundStyle(Theme.text2)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Palette.orchid.opacity(0.16)))
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(Theme.font(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                if !role.isEmpty { Text(role).font(Theme.font(size: 12)).foregroundStyle(Theme.muted).lineLimit(1) }
            }
        }
    }

    /// The client first, then everyone else on the project with their role, each name once.
    private func involved(_ p: Project) -> [(name: String, role: String)] {
        var out: [(name: String, role: String)] = []
        var seen = Set<String>()
        let client = p.client.trimmingCharacters(in: .whitespaces)
        if !client.isEmpty { out.append((client, "Client")); seen.insert(client.lowercased()) }
        for person in p.people ?? [] {
            let name = person.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            out.append((name, person.role))
        }
        return out
    }

    private func briefSentence(_ p: Project) -> String {
        var first = ""
        let client = p.client.trimmingCharacters(in: .whitespaces)
        let place = p.location.trimmingCharacters(in: .whitespaces)
        let past = (p.shootDate ?? .distantFuture) <= Date()
        if !client.isEmpty || p.shootDate != nil || !place.isEmpty {
            first = p.shootDate == nil ? "A shoot" : (past ? "Shot" : "Shooting")
            if !client.isEmpty { first += " for \(client)" }
            if let d = p.shootDate { first += " on \(d.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))" }
            if !place.isEmpty { first += " at \(place)" }
            if let price = p.price, price > 0 { first += ", for \(Money.string(price))" }
            first += ". "
        }
        let now: String
        switch p.stage {
        case .lead: now = "It's still a possible job."
        case .booked: now = past ? "It's booked." : "It's booked and the shoot is coming up."
        case .shoot: now = past ? "The shoot's done and the edit is next." : "The shoot is coming up."
        case .edit: now = "It's in the edit now."
        case .delivered: now = "It's delivered and waiting on payment."
        case .paid: now = "It's delivered and paid."
        case .archived: now = "It's finished and put away."
        }
        return first + now
    }

    /// A shoot with nothing found yet: say so, and offer the loose folders most likely to be it.
    private func notFound(_ project: Project) -> some View {
        let shelf = index.shelf(projects: projects.projects, links: links, catalog: catalog)
        let loose = shelf.unsorted.compactMap { index.folders.indices.contains($0) ? index.folders[$0] : nil }
            .filter { !links.isRejected($0, project.id) }
        let guessed = loose.filter { ShootGuess.project(for: $0, among: projects.projects, links: links)?.id == project.id }
        let nearby: [LibraryFolder] = {
            guard let shoot = project.shootDate else { return [] }
            return loose.filter { f in
                f.first != .distantFuture && !guessed.contains(f)
                    && abs(f.first.timeIntervalSince(shoot)) < 14 * 86_400
            }
            .sorted { abs($0.first.timeIntervalSince(shoot)) < abs($1.first.timeIntervalSince(shoot)) }
        }()
        let likely = Array((guessed + nearby).prefix(6))
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Lens hasn't found the photos and videos for this shoot yet")
                    .font(Theme.font(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                Text(likely.isEmpty ? "If they're on a drive, plug it in and they'll show up here. To file a folder that's already in the Library, find it in the List view and say which project it's from."
                                    : "If they're on a drive, plug it in and they'll show up here. If they're already in the Library, pick the folder below.")
                    .font(Theme.font(size: 14)).foregroundStyle(Theme.muted)
            }
            if !likely.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(project.shootDate == nil ? "Could it be one of these?" : "From around the shoot date")
                        .font(Theme.font(size: 13, weight: .semibold)).foregroundStyle(Theme.text3)
                    VStack(spacing: 0) {
                        ForEach(likely) { folder in
                            HStack(spacing: 12) {
                                Image(systemName: folder.videos > 0 ? "film" : "photo.on.rectangle")
                                    .foregroundStyle(Theme.text3).frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(folder.name).font(Theme.font(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                                    Text(looseDetail(folder)).font(Theme.font(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Button("This is it") { LibraryFiles.file(folder, under: project, projects: projects, catalog: catalog) }
                                    .buttonStyle(PrimaryButtonStyle())
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            if folder.id != likely.last?.id { Divider().overlay(Theme.line) }
                        }
                    }
                    .panel(padding: 0)
                }
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    private func looseDetail(_ folder: LibraryFolder) -> String {
        var parts: [String] = []
        if folder.first != .distantFuture { parts.append(folder.first.formatted(.dateTime.month(.abbreviated).day().year())) }
        if folder.videos > 0 { parts.append("\(folder.videos) video\(folder.videos == 1 ? "" : "s")") }
        if folder.photos > 0 { parts.append("\(folder.photos) photo\(folder.photos == 1 ? "" : "s")") }
        if let drive = catalog.drives.first(where: { $0.id == folder.driveID }) { parts.append(drive.name) }
        return parts.joined(separator: " · ")
    }

    private func header(_ all: [FolderItem], entries: [Entry]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project?.name ?? folders.first?.name ?? "Photos and videos")
                        .font(Theme.font(size: 24, weight: .bold)).foregroundStyle(Theme.text)
                    Text(summary(all)).font(Theme.font(size: 13)).foregroundStyle(Theme.muted)
                }
                Spacer()
                if let item = all.first(where: { $0.id == selected }), item.canPreview {
                    Button("Preview") { previewing = item }.buttonStyle(SecondaryButtonStyle())
                }
                if let project {
                    Button("Open project") { navigator.openProject(project.id) }.buttonStyle(SecondaryButtonStyle())
                }
            }
            if !folders.isEmpty {
                HStack(spacing: 18) {
                    Picker("", selection: $show) { ForEach(Show.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                    let options = choices(entries)
                    if options.count > 1 {
                        Picker("Sort by", selection: Binding(get: { arrange(entries).rawValue }, set: { arrangeRaw = $0 })) {
                            ForEach(options) { Text($0.rawValue).tag($0.rawValue) }
                        }
                        .pickerStyle(.menu).fixedSize()
                        .font(Theme.font(size: 13))
                    }
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
    }

    private func summary(_ all: [FolderItem]) -> String {
        let photos = all.filter { $0.kind == .photo }.count, videos = all.filter { $0.kind == .video }.count
        var parts: [String] = []
        if let p = project {
            if let d = p.shootDate { parts.append(d.formatted(.dateTime.month(.wide).day().year())) }
            var places: [String: Int] = [:]
            for f in folders { for i in f.items where index.items.indices.contains(i) { if let pl = index.items[i].place { places[pl, default: 0] += 1 } } }
            if let place = Shoot.place(of: p, files: places)?.label, !place.isEmpty { parts.append(place) }
        }
        if videos > 0 { parts.append("\(videos.formatted()) video\(videos == 1 ? "" : "s")") }
        if photos > 0 { parts.append("\(photos.formatted()) photo\(photos == 1 ? "" : "s")") }
        if !all.isEmpty { parts.append(ByteFormat.string(all.reduce(0) { $0 + $1.size })) }
        return parts.joined(separator: " · ")
    }

    private func folderHeader(_ folder: LibraryFolder, count: Int) -> some View {
        let drive = catalog.drives.first { $0.id == folder.driveID }
        let plugged = drive.map { catalog.isPlugged($0) } ?? false
        let place = drive.flatMap { catalog.location(of: folder.folder, on: $0) }
        return HStack(spacing: 8) {
            Image(systemName: "folder.fill").foregroundStyle(Theme.text3)
            Text(folder.name).font(Theme.font(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            Text("\(count) · \(drive?.name ?? "")").font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
            if let drive, !plugged, !drive.isPhotos {
                Label("Plug in \(drive.name) to open these", systemImage: "externaldrive")
                    .font(Theme.font(size: 12, weight: .semibold)).foregroundStyle(Theme.amber)
            }
            Spacer()
            if let place, !folder.isPhotosDay {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([place]) }
                    .buttonStyle(.link).font(Theme.font(size: 12))
            }
            if project != nil, links.data.links.contains(where: { $0.driveID == folder.driveID && $0.folder == folder.folder }) {
                Button("Not this shoot") { links.unlink(folder) }
                    .buttonStyle(.link).font(Theme.font(size: 12))
            }
        }
    }

    private func tile(_ item: FolderItem) -> some View {
        let isSelected = selected == item.id
        return VStack(alignment: .leading, spacing: 6) {
            Thumbnail(url: item.url, assetID: item.assetID, kind: item.kind)
                .frame(height: 130)
                .frame(maxWidth: .infinity)
                .background(Theme.raised)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomLeading) {
                    if item.kind == .video {
                        Image(systemName: "play.fill").font(Theme.font(size: 10)).padding(5)
                            .background(.black.opacity(0.55)).clipShape(Circle()).padding(6).foregroundStyle(.white)
                    }
                }
            Text(item.name).font(Theme.font(size: 12, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
            Text("\(ByteFormat.string(item.size)) · \(item.modified.formatted(.dateTime.month().day().year()))")
                .font(Theme.font(size: 11)).foregroundStyle(Theme.muted)
        }
        .padding(8)
        .background(isSelected ? Theme.teal.opacity(0.18) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Theme.teal.opacity(0.7) : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if item.canPreview { previewing = item } }
        .simultaneousGesture(TapGesture().onEnded { selected = item.id })
        .onDrag { item.url.map { NSItemProvider(contentsOf: $0) ?? NSItemProvider() } ?? NSItemProvider() }
        .contextMenu {
            if let url = item.url {
                Button("Preview") { previewing = item }
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }
}
