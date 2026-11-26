import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - What's showing on the wall

/// Which projects the wall shows. Saved, so she comes back to the same view.
enum WallFilter: Hashable {
    case all, needsYou, step(ProjectStage), didntBook, putAway

    var key: String {
        switch self {
        case .all: return "all"
        case .needsYou: return "needs"
        case .step(let s): return "step.\(s.rawValue)"
        case .didntBook: return "lost"
        case .putAway: return "away"
        }
    }

    init(key: String) {
        switch key {
        case "needs": self = .needsYou
        case "lost": self = .didntBook
        case "away": self = .putAway
        default:
            if key.hasPrefix("step."), let n = Int(key.dropFirst(5)), let s = ProjectStage(rawValue: n) { self = .step(s) }
            else { self = .all }
        }
    }
}

/// Why a project is waiting on her right now, in a few words. Nil when it isn't.
enum WallAttention {
    @MainActor static func reason(_ p: Project, deals: DealStore) -> String? {
        let cal = Calendar.current
        switch p.stage {
        case .lead:
            guard let q = deals.quote(for: p), q.stage.isOpen else { return nil }
            if q.isStale { return DealCard.nextMove(q) }
            if let due = q.proposalDue, due < Date() { return DealCard.nextMove(q) }
            return nil
        case .booked, .deposit, .shoot:
            guard let d = p.shootDate else { return nil }
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: d)).day ?? 99
            if (p.stage == .booked || p.stage == .deposit) && days < 0 { return "The shoot was \(SimpleProject.when(d)). Mark it shot" }
            if (0...2).contains(days) { return "Shooting \(SimpleProject.when(d))" }
            return nil
        default:
            return nil
        }
    }
}

// MARK: - The wall

/// Every project as a big picture, filtered by step along the top. Ones waiting on her glow.
struct ProjectWall: View {
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var deals: DealStore
    @AppStorage("projects.wallFilter") private var filterKey = "all"

    private var filter: WallFilter { WallFilter(key: filterKey) }

    private var archived: [Project] { projects.projects.filter { $0.stage == .archived } }
    private var lost: [Project] { archived.filter { deals.didntBook($0) } }
    private var away: [Project] { archived.filter { !deals.didntBook($0) } }
    private var waiting: [Project] { projects.active.filter { WallAttention.reason($0, deals: deals) != nil } }

