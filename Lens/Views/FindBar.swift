import SwiftUI

// The "Find or do anything" bar (⌘K). Type a name, a place or a job and jump straight there.
// It only jumps: anything bigger goes to Ask Lens through the last row.

private struct FindResult: Identifiable {
    enum Kind { case project(Project), person(Person), place, action, ask }
    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let icon: String
    let run: () -> Void
}

struct FindBar: View {
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var people: PeopleStore
    @EnvironmentObject private var navigator: Navigator
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private var words: [String] {
        query.lowercased().split(separator: " ").map(String.init)
    }

    private func close() { navigator.findOpen = false }

    private var results: [FindResult] {
        var out: [FindResult] = []
        let typed = query.trimmingCharacters(in: .whitespaces)

        if !words.isEmpty {
            let found = projects.projects.filter { ProjectFinder.matches($0, words) }
            let lead = words.joined(separator: " ")
            let ranked = found.sorted { a, b in
                let ap = a.name.lowercased().hasPrefix(lead), bp = b.name.lowercased().hasPrefix(lead)
                if ap != bp { return ap }
                if (a.stage == .archived) != (b.stage == .archived) { return a.stage != .archived }
                return a.createdAt > b.createdAt
            }
            for p in ranked.prefix(6) {
                out.append(FindResult(id: "p\(p.id)", kind: .project(p), title: p.name,
                                      subtitle: [p.stage.label, p.client, p.location].filter { !$0.isEmpty }.joined(separator: " · "),
                                      icon: "folder") { navigator.openProject(p.id) })
            }
            for person in people.search(typed).prefix(4) {
                out.append(FindResult(id: "m\(person.id)", kind: .person(person), title: person.name,
                                      subtitle: person.subtitle.isEmpty ? "Person" : person.subtitle,
                                      icon: "person") { navigator.openPerson(person.id) })
            }
        }

        let places: [(String, SidebarSection)] = [("Today", .today), ("Projects", .projects), ("People", .people),
                                                  ("Library", .footage), ("Money", .money), ("Gear", .gear),
                                                  ("Log-ins", .logins), ("Settings", .settings)]
        for (name, section) in places where words.allSatisfy({ name.lowercased().contains($0) }) {
            out.append(FindResult(id: "s\(name)", kind: .place, title: name, subtitle: "Go to \(name)",
                                  icon: section.systemImage) {
                if section == .projects { navigator.projectID = nil }
                if section == .people { navigator.personID = nil }
                navigator.open(section)
            })
        }

        let actions: [(String, String, [String], String, () -> Void)] = [
            ("New project", "Start a project of your own or for a client", ["new", "project", "start", "add", "create"], "plus.circle",
             { navigator.projectID = nil; navigator.open(.projects); navigator.newProjectRequested = true }),
            ("Change the style", "Pick how Lens looks", ["style", "look", "colour", "color", "theme", "dark"], "paintpalette",
             { navigator.choosingStyle = true }),
            ("Take the tour", "A one minute look around", ["tour", "help", "show", "around"], "figure.walk",
             { navigator.startTour() }),
        ]
        for (title, sub, keys, icon, run) in actions {
            let hay = ([title.lowercased()] + keys).joined(separator: " ")
            if words.isEmpty ? title == "New project" : words.allSatisfy({ hay.contains($0) }) {
                out.append(FindResult(id: "a\(title)", kind: .action, title: title, subtitle: sub, icon: icon, run: run))
            }
        }

        if !typed.isEmpty {
            out.append(FindResult(id: "ask", kind: .ask, title: "Ask Lens: \(typed)",
                                  subtitle: "Let Lens look into it", icon: "sparkles") {
                navigator.askDraft = typed
                navigator.askOpen = true
            })
        }
        return out
    }

    private func pick(_ r: FindResult) {
        close()
        r.run()
    }

    var body: some View {
        let list = results
        ZStack(alignment: .top) {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.text3)
                    TextField("Find a project, a person or a place, or do something", text: $query)
                        .textFieldStyle(.plain)
                        .font(Theme.font(size: 17))
                        .focused($focused)
                        .onSubmit { if list.indices.contains(selected) { pick(list[selected]) } }
                        .onKeyPress(.downArrow) { selected = min(selected + 1, max(list.count - 1, 0)); return .handled }
                        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                    Text("esc").font(Theme.font(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line))
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                Divider().overlay(Theme.line)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, r in
                                Button { pick(r) } label: { row(r, on: i == selected) }
                                    .buttonStyle(.plain)
                                    .id(r.id)
                                    .onHover { if $0 { selected = i } }
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: selected) { _, new in
                        if list.indices.contains(new) { proxy.scrollTo(list[new].id) }
                    }
                }
            }
            .frame(width: 580)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
            .shadow(color: .black.opacity(0.35), radius: 28, y: 10)
            .padding(.top, 70)
        }
        .onAppear {
            query = ""
            selected = 0
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: query) { _, _ in selected = 0 }
        .onExitCommand { close() }
    }

    private func row(_ r: FindResult, on: Bool) -> some View {
        HStack(spacing: 12) {
            Group {
                switch r.kind {
                case .project(let p):
                    ProjectCoverView(project: p)
                        .frame(width: 46, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                case .person(let person):
                    PersonBadge(person: person, size: 32)
                default:
                    Image(systemName: r.icon)
                        .font(.system(size: 14))
                        .foregroundStyle(r.id == "ask" ? Palette.violet : Theme.text3)
                        .frame(width: 32, height: 32)
                }
            }
            .frame(width: 46)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.title).font(Theme.font(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                if !r.subtitle.isEmpty {
                    Text(r.subtitle).font(Theme.font(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if on { Text("↩").font(Theme.font(size: 12)).foregroundStyle(Theme.muted) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.teal.opacity(0.16) : .clear))
        .contentShape(Rectangle())
    }
}
