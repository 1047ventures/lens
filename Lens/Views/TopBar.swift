import SwiftUI

// The bar across the top of the window, instead of a sidebar. Left: the Lens mark (home, the wall of
// projects) and the few projects she's working on, as little pictures. Right: the other places as icons,
// Simple or Everything, Ask Lens, and her picture with Log-ins, Settings and Style behind it.

// MARK: - Pinned projects

/// The projects on the top bar. Ones she pinned; until she pins any, Lens picks the live ones
/// with the nearest shoot dates. Saved on this Mac (it's about how Lens looks, not her data).
@MainActor
enum TopBarPins {
    private static let key = "topbar.pins"
    static let most = 5

    static func pinnedIDs() -> [UUID] {
        (UserDefaults.standard.string(forKey: key) ?? "").split(separator: ",").compactMap { UUID(uuidString: String($0)) }
    }

    private static func save(_ ids: [UUID]) {
        UserDefaults.standard.set(ids.map(\.uuidString).joined(separator: ","), forKey: key)
    }

    static func shown(_ projects: ProjectStore) -> [Project] {
        let pinned = pinnedIDs().compactMap { projects.project(id: $0) }.filter { $0.stage != .archived }
        if !pinned.isEmpty { return Array(pinned.prefix(most)) }
        let live = projects.active.filter { [.booked, .deposit, .shoot, .edit, .delivered].contains($0.stage) }
        return Array(live.sorted { ($0.shootDate ?? .distantFuture) < ($1.shootDate ?? .distantFuture) }.prefix(4))
    }

    static func isShown(_ project: Project, in projects: ProjectStore) -> Bool {
        shown(projects).contains { $0.id == project.id }
    }

    static func pin(_ project: Project, in projects: ProjectStore) {
        var ids = shown(projects).map(\.id)
        guard !ids.contains(project.id) else { return }
        ids.append(project.id)
        save(Array(ids.suffix(most)))
    }

    static func unpin(_ project: Project, in projects: ProjectStore) {
        save(shown(projects).map(\.id).filter { $0 != project.id })
        // Taking every one off leaves it empty on purpose: a dash so Lens doesn't fill it again.
        if pinnedIDs().isEmpty { UserDefaults.standard.set("-", forKey: key) }
    }
}

/// The Lens mark (back to the wall) and the pinned projects.
struct TopBarLeading: View {
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var navigator: Navigator
    /// Redraws when pins change.
    @AppStorage("topbar.pins") private var pinsRaw = ""

    private var onWall: Bool { navigator.section == .projects && navigator.projectID == nil }
    private var onHome: Bool { navigator.section == .today }

    var body: some View {
        HStack(spacing: 6) {
            place(on: onHome, help: "Home: what's happening today, this week and this month") {
                Image("LensMark").resizable().frame(width: 22, height: 22)
                Text("Home")
            } action: {
                navigator.open(.today)
            }
            place(on: onWall, help: "All your projects") {
                Image(systemName: "square.grid.2x2").font(.system(size: 13))
                Text("Projects")
            } action: {
                navigator.open(.projects)
                navigator.projectID = nil
            }

            let pins = TopBarPins.shown(projects)
            if !pins.isEmpty {
                Rectangle().fill(Theme.line).frame(width: 1, height: 20)
                ForEach(pins) { PinButton(project: $0) }
            }
        }
        .id(pinsRaw)
    }