    /// Pictures (the wall) or Board (a column per step, left to right). Saved on this Mac.
    @AppStorage("projects.view") private var view = "wall"

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 16) {
                if view == "board" {
                    Text("Every live project, by the step it's at. Click one to open it.")
                        .font(Theme.font(size: 14)).foregroundStyle(Theme.muted)
                } else {
                    chips
                }
                Spacer(minLength: 0)
                Picker("View", selection: $view) {
                    Label("Pictures", systemImage: "square.grid.2x2").tag("wall")
                    Label("Board", systemImage: "rectangle.split.3x1").tag("board")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("See projects as pictures, or as a board with a column for each step")
            }
            if view == "board" {
                ProjectBoard(columns: ProjectStage.allCases.filter { $0 != .archived }.map { step in
                    let items = sorted(projects.active.filter { $0.stage == step })
                    return (step, title(for: step, items), items)
                })
            } else {
                wall
            }
        }
        .onAppear {
            // A filter that empties out goes back to everything.
            if case .needsYou = filter, waiting.isEmpty { filterKey = "all" }
        }
    }

    @ViewBuilder private var wall: some View {
            switch filter {
            case .all:
                ForEach(ProjectStage.allCases.filter { $0 != .archived }) { step in
                    let items = sorted(projects.active.filter { $0.stage == step })
                    if !items.isEmpty { WallSection(title: title(for: step, items), items: items) }
                }
            case .needsYou:
                shown(waiting, empty: "Nothing is waiting on you. Nice.")
            case .step(let step):
                shown(sorted(projects.active.filter { $0.stage == step }), empty: "No projects at \(step.label) right now.")
            case .didntBook:
                shown(lost, empty: "Nothing here.")
            case .putAway:
                shown(away, empty: "Nothing put away yet.")
            }
    }

    @ViewBuilder private func shown(_ items: [Project], empty: String) -> some View {
        if items.isEmpty {
            Text(empty).font(Theme.font(size: 15)).foregroundStyle(Theme.muted).padding(.vertical, 20)
        } else {
            WallGrid(items: items)
        }
    }

    private func sorted(_ items: [Project]) -> [Project] {
        items.sorted {
            let a = WallAttention.reason($0, deals: deals) != nil, b = WallAttention.reason($1, deals: deals) != nil
            if a != b { return a }
            return ($0.shootDate ?? $0.createdAt) < ($1.shootDate ?? $1.createdAt)
        }
    }

    private func title(for step: ProjectStage, _ items: [Project]) -> String {
        var t = step.label
        if step == .lead {
            let total = items.compactMap { deals.quote(for: $0).flatMap { deals.value(of: $0) } }.reduce(0, +)
            if total > 0 { t += " · up to \(Money.short(total))" }
        }
        return t
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", count: projects.active.count, .all)
                if !waiting.isEmpty { chip("Needs you", count: waiting.count, .needsYou, warm: true) }
                ForEach(ProjectStage.allCases.filter { $0 != .archived }) { step in
                    let n = projects.active.filter { $0.stage == step }.count
                    if n > 0 { chip(step.label, count: n, .step(step)) }
                }
                if !lost.isEmpty { chip("Didn't book", count: lost.count, .didntBook) }
                if !away.isEmpty { chip("Put away", count: away.count, .putAway) }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(_ label: String, count: Int, _ f: WallFilter, warm: Bool = false) -> some View {
        let on = filter == f
        let tint = warm ? Theme.amber : Theme.teal
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { filterKey = f.key }
        } label: {
            HStack(spacing: 6) {
                if warm { Circle().fill(on ? Theme.onTeal : Theme.amber).frame(width: 7, height: 7) }
                Text(label).font(Theme.font(size: 13, weight: .semibold))
                Text("\(count)").font(Theme.font(size: 12)).monospacedDigit().opacity(0.75)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .foregroundStyle(on ? Theme.onTeal : Theme.text2)
            .background(on ? tint : Theme.panel)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(on ? Color.clear : Theme.line))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A heading and its tiles.
struct WallSection: View {
    let title: String
    let items: [Project]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(Theme.display(size: 20)).foregroundStyle(Theme.text)
                Text("\(items.count)").font(Theme.font(size: 14)).monospacedDigit().foregroundStyle(Theme.muted)
            }
            WallGrid(items: items)
        }
    }
}

struct WallGrid: View {
    let items: [Project]
    private let columns = [GridItem(.adaptive(minimum: 270, maximum: 420), spacing: 18)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            ForEach(items) { ProjectTile(project: $0) }
        }
    }
}

// MARK: - One tile

struct ProjectTile: View {
    let project: Project
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var deals: DealStore
    @EnvironmentObject private var money: MoneyStore
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var appearance: Appearance
    @State private var hovering = false
    @State private var dropping = false
    /// So the menu says Pin or Take off correctly after a change.
    @AppStorage("topbar.pins") private var pinsRaw = ""

    private var reason: String? { WallAttention.reason(project, deals: deals) }
    private var lostOne: Bool { deals.didntBook(project) }

