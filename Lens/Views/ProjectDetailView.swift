import SwiftUI
import AppKit

/// One project's hub: where it is in the lifecycle, its footage, and its story so far.
struct ProjectDetailView: View {
    let project: Project
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var viewModel: ScanViewModel
    @EnvironmentObject private var navigator: Navigator
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var moving = false

    private var files: [MediaFile] { project.files(in: viewModel.allFiles) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Button {
                    navigator.projectID = nil
                } label: {
                    Label("All projects", systemImage: "chevron.left")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)

                header
                stageTrack
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 28) { footagePanel; story }
                            .frame(minWidth: 420)
                        details.frame(width: 300)
                    }
                    VStack(alignment: .leading, spacing: 28) { footagePanel; story; details }
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $editing) {
            ProjectEditor(initial: project) { projects.update($0) }
        }
        .confirmationDialog("Delete \(project.name)?", isPresented: $confirmDelete) {
            Button("Delete project", role: .destructive) {
                navigator.projectID = nil
                projects.delete(project)
            }
        } message: {
            Text("This removes the project from Lens. Its footage folder stays where it is.")
        }
    }

    // MARK: - Header and lifecycle

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(project.name)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Theme.text)
            let meta = [project.client,
                        project.shootDate?.formatted(date: .complete, time: .shortened) ?? "",
                        project.location].filter { !$0.isEmpty }
            if !meta.isEmpty {
                Text(meta.joined(separator: " · "))
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text3)
            }
        }
    }

    private var stageTrack: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 6) {
                ForEach(ProjectStage.allCases) { step in
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(step.rawValue < project.stage.rawValue ? Theme.tealDim
                                  : step == project.stage ? Theme.text : Theme.track)
                            .frame(height: 6)
                        Text(step.label)
                            .font(.system(size: 12, weight: step == project.stage ? .bold : .medium))
                            .foregroundStyle(step.rawValue <= project.stage.rawValue ? Theme.text2 : Theme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(project.stage.rawValue + 1) of 7, \(project.stage.label)")

            HStack(spacing: 10) {
                if project.stage == .paid, project.folderPath != nil, !project.isOnServer {
                    Button(moving ? "Moving…" : "Move footage to the server") { moveToServer() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(moving)
                } else if let next = project.stage.next, next != .archived {
                    Button("Mark as \(next.label.lowercased())") {
                        projects.setStage(next, for: project)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                if project.stage != .lead, let previous = ProjectStage(rawValue: project.stage.rawValue - 1),
                   project.stage != .archived {
                    Button("Back to \(previous.label.lowercased())") {
                        projects.setStage(previous, for: project, note: "Moved back to \(previous.label)")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    // MARK: - Footage

    private var footagePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Footage")
            if project.isOnServer {
                Text("On the server")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if let path = project.archivedPath {
                    Text(path)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1).truncationMode(.middle)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            } else if let folder = project.folderURL {
                if viewModel.hasScanned {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        HeadlineNumber(text: "\(files.count)", size: 30)
                        Text("clip\(files.count == 1 ? "" : "s") · \(ByteFormat.string(files.reduce(0) { $0 + $1.sizeBytes }))")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.text3)
                    }
                    if !files.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(files.prefix(5)) { file in
                                ThumbnailImageView(file: file, size: CGSize(width: 88, height: 50))
                            }
                        }
                    }
                } else {
                    Text("Scan the drive in Footage to see this project's clips.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.text3)
                }
                Text(folder.path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 10) {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button("Footage overview") { navigator.open(.footage) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            } else {
                Text("No footage folder yet. Pick the folder this project's clips live in.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text3)
                Button("Choose folder…") { chooseFolder() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .panel(padding: 22)
    }

    // MARK: - Story and details

    private var story: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("The story so far")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(project.events.enumerated()), id: \.element.id) { index, event in
                    let isLatest = index == project.events.count - 1
                    HStack(alignment: .top, spacing: 12) {
                        Text(event.date.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .frame(width: 52, alignment: .leading)
                        Circle()
                            .fill(isLatest ? Theme.text : Theme.tealDim)
                            .frame(width: 9, height: 9)
                            .padding(.top, 4)
                        Text(event.text)
                            .font(.system(size: 14, weight: isLatest ? .semibold : .regular))
                            .foregroundStyle(isLatest ? Theme.text : Theme.text2)
                    }
                    .padding(.bottom, 14)
                }
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Details")
            detailRow("Client", project.client)
            detailRow("Shoot", project.shootDate?.formatted(date: .abbreviated, time: .shortened) ?? "")
            detailRow("Location", project.location)
            HStack(spacing: 10) {
                Button("Edit details") { editing = true }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Delete") { confirmDelete = true }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.top, 4)
        }
        .panel(padding: 20)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(Theme.muted)
            Spacer()
            Text(value.isEmpty ? "—" : value).foregroundStyle(Theme.text2)
        }
        .font(.system(size: 13))
    }

    // MARK: - Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use this folder"
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        var updated = project
        updated.folderPath = url.path
        updated.events.append(ProjectEvent(text: "Footage folder set to \(url.lastPathComponent)"))
        projects.update(updated)
    }

    private func moveToServer() {
        guard let server = ServerFolder.resolve(viewModel.trustSettings) else { return }
        moving = true
        Task {
            do {
                try await projects.moveToServer(project, serverFolder: server)
                viewModel.scan(runAutoApply: false)
            } catch {
                viewModel.errorMessage = "Couldn't move \(project.name) to the server: \(error.localizedDescription)"
            }
            moving = false
        }
    }
}

/// Where finished projects go. Reuses the Archive destination setting, asking once if it's unset.
enum ServerFolder {
    @MainActor
    static func resolve(_ settings: TrustSettings) -> URL? {
        if let path = settings.archiveDestinationPath { return URL(fileURLWithPath: path) }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the folder on the home server where finished projects should go."
        panel.prompt = "Use as server folder"
        guard panel.runModal() == .OK, let url = panel.urls.first else { return nil }
        settings.archiveDestinationPath = url.path
        settings.save()
        return url
    }
}
