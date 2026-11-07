import SwiftUI
import AppKit

struct ProjectsView: View {
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var viewModel: ScanViewModel
    @EnvironmentObject private var navigator: Navigator
    @State private var editing: Project?
    @State private var creating = false
    @State private var importMessage: String?

    var body: some View {
        Group {
            if let project = projects.project(id: navigator.projectID) {
                ProjectDetailView(project: project)
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
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(Theme.text)
                        Text("Every gig, from first inquiry to archived.")
                            .font(.system(size: 15))
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
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text3)
                }

                if projects.projects.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No projects yet")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text(viewModel.roots.isEmpty
                             ? "Create one, or add Emma's drive in Footage and import its folders as projects."
                             : "Create one, or turn the drive's folders into projects with “Import from drive folders”.")
                            .font(.system(size: 14))
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
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                Text(subtitle(for: project))
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.muted)
                            }
                            Spacer(minLength: 16)
                            VStack(alignment: .trailing, spacing: 6) {
                                Text(project.stage.label)
                                    .font(.system(size: 12, weight: .semibold))
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
    let onSave: (Project) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var client = ""
    @State private var location = ""
    @State private var hasDate = false
    @State private var shootDate = Date()
    @State private var stage: ProjectStage = .lead
    @State private var folderPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(initial == nil ? "New project" : "Edit project")
                .font(.system(size: 20, weight: .bold))
            Form {
                TextField("Name", text: $name, prompt: Text("Hartley wedding"))
                TextField("Client", text: $client)
                TextField("Location", text: $location)
                Toggle("Has a shoot date", isOn: $hasDate)
                if hasDate {
                    DatePicker("Shoot date", selection: $shootDate)
                }
                Picker("Stage", selection: $stage) {
                    ForEach(ProjectStage.allCases) { Text($0.label).tag($0) }
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
        guard let initial else { return }
        name = initial.name
        client = initial.client
        location = initial.location
        hasDate = initial.shootDate != nil
        shootDate = initial.shootDate ?? Date()
        stage = initial.stage
        folderPath = initial.folderPath
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
        var project = initial ?? Project(name: name)
        let stageChanged = initial != nil && initial?.stage != stage
        project.name = name.trimmingCharacters(in: .whitespaces)
        project.client = client
        project.location = location
        project.shootDate = hasDate ? shootDate : nil
        project.stage = stage
        project.folderPath = folderPath
        if stageChanged { project.events.append(ProjectEvent(text: "Moved to \(stage.label)")) }
        onSave(project)
        dismiss()
    }
}