    var body: some View {
        Button {
            navigator.projectID = project.id
        } label: {
            ZStack(alignment: .bottomLeading) {
                ProjectCoverView(project: project)
                LinearGradient(colors: [.black.opacity(0), .black.opacity(0.15), .black.opacity(0.72)],
                               startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        pill(lostOne ? "Didn't book" : project.stage.label)
                        if project.isTiming {
                            HStack(spacing: 5) { Circle().fill(Theme.coral).frame(width: 7, height: 7); Text("Timing") }
                                .font(Theme.font(size: 11, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.black.opacity(0.35)).clipShape(Capsule())
                        }
                        Spacer()
                        if !appearance.simple, let worth { pill(worth) }
                    }
                    Spacer(minLength: 0)
                    Text(project.name)
                        .font(Theme.display(size: 20)).foregroundStyle(.white)
                        .lineLimit(2).shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    Text(line)
                        .font(Theme.font(size: 12, weight: reason == nil ? .regular : .semibold))
                        .foregroundStyle(reason == nil ? .white.opacity(0.85) : Color(hex: 0xFFD27A))
                        .lineLimit(1).padding(.top, 3)
                    steps.padding(.top, 10)
                }
                .padding(14)
            }
            .aspectRatio(3 / 2, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(dropping ? Theme.teal : (reason != nil ? Theme.amber : Color.white.opacity(0.08)),
                                  lineWidth: dropping || reason != nil ? 3 : 1)
            }
            .shadow(color: reason != nil ? Theme.amber.opacity(0.45) : .black.opacity(hovering ? 0.22 : 0.10),
                    radius: reason != nil ? 14 : (hovering ? 14 : 6), y: reason != nil ? 0 : 4)
            .saturation(lostOne || project.stage == .archived ? 0.35 : 1)
            .scaleEffect(hovering ? 1.015 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .help(reason.map { "Needs you: \($0)" } ?? project.name)
        .contextMenu {
            Button("Open") { navigator.projectID = project.id }
            if project.stage != .archived {
                if TopBarPins.isShown(project, in: projects) {
                    Button("Take off the top bar") { TopBarPins.unpin(project, in: projects) }
                } else {
                    Button("Pin to the top bar") { TopBarPins.pin(project, in: projects) }
                }
            }
            Divider()
            Button("Choose cover picture…") { chooseCover() }
            if project.coverPath != nil {
                Button("Let Lens pick the cover") { setCover(nil) }
            }
            Divider()
            ProjectMoveItems(project: project)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: ProjectCover.canUse) else { return false }
            setCover(url.path)
            return true
        } isTargeted: { dropping = $0 }
        .accessibilityLabel("\(project.name), \(project.stage.label)\(reason.map { ", needs you: \($0)" } ?? "")")
    }

    /// What's next, or why it's waiting on her.
    private var line: String {
        if let reason { return reason }
        var parts: [String] = []
        if !project.client.isEmpty { parts.append(project.client) } else { parts.append("Your own idea") }
        if project.stage == .lead, let q = deals.quote(for: project), q.stage.isOpen {
            parts.append(DealCard.nextMove(q))
        } else if let d = project.shootDate {
            parts.append(SimpleProject.when(d))
        }
        return parts.joined(separator: " · ")
    }

    /// The quote's value at Quoting, otherwise the price.
    private var worth: String? {
        if lostOne { return nil }
        if project.stage == .lead, let q = deals.quote(for: project), deals.value(of: q) != nil { return deals.valueText(of: q) }
        let books = ProjectBooks.make(project, money: money, deals: deals)
        return books.price.map { Money.short($0) }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(Theme.font(size: 11, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(.ultraThinMaterial.opacity(0.9))
            .background(.black.opacity(0.25))
            .clipShape(Capsule())
    }

    /// The seven steps, drawn to read on any picture.
    private var steps: some View {
        HStack(spacing: 3) {
            ForEach(ProjectStage.allCases) { step in
                Capsule()
                    .fill(step.order <= project.stage.order ? Color.white.opacity(step == project.stage ? 1 : 0.7)
                                                                  : Color.white.opacity(0.22))
                    .frame(height: 3)
            }
        }
    }

    private func chooseCover() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie]
        panel.prompt = "Use as cover"
        panel.message = "Pick a photo or clip for \(project.name)"
        if let folder = project.folderURL { panel.directoryURL = folder }
        if panel.runModal() == .OK, let url = panel.url { setCover(url.path) }
    }

    private func setCover(_ path: String?) {
        guard var p = projects.project(id: project.id) else { return }
        p.coverPath = path
        projects.update(p)
    }
}

// MARK: - The picture

/// The project's photo, or a colour card in its step's colour until there is one.
struct ProjectCoverView: View {
    let project: Project
    @State private var image: NSImage?

    private var key: String { "\(project.id)|\(project.coverPath ?? "")|\(project.folderPath ?? "")|\(project.archivedPath ?? "")" }

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    CoverCard(project: project)
                }
            }
            .clipped()
            .task(id: key) { image = await ProjectCover.image(for: project) }
    }
}

/// A clean card for a project with no pictures yet: its own colour, a soft light and a big monogram.
/// The colour comes from the name, so it stays the same every time and neighbours rarely match.
struct CoverCard: View {
    let project: Project

    private var initials: String {
        let words = project.name.split(separator: " ").filter { $0.first?.isLetter == true }
        return words.prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    /// Eight warm-to-cool washes, like light at different times of day. Picked from the name, so it never changes.
    private static let washes: [(UInt32, UInt32, UInt32)] = [
        (0xF2B36B, 0xD8615A, 0x5A3A6B),  // sunset
        (0x9FD6E3, 0x3F8FB0, 0x1D4A66),  // sea
        (0xC7D9A3, 0x6F9A5C, 0x2F4D36),  // forest
        (0xF1E1C9, 0xC9A27A, 0x7A5A44),  // sand
        (0xE8B8C8, 0xA8628A, 0x4A2C4F),  // dusk
        (0xD9DDE6, 0x8A96AD, 0x3C4660),  // fog
        (0xFFD98A, 0xE59A3A, 0x8A4B1F),  // golden hour
        (0xA9E0CF, 0x3C9C88, 0x1B4F48),  // lagoon
    ]

    private var wash: [Color] {
        let n = project.name.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0xFFFFF }
        let w = Self.washes[n % Self.washes.count]
        return [Color(hex: w.0), Color(hex: w.1), Color(hex: w.2)]
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: wash, startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.22), .clear], center: .topLeading, startRadius: 0, endRadius: 260)
            Text(initials)
                .font(Theme.display(size: 132))
                .foregroundStyle(.white.opacity(0.17))
                .lineLimit(1).fixedSize()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .offset(x: 14, y: -10)
        }
    }
}

