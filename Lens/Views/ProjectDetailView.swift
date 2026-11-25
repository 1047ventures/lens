import SwiftUI
import AppKit

/// One project's hub: where it is in the lifecycle, and everything for it in one place, in tabs:
/// Overview, People, Meeting notes, Emails, Proposal and files, Hours, Money.
struct ProjectDetailView: View {
    let project: Project
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var deals: DealStore
    @EnvironmentObject private var zoom: ZoomNotes
    @State private var place: ProjectPlace = .tab(.overview)
    @EnvironmentObject private var viewModel: ScanViewModel
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var money: MoneyStore
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var moving = false
    @EnvironmentObject private var appearance: Appearance
    @State private var addingPerson = false
    @EnvironmentObject private var quotes: QuoteStore
    @State private var showWon = false
    @State private var showLost = false
    @State private var showFollowUp = false
    /// The step chip she clicked on the simple page, to peek at what happened in it.
    @State private var simplePeek: ProjectStage?
    /// The quote behind this project, when it has one (every inquiry does).
    private var quote: Deal? { deals.quote(for: project) }

    @ObservedObject private var index = LibraryIndex.shared
    @ObservedObject private var links = LibraryLinks.shared
    @ObservedObject private var catalog = DriveCatalog.shared
    private var books: ProjectBooks { ProjectBooks.make(project, money: money, deals: deals) }

    var body: some View {
        Group {
            if let quote, navigator.builderDealID == quote.id {
                ProposalBuilderView(dealID: quote.id)
            } else if appearance.simple { simpleBody } else { everythingBody }
        }
        .sheet(isPresented: $showWon) { if let quote { WonSheet(dealID: quote.id) } }
        .sheet(isPresented: $showLost) { if let quote { LostSheet(dealID: quote.id) } }
        .sheet(isPresented: $showFollowUp) { if let quote { FollowUpSheet(dealID: quote.id) } }
        // Back where she left this project, even after visiting another section; a project she
        // hasn't opened yet starts on the step it's at.
        .onAppear { place = navigator.projectTabs[project.id] ?? .stage(project.stage) }
        .onChange(of: project.id) { _, id in
            simplePeek = nil
            place = navigator.projectTabs[id] ?? .stage(projects.project(id: id)?.stage ?? .lead)
        }
        .onChange(of: place) { _, now in navigator.projectTabs[project.id] = now }
        // When she moves the project on, follow it if she was looking at the step it left.
        .onChange(of: project.stage) { old, new in if place == .stage(old) { place = .stage(new) } }
    }

    /// Overview's boxes in their usual order; she can rearrange, resize or hide them.
    private var overviewBoxes: [PageBox] {
        [
            PageBox("footage", "Footage", color: Theme.teal) { footagePanel },
            PageBox("story", "The story so far", color: Theme.teal, half: true) { story },
            PageBox("details", "Details", color: Theme.teal, half: true) { details },
            PageBox("glance", "In this project", color: Theme.teal, half: true) { atAGlance },
            PageBox("autoFiled", "Filed by Lens", color: Theme.amber, half: true) { AutoFiledPanel(project: project) },
        ]
    }

    /// The simple page's boxes in their usual order; the name and dates stay at the top.
    private var simpleBoxes: [PageBox] {
        var boxes: [PageBox] = [
            PageBox("stage", "Where it's at", color: Theme.teal) { simpleStageLine },
            PageBox("next", "Next up", color: Theme.coral) { simpleNextUp },
            PageBox("people", "Who's on it", color: Palette.orchid) { simplePeople },
        ]
        if !moneySentences.isEmpty { boxes.append(PageBox("money", "Money", color: Palette.lime) { simpleMoney }) }
        if !(project.emails ?? []).isEmpty {
            boxes.append(PageBox("emails", "Latest emails", color: Palette.blue) { simpleEmails })
        }
        boxes.append(PageBox("more", "Where to find the rest", color: Theme.muted) { simpleFooter })
        return boxes
    }

    private var everythingBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Button {
                    navigator.projectID = nil
                } label: {
                    Label("All projects", systemImage: "chevron.left")
                        .font(Theme.font(size: 13))
                        .foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)

