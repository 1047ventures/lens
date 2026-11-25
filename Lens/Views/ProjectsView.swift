import SwiftUI
import AppKit

struct ProjectsView: View {
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var viewModel: ScanViewModel
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var money: MoneyStore
    @EnvironmentObject private var deals: DealStore
    @EnvironmentObject private var appearance: Appearance
    @EnvironmentObject private var history: EmailHistory
    @EnvironmentObject private var gmail: GmailSync
    @State private var editing: Project?
    @State private var creating = false
    @State private var importMessage: String?
    @State private var showQuotes = false
    @State private var showRates = false
    @AppStorage("projects.arrange") private var arrangeRaw = ProjectArrange.next.rawValue

    private var arrange: ProjectArrange { ProjectArrange(rawValue: arrangeRaw) ?? .next }
    /// Searching or sorting another way swaps the usual groups for the found list.
    private var finding: Bool {
        !navigator.projectQuery.trimmingCharacters(in: .whitespaces).isEmpty || arrange != .next
    }

    var body: some View {
        Group {
            if let project = projects.project(id: navigator.projectID) {
                ProjectDetailView(project: project)
            } else if appearance.simple {
                simpleList
            } else {
                list
            }
        }
        .sheet(isPresented: $creating) {
            ProjectEditor(initial: nil) { p in
                projects.add(p)
                // Client work at Quoting gets its quote right away, ready to price.
                if p.stage == .lead && !p.client.trimmingCharacters(in: .whitespaces).isEmpty { deals.startQuote(for: p) }
                navigator.projectID = p.id
            }
        }
        // "New project" from the find bar.
        .onAppear { takeNewProjectRequest() }
        .onChange(of: navigator.newProjectRequested) { _, _ in takeNewProjectRequest() }
        .sheet(isPresented: $showQuotes) { QuoteHistoryView() }
        .sheet(isPresented: $showRates) { RateCardSheet() }
    }

    private func takeNewProjectRequest() {
        guard navigator.newProjectRequested else { return }
        navigator.newProjectRequested = false
        creating = true
    }

    /// Past quotes and her rates: what every quote is priced from.
    private var quotesMenu: some View {
        Menu("Quotes") {
            Button("Past quotes") { showQuotes = true }
            Button("Rates & profile") { showRates = true }
        }
        .menuStyle(.button)
        .fixedSize()
    }

    /// Emails waiting for her say-so before they become projects.
    private var waitingEmails: Int {
        gmail.suggestions.filter { [.inquiry, .project, .attach].contains($0.kind) }.count
    }

    private var list: some View { page(simple: false) }
    private var simpleList: some View { page(simple: true) }