// MARK: - Board

/// Every live project in a column for its step, left to right, so the whole flow shows at a glance.
struct ProjectBoard: View {
    let columns: [(step: ProjectStage, title: String, items: [Project])]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(width: nil)
            ScrollView(.horizontal, showsIndicators: true) { row(width: 236).padding(.bottom, 10) }
        }
    }

    private func row(width: CGFloat?) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(columns, id: \.step) { column in
                BoardColumn(title: column.title, count: column.items.count, items: column.items)
                    .frame(minWidth: width ?? 190, idealWidth: width, maxWidth: width ?? .infinity, alignment: .top)
            }
        }
    }
}

private struct BoardColumn: View {
    let title: String
    let count: Int
    let items: [Project]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(Theme.font(size: 14, weight: .bold)).foregroundStyle(Theme.text)
                    .lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                Text("\(count)").font(Theme.font(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Theme.line.opacity(0.6)).clipShape(Capsule())
            }
            .padding(.horizontal, 4)
            if items.isEmpty {
                Text("Nothing here right now")
                    .font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            } else {
                ForEach(items) { BoardCard(project: $0) }
            }
        }
        .padding(10)
        .background(Theme.panel.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A small card on the board: a strip of the cover picture, the name, and what's next.
private struct BoardCard: View {
    let project: Project
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var deals: DealStore
    @EnvironmentObject private var money: MoneyStore
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var appearance: Appearance
    @State private var hovering = false
    @AppStorage("topbar.pins") private var pinsRaw = ""

    private var reason: String? { WallAttention.reason(project, deals: deals) }

    var body: some View {
        Button {
            navigator.projectID = project.id
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                ProjectCoverView(project: project)
                    .frame(height: 74)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .overlay(alignment: .topTrailing) {
                        if !appearance.simple, let worth {
                            Text(worth)
                                .font(Theme.font(size: 11, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.black.opacity(0.45)).clipShape(Capsule())
                                .padding(7)
                        }
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                        .font(Theme.font(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text(line)
                        .font(Theme.font(size: 12, weight: reason == nil ? .regular : .semibold))
                        .foregroundStyle(reason == nil ? Theme.text3 : Theme.amber)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 11).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(reason != nil ? Theme.amber : Theme.line, lineWidth: reason != nil ? 2 : 1)
            }
            .shadow(color: .black.opacity(hovering ? 0.18 : 0.06), radius: hovering ? 10 : 4, y: 3)
            .scaleEffect(hovering ? 1.015 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .help(reason.map { "Needs you: \($0)" } ?? project.name)
        .contextMenu {
            Button("Open") { navigator.projectID = project.id }
            if TopBarPins.isShown(project, in: projects) {
                Button("Take off the top bar") { TopBarPins.unpin(project, in: projects) }
            } else {
                Button("Pin to the top bar") { TopBarPins.pin(project, in: projects) }
            }
            Divider()
            ProjectMoveItems(project: project)
        }
        .accessibilityLabel("\(project.name), \(project.stage.label)\(reason.map { ", needs you: \($0)" } ?? "")")
    }

    private var line: String {
        if let reason { return reason }
        var parts: [String] = [project.client.isEmpty ? "Your own idea" : project.client]
        if project.stage == .lead, let q = deals.quote(for: project), q.stage.isOpen {
            parts.append(DealCard.nextMove(q))
        } else if let d = project.shootDate {
            parts.append(SimpleProject.when(d))
        }
        return parts.joined(separator: " · ")
    }

    private var worth: String? {
        if project.stage == .lead, let q = deals.quote(for: project), deals.value(of: q) != nil { return deals.valueText(of: q) }
        return ProjectBooks.make(project, money: money, deals: deals).price.map { Money.short($0) }
    }
}