    private func place<Label: View>(on: Bool, help: String, @ViewBuilder label: () -> Label, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) { label() }
                .font(Theme.font(size: 13, weight: .semibold))
                .foregroundStyle(on ? Theme.text : Theme.text3)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(on ? Theme.teal.opacity(0.16) : .clear)
                .clipShape(Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct PinButton: View {
    let project: Project
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var navigator: Navigator
    @State private var hovering = false

    private var open: Bool { navigator.section == .projects && navigator.projectID == project.id }

    var body: some View {
        Button {
            navigator.openProject(project.id)
        } label: {
            HStack(spacing: 7) {
                ProjectCoverView(project: project)
                    .frame(width: 40, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(open ? Theme.teal : Theme.line, lineWidth: open ? 2 : 1)
                    }
                if open || hovering {
                    Text(project.name)
                        .font(Theme.font(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .frame(maxWidth: 150, alignment: .leading)
                }
            }
            .padding(.trailing, open || hovering ? 8 : 0)
            .background(open ? Theme.teal.opacity(0.12) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .help("\(project.name) · \(project.stage.label)")
        .contextMenu {
            Button("Take off the top bar") { TopBarPins.unpin(project, in: projects) }
        }
    }
}

// MARK: - Places

/// The other places, as icons. The open one is tinted.
struct TopBarPlaces: View {
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var people: PeopleStore
    @ObservedObject private var office = BackOffice.shared

    private let places: [SidebarSection] = [.helper, .people, .footage, .money, .gear]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(places) { place in
                let on = navigator.section == place
                Button {
                    navigator.open(place)
                } label: {
                    Image(systemName: place.systemImage)
                        .font(.system(size: 14, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.teal : Theme.text3)
                        .frame(width: 32, height: 28)
                        .background(on ? Theme.teal.opacity(0.14) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(alignment: .topTrailing) {
                            if (place == .people && !people.followUpsDue.isEmpty) || (place == .helper && office.waitingCount > 0) {
                                Circle().fill(Theme.amber).frame(width: 7, height: 7).offset(x: -4, y: 4)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(place.rawValue)
                .accessibilityLabel(place.rawValue)
            }
        }
    }
}

// MARK: - Timer and update

/// While a timer runs: a red dot and the time, always in view. Click to open the project.
struct TimerPill: View {
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var navigator: Navigator

    var body: some View {
        if let project = projects.timing, let started = project.timerStartedAt {
            Button {
                navigator.openProject(project.id)
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(Theme.coral).frame(width: 7, height: 7)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Hours.clock(context.date.timeIntervalSince(started)))
                            .font(Theme.font(size: 12, weight: .semibold)).monospacedDigit()
                    }
                }
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.coral.opacity(0.15))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Timer running on \(project.name). Click to open it.")
            .contextMenu { Button("Stop the timer") { projects.stopTimer(project.id) } }
        }
    }
}

/// Shows when a new version of Lens is ready.
struct UpdatePill: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        if let release = updater.available {
            Button {
                Task { await updater.install() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                    Text(busy ? "Installing…" : "Update ready").fontWeight(.semibold)
                }
                .font(Theme.font(size: 12))
                .foregroundStyle(Theme.onTeal)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(Theme.teal)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .help("Lens \(release.version) is ready. Click to install it and restart. \(release.notes)")
        }
    }

    private var busy: Bool { updater.phase == .downloading || updater.phase == .installing }
}

// MARK: - Her picture

/// Her initial in a circle. Click it for the behind-the-scenes places: Log-ins, Settings, Style.
struct ProfileMenu: View {
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var logins: ConnectionStore
    @ObservedObject private var updater = Updater.shared
    @State private var open = false

    private var initial: String {
        let name = NSFullUserName().trimmingCharacters(in: .whitespaces)
        return name.first.map { String($0).uppercased() } ?? ""
    }
    private var loginsToDo: Int { logins.progress.total - logins.progress.done }

    var body: some View {
        Button { open.toggle() } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if initial.isEmpty {
                        Image(systemName: "person.fill").font(.system(size: 12))
                    } else {
                        Text(initial).font(Theme.font(size: 13, weight: .bold))
                    }
                }
                .foregroundStyle(Theme.onTeal)
                .frame(width: 28, height: 28)
                .background(Theme.teal)
                .clipShape(Circle())
                if loginsToDo > 0 {
                    Circle().fill(Theme.amber).frame(width: 8, height: 8).offset(x: 1, y: -1)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Log-ins, Settings and Style")
        .onChange(of: navigator.section) { _, _ in open = false }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                row("Log-ins", "key", note: loginsToDo > 0 ? "\(loginsToDo) to set up" : nil) { navigator.open(.logins) }
                row("Settings", "gearshape") { navigator.open(.settings) }
                row("Style", "paintpalette") { navigator.choosingStyle = true }
                Divider().padding(.vertical, 4)
                row("Take the tour", "figure.walk") { navigator.startTour() }
                row("Check for updates", "arrow.triangle.2.circlepath", note: "Lens \(updater.currentVersion)") {
                    Task { await updater.check() }
                }
            }
            .padding(8)
            .frame(width: 250)
        }
    }

    private func row(_ title: String, _ icon: String, note: String? = nil, action: @escaping () -> Void) -> some View {
        Button {
            open = false
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(Theme.text3)
                Text(title).font(Theme.font(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                Spacer()
                if let note { Text(note).font(Theme.font(size: 11)).foregroundStyle(title == "Log-ins" ? Theme.amber : Theme.muted) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(ProfileRowStyle())
    }
}

private struct ProfileRowStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.teal.opacity(configuration.isPressed ? 0.2 : (hovering ? 0.1 : 0))))
            .onHover { hovering = $0 }
    }
}
