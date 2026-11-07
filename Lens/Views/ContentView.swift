import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case today = "Today"
    case pipeline = "Pipeline"
    case projects = "Projects"
    case footage = "Footage"
    case gear = "Gear"
    case money = "Money"
    case logins = "Log-ins"
    case settings = "Settings"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .today: return "sun.max"
        case .pipeline: return "line.3.horizontal.decrease"
        case .projects: return "folder"
        case .footage: return "film"
        case .gear: return "camera"
        case .money: return "dollarsign"
        case .logins: return "key"
        case .settings: return "gearshape"
        }
    }

    static var main: [SidebarSection] { [.today, .pipeline, .projects, .footage, .gear, .money, .logins] }
}

/// Shared navigation state, so any screen can jump to a section or open a project.
@MainActor
final class Navigator: ObservableObject {
    @Published var section: SidebarSection? = .today
    @Published var projectID: UUID?
    @Published var dealID: UUID?
    /// The deal whose proposal builder is open.
    @Published var builderDealID: UUID?
    /// Whether the Ask Lens panel is open.
    @Published var askOpen = false

    func open(_ section: SidebarSection) {
        self.section = section
    }

    func openDeal(_ id: UUID) {
        dealID = id
        builderDealID = nil
        section = .pipeline
    }

    func openBuilder(_ id: UUID) {
        dealID = id
        builderDealID = id
        section = .pipeline
    }

    func openProject(_ id: UUID) {
        projectID = id
        section = .projects
    }
}

