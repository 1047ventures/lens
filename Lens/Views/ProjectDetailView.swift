import SwiftUI
import AppKit

/// One project's hub: where it is in the lifecycle, and everything for it in one place, in tabs:
/// Overview, People, Meeting notes, Emails, Proposal and files, Hours, Money.
struct ProjectDetailView: View {
    let project: Project
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var deals: DealStore
    @EnvironmentObject private var zoom: ZoomNotes
    @State private var tab: ProjectTab = .overview
    @EnvironmentObject private var viewModel: ScanViewModel
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var money: MoneyStore
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var moving = false
    @EnvironmentObject private var appearance: Appearance
    @State private var addingPerson = false

    private var files: [MediaFile] { project.files(in: viewModel.allFiles) }
    private var books: ProjectBooks { ProjectBooks.make(project, money: money, deals: deals) }

    var body: some View {
        if appearance.simple { simpleBody } else { everythingBody }
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
                switch tab {
                case .overview:
                    ArrangeablePage("project", columns: true, spacing: 28, boxes: overviewBoxes)
                case .people:
                    ProjectPeopleTab(project: project)
                case .notes: ProjectNotesTab(project: project)
                case .emails: ProjectEmailsTab(project: project)
                case .proposal: ProjectProposalTab(project: project)
                case .hours:
                    VStack(alignment: .leading, spacing: 28) {
                        ProjectTimePanel(project: project, books: books)
                        ProjectHoursTab(project: project)
                    }
                case .money:
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
                    Button {
                        tab = t
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
                        .font(Theme.font(size: 13, weight: tab == t ? .semibold : .medium))
                        .foregroundStyle(tab == t ? Theme.text : Theme.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(tab == t ? Theme.raised : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == t ? .isSelected : [])
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
                Button { tab = t } label: {
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
            Text(project.name)
                .font(Theme.font(size: 30, weight: .bold))
                .foregroundStyle(Theme.text)
            let meta = [project.client,
                        project.shootDate?.formatted(date: .complete, time: .shortened) ?? "",
                        project.location].filter { !$0.isEmpty }
            if !meta.isEmpty {
                Text(meta.joined(separator: " · "))
                    .font(Theme.font(size: 14))
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
                            .font(Theme.font(size: 12, weight: step == project.stage ? .bold : .medium))
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
                    .font(Theme.font(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if let path = project.archivedPath {
                    Text(path)
                        .font(Theme.font(size: 12, design: .monospaced))
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
                            .font(Theme.font(size: 14))
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
                    Text("Read the drive in Library to see this project's clips.")
                        .font(Theme.font(size: 14))
                        .foregroundStyle(Theme.text3)
                }
                Text(folder.path)
                    .font(Theme.font(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 10) {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button("Open Library") { navigator.open(.footage) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            } else {
                Text("No footage folder yet. Pick the folder this project's clips live in.")
                    .font(Theme.font(size: 14))
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
    private var chips: [(String, ProjectStage)] {
        [("Booked", .booked), ("Shot", .shoot), ("Editing", .edit), ("Delivered", .delivered), ("Paid", .paid)]
    }

    /// Where the project sits in the five chips, or -1 for an inquiry.
    private var chipIndex: Int {
        switch project.stage {
        case .lead: return -1
        case .booked: return 0
        case .shoot: return 1
        case .edit: return 2
        case .delivered: return 3
        case .paid, .archived: return 4
        }
    }

    private var stageSentence: String {
        switch project.stage {
        case .lead: return "You're getting this one booked"
        case .booked: return "You're booked"
        case .shoot: return "You're shooting"
        case .edit: return "You're editing"
        case .delivered: return "You've delivered"
        case .paid: return "You're paid"
        case .archived: return "This one's done"
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
        }
    }

    private var simpleStageLine: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(stageSentence).font(Theme.font(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
            HStack(spacing: 8) {
                ForEach(Array(chips.enumerated()), id: \.offset) { i, chip in
                    let current = i == chipIndex
                    let past = i < chipIndex
                    Text(chip.0)
                        .font(Theme.font(size: 13, weight: current ? .bold : .medium))
                        .foregroundStyle(current ? Theme.onTeal : past ? Theme.teal : Theme.muted)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(current ? Theme.teal : past ? Theme.teal.opacity(0.14) : Color.clear)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(current || past ? Color.clear : Theme.line))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(stageSentence)
        }
    }

    private var nextSentence: String {
        var line = SimpleProject.nextLine(project)
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
            Button("Mark as booked") { projects.setStage(.booked, for: project) }.buttonStyle(PrimaryButtonStyle())
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
            EmptyView()
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