    /// The wall of projects, with what Lens found in email and calls underneath.
    private func page(simple: Bool) -> some View {
        ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Projects")
                                .font(simple ? Theme.display(size: 34) : Theme.font(size: 30, weight: .bold))
                                .foregroundStyle(Theme.text)
                            Text(simple ? "Here's what's on your plate. Click a picture to open it."
                                        : "Every idea you're bringing to life, from first spark to finished.")
                                .font(Theme.font(size: 15))
                                .foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        if !simple, let root = viewModel.roots.first {
                            Button("Import from drive folders") {
                                let added = projects.importProjects(fromFoldersIn: root)
                                importMessage = added == 0 ? "No new folders to import." : "Added \(added) project\(added == 1 ? "" : "s") from the drive."
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                        if !simple { quotesMenu }
                        Button("New project") { creating = true }
                            .buttonStyle(PrimaryButtonStyle())
                    }

                    if let importMessage {
                        Text(importMessage).font(Theme.font(size: 13)).foregroundStyle(Theme.text3)
                    }

                    if waitingEmails > 0 && !finding {
                        Button {
                            withAnimation { scroller.scrollTo("fromEmail", anchor: .top) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "envelope.badge").foregroundStyle(Theme.amber)
                                Text(waitingEmails == 1 ? "1 new email could be a project" : "\(waitingEmails) new emails could be projects")
                                    .font(Theme.font(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                                Text("Take a look").font(Theme.font(size: 13)).foregroundStyle(Theme.teal)
                                Spacer()
                            }
                            .padding(.horizontal, 16).padding(.vertical, 11)
                            .background(Theme.amber.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if projects.projects.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No projects yet")
                                .font(Theme.display(size: 20)).foregroundStyle(Theme.text)
                            Text(simple || viewModel.roots.isEmpty
                                 ? "Start one with New project: a client booking, or an idea of your own you want to bring to life."
                                 : "Create one, or turn the drive's folders into projects with \u{201C}Import from drive folders\u{201D}.")
                                .font(Theme.font(size: 14)).foregroundStyle(Theme.muted)
                        }
                        .panel(padding: 22)
                    } else {
                        findBar
                        if finding { found } else { ProjectWall() }
                    }

                    if !finding {
                        VStack(alignment: .leading, spacing: 20) {
                            if !simple || !history.found.isEmpty { FoundWorkPanel() }
                            EmailSuggestionsPanel(place: .projects)
                            if !simple { UnmatchedNotesPanel() }
                        }
                        .padding(.top, 12)
                        .id("fromEmail")
                    }
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Find and sort

    private var findBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("Find by name, client, place, date or anyone involved", text: $navigator.projectQuery)
                    .textFieldStyle(.plain)
                    .font(Theme.font(size: 14))
                if !navigator.projectQuery.isEmpty {
                    Button { navigator.projectQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
            Picker("Sort by", selection: $arrangeRaw) {
                ForEach(ProjectArrange.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.menu).fixedSize()
            .font(Theme.font(size: 13))
        }
    }

    @ViewBuilder private var found: some View {
        let query = navigator.projectQuery.trimmingCharacters(in: .whitespaces)
        let words = query.lowercased().split(separator: " ").map(String.init)
        let items = projects.projects.filter { words.isEmpty || ProjectFinder.matches($0, words) }
        if items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nothing matches \u{201C}\(query)\u{201D}")
                    .font(Theme.font(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Try a client, a place, a month like \u{201C}June\u{201D}, or the name of someone involved.")
                    .font(Theme.font(size: 14)).foregroundStyle(Theme.muted)
            }
            .panel(padding: 22)
        } else {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(ProjectFinder.groups(items, by: arrange)) { group in
                    WallSection(title: group.title, items: group.items)
                }
            }
        }
    }
}

// MARK: - Create / edit

struct ProjectEditor: View {
    let initial: Project?
    /// For a new project Lens filled in from a call or an email: name, client, people and keywords.
    var prefill: Project? = nil
    let onSave: (Project) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var client = ""
    @State private var location = ""
    @State private var hasDate = false
    @State private var shootDate = Date()
    @State private var stage: ProjectStage = .lead
    @State private var folderPath: String?
    @State private var keywords = ""
    @State private var priceText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(initial == nil ? "New project" : "Edit project")
                    .font(Theme.font(size: 20, weight: .bold))
                if initial == nil {
                    Text("A client booking, or an idea of your own you want to bring to life.")
                        .font(Theme.font(size: 13)).foregroundStyle(Theme.muted)
                }
            }
            Form {
                TextField("Name", text: $name, prompt: Text("Hartley wedding"))
                TextField("Client", text: $client, prompt: Text("Leave empty if it's your own"))
                TextField("Location", text: $location)
                TextField("Keywords", text: $keywords, prompt: Text("CU, documentary"))
                    .help("Words that show a Zoom call or email is about this project, separated by commas")
                TextField("Price", text: $priceText, prompt: Text("Leave empty to use the quote's price"))
                Toggle("Has a shoot date", isOn: $hasDate)
                if hasDate {
                    DatePicker("Shoot date", selection: $shootDate)
                }
                Picker("Stage", selection: $stage) {
                    ForEach(ProjectStage.allCases) { Text($0.label).tag($0) }
                }
                if initial == nil, let people = prefill?.people, !people.isEmpty {
                    LabeledContent("People") {
                        Text(people.map(\.name).joined(separator: ", "))
                            .foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.trailing)
                    }
                    .help("Lens found these people in the call or email. You can change roles on the People tab.")
                }
                LabeledContent("Footage folder") {
                    HStack {
                        Text(folderPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None")
                            .foregroundStyle(.secondary)
                        Button("Choose…") { chooseFolder() }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(initial == nil ? "Create project" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear(perform: loadInitial)
    }

    private func loadInitial() {
        guard let initial = initial ?? prefill else { return }
        name = initial.name
        client = initial.client
        location = initial.location
        hasDate = initial.shootDate != nil
        shootDate = initial.shootDate ?? Date()
        stage = initial.stage
        folderPath = initial.folderPath
        keywords = (initial.keywords ?? []).joined(separator: ", ")
        priceText = initial.price.map { String(Int($0.rounded())) } ?? ""
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use this folder"
        if panel.runModal() == .OK, let url = panel.urls.first {
            folderPath = url.path
        }
    }

    private func save() {
        var project = initial ?? prefill ?? Project(name: name)
        let stageChanged = initial != nil && initial?.stage != stage
        project.name = name.trimmingCharacters(in: .whitespaces)
        project.client = client
        project.location = location
        project.shootDate = hasDate ? shootDate : nil
        project.stage = stage
        project.folderPath = folderPath
        let words = keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        project.keywords = words.isEmpty ? nil : words
        project.price = MoneyStore.parseAmount(priceText).flatMap { $0 > 0 ? $0 : nil }
        if stageChanged { project.events.append(ProjectEvent(text: "Moved to \(stage.label)")) }
        onSave(project)
        dismiss()
    }
}

/// Projects and inquiries Lens found in Emma's email and calls and added by itself, with Keep and Remove.
struct FoundWorkPanel: View {
    @EnvironmentObject private var history: EmailHistory
    @EnvironmentObject private var navigator: Navigator
    @State private var looking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(history.found.isEmpty ? "Your work, from email and calls" : "Lens found these in your email and calls")
                Spacer()
                Button(looking ? "Looking…" : "Look again now") {
                    looking = true
                    Task { await history.findWork(force: true); looking = false }
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(looking)
            }
            if history.found.isEmpty {
                Text("Lens reads your work email and call notes and adds your current and upcoming projects here by itself, with their people. Possible jobs start at Quoting.")
                    .font(Theme.font(size: 13)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(history.found) { item in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: item.isProject ? "folder.fill" : "tray.and.arrow.down.fill").foregroundStyle(Theme.teal)
                    VStack(alignment: .leading, spacing: 2) {
                        Button(item.name) {
                            if item.isProject { navigator.openProject(item.id) } else { navigator.openDeal(item.id) }
                        }
                        .buttonStyle(.plain)
                        .font(Theme.font(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                        Text((item.isProject ? "Added as a project" : "Added at Quoting") + (item.why.isEmpty ? "" : " · " + item.why))
                            .font(Theme.font(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Keep") { history.keep(item) }.buttonStyle(SecondaryButtonStyle())
                    Button("Remove") { history.undo(item) }.buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .panel(padding: 22)
    }
}

// MARK: - Simple wording shared by the list and the project page

enum SimpleProject {
    /// "Saturday, Dec 6", "in 3 days", "today", "yesterday".
    static func when(_ date: Date) -> String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case 2...6: return "in \(days) days"
        case ..<0: return date.formatted(.dateTime.month(.abbreviated).day())
        default: return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
    }

    static func chipName(_ stage: ProjectStage) -> String { stage.label }

    /// One plain sentence about what comes next.
    static func nextLine(_ p: Project) -> String {
        let day = p.shootDate.map { when($0) }
        let ahead = p.shootDate.map { $0 >= Calendar.current.startOfDay(for: Date()) } ?? false
        switch p.stage {
        case .lead: return "Follow up and get this one booked."
        case .booked:
            if let day, ahead { return "Shoot day is \(day)." }
            if let day { return "The shoot was \(day). Mark it shot once it's done." }
            return "Set the shoot date when you have it."
        case .shoot:
            if let day, ahead { return "Shooting \(day), then bring the footage in." }
            return "Finish shooting, then bring the footage in."
        case .edit:
            return p.folderPath == nil ? "Finish the edit. Pick the footage folder to find it fast." : "Finish the edit and deliver it."
        case .delivered: return "Delivered. Waiting for the final payment."
        case .paid: return p.folderPath != nil && !p.isOnServer ? "Paid. Move the footage to the server when you're ready." : "All paid. Nicely done."
        case .archived: return "Finished and put away."
        }
    }
}

// MARK: - Finding projects

/// The ways she can lay out the Projects list. "What's next" is the usual page.
enum ProjectArrange: String, CaseIterable, Identifiable {
    case next = "What's next"
    case date = "Date"
    case place = "Place"
    case people = "People involved"
    case client = "Client"
    var id: String { rawValue }
}

struct ProjectGroup: Identifiable {
    let title: String
    var items: [Project]
    var id: String { title }
}

enum ProjectFinder {
    /// Every word she typed shows up somewhere on the project: its name, client, place, keywords,
    /// stage, the people involved and their roles, or its month and day.
    static func matches(_ p: Project, _ words: [String]) -> Bool {
        var parts = [p.name, p.client, p.location, p.stage.label, SimpleProject.chipName(p.stage)]
        parts += p.keywords ?? []
        parts += (p.people ?? []).flatMap { [$0.name, $0.role] }
        if let d = p.shootDate {
            parts.append(d.formatted(.dateTime.month(.wide).day().year()))
            parts.append(d.formatted(.dateTime.month(.abbreviated)))
        }
        if p.client.trimmingCharacters(in: .whitespaces).isEmpty { parts.append("own personal idea") }
        let hay = parts.joined(separator: " ").lowercased()
        return words.allSatisfy { hay.contains($0) }
    }

    private static func when(_ p: Project) -> Date { p.shootDate ?? p.createdAt }

    static func groups(_ items: [Project], by arrange: ProjectArrange) -> [ProjectGroup] {
        let newest = items.sorted { when($0) > when($1) }
        switch arrange {
        case .next:
            return ProjectStage.allCases.compactMap { stage in
                let members = newest.filter { $0.stage == stage }
                return members.isEmpty ? nil : ProjectGroup(title: SimpleProject.chipName(stage), items: members)
            }
        case .date:
            var groups: [ProjectGroup] = []
            for p in newest where p.shootDate != nil {
                let title = p.shootDate!.formatted(.dateTime.month(.wide).year())
                if groups.last?.title == title { groups[groups.count - 1].items.append(p) }
                else { groups.append(ProjectGroup(title: title, items: [p])) }
            }
            let undated = newest.filter { $0.shootDate == nil }
            if !undated.isEmpty { groups.append(ProjectGroup(title: "No date yet", items: undated)) }
            return groups
        case .place:
            return labelled(newest, none: "No place set") { [$0.location] }
        case .people:
            // The client first, as on the shoot brief, then everyone on the People tab.
            return labelled(newest, none: "No one added yet") { [$0.client] + ($0.people ?? []).map(\.name) }
        case .client:
            return labelled(newest, none: "Your own projects") { [$0.client] }
        }
    }

    /// One group per label, busiest first; a project with several people shows under each of them.
    private static func labelled(_ items: [Project], none: String, _ labels: (Project) -> [String]) -> [ProjectGroup] {
        var order: [String] = []
        var byKey: [String: ProjectGroup] = [:]
        var leftover: [Project] = []
        for p in items {
            var seen = Set<String>()
            let names = labels(p).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if names.isEmpty { leftover.append(p); continue }
            for name in names {
                let key = name.lowercased()
                guard seen.insert(key).inserted else { continue }
                if byKey[key] == nil { byKey[key] = ProjectGroup(title: name, items: []); order.append(key) }
                byKey[key]!.items.append(p)
            }
        }
        var groups = order.compactMap { byKey[$0] }
            .sorted { $0.items.count != $1.items.count ? $0.items.count > $1.items.count : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if !leftover.isEmpty { groups.append(ProjectGroup(title: none, items: leftover)) }
        return groups
    }
}
