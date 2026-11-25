import SwiftUI
import Combine

enum SidebarSection: String, CaseIterable, Identifiable {
    case today = "Today"
    case pipeline = "Pipeline"
    case people = "People"
    case projects = "Projects"
    case footage = "Library"
    case gear = "Gear"
    case money = "Money"
    case logins = "Log-ins"
    case settings = "Settings"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .today: return "sun.max"
        case .pipeline: return "line.3.horizontal.decrease"
        case .people: return "person.2"
        case .projects: return "folder"
        case .footage: return "photo.stack"
        case .gear: return "camera"
        case .money: return "dollarsign"
        case .logins: return "key"
        case .settings: return "gearshape"
        }
    }

    // Pipeline isn't its own place any more: a deal is a project at its Quoting step.
    static var main: [SidebarSection] { [.today, .people, .projects, .footage, .gear, .money, .logins] }
    /// Simple mode keeps the list short: Gear and Log-ins live under "More".
    static var simpleMain: [SidebarSection] { [.today, .people, .projects, .footage, .money] }
    static var simpleMore: [SidebarSection] { [.gear, .logins] }
}

/// Shared navigation state, so any screen can jump to a section or open a project.
@MainActor
final class Navigator: ObservableObject {
    @Published var section: SidebarSection? = .today
    /// "Style" is open.
    @Published var choosingStyle = false
    @Published var projectID: UUID?
    /// What she typed in the Projects search box, kept while she visits other sections.
    @Published var projectQuery = ""
    @Published var dealID: UUID?
    /// The person whose page is open in People.
    @Published var personID: UUID?
    /// Whether the "Find a person" search is showing.
    @Published var findingPerson = false
    /// The deal whose proposal builder is open.
    @Published var builderDealID: UUID?
    /// Whether the Ask Lens panel is open.
    @Published var askOpen = false
    /// A question to drop into the Ask Lens box when it opens. Ask Lens clears it once used.
    @Published var askDraft: String?
    /// The bank, Venmo or PayPal log-in window, when open.
    @Published var bankLogin: LoginID?
    /// Whether the one minute tour is showing.
    @Published var touring = false
    /// Which stop of the tour is showing.
    @Published var tourStep = 0

    func startTour() {
        tourStep = 0
        askOpen = false
        section = .today
        touring = true
    }

    /// Set once at launch, so a deal can be opened as the project it belongs to.
    weak var deals: DealStore?
    weak var projects: ProjectStore?

    func open(_ section: SidebarSection) {
        self.section = section == .pipeline ? .projects : section
        if section == .pipeline { projectID = nil }
    }

    /// A deal is a project at its Quoting step: open that project there.
    func openDeal(_ id: UUID) {
        builderDealID = nil
        openQuote(id)
    }

    /// The proposal builder for a deal, on its project's page.
    func openBuilder(_ id: UUID) {
        openQuote(id)
        builderDealID = id
    }

    private func openQuote(_ id: UUID) {
        dealID = id
        if let deals, let projects, deals.deal(id: id)?.projectID == nil { deals.giveEveryDealAProject(projects) }
        guard let pid = deals?.deal(id: id)?.projectID else { section = .projects; return }
        if projects?.project(id: pid)?.stage == .lead { projectTabs[pid] = .stage(.lead) }
        openProject(pid)
    }

    func openPerson(_ id: UUID) {
        personID = id
        section = .people
    }

    /// A Library page to open when the Library next shows, like one shoot's photos and videos.
    @Published var footageRoute: FootageRoute?
    /// Where she is in the Library (a shoot, a drive, a folder), kept here so going to another
    /// section and back returns her to the same page instead of the top.
    @Published var libraryPath: [FootageRoute] = []
    /// A copy of `libraryPath` taken while the Library is showing. SwiftUI empties the live one
    /// when the Library is put away, so this is what's put back on return.
    var librarySaved: [FootageRoute] = []
    /// The tab each project was last on, so a project opens where she left it.
    var projectTabs: [UUID: ProjectPlace] = [:]