struct ContentView: View {
    @StateObject private var viewModel = ScanViewModel()
    @StateObject private var projects = ProjectStore()
    @StateObject private var deals = DealStore()
    @StateObject private var logins = ConnectionStore()
    @StateObject private var ai = LensAI()
    @StateObject private var money = MoneyStore()
    @StateObject private var navigator = Navigator()

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            Group {
                switch navigator.section ?? .today {
                case .today: TodayView()
                case .pipeline: PipelineView()
                case .projects: ProjectsView()
                case .footage: FootageView()
                case .gear: GearView()
                case .money: MoneyView()
                case .logins: LoginsView()
                case .settings: SettingsView(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.ground)
            .inspector(isPresented: $navigator.askOpen) {
                AskLensView()
                    .inspectorColumnWidth(min: 320, ideal: 380, max: 560)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        navigator.askOpen.toggle()
                    } label: {
                        Label("Ask Lens", systemImage: "sparkles")
                    }
                    .keyboardShortcut("k", modifiers: .command)
                    .help("Ask Lens (⌘K)")
                }
            }
        }
        .environmentObject(viewModel)
        .environmentObject(projects)
        .environmentObject(deals)
        .environmentObject(logins)
        .environmentObject(ai)
        .environmentObject(money)
        .environmentObject(navigator)
        // Look at the remembered drive as soon as the app opens, so Today is current right away.
        .task {
            ai.attach(deals: deals, projects: projects, navigator: navigator, money: money)
            Updater.shared.start()
            if !viewModel.roots.isEmpty && !viewModel.hasScanned { viewModel.scan() }
        }
        // After every scan (including the rescan an undo triggers), notice footage that came back from the server.
        .onChange(of: viewModel.isScanning) { _, scanning in
            if !scanning { projects.reconcileArchives() }
        }
        .alert("Auto-apply paused", isPresented: .constant(viewModel.pendingCheckpointMessage != nil)) {
            Button("OK") { viewModel.pendingCheckpointMessage = nil }
        } message: {
            Text(viewModel.pendingCheckpointMessage ?? "")
        }
        .alert("Something went wrong", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject private var viewModel: ScanViewModel
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var deals: DealStore
    @EnvironmentObject private var logins: ConnectionStore
    @EnvironmentObject private var navigator: Navigator

    var body: some View {
        List(selection: $navigator.section) {
            HStack(spacing: 9) {
                Image("LensMark")
                    .resizable()
                    .frame(width: 26, height: 26)
                Text("Lens")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.text)
            }
            .padding(.vertical, 6)
            .selectionDisabled()
            .accessibilityElement(children: .combine)
            Section {
                ForEach(SidebarSection.main) { section in
                    Label(section.rawValue, systemImage: section.systemImage)
                        .badge(section == .pipeline ? deals.open.filter(\.isStale).count
                               : section == .logins ? logins.progress.total - logins.progress.done : 0)
                        .tag(section)
                }
            }

            if !projects.active.isEmpty {
                Section("Active projects") {
                    ForEach(projects.active.prefix(6)) { project in
                        Button {
                            navigator.openProject(project.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(project.name)
                                        .font(.system(size: 12, weight: .semibold))
                                        .lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text(project.stage.label)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.text3)
                                }
                                StageBar(stage: project.stage)
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                UpdateBanner()
                Button {
                    navigator.open(.settings)
                } label: {
                    Label("Settings", systemImage: SidebarSection.settings.systemImage)
                        .font(.system(size: 13, weight: navigator.section == .settings ? .semibold : .regular))
                        .foregroundStyle(navigator.section == .settings ? Theme.text : Theme.text3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(navigator.section == .settings ? Theme.raised : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                StorageMeter()
            }
            .padding(12)
            .background(Theme.sidebar)
            .overlay(alignment: .top) { Divider().overlay(Theme.line) }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.sidebar)
        .navigationTitle("Lens")
    }
}

/// The SSD's fill level, always visible at the bottom of the sidebar.
struct StorageMeter: View {
    @EnvironmentObject private var viewModel: ScanViewModel
    @EnvironmentObject private var navigator: Navigator

    var body: some View {
        Button {
            navigator.open(.footage)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                if let root = viewModel.roots.first, let capacity = DriveInfo.capacity(for: root) {
                    HStack {
                        Text(capacity.name).foregroundStyle(Theme.text3)
                        Spacer()
                        Text("\(Int((capacity.fractionUsed * 100).rounded()))% full")
                            .fontWeight(.semibold)
                            .foregroundStyle(capacity.fractionUsed > 0.8 ? Theme.amber : Theme.text2)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.track)
                            Capsule()
                                .fill(capacity.fractionUsed > 0.8 ? Theme.amber : Theme.tealDim)
                                .frame(width: geo.size.width * capacity.fractionUsed)
                        }
                    }
                    .frame(height: 4)
                    Text("\(ByteFormat.string(capacity.free)) free")
                        .foregroundStyle(Theme.muted)
                } else {
                    Text("No drive added yet").foregroundStyle(Theme.text3)
                    Text("Add one in Footage").foregroundStyle(Theme.muted)
                }
            }
            .font(.system(size: 11))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Placeholder for sections still to come

struct ComingSoonView: View {
    let title: String
    let summary: String
    let points: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text(summary)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.muted)
                }
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel("Coming next")
                    ForEach(points, id: \.self) { point in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle().fill(Theme.tealDim).frame(width: 6, height: 6)
                            Text(point)
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.text2)
                        }
                    }
                }
                .panel(padding: 22)
                .frame(maxWidth: 640, alignment: .leading)
            }
            .padding(40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}


/// Shows up at the bottom of the sidebar when a new version of Lens is ready.
struct UpdateBanner: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        if let release = updater.available {
            Button {
                Task { await updater.install() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Lens \(release.version) is ready").font(.system(size: 12, weight: .semibold))
                        Text(phaseText ?? "Install and restart").font(.system(size: 11)).opacity(0.8)
                    }
                    Spacer()
                }
                .padding(10)
                .background(Theme.teal.opacity(0.2))
                .foregroundStyle(Theme.text)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(updater.phase == .downloading || updater.phase == .installing)
            .help(release.notes)
        } else if let text = phaseText {
            Text(text).font(.system(size: 11)).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var phaseText: String? {
        switch updater.phase {
        case .checking: return "Checking for updates…"
        case .upToDate: return "Lens \(updater.currentVersion) is up to date"
        case .downloading: return "Downloading…"
        case .installing: return "Installing…"
        case .failed(let message): return message
        case .idle: return nil
        }
    }
}
