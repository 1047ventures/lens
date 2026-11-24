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
    @State private var doneOpen = false
    @State private var editing: Project?
    @State private var creating = false
    @State private var importMessage: String?

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
            ProjectEditor(initial: nil) { projects.add($0); navigator.projectID = $0.id }
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Projects")
                            .font(Theme.font(size: 30, weight: .bold))
                            .foregroundStyle(Theme.text)
                        Text("Every gig, from first inquiry to archived.")
                            .font(Theme.font(size: 15))
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    if let root = viewModel.roots.first {
                        Button("Import from drive folders") {
                            let added = projects.importProjects(fromFoldersIn: root)
                            importMessage = added == 0 ? "No new folders to import." : "Added \(added) project\(added == 1 ? "" : "s") from the drive."
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    Button("New project") { creating = true }
                        .buttonStyle(PrimaryButtonStyle())
                }

                if let importMessage {
                    Text(importMessage)
                        .font(Theme.font(size: 13))
                        .foregroundStyle(Theme.text3)
                }

                FoundWorkPanel()
                EmailSuggestionsPanel(place: .projects)
                UnmatchedNotesPanel()

                if projects.projects.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No projects yet")
                            .font(Theme.font(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text(viewModel.roots.isEmpty
                             ? "Create one, or add your drive in Library and import its folders as projects."
                             : "Create one, or turn the drive's folders into projects with “Import from drive folders”.")
                            .font(Theme.font(size: 14))
                            .foregroundStyle(Theme.muted)
                    }
                    .panel(padding: 22)
                } else {
                    group(title: "Active", items: projects.active)
                    let archived = projects.projects.filter { $0.stage == .archived }
                    if !archived.isEmpty { group(title: "Archived", items: archived) }
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Simple

    private func simpleGroup(_ title: String, _ items: [Project]) -> [(String, [Project])] {
        items.isEmpty ? [] : [(title, items)]
    }

    private var simpleList: some View {
        let all = projects.projects
        func byDate(_ a: Project, _ b: Project) -> Bool {
            (a.shootDate ?? .distantFuture) < (b.shootDate ?? .distantFuture)
        }
        let groups = simpleGroup("Coming up", all.filter { $0.stage == .lead || $0.stage == .booked }.sorted(by: byDate))
            + simpleGroup("Shooting", all.filter { $0.stage == .shoot }.sorted(by: byDate))
            + simpleGroup("Editing", all.filter { $0.stage == .edit }.sorted(by: byDate))
            + simpleGroup("Waiting on payment", all.filter { $0.stage == .delivered }.sorted(by: byDate))
        let done = all.filter { $0.stage == .paid || $0.stage == .archived }
            .sorted { ($0.shootDate ?? $0.createdAt) > ($1.shootDate ?? $1.createdAt) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Projects")
                            .font(Theme.display(size: 34))
                            .foregroundStyle(Theme.text)
                        Text("Here's what's on your plate, grouped by what you do next.")
                            .font(Theme.font(size: 15))
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button("New project") { creating = true }
                        .buttonStyle(PrimaryButtonStyle())
                }
                if !history.found.isEmpty { FoundWorkPanel() }
                if all.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No projects yet")
                            .font(Theme.display(size: 20)).foregroundStyle(Theme.text)
                        Text("Start one with New project, and it will show up here.")
                            .font(Theme.font(size: 14)).foregroundStyle(Theme.muted)
                    }
                    .panel(padding: 22)
                }
                ForEach(groups, id: \.0) { title, items in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(title)
                            .font(Theme.display(size: 20)).foregroundStyle(Theme.text)
                        ForEach(items) { simpleCard($0) }
                    }
                }
                if !done.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            withAnimation { doneOpen.toggle() }
                        } label: {
                            HStack(spacing: 8) {
                                Text("Finished and paid · \(done.count)")
                                    .font(Theme.display(size: 20)).foregroundStyle(Theme.text)
                                Image(systemName: doneOpen ? "chevron.down" : "chevron.right")
                                    .font(Theme.font(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if doneOpen { ForEach(done) { simpleCard($0) } }
                    }
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 40)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func simpleCard(_ project: Project) -> some View {
        Button {
            navigator.projectID = project.id
        } label: {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(project.name)
                        .font(Theme.display(size: 19)).foregroundStyle(Theme.text)
                    if !project.client.isEmpty {
                        Text(project.client).font(Theme.font(size: 13)).foregroundStyle(Theme.muted)
                    }
                    Text(SimpleProject.nextLine(project))
                        .font(Theme.font(size: 14)).foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 8) {
                    Text(SimpleProject.chipName(project.stage))
                        .font(Theme.font(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.teal)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Theme.teal.opacity(0.12))
                        .clipShape(Capsule())
                    if let date = project.shootDate {
                        Text(SimpleProject.when(date))
                            .font(Theme.font(size: 13)).foregroundStyle(Theme.muted)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .panel(padding: 20)
    }

    private func group(title: String, items: [Project]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("\(title) · \(items.count)")
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, project in
                    if index > 0 { Divider().overlay(Theme.lineSoft) }
                    Button {
                        navigator.projectID = project.id
                    } label: {
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.name)
                                    .font(Theme.font(size: 15, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                Text(subtitle(for: project))
                                    .font(Theme.font(size: 13))
                                    .foregroundStyle(Theme.muted)
                            }
                            Spacer(minLength: 16)
                            glance(for: project)
                            VStack(alignment: .trailing, spacing: 6) {
                                Text(project.stage.label)
                                    .font(Theme.font(size: 12, weight: .semibold))
                                    .foregroundStyle(project.stage == .delivered ? Theme.coral : Theme.text3)
                                StageBar(stage: project.stage).frame(width: 170)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
        }
    }

    /// Hours and what she keeps, at a glance.
    @ViewBuilder private func glance(for project: Project) -> some View {
        let books = ProjectBooks.make(project, money: money, deals: deals)
        if books.hours > 0 || books.keep != nil || books.spent > 0 {
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 5) {
                    if project.isTiming { Circle().fill(Theme.coral).frame(width: 7, height: 7) }
                    Text(books.hours > 0 ? Hours.short(books.hours) : "No time yet")
                        .font(Theme.font(size: 13, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(books.hours > 0 ? Theme.text2 : Theme.muted)
                }
                if let keep = books.keep {
                    Text(keep >= 0 ? "Keep \(Money.short(keep))" : "Over by \(Money.short(-keep))")
                        .font(Theme.font(size: 12)).monospacedDigit()
                        .foregroundStyle(keep >= 0 ? Theme.teal : Theme.coral)
                } else if books.spent > 0 {
                    Text("Spent \(Money.short(books.spent))")
                        .font(Theme.font(size: 12)).monospacedDigit().foregroundStyle(Theme.muted)
                }
            }
            .frame(width: 130, alignment: .trailing)
        }
    }

    private func subtitle(for project: Project) -> String {
        var parts: [String] = []
        if !project.client.isEmpty { parts.append(project.client) }
        if let date = project.shootDate { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        if project.isOnServer { parts.append("On the server") }
        else if project.folderPath == nil { parts.append("No footage folder") }
        return parts.isEmpty ? "No details yet" : parts.joined(separator: " · ")
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
            Text(initial == nil ? "New project" : "Edit project")
                .font(Theme.font(size: 20, weight: .bold))
            Form {
                TextField("Name", text: $name, prompt: Text("Hartley wedding"))
                TextField("Client", text: $client)
                TextField("Location", text: $location)
                TextField("Keywords", text: $keywords, prompt: Text("CU, documentary"))
                    .help("Words that show a Zoom call or email is about this project, separated by commas")
                TextField("Price", text: $priceText, prompt: Text("Leave empty to use the won deal's price"))
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
                Text("Lens reads your work email and call notes and adds your current and upcoming projects here by itself, with their people. Possible jobs go on Pipeline.")
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
                        Text((item.isProject ? "Added as a project" : "Added to Pipeline") + (item.why.isEmpty ? "" : " · " + item.why))
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

    static func chipName(_ stage: ProjectStage) -> String {
        switch stage {
        case .lead: return "Inquiry"
        case .booked: return "Booked"
        case .shoot: return "Shooting"
        case .edit: return "Editing"
        case .delivered: return "Delivered"
        case .paid: return "Paid"
        case .archived: return "Done"
        }
    }

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