                header
                stageTrack
                tabBar
                switch place {
                case .stage(let step):
                    ProjectStageView(project: project, stage: step, books: books, footage: footagePanel) { place = .tab($0) }
                case .tab(.overview):
                    ArrangeablePage("project", columns: true, spacing: 28, boxes: overviewBoxes)
                case .tab(.people):
                    ProjectPeopleTab(project: project)
                case .tab(.notes): ProjectNotesTab(project: project)
                case .tab(.emails): ProjectEmailsTab(project: project)
                case .tab(.proposal): ProjectProposalTab(project: project)
                case .tab(.hours):
                    VStack(alignment: .leading, spacing: 28) {
                        ProjectTimePanel(project: project, books: books)
                        ProjectHoursTab(project: project)
                    }
                case .tab(.money):
                    VStack(alignment: .leading, spacing: 28) {
                        ProjectMoneyPanel(project: project, books: books)
                        ProjectMoneyTab(project: project)
                    }
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
                if let quote, quote.stage != .won { deals.delete(quote) }
                projects.delete(project)
            }
        } message: {
            Text("This removes the project from Lens. Its footage folder stays where it is.")
        }
    }

    // MARK: - Tabs

    private func count(_ t: ProjectTab) -> Int? {
        switch t {
        case .people: return project.people?.count ?? 0
        case .notes: return project.meetingNotes?.count ?? 0
        case .emails: return project.emails?.count ?? 0
        case .proposal:
            return (project.documents?.count ?? 0) + (deals.deals.contains { $0.projectID == project.id } ? 1 : 0)
        case .overview, .hours, .money: return nil
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(ProjectTab.allCases) { t in
                    let label = count(t).map { "\(t.rawValue) · \($0)" } ?? t.rawValue
                    let waiting = t == .notes ? zoom.waiting(for: project.id).count : 0
                    let on = place == .tab(t)
                    Button {
                        place = .tab(t)
                    } label: {
                        HStack(spacing: 6) {
                            Text(label)
                            if waiting > 0 {
                                Text("\(waiting) new")
                                    .font(Theme.font(size: 11, weight: .bold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Palette.violet.opacity(0.25))
                                    .foregroundStyle(Palette.violet)
                                    .clipShape(Capsule())
                            }
                        }
                        .font(Theme.font(size: 13, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? Theme.text : Theme.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(on ? Theme.raised : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .padding(4)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Theme.line))
    }

    /// A short list on Overview of what's in the other tabs, each one tap away.
    private var atAGlance: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("In this project")
            ForEach([ProjectTab.people, .notes, .emails, .proposal]) { t in
                Button { place = .tab(t) } label: {
                    HStack {
                        Text(t.rawValue).foregroundStyle(Theme.text2)
                        Spacer()
                        Text("\(count(t) ?? 0)").foregroundStyle(Theme.muted)
                        Image(systemName: "chevron.right").font(Theme.font(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                    }
                    .font(Theme.font(size: 13))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .panel(padding: 20)
    }

    // MARK: - Header and lifecycle

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(project.name)
                    .font(Theme.font(size: 30, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 20)
                if let price = headerPrice { HeadlineNumber(text: price, size: 26) }
            }
            let meta = [project.client,
                        project.shootDate?.formatted(date: .complete, time: .shortened) ?? "",
                        project.location,
                        project.stage == .lead && !(quote?.source ?? "").isEmpty ? "came in by \(quote!.source.lowercased())" : ""]
                .filter { !$0.isEmpty }
            if !meta.isEmpty {
                Text(meta.joined(separator: " · "))
                    .font(Theme.font(size: 14))
                    .foregroundStyle(Theme.text3)
            }
            ProjectSummaryView(project: project, size: 16)
                .padding(.top, 4)
        }
    }

    /// The price: what's being quoted while it's at Quoting, what it's booked at after.
    private var headerPrice: String? {
        if project.stage == .lead, let quote {
            let text = deals.valueText(of: quote)
            return text == "No price yet" || text.isEmpty ? nil : text
        }
        return books.price.map { Money.short($0) }
    }

    private var stageTrack: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Each step opens what happened in it (or what's coming); the bar is the way around a project.
            HStack(alignment: .top, spacing: 4) {
                ForEach(ProjectStage.allCases) { step in
                    StageStep(step: step, current: project.stage, selected: place == .stage(step),
                              name: step == .archived && deals.didntBook(project) ? "Didn't book" : step.label) {
                        place = .stage(step)
                    }
                }
            }

            HStack(spacing: 10) {
                if project.stage == .lead, let quote, quote.stage.isOpen {
                    quotingActions(quote)
                } else if let quote, quote.stage == .lost, project.stage == .archived {
                    Button("Reopen") { deals.reopen(quote, projects: projects) }.buttonStyle(PrimaryButtonStyle())
                        .help("They came back: put it back at Quoting")
                } else if project.stage == .paid, project.folderPath != nil, !project.isOnServer {
                    Button(moving ? "Moving…" : "Move footage to the server") { moveToServer() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(moving)
                } else if let next = project.stage.next, next != .archived {
                    Button(next.moveLabel) {
                        projects.setStage(next, for: project)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                if project.stage != .lead, let previous = ProjectStage(rawValue: project.stage.rawValue - 1),
                   project.stage != .archived {
                    Button("Back to \(previous.label.lowercased())") {
                        projects.setStage(previous, for: project, note: "Moved back to \(previous.label)")
                        // Back to quoting means the quote is open again.
                        if previous == .lead, let quote, quote.stage == .won { deals.setStage(.talking, for: quote, note: "Back to quoting") }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    /// The buttons while it's at Quoting: the same spot every step's buttons sit in.
    @ViewBuilder private func quotingActions(_ quote: Deal) -> some View {
        let uploaded = quotes.uploadedProposal(dealID: quote.id, projectID: project.id) != nil
        if quote.stage == .inquiry {
            if uploaded {
                Button("Open your proposal") { quotes.openProposal(for: quote, deals: deals, projects: projects) }
                    .buttonStyle(PrimaryButtonStyle())
            } else {
                Button("Build proposal · \(BuilderStep.progress(quote))/\(BuilderStep.allCases.count)") { navigator.builderDealID = quote.id }
                    .buttonStyle(PrimaryButtonStyle())
            }
            Button("Quote sent") { deals.setStage(.proposalOut, for: quote, note: "Quote sent") }
                .buttonStyle(SecondaryButtonStyle())
            Button("Mark as booked…") { showWon = true }.buttonStyle(SecondaryButtonStyle())
                .help("They said yes: on to Planning")
        } else {
            Button("Mark as booked…") { showWon = true }.buttonStyle(PrimaryButtonStyle())
                .help("They said yes: on to Planning")
            if uploaded {
                Button("Open your proposal") { quotes.openProposal(for: quote, deals: deals, projects: projects) }
                    .buttonStyle(SecondaryButtonStyle())
            } else {
                Button("Proposal") { navigator.builderDealID = quote.id }.buttonStyle(SecondaryButtonStyle())
            }
        }
        Button("Log a follow-up") { showFollowUp = true }.buttonStyle(SecondaryButtonStyle())
        Button("Didn't book…") { showLost = true }.buttonStyle(SecondaryButtonStyle())
    }

    // MARK: - Footage

    /// The photos and videos the Library has filed under this project, on any drive.
    private var libraryFiles: (photos: Int, videos: Int, bytes: Int64, sample: [LibraryItem]) {
        let shelf = index.shelf(projects: projects.projects, links: links, catalog: catalog)
        var photos = 0, videos = 0, bytes: Int64 = 0
        var items: [LibraryItem] = []
        for i in shelf.byProject[project.id] ?? [] where index.folders.indices.contains(i) {
            let f = index.folders[i]
            photos += f.photos; videos += f.videos; bytes += f.bytes
            items += f.items.compactMap { index.items.indices.contains($0) ? index.items[$0] : nil }
        }
        let picked = items.filter { $0.kind == .photo || $0.kind == .video }.sorted { $0.date < $1.date }
        let step = max(picked.count / 5, 1)
        let sample = stride(from: 0, to: picked.count, by: step).prefix(5).map { picked[$0] }
        return (photos, videos, bytes, sample)
    }

    private var footagePanel: some View {
        let found = libraryFiles
        return VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Footage")
            if found.photos + found.videos > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    HeadlineNumber(text: "\(found.photos + found.videos)", size: 30)
                    Text(footageCounts(found.photos, found.videos, found.bytes))
                        .font(Theme.font(size: 14))
                        .foregroundStyle(Theme.text3)
                }
                Button { navigator.openShoot(project.id) } label: {
                    HStack(spacing: 4) {
                        ForEach(found.sample) { item in
                            Thumbnail(url: LibraryFiles.url(of: item, catalog: catalog), assetID: item.assetID, kind: item.kind)
                                .frame(width: 88, height: 56)
                                .background(Theme.raised)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .buttonStyle(.plain)
            } else if project.folderURL != nil || project.isOnServer {
                Text("Lens hasn't looked in this project's folder yet. Look at its drive in Library and the photos and videos show up here.")
                    .font(Theme.font(size: 14))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No footage folder yet. Pick the folder this project's photos and videos live in.")
                    .font(Theme.font(size: 14))
                    .foregroundStyle(Theme.text3)
            }
            if let path = project.isOnServer ? project.archivedPath : project.folderPath {
                Text((project.isOnServer ? "On the server: " : "") + path)
                    .font(Theme.font(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: 10) {
                if found.photos + found.videos > 0 {
                    Button("See the photos and videos") { navigator.openShoot(project.id) }
                        .buttonStyle(PrimaryButtonStyle())
                } else if project.folderURL != nil || project.isOnServer {
                    Button("Open Library") { navigator.open(.footage) }
                        .buttonStyle(SecondaryButtonStyle())
                } else {
                    Button("Choose folder…") { chooseFolder() }
                        .buttonStyle(SecondaryButtonStyle())
                }
                if let path = project.isOnServer ? project.archivedPath : project.folderPath {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .panel(padding: 22)
        .onAppear { index.start() }
    }

    private func footageCounts(_ photos: Int, _ videos: Int, _ bytes: Int64) -> String {
        var parts: [String] = []
        if photos > 0 { parts.append("\(photos) photo\(photos == 1 ? "" : "s")") }
        if videos > 0 { parts.append("\(videos) video\(videos == 1 ? "" : "s")") }
        parts.append(ByteFormat.string(bytes))
        return parts.joined(separator: " · ")
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
                            .font(Theme.font(size: 12))
                            .foregroundStyle(Theme.muted)
                            .frame(width: 52, alignment: .leading)
                        Circle()
                            .fill(isLatest ? Theme.text : Theme.tealDim)
                            .frame(width: 9, height: 9)
                            .padding(.top, 4)
                        Text(event.text)
                            .font(Theme.font(size: 14, weight: isLatest ? .semibold : .regular))
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
            detailRow("Keywords", (project.keywords ?? []).joined(separator: ", "))
            detailRow("Price", books.price.map { Money.string($0) } ?? "")
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
        .font(Theme.font(size: 13))
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


// MARK: - Simple

extension ProjectDetailView {
    /// The steps on the simple page. Put away folds into Wrapping up.
    private var chips: [ProjectStage] { [.lead, .booked, .shoot, .edit, .delivered, .paid] }

    /// The chip that lights up as where the project is now.
    private var currentChip: ProjectStage { project.stage == .archived ? .paid : project.stage }

    private var stageSentence: String {
        switch project.stage {
        case .lead: return "You're quoting"
        case .booked: return "You're planning"
        case .shoot: return "You're shooting"
        case .edit: return "You're editing"
        case .delivered: return "You're getting paid"
        case .paid: return "You're wrapping up"
        case .archived: return deals.didntBook(project) ? "This one didn't book" : "This one's put away"
        }
    }

    var simpleBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Button {
                    navigator.projectID = nil
                } label: {
                    Label("All projects", systemImage: "chevron.left")
                        .font(Theme.font(size: 13)).foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)

                simpleHeader
                ArrangeablePage("project", spacing: 26, boxes: simpleBoxes)
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $addingPerson) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Who's on it").font(Theme.display(size: 22)).foregroundStyle(Theme.text)
                ScrollView { ProjectPeopleTab(project: project) }
                HStack { Spacer(); Button("Done") { addingPerson = false }.buttonStyle(PrimaryButtonStyle()) }
            }
            .padding(24)
            .frame(width: 640, height: 520)
        }
    }

    private var simpleHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            let when = [project.shootDate?.formatted(.dateTime.month(.wide).day()) ?? "", project.location]
                .filter { !$0.isEmpty }.joined(separator: ", ")
            let meta = [project.client, when].filter { !$0.isEmpty }.joined(separator: " · ")
            if !meta.isEmpty {
                Text(meta).font(Theme.font(size: 13)).foregroundStyle(Theme.muted)
            }
            Text(project.name).font(Theme.display(size: 38)).foregroundStyle(Theme.text)
            ProjectSummaryView(project: project, size: 17)
                .padding(.top, 2)
        }
    }

    private var simpleStageLine: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(stageSentence).font(Theme.font(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            HStack(spacing: 8) {
                ForEach(chips) { step in
                    let current = step == currentChip
                    let past = step.rawValue < currentChip.rawValue
                    let peeking = simplePeek == step && !current
                    Button {
                        simplePeek = current || peeking ? nil : step
                    } label: {
                        Text(step.label)
                            .font(Theme.font(size: 13, weight: current || peeking ? .bold : .medium))
                            .foregroundStyle(current ? Theme.onTeal : past ? Theme.teal : Theme.muted)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(current ? Theme.teal : past ? Theme.teal.opacity(0.14) : Color.clear)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(peeking ? Theme.teal : current || past ? Color.clear : Theme.line,
                                                      lineWidth: peeking ? 1.5 : 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(current ? "Where it is now" : step.rawValue > currentChip.rawValue ? "See what's coming in \(step.label.lowercased())" : "See \(step.label.lowercased())")
                    .accessibilityLabel("\(step.label)\(current ? ", where it is now" : "")")
                }
            }
            // The same short summary the full page opens with; the step it's at is already in Next up.
            if let step = simplePeek, step != currentChip {
                ProjectStageView(project: project, stage: step, books: books, footage: EmptyView(), briefOnly: true) { _ in }
            }
        }
    }

    private var nextSentence: String {
        var line = SimpleProject.nextLine(project)
        if project.stage == .lead, let quote, quote.stage.isOpen { line = DealCard.nextMove(quote) + "." }
        if project.stage == .delivered,
           let due = money.receivables.filter({ $0.projectID == project.id && $0.paidOn == nil }).map(\.due).min() {
            line = "Delivered. The final payment is due \(SimpleProject.when(due))."
        }
        return line
    }

    private var simpleNextUp: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Next up").font(Theme.display(size: 20)).foregroundStyle(Theme.text)
            Text(nextSentence)
                .font(Theme.font(size: 16)).foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
            simpleAction
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 22)
        .accentBar(Theme.teal)
    }

    @ViewBuilder private var simpleAction: some View {
        let folder = project.folderURL
        switch project.stage {
        case .lead:
            if let quote, quote.stage.isOpen {
                HStack(spacing: 10) {
                    if quote.stage == .inquiry {
                        Button("Build the proposal") { navigator.builderDealID = quote.id }.buttonStyle(PrimaryButtonStyle())
                        Button("Mark as booked") { showWon = true }.buttonStyle(SecondaryButtonStyle())
                    } else {
                        Button("Mark as booked") { showWon = true }.buttonStyle(PrimaryButtonStyle())
                        Button("See the proposal") { navigator.builderDealID = quote.id }.buttonStyle(SecondaryButtonStyle())
                    }
                    Button("Didn't book") { showLost = true }.buttonStyle(SecondaryButtonStyle())
                }
            } else {
                Button("Mark as booked") { projects.setStage(.booked, for: project) }.buttonStyle(PrimaryButtonStyle())
            }
        case .booked:
            Button("Start shooting") { projects.setStage(.shoot, for: project) }.buttonStyle(PrimaryButtonStyle())
        case .shoot:
            Button("The shoot is done, start editing") { projects.setStage(.edit, for: project) }.buttonStyle(PrimaryButtonStyle())
        case .edit:
            if let folder {
                HStack(spacing: 10) {
                    Button("Open the footage") { NSWorkspace.shared.open(folder) }.buttonStyle(PrimaryButtonStyle())
                    Button("Mark as delivered") { projects.setStage(.delivered, for: project) }.buttonStyle(SecondaryButtonStyle())
                }
            } else {
                HStack(spacing: 10) {
                    Button("Choose the footage folder") { chooseFolder() }.buttonStyle(PrimaryButtonStyle())
                    Button("Mark as delivered") { projects.setStage(.delivered, for: project) }.buttonStyle(SecondaryButtonStyle())
                }
            }
        case .delivered:
            Button("Mark as paid") { projects.setStage(.paid, for: project) }.buttonStyle(PrimaryButtonStyle())
        case .paid:
            if project.folderPath != nil, !project.isOnServer {
                Button(moving ? "Moving…" : "Move footage to the server") { moveToServer() }
                    .buttonStyle(PrimaryButtonStyle()).disabled(moving)
            }
        case .archived:
            if let quote, quote.stage == .lost {
                Button("Reopen") { deals.reopen(quote, projects: projects) }.buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private func initials(_ name: String) -> String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first }
        return String(letters).uppercased()
    }

    private var simplePeople: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Who's on it").font(Theme.display(size: 20)).foregroundStyle(Theme.text)
            let people = project.people ?? []
            if people.isEmpty {
                Text("No one added yet.").font(Theme.font(size: 14)).foregroundStyle(Theme.muted)
            }
            ForEach(people) { person in
                HStack(spacing: 12) {
                    Text(initials(person.name))
                        .font(Theme.font(size: 13, weight: .bold)).foregroundStyle(Theme.teal)
                        .frame(width: 38, height: 38)
                        .background(Theme.teal.opacity(0.14)).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(person.name).font(Theme.font(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                        if !person.role.isEmpty {
                            Text(person.role).font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
            Button("+ Add someone") { addingPerson = true }
                .buttonStyle(.link).font(Theme.font(size: 13, weight: .semibold))
        }
    }

    private var moneySentences: [String] {
        let mine = money.receivables.filter { $0.projectID == project.id }
        let paid = mine.filter { $0.paidOn != nil }.reduce(0) { $0 + $1.amount }
        let total = books.price ?? (mine.isEmpty ? nil : mine.reduce(0) { $0 + $1.amount })
        let hours = project.totalHours
        var sentences: [String] = []
        if let total, total > 0 {
            if paid > 0 {
                let who = project.client.trimmingCharacters(in: .whitespaces).isEmpty ? "They've" : "\(project.client) has"
                var s = "\(who) paid \(Money.string(paid)) of \(Money.string(total))."
                if paid < total { s += project.stage.rawValue < ProjectStage.delivered.rawValue ? " The rest comes after you deliver." : " The rest is still to come." }
                sentences.append(s)
            } else {
                sentences.append("The price is \(Money.string(total)). Nothing has come in yet.")
            }
        }
        if hours > 0 { sentences.append("You've spent \(Hours.short(hours)) on it so far.") }
        return sentences
    }

    @ViewBuilder private var simpleMoney: some View {
        let sentences = moneySentences
        if !sentences.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Money").font(Theme.display(size: 20)).foregroundStyle(Theme.text)
                Text(sentences.joined(separator: " "))
                    .font(Theme.font(size: 15)).foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var simpleEmails: some View {
        let latest = (project.emails ?? []).sorted { $0.lastDate > $1.lastDate }.prefix(2)
        if !latest.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(project.client.isEmpty ? "Latest emails" : "Latest from \(project.client)")
                    .font(Theme.display(size: 20)).foregroundStyle(Theme.text)
                ForEach(Array(latest)) { mail in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(mail.subject.isEmpty ? "No subject" : mail.subject)
                                .font(Theme.font(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                            Spacer()
                            Text(mail.lastDate.formatted(.relative(presentation: .named)))
                                .font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
                        }
                        if !mail.snippet.isEmpty {
                            Text(mail.snippet).font(Theme.font(size: 13)).foregroundStyle(Theme.muted).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel(padding: 16)
                }
            }
        }
    }

    private var simpleFooter: some View {
        HStack(spacing: 0) {
            Text("Meeting notes, files, hours and every detail are in ")
            Button("Everything") { Appearance.shared.detail = .everything }
                .buttonStyle(.link)
            Text(".")
        }
        .font(Theme.font(size: 13)).foregroundStyle(Theme.muted)
        .padding(.top, 8)
    }
}

/// One step on a project's stage bar: its progress line and name, clickable to open that step.
private struct StageStep: View {
    let step: ProjectStage
    let current: ProjectStage
    let selected: Bool
    var name: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(step.rawValue < current.rawValue ? Theme.tealDim : step == current ? Theme.text : Theme.track)
                    .frame(height: 6)
                Text(name)
                    .font(Theme.font(size: 12, weight: step == current || selected ? .bold : .medium))
                    .foregroundStyle(selected ? Theme.text : step.rawValue <= current.rawValue ? Theme.text2 : Theme.muted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6).padding(.top, 6).padding(.bottom, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.raised : hovering ? Theme.raised.opacity(0.5) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(step.rawValue > current.rawValue ? "See what's coming in \(name.lowercased())" : "See \(name.lowercased())")
        .accessibilityLabel("\(name)\(step == current ? ", where this project is now" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
