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
                case .gear:
                    ComingSoonView(title: "Gear", summary: "Everything you own, what it's worth today, and when it was last looked after.", points: [
                        "Gear added automatically from receipts",
                        "Value today, which feeds into what the business is worth",
                        "Pack lists for each shoot",
                        "Service reminders based on how much each piece gets used"
                    ])
                case .money:
                    ComingSoonView(title: "Money", summary: "Three questions every business owner should be able to answer.", points: [
                        "Did I make money? (income statement)",
                        "Where did the cash go? (cash flow)",
                        "What's it all worth? (balance sheet)",
                        "Read-only links to your bank, card, PayPal and Venmo"
                    ])
                case .logins: LoginsView()
                case .settings: SettingsView(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.ground)
        }
        .environmentObject(viewModel)
        .environmentObject(projects)
        .environmentObject(deals)
        .environmentObject(logins)
        .environmentObject(navigator)
        // Look at the remembered drive as soon as the app opens, so Today is current right away.
        .task {
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
