import SwiftUI
import AppKit

enum FootageRoute: Hashable {
    case duplicates, cache, organize, retirees
}

/// The footage engine (formerly Deadweight), living inside the business hub: where the SSD's space is going,
/// one-click ways to get it back, and footage grouped by project.
struct FootageView: View {
    @EnvironmentObject private var viewModel: ScanViewModel
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var navigator: Navigator
    @State private var path: [FootageRoute] = []
    @State private var movingAll = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    drives
                    if viewModel.hasScanned {
                        drivePanel
                        reclaim
                        byProject
                        loose
                    } else if !viewModel.roots.isEmpty {
                        Text("Scan the drive to see where its space is going.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.text3)
                            .panel(padding: 22)
                    }
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.ground)
            .navigationDestination(for: FootageRoute.self) { route in
                Group {
                    switch route {
                    case .duplicates: DuplicatesView(viewModel: viewModel)
                    case .cache: CacheCleanupView(viewModel: viewModel)
                    case .organize: OrganizeView(viewModel: viewModel)
                    case .retirees: ArchiveCandidatesView(viewModel: viewModel)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Theme.ground)
            }
        }
    }

    // MARK: - Header and drives

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Footage")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text("Everything on the drive, sorted by project. Finished work goes to the home server.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            Button("Add drive…") { addDrive() }
                .buttonStyle(SecondaryButtonStyle())
            Button {
                viewModel.scan()
            } label: {
                if viewModel.isScanning {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Scanning…") }
                } else {
                    Text("Scan now")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(viewModel.roots.isEmpty || viewModel.isScanning)
        }
    }

    private var drives: some View {
        VStack(alignment: .leading, spacing: 10) {
            if viewModel.roots.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No drive added yet")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("Add Emma's SSD (or a single project folder) and scan it.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted)
                }
                .panel(padding: 22)
            } else {
                ForEach(viewModel.roots, id: \.self) { root in
                    HStack(spacing: 10) {
                        Image(systemName: "externaldrive").foregroundStyle(Theme.text3)
                        Text(root.path)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.text2)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            viewModel.removeRoot(root)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted)
                        }
                        .buttonStyle(.plain)
                        .help("Stop watching this folder")
                    }
                }
                if !viewModel.scanStatusText.isEmpty {
                    Text(viewModel.scanStatusText)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                }
                if let summary = viewModel.lastAutoRunSummary {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.teal)
                        Text(summary).font(.system(size: 13)).foregroundStyle(Theme.text2)
                        Spacer()
                        Button("Undo") { viewModel.undoLastBatch() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    .panel(padding: 12)
                }
            }
        }
    }

    // MARK: - Where the space is going

    private struct Segment: Identifiable {
        let id: String
        let label: String
        let bytes: Int64
        let color: Color
    }

    private var onDriveProjects: [Project] { projects.projects.filter { $0.folderPath != nil && !$0.isOnServer } }

    private func bytes(for projectsList: [Project]) -> Int64 {
        projectsList.reduce(0) { total, project in
            total + project.files(in: viewModel.allFiles).reduce(0) { $0 + $1.sizeBytes }
        }
    }

    private var readyProjects: [Project] { onDriveProjects.filter { $0.stage == .paid } }

    private var segments: [Segment] {
        let active = bytes(for: onDriveProjects.filter { $0.stage != .paid })
        let ready = bytes(for: readyProjects)
        let dupes = viewModel.overview.duplicateWastedBytes
        let cache = viewModel.overview.cacheBytes
        let used = viewModel.roots.first.flatMap(DriveInfo.capacity(for:))?.used ?? (active + ready + dupes + cache)
        let other = max(0, used - active - ready - dupes - cache)
        return [
            Segment(id: "active", label: "Active projects", bytes: active, color: Theme.chartActive),
            Segment(id: "ready", label: "Ready for the server", bytes: ready, color: Theme.chartReady),
            Segment(id: "dupes", label: "Duplicates", bytes: dupes, color: Theme.chartDuplicates),
            Segment(id: "cache", label: "Premiere cache", bytes: cache, color: Theme.chartCache),
            Segment(id: "other", label: "Everything else", bytes: other, color: Theme.chartOther)
        ]
    }

    private var drivePanel: some View {
        let capacity = viewModel.roots.first.flatMap(DriveInfo.capacity(for:))
        let total = max(capacity?.total ?? segments.reduce(0) { $0 + $1.bytes }, 1)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(capacity?.name ?? "Drive")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.text)
                Spacer()
                if let capacity {
                    HeadlineNumber(text: ByteFormat.string(capacity.used), size: 22)
                    Text("of \(ByteFormat.string(capacity.total)) used · \(ByteFormat.string(capacity.free)) free")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.text3)
                }
            }

            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(segments.filter { $0.bytes > 0 }) { segment in
                        Rectangle()
                            .fill(segment.color)
                            .frame(width: max(2, geo.size.width * CGFloat(Double(segment.bytes) / Double(total))))
                            .help("\(segment.label) · \(ByteFormat.string(segment.bytes))")
                    }
                    Rectangle().fill(Theme.line)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 14)
            .accessibilityElement()
            .accessibilityLabel(segments.map { "\($0.label) \(ByteFormat.string($0.bytes))" }.joined(separator: ", "))

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(segments) { segment in
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 3).fill(segment.color).frame(width: 10, height: 10)
                        Text(segment.label).foregroundStyle(Theme.text3)
                        Text(ByteFormat.string(segment.bytes)).fontWeight(.semibold).foregroundStyle(Theme.text)
                    }
                    .font(.system(size: 12))
                }
            }

            if let server = viewModel.trustSettings.archiveDestinationPath {
                Divider().overlay(Theme.lineSoft)
                HStack {
                    Text("Server folder").foregroundStyle(Theme.muted)
                    Text(server)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1).truncationMode(.middle)
                    if let serverCapacity = DriveInfo.capacity(for: URL(fileURLWithPath: server)) {
                        Spacer()
                        Text("\(ByteFormat.string(serverCapacity.free)) free").foregroundStyle(Theme.text2)
                    }
                }
                .font(.system(size: 13))
            }
        }
        .panel(padding: 24)
    }

    // MARK: - Get space back

    private var reclaim: some View {
        let ready = bytes(for: readyProjects)
        let cache = viewModel.overview.cacheBytes
        let dupes = viewModel.overview.duplicateWastedBytes
        let total = ready + cache + dupes
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Get space back")
                Spacer()
                if total > 0, let capacity = viewModel.roots.first.flatMap(DriveInfo.capacity(for:)) {
                    let after = Double(max(0, capacity.used - total)) / Double(max(capacity.total, 1))
                    Text("All three: \(ByteFormat.string(total)) back, drive drops to \(Int((after * 100).rounded()))% full")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text3)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                reclaimTile(color: Theme.chartReady, title: "Ready for the server", bytes: ready,
                            detail: readyProjects.isEmpty
                                ? "Projects marked paid show up here."
                                : "\(readyProjects.count) project\(readyProjects.count == 1 ? "" : "s") delivered and paid.",
                            action: movingAll ? "Moving…" : "Move to server",
                            disabled: readyProjects.isEmpty || movingAll) { moveAllReady() }
                reclaimTile(color: Theme.chartCache, title: "Premiere cache", bytes: cache,
                            detail: "Premiere rebuilds this whenever it needs it. Always safe to clear.",
                            action: "Review", disabled: cache == 0) { path.append(.cache) }
                reclaimTile(color: Theme.chartDuplicates, title: "Duplicates", bytes: dupes,
                            detail: "\(viewModel.duplicateGroups.count) sets of copies. The one linked in Premiere is always kept.",
                            action: "Review", disabled: dupes == 0) { path.append(.duplicates) }
            }
        }
    }

    private func reclaimTile(color: Color, title: String, bytes: Int64, detail: String,
                             action: String, disabled: Bool, perform: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            }
            HeadlineNumber(text: ByteFormat.string(bytes), size: 28)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action, action: perform)
                .buttonStyle(SecondaryButtonStyle())
                .disabled(disabled)
                .opacity(disabled ? 0.5 : 1)
        }
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .panel(padding: 20)
    }

    // MARK: - By project

    private var byProject: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("By project")
                Spacer()
                if let root = viewModel.roots.first {
                    Button("Import folders as projects") {
                        projects.importProjects(fromFoldersIn: root)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 13))
                }
            }
            if onDriveProjects.isEmpty {
                Text("No projects point at folders on this drive yet. Import the drive's folders, or set a footage folder on a project.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text3)
                    .panel(padding: 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(onDriveProjects.enumerated()), id: \.element.id) { index, project in
                        if index > 0 { Divider().overlay(Theme.lineSoft) }
                        projectRow(project)
                    }
                }
                .background(Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
            }
        }
    }

    private func projectRow(_ project: Project) -> some View {
        let files = project.files(in: viewModel.allFiles)
        return HStack(spacing: 18) {
            HStack(spacing: 3) {
                ForEach(files.prefix(3)) { file in
                    ThumbnailImageView(file: file, size: CGSize(width: 56, height: 32))
                }
                ForEach(0..<max(0, 3 - min(files.count, 3)), id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [3]))
                        .frame(width: 56, height: 32)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Button(project.name) { navigator.openProject(project.id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(project.stage.label)
                        .font(.system(size: 12))
                        .foregroundStyle(project.stage == .paid ? Theme.chartReady : Theme.text3)
                }
                StageBar(stage: project.stage).frame(maxWidth: 180)
            }
            Spacer()
            Text(files.isEmpty ? "No footage yet" : "\(files.count) clips · \(ByteFormat.string(files.reduce(0) { $0 + $1.sizeBytes }))")
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(Theme.text3)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Loose clips

    private var looseFiles: [MediaFile] {
        let folders = projects.projects.compactMap { $0.folderPath }.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        return viewModel.allFiles.filter { file in !folders.contains { file.path.hasPrefix($0) } }
    }

    private var loose: some View {
        let files = looseFiles
        return VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Outside any project")
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(files.isEmpty ? "Every clip belongs to a project" : "\(files.count) loose clip\(files.count == 1 ? "" : "s") · \(ByteFormat.string(files.reduce(0) { $0 + $1.sizeBytes }))")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("Sort them into folders by date, camera, location or clip length.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Sort them") { path.append(.organize) }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(viewModel.organizeProposals.isEmpty)
            }
            .panel(padding: 20)

            if !viewModel.archiveCandidates.isEmpty {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(viewModel.archiveCandidates.count) old clip\(viewModel.archiveCandidates.count == 1 ? "" : "s") nobody's touched in a while")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text("Not linked to any Premiere project. Could move to the server too.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button("Review") { path.append(.retirees) }
                        .buttonStyle(SecondaryButtonStyle())
                }
                .panel(padding: 20)
            }
        }
    }

    // MARK: - Actions

    private func addDrive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK {
            panel.urls.forEach(viewModel.addRoot)
        }
    }

    private func moveAllReady() {
        guard let server = ServerFolder.resolve(viewModel.trustSettings) else { return }
        let toMove = readyProjects
        movingAll = true
        Task {
            for project in toMove {
                do {
                    try await projects.moveToServer(project, serverFolder: server)
                } catch {
                    viewModel.errorMessage = "Couldn't move \(project.name) to the server: \(error.localizedDescription)"
                }
            }
            movingAll = false
            viewModel.scan(runAutoApply: false)
        }
    }
}