    func openShoot(_ id: UUID) {
        footageRoute = .shoot(id)
        section = .footage
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
    @StateObject private var gmail = GmailSync()
    @StateObject private var zoom = ZoomNotes()
    @StateObject private var people = PeopleStore()
    @StateObject private var quotes = QuoteStore()
    @StateObject private var history = EmailHistory()
    @StateObject private var freshbooks = FreshBooksSync()
    @State private var whatsNew: [WhatsNew.Item] = []
    @ObservedObject private var appearance = Appearance.shared

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
                // The sidebar is deep teal on Daylight too, so it always draws as dark.
                .environment(\.colorScheme, .dark)
        } detail: {
            Group {
                switch navigator.section ?? .today {
                case .today: TodayView()
                case .pipeline: ProjectsView()
                case .people: PeopleView()
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
            .overlay(alignment: .bottomTrailing) {
                if navigator.touring { TourCard().transition(.opacity) }
            }
            .inspector(isPresented: $navigator.askOpen) {
                AskLensView()
                    .inspectorColumnWidth(min: 320, ideal: 380, max: 560)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        navigator.findingPerson.toggle()
                    } label: {
                        Label("Find a person", systemImage: "magnifyingglass")
                    }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .help("Find a person (⇧⌘P)")
                    .popover(isPresented: $navigator.findingPerson, arrowEdge: .bottom) {
                        FindPersonPopover()
                            .environmentObject(people)
                            .environmentObject(navigator)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    // How much every screen shows, one click away wherever she is.
                    Picker("", selection: $appearance.detail) {
                        ForEach(Detail.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Simple shows just what you need. Everything shows every number and option.")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        navigator.askOpen.toggle()
                    } label: {
                        // Words, not just an icon, so it's obvious what it does.
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                            Text("Ask Lens").fontWeight(.semibold)
                        }
                        .font(Theme.font(size: 13))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Palette.violet.opacity(navigator.askOpen ? 0.35 : 0.2))
                        .foregroundStyle(Theme.text)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Palette.violet.opacity(0.55)))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("k", modifiers: .command)
                    .help("Ask Lens (⌘K)")
                }
            }
            .sheet(isPresented: Binding(get: { !whatsNew.isEmpty }, set: { if !$0 { whatsNew = []; WhatsNew.markSeen() } })) {
                WhatsNewView(items: whatsNew)
            }
            .task {
                try? await Task.sleep(for: .seconds(1))
                whatsNew = WhatsNew.unseen()
                if whatsNew.isEmpty { WhatsNew.markSeen() }
            }
            .sheet(item: $navigator.bankLogin) { id in
                BankLoginView(id: id, folder: logins.state.statementsFolder.map { URL(fileURLWithPath: $0) } ?? BankSite.defaultFolder)
                    .environmentObject(logins)
                    .environmentObject(money)
            }
        }
        // A new look redraws the window with its colours (the stores and their data stay as they are).
        .id(appearance.look)
        // Outside the part that redraws, so the picker stays open while the look changes.
        .sheet(isPresented: $navigator.choosingStyle) { StylePickerView() }
        .preferredColorScheme(appearance.look.isDark ? .dark : .light)
        .tint(Theme.teal)
        .environmentObject(appearance)
        .environmentObject(viewModel)
        .environmentObject(projects)
        .environmentObject(deals)
        .environmentObject(logins)
        .environmentObject(ai)
        .environmentObject(money)
        .environmentObject(navigator)
        .environmentObject(gmail)
        .environmentObject(zoom)
        .environmentObject(people)
        .environmentObject(quotes)
        .environmentObject(history)
        .environmentObject(freshbooks)
        // Look at the remembered drive as soon as the app opens, so Today is current right away.
        .task {
            // People: everyone on a deal or project, kept up to date as those change.
            people.attach(deals: deals, projects: projects, money: money, logins: logins)
            ai.attach(deals: deals, projects: projects, navigator: navigator, money: money, people: people)
            // Look through Gmail now and every hour for new inquiries and booked work.
            gmail.attach(deals: deals, projects: projects, logins: logins, ai: ai, people: people)
            gmail.start()
            // Zoom AI summaries, straight from Zoom (or from Gmail until Zoom is connected): attach each to its deal or project.
            zoom.attach(deals: deals, projects: projects, logins: logins, ai: ai)
            ai.attachZoom(zoom)
            ai.attachLogins(logins)
            ai.attachQuotes(quotes)
            // A deal that was attached to a project already past Quoting but never booked (an older way
            // of linking): finish booking it, so its emails, people and price are on the project.
            for d in deals.deals where d.stage.isOpen {
                if let pid = d.projectID, let p = projects.project(id: pid), p.stage != .lead, p.stage != .archived {
                    deals.link(d, to: pid, option: nil, projects: projects)
                }
            }
            // Every deal is a project from the moment it comes in, at Quoting until it's booked.
            navigator.deals = deals
            navigator.projects = projects
            deals.giveEveryDealAProject(projects)
            // Once: each project keeps only emails with its own people, and people Lens added come off.
            ProjectRelevance.me = logins.ownerEmail
            ProjectRelevance.tidy(projects)
            // Once: clear junk Lens added to People before it got stricter.
            if !UserDefaults.standard.bool(forKey: "peopleTidy.v1") {
                UserDefaults.standard.set(true, forKey: "peopleTidy.v1")
                people.tidy()
            }
            ai.attachHistory(history)
            // Every work conversation in Gmail, summarized, with people's details and quotes pulled out.
            history.attach(logins: logins, gmail: gmail, people: people, quotes: quotes, ai: ai)
            history.attachWork(deals: deals, projects: projects, zoom: zoom)
            // FreshBooks invoices and estimates, hourly once connected.
            freshbooks.attach(money: money, quotes: quotes, projects: projects)
            history.start()
            logins.importZoomClient()
            zoom.start()
            // First time Lens opens, show the tour.
            if !UserDefaults.standard.bool(forKey: "tourSeen") { navigator.startTour() }
            Updater.shared.start()
            // A drive Lens knows gets read again whenever it's plugged back in.
            DriveCatalog.shared.onKnownDrivePlugged = { [weak viewModel] url in
                guard let viewModel else { return }
                if !viewModel.roots.contains(where: { $0.path.hasPrefix(url.path) }) { viewModel.addRoot(url) }
                viewModel.scan()
            }
            if !viewModel.pluggedRoots.isEmpty && !viewModel.hasScanned { viewModel.scan() }
        }
        // After every scan (including the rescan an undo triggers), notice footage that came back from the server.
        // Once Google is connected, look at email straight away rather than waiting for the hourly check.
        .onChange(of: logins.gmailReady) { _, ready in
            if ready { Task { await gmail.check(); await zoom.check() } }
        }
        // Zoom just got connected: start reading every summary in the background.
        .onChange(of: logins.zoomConnected) { _, connected in
            if connected { Task { await zoom.check() } }
        }
        // @Published sends the new list before it's stored, so pass it along rather than reading the store.
        .onReceive(deals.$deals) { list in
            people.sync(deals: list, projects: projects.projects)
            DealHistory.pull(list, gmail: gmail)
            // A new inquiry (from Gmail, Ask Lens or by hand) becomes a project at Quoting right away.
            if list.contains(where: { $0.projectID == nil && $0.stage != .won }) {
                DispatchQueue.main.async { deals.giveEveryDealAProject(projects) }
            }
        }
        .onReceive(projects.$projects) { list in
            people.sync(deals: deals.deals, projects: list)
            money.autoTagProjects(list)
            ProjectHistory.pull(list, gmail: gmail, zoom: zoom)
        }
        // New statement lines: put the ones that clearly belong to a project on it (after they're stored).
        .onReceive(money.$data.map(\.txns.count).removeDuplicates().debounce(for: .seconds(2), scheduler: RunLoop.main)) { _ in
            money.autoTagProjects(projects.projects)
        }
        // Everyone on a Zoom call Lens hasn't filed yet goes in People too.
        .onReceive(zoom.$unmatched) { notes in people.noteMeetings(notes) }
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
    @EnvironmentObject private var people: PeopleStore
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var appearance: Appearance
    @AppStorage("sidebarMoreOpen") private var moreOpen = false

    private func row(_ section: SidebarSection) -> some View {
        Label(section.rawValue, systemImage: section.systemImage)
            .badge(section == .projects ? deals.open.filter(\.isStale).count
                   : section == .people ? people.followUpsDue.count
                   : section == .logins ? logins.progress.total - logins.progress.done : 0)
            .tag(section)
    }

    var body: some View {
        List(selection: $navigator.section) {
            HStack(spacing: 9) {
                Image("LensMark")
                    .resizable()
                    .frame(width: 26, height: 26)
                Text("Lens")
                    .font(Theme.isStudio ? Theme.font(size: 17, weight: .bold) : Theme.display(size: 21))
                    .foregroundStyle(Theme.sideText)
            }
            .padding(.vertical, 6)
            .selectionDisabled()
            .accessibilityElement(children: .combine)
            Section {
                if appearance.simple {
                    ForEach(SidebarSection.simpleMain) { row($0) }
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { moreOpen.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Text("More").font(Theme.font(size: 12, weight: .semibold))
                            Image(systemName: moreOpen ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                            Spacer()
                        }
                        .foregroundStyle(Theme.sideMuted)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .selectionDisabled()
                    // Stays showing while one of its screens is open, so the highlight never disappears.
                    if moreOpen || SidebarSection.simpleMore.contains(where: { $0 == navigator.section }) {
                        ForEach(SidebarSection.simpleMore) { row($0) }
                    }
                } else {
                    ForEach(SidebarSection.main) { row($0) }
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
                                        .font(Theme.font(size: 12, weight: .semibold))
                                        .lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text(project.stage.label)
                                        .font(Theme.font(size: 11))
                                        .foregroundStyle(Theme.sideMuted)
                                }
                                StageBar(stage: project.stage, onSidebar: true)
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
                RunningTimerBadge()
                UpdateBanner()
                Button {
                    navigator.choosingStyle = true
                } label: {
                    Label("Style", systemImage: "paintpalette")
                        .font(Theme.font(size: 13))
                        .foregroundStyle(Theme.sideMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Choose how Lens looks and how much each screen shows")
                Button {
                    navigator.open(.settings)
                } label: {
                    Label("Settings", systemImage: SidebarSection.settings.systemImage)
                        .font(Theme.font(size: 13, weight: navigator.section == .settings ? .semibold : .regular))
                        .foregroundStyle(navigator.section == .settings ? Theme.sideText : Theme.sideMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(navigator.section == .settings ? Theme.sideText.opacity(0.12) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                StorageMeter()
                // Which version this is. Click to check for a newer one.
                Button {
                    Task { await Updater.shared.check() }
                } label: {
                    Text("Lens \(Updater.shared.currentVersion)")
                        .font(Theme.font(size: 11))
                        .foregroundStyle(Theme.sideMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 4)
                }
                .buttonStyle(.plain)
                .help("Check for updates")
                .overlay(alignment: .trailing) {
                    Button("Take the tour") { navigator.startTour() }
                        .buttonStyle(.plain)
                        .font(Theme.font(size: 11))
                        .foregroundStyle(Theme.current.sideAccent)
                        .padding(.trailing, 4)
                }
            }
            .padding(12)
            .background(Theme.sidebar)
            .overlay(alignment: .top) { Divider().overlay(Theme.current.sideTrack) }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.sidebar)
        // The highlight on the chosen section: the look's teal rather than the Mac's own accent colour.
        .tint(Theme.isStudio ? Theme.tealDim : Color(hex: 0x1E6B5E))
        .navigationTitle("Lens")
    }
}

/// The SSD's fill level, always visible at the bottom of the sidebar.
struct StorageMeter: View {
    @EnvironmentObject private var viewModel: ScanViewModel
    @EnvironmentObject private var navigator: Navigator
    @ObservedObject private var catalog = DriveCatalog.shared

    var body: some View {
        Button {
            navigator.open(.footage)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                if let root = viewModel.pluggedRoots.first, let capacity = DriveInfo.capacity(for: root) {
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
                } else if !DriveCatalog.shared.outside.isEmpty {
                    let count = DriveCatalog.shared.outside.count
                    Text("\(count) drive\(count == 1 ? "" : "s") in the Library").foregroundStyle(Theme.text3)
                    Text("Plug one in to tidy it").foregroundStyle(Theme.muted)
                } else {
                    Text("No drive added yet").foregroundStyle(Theme.text3)
                    Text("Add one in Library").foregroundStyle(Theme.muted)
                }
            }
            .font(Theme.font(size: 11))
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
                        .font(Theme.font(size: 30, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text(summary)
                        .font(Theme.font(size: 15))
                        .foregroundStyle(Theme.muted)
                }
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel("Coming next")
                    ForEach(points, id: \.self) { point in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle().fill(Theme.tealDim).frame(width: 6, height: 6)
                            Text(point)
                                .font(Theme.font(size: 14))
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
                    Image(systemName: "arrow.down.circle.fill").font(Theme.font(size: 18))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Lens \(release.version) is ready").font(Theme.font(size: 12, weight: .semibold))
                        Text(phaseText ?? "Install and restart").font(Theme.font(size: 11)).opacity(0.8)
                    }
                    Spacer()
                }
                .padding(10)
                .background(Theme.teal.opacity(0.2))
                .background(Theme.panel)
                .foregroundStyle(Theme.text)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(updater.phase == .downloading || updater.phase == .installing)
            .help(release.notes)
        } else if let text = phaseText {
            Text(text).font(Theme.font(size: 11)).foregroundStyle(Theme.sideMuted)
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

/// When people, keywords or a name are added to a project, Lens goes back through Gmail and every Zoom
/// summary for everything about it, however old, so the project page has its whole history.
@MainActor
enum ProjectHistory {
    private static var running = Set<UUID>()

    static func pull(_ list: [Project], gmail: GmailSync, zoom: ZoomNotes) {
        for project in list where project.stage != .archived {
            let people = (project.people ?? []).map { "\($0.name.lowercased())|\($0.email.lowercased())" }.sorted()
            let signature = ([project.name.lowercased()] + people + (project.keywords ?? []).map { $0.lowercased() }.sorted())
                .joined(separator: ";")
            let key = "history.\(project.id.uuidString)"
            guard !(project.people ?? []).isEmpty || !(project.keywords ?? []).isEmpty,
                  UserDefaults.standard.string(forKey: key) != signature, !running.contains(project.id) else { continue }
            running.insert(project.id)
            Task {
                // Give Emma a moment to finish typing before searching.
                try? await Task.sleep(for: .seconds(5))
                await gmail.backfill(project)
                await zoom.backfill(project)
                UserDefaults.standard.set(signature, forKey: key)
                running.remove(project.id)
            }
        }
    }
}

/// When a deal gets its people (or its first email), Lens goes back through Gmail for every conversation
/// with them, however old, so the deal shows the whole thread of the job.
@MainActor
enum DealHistory {
    private static var running = Set<UUID>()

    static func pull(_ list: [Deal], gmail: GmailSync) {
        for deal in list where deal.stage != .lost {
            var people = deal.contacts.map { $0.email.lowercased() }.filter { $0.contains("@") }
            for t in deal.emails ?? [] { people += GmailSync.emails(in: t).map { $0.lowercased() } }
            let signature = Set(people).sorted().joined(separator: ";")
            let key = "dealHistory.\(deal.id.uuidString)"
            guard !signature.isEmpty, UserDefaults.standard.string(forKey: key) != signature, !running.contains(deal.id) else { continue }
            running.insert(deal.id)
            Task {
                try? await Task.sleep(for: .seconds(5))
                await gmail.backfill(deal: deal)
                UserDefaults.standard.set(signature, forKey: key)
                running.remove(deal.id)
            }
        }
    }
}
