import SwiftUI
import AppKit

enum FootageRoute: Hashable {
    case duplicates, cache, organize, retirees, cleanupList
    case folder(driveID: String, path: String)
    case drive(id: String)
    case shoot(UUID)
    case unsorted(driveID: String, folder: String)
}

/// The Library: every shoot's photos and videos, on every drive, sorted the way she asks. Below
/// that, the drives themselves; in Everything, where each drive's space is going and how to get it back.
struct FootageView: View {
    @EnvironmentObject private var viewModel: ScanViewModel
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var appearance: Appearance
    @State private var query = ""
    @State private var path: [FootageRoute] = []
    @State private var movingAll = false
    @State private var addingSite = false
    /// Watched so the page updates the moment a drive is plugged in or pulled out.
    @ObservedObject private var catalog = DriveCatalog.shared

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    LibraryDrivesView(part: .search, query: $query)
                    LibraryShootsView(query: query)
                    drivesSection
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.ground)
            .sheet(isPresented: $addingSite) { SiteImportView() }
            .navigationDestination(for: FootageRoute.self) { route in
                Group {
                    switch route {
                    case .duplicates: DuplicatesView(viewModel: viewModel)
                    case .cache: CacheCleanupView(viewModel: viewModel)
                    case .organize: OrganizeView(viewModel: viewModel)
                    case .retirees: ArchiveCandidatesView(viewModel: viewModel)
                    case .cleanupList: CleanupExplainedView(viewModel: viewModel)
                    case .folder(let driveID, let path): LibraryFolderView(driveID: driveID, folder: path)
                    case .drive(let id): LibraryDriveView(driveID: id)
                    case .shoot(let id): ShootFilesView(subject: .project(id))
                    case .unsorted(let driveID, let folder): ShootFilesView(subject: .folder(driveID: driveID, folder: folder))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Theme.ground)
            }
        }
    }

    // MARK: - Header and drives

    /// Whether any drive being tidied is plugged in right now.
    private var pluggedRoots: Bool {
        !viewModel.pluggedRoots.isEmpty
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Library")
                    .font(Theme.font(size: 30, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text("Every shoot, on every drive. Find footage by project, date, place or camera.")
                    .font(Theme.font(size: 15))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            Button("Add a website…") { addingSite = true }
                .buttonStyle(SecondaryButtonStyle())
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
            .disabled(viewModel.pluggedRoots.isEmpty || viewModel.isScanning)
        }
    }

    /// The drives themselves. Simple shows them and what's happening; Everything adds the space
    /// on each drive and the ways to get it back.
    private var drivesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Drives")
                Spacer()
                if !appearance.simple, let root = viewModel.pluggedRoots.first {
                    Button("Make projects from this drive's folders") {
                        projects.importProjects(fromFoldersIn: root)
                    }
                    .buttonStyle(.link)
                    .font(Theme.font(size: 13))
                }
            }
            LibraryDrivesView(part: .drives, query: $query)
            drives
            if !appearance.simple {
                if viewModel.hasScanned && !pluggedRoots {
                    Text("Plug in a drive to tidy it up. Everything on your drives is still searchable above.")
                        .font(Theme.font(size: 14))
                        .foregroundStyle(Theme.text3)
                        .panel(padding: 22)
                } else if viewModel.hasScanned {
                    drivePanel
                    reclaim
                    loose
                } else if !viewModel.pluggedRoots.isEmpty {
                    Text("Scan the drive to see where its space is going.")
                        .font(Theme.font(size: 14))
                        .foregroundStyle(Theme.text3)
                        .panel(padding: 22)
                }
            }
        }
    }

    private var drives: some View {
        VStack(alignment: .leading, spacing: 10) {
            if viewModel.roots.isEmpty {
                EmptyView()
            } else {
                ForEach(appearance.simple ? [] : viewModel.pluggedRoots, id: \.self) { root in
                    HStack(spacing: 10) {
                        Image(systemName: "externaldrive").foregroundStyle(Theme.text3)
                        Text(root.path)
                            .font(Theme.font(size: 12, design: .monospaced))
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
                        .font(Theme.font(size: 13))
                        .foregroundStyle(Theme.muted)
                }
                if let summary = viewModel.lastAutoRunSummary {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.teal)
                        Text(summary).font(Theme.font(size: 13)).foregroundStyle(Theme.text2)
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
                    .font(Theme.font(size: 17, weight: .bold))
                    .foregroundStyle(Theme.text)
                Spacer()
                if let capacity {
                    HeadlineNumber(text: ByteFormat.string(capacity.used), size: 22)
                    Text("of \(ByteFormat.string(capacity.total)) used · \(ByteFormat.string(capacity.free)) free")
                        .font(Theme.font(size: 14))
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
                    .font(Theme.font(size: 12))
                }
            }

            if let server = viewModel.trustSettings.archiveDestinationPath {
                Divider().overlay(Theme.lineSoft)
                HStack {
                    Text("Server folder").foregroundStyle(Theme.muted)
                    Text(server)
                        .font(Theme.font(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1).truncationMode(.middle)
                    if let serverCapacity = DriveInfo.capacity(for: URL(fileURLWithPath: server)) {
                        Spacer()
                        Text("\(ByteFormat.string(serverCapacity.free)) free").foregroundStyle(Theme.text2)
                    }
                }
                .font(Theme.font(size: 13))
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
                Button("See exactly what's included") { path.append(.cleanupList) }
                    .buttonStyle(.link).font(Theme.font(size: 13))
                Spacer()
                if total > 0, let capacity = viewModel.roots.first.flatMap(DriveInfo.capacity(for:)) {
                    let after = Double(max(0, capacity.used - total)) / Double(max(capacity.total, 1))
                    Text("All three: \(ByteFormat.string(total)) back, drive drops to \(Int((after * 100).rounded()))% full")
                        .font(Theme.font(size: 13))
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
                Text(title).font(Theme.font(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
            }
            HeadlineNumber(text: ByteFormat.string(bytes), size: 28)
            Text(detail)
                .font(Theme.font(size: 13))
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
                        .font(Theme.font(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text("Sort them into folders by date, camera, location or clip length.")
                        .font(Theme.font(size: 13))
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
                            .font(Theme.font(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text("Not linked to any Premiere project. Could move to the server too.")
                            .font(Theme.font(size: 13))
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
