import SwiftUI
import AppKit

/// The tabs on a project page, with their names as the user sees them.
enum ProjectTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case people = "People"
    case notes = "Meeting notes"
    case emails = "Emails"
    case proposal = "Proposal and files"
    case hours = "Hours"
    case money = "Money"

    var id: String { rawValue }
}

extension ProjectStore {
    /// Changes one project in place, starting from what's saved now.
    func edit(_ id: UUID, _ change: (inout Project) -> Void) {
        guard var p = project(id: id) else { return }
        change(&p)
        update(p)
    }
}

// MARK: - People

/// Who's on the project: client, directors, interviewees, crew. Their calls and emails land here.
struct ProjectPeopleTab: View {
    let project: Project
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var logins: ConnectionStore
    @State private var name = ""
    @State private var email = ""
    @State private var role = ""

    private var people: [ProjectPerson] { project.people ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("People · \(people.count)")
                Text("Zoom notes and emails with anyone here go on this project by themselves. Lens also adds people it keeps seeing in this project's calls and emails.")
                    .font(.system(size: 13)).foregroundStyle(Theme.text3)
                if people.isEmpty {
                    Text("No one yet. Add the people you're working with, or pick from the suggestions below.")
                        .font(.system(size: 14)).foregroundStyle(Theme.muted)
                }
                ForEach(people) { person in row(person) }
                addForm
            }
            .panel(padding: 22)

            let found = suggestions
            if !found.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ColorLabel("Suggested · \(found.count)", Palette.violet)
                    Text("People in this project's emails and meeting notes who aren't on the list yet.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    ForEach(found, id: \.email) { s in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                                Text("\(s.email) · in \(s.count) conversation\(s.count == 1 ? "" : "s")")
                                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            Menu {
                                ForEach(ProjectPerson.roles, id: \.self) { r in
                                    Button(r) { add(ProjectPerson(name: s.name, email: s.email, role: r)) }
                                }
                                Divider()
                                Button("No role yet") { add(ProjectPerson(name: s.name, email: s.email, role: "")) }
                            } label: {
                                Text("Add as…")
                            }
                            .menuStyle(.borderedButton)
                            .fixedSize()
                        }
                        .padding(12)
                        .background(Theme.raised.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .panel(padding: 18)
                .accentBar(Palette.violet)
            }
        }
    }

    private func row(_ person: ProjectPerson) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Text(person.email.isEmpty ? "No email" : person.email)
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .textSelection(.enabled)
            }
            Spacer()
            Menu {
                ForEach(ProjectPerson.roles, id: \.self) { r in
                    Button(r) { change(person) { $0.role = r } }
                }
            } label: {
                Text(person.role.isEmpty ? "Pick a role" : person.role)
            }
            .menuStyle(.borderedButton)
            .fixedSize()
            Button {
                projects.edit(project.id) { p in p.people = (p.people ?? []).filter { $0.id != person.id } }
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            .help("Take \(person.name) off this project")
        }
        .padding(.vertical, 6)
    }

    private var addForm: some View {
        HStack(spacing: 8) {
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(minWidth: 140)
            TextField("Email", text: $email).textFieldStyle(.roundedBorder).frame(minWidth: 180)
            TextField("Role", text: $role, prompt: Text("Director")).textFieldStyle(.roundedBorder).frame(width: 120)
            Button("Add person") {
                add(ProjectPerson(name: name.trimmingCharacters(in: .whitespaces),
                                  email: email.trimmingCharacters(in: .whitespaces).lowercased(),
                                  role: role.trimmingCharacters(in: .whitespaces)))
                name = ""; email = ""; role = ""
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty && !email.contains("@"))
        }
        .padding(.top, 6)
    }

    private func add(_ person: ProjectPerson) {
        var p = person
        if p.name.isEmpty { p.name = p.email }
        projects.edit(project.id) { $0.people = ($0.people ?? []) + [p] }
    }

    private func change(_ person: ProjectPerson, _ update: (inout ProjectPerson) -> Void) {
        projects.edit(project.id) { p in
            guard var list = p.people, let i = list.firstIndex(where: { $0.id == person.id }) else { return }
            update(&list[i])
            p.people = list
        }
    }

    /// Everyone on the project's emails and calls who isn't listed yet, most often seen first.
    private var suggestions: [(name: String, email: String, count: Int)] {
        let me = logins.ownerEmail.lowercased()
        let known = Set(people.map { $0.email.lowercased() })
        var found: [String: (name: String, count: Int)] = [:]
        func note(_ name: String, _ email: String) {
            let e = email.lowercased()
            guard e.contains("@"), e != me, !known.contains(e),
                  !["noreply", "no-reply", "donotreply", "notifications", "calendar-notification", "mailer-daemon"].contains(where: e.contains),
                  !e.hasSuffix("zoom.us") else { return }
            let current = found[e]
            let better = (current?.name ?? e) == e ? name : current!.name
            found[e] = (better, (current?.count ?? 0) + 1)
        }
        for thread in project.emails ?? [] {
            for raw in thread.people ?? [] {
                let a = GmailAPI.parseAddress(raw)
                note(a.name, a.email)
            }
        }
        for call in project.meetingNotes ?? [] {
            for e in call.attendees ?? [] { note(e, e) }
        }
        return found.map { (name: $0.value.name, email: $0.key, count: $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
            .prefix(10).map { $0 }
    }
}

// MARK: - Meeting notes

/// Every Zoom call on the project, newest first and searchable, plus calls that might belong here,
/// where Lens asks "Which project is this for?".
struct ProjectNotesTab: View {
    let project: Project
    @EnvironmentObject private var zoom: ZoomNotes
    @State private var search = ""
    @State private var drafting: ProjectDraft?

    private var notes: [MeetingNote] {
        let all = (project.meetingNotes ?? []).sorted { $0.date > $1.date }
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.summary.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            let waiting = zoom.waiting(for: project.id)
            if !waiting.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ColorLabel("Might be for this project · \(waiting.count)", Palette.violet)
                    Text("Zoom calls that might be about \(project.name). Lens wasn't sure, so it's asking.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    ForEach(waiting) { note in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(note.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                                Text(note.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                                if !note.summary.isEmpty {
                                    Text(note.summary).font(.system(size: 13)).foregroundStyle(Theme.text3).lineLimit(3)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 8)
                            NoteQuestion(note: note, drafting: $drafting)
                        }
                        .padding(12)
                        .background(Theme.raised.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .panel(padding: 18)
                .accentBar(Palette.violet)
                .sheet(item: $drafting) { draft in ProjectDraftSheet(draft: draft) }
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionLabel("Meeting notes · \(project.meetingNotes?.count ?? 0)")
                    Spacer()
                    TextField("Search notes", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                if notes.isEmpty {
                    Text(search.isEmpty
                         ? "No Zoom notes yet. Calls with the people on this project, or that mention it, show up here."
                         : "No notes mention \"\(search)\".")
                        .font(.system(size: 14)).foregroundStyle(Theme.muted)
                } else {
                    MeetingNotesList(notes: notes, projectID: project.id)
                }
            }
            .panel(padding: 22)
        }
    }
}

// MARK: - Emails

struct ProjectEmailsTab: View {
    let project: Project
    @State private var search = ""

    private var threads: [EmailThread] {
        let all = (project.emails ?? []).sorted { $0.lastDate > $1.lastDate }
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.subject.localizedCaseInsensitiveContains(q) || $0.snippet.localizedCaseInsensitiveContains(q)
                || $0.from.localizedCaseInsensitiveContains(q) || ($0.people ?? []).contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel("Emails · \(project.emails?.count ?? 0)")
                Spacer()
                TextField("Search emails", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            if threads.isEmpty {
                Text(search.isEmpty
                     ? "No emails yet. Conversations with the people on this project show up here."
                     : "No emails mention \"\(search)\".")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted)
            } else {
                EmailThreadsList(threads: threads)
            }
        }
        .panel(padding: 22)
    }
}

// MARK: - Proposal and files

/// The proposal from the project's deal (open, print, save as PDF), plus contracts, treatments and other files.
struct ProjectProposalTab: View {
    let project: Project
    @EnvironmentObject private var quotes: QuoteStore
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var deals: DealStore
    @EnvironmentObject private var navigator: Navigator
    @State private var addingLink = false
    @State private var linkName = ""
    @State private var linkURL = ""
    @State private var linkKind = "Other"

    private var deal: Deal? { deals.deals.first { $0.projectID == project.id } }
    private var files: [ProjectFile] { (project.documents ?? []).sorted { $0.added > $1.added } }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            proposal
            QuotesPanel(projectID: project.id, dealID: deal?.id, client: project.client)
            filesPanel
        }
    }

    // The proposal

    @ViewBuilder private var proposal: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Proposal")
            if let deal {
                VStack(alignment: .leading, spacing: 6) {
                    Text(deal.story.headline.isEmpty ? deal.title : deal.story.headline)
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.text)
                    HStack(spacing: 18) {
                        fact("Price", deals.valueText(of: deal))
                        fact("Sent", sentDate(deal).map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Not marked as sent")
                        if let option = deal.chosenOption { fact("Chosen", "\(option.name) · \(option.tagline)") }
                    }
                }
                HStack(spacing: 10) {
                    Button(quotes.uploadedProposal(dealID: deal.id, projectID: project.id) != nil ? "Open your proposal" : "Open proposal") {
                        quotes.openProposal(for: deal, deals: deals, projects: projects)
                    }
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Print…") { ProposalPrinter.print(deal, store: deals, projects: projects) }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Save as PDF…") { ProposalPrinter.savePDF(deal, store: deals, projects: projects) }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Open in Pipeline") { navigator.openDeal(deal.id) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            } else {
                if let q = quotes.uploadedProposal(dealID: nil, projectID: project.id) {
                    HStack(spacing: 10) {
                        Text(q.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                        if let a = q.amount { Text(Money.string(a)).font(.system(size: 14)).foregroundStyle(Theme.text2) }
                    }
                    Button("Open your proposal") { NSWorkspace.shared.open(URL(fileURLWithPath: q.location)) }
                        .buttonStyle(PrimaryButtonStyle())
                } else {
                    Text("This project doesn't have a proposal yet. Upload yours below, or build one here and Lens works out the price from your rates.")
                        .font(.system(size: 14)).foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("Build a quote") { buildQuote() }
                            .buttonStyle(PrimaryButtonStyle())
                        Button("Ask Lens to price it") {
                            navigator.askDraft = "Help me price the \(project.name) project. Ask me what's involved (full days, half days or hours, and whether it's a finished film or just edited images and B-roll), compare it with my past quotes, then suggest the options."
                            navigator.askOpen = true
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
                let free = deals.deals.filter { $0.projectID == nil && $0.stage != .lost }
                if !free.isEmpty {
                    Menu {
                        ForEach(free) { d in
                            Button("\(d.client) · \(d.title)") {
                                deals.link(d, to: project.id, option: nil, projects: projects)
                            }
                        }
                    } label: {
                        Text("Bring in its deal from Pipeline")
                    }
                    .menuStyle(.borderedButton)
                    .fixedSize()
                }
            }
        }
        .panel(padding: 22)
    }

    /// A new quote for this project: a deal tied to it, with one starter option, opened in the proposal builder.
    private func buildQuote() {
        var deal = Deal(client: project.client.isEmpty ? project.name : project.client, title: project.name, source: "Project",
                        stage: .talking, lastTouch: Date(), createdAt: Date())
        var option = ScopeOption.starter()
        option.interviewees = 0
        deal.options = [option]
        deal.projectID = project.id
        deal.eventDate = project.shootDate
        deal.contacts = (project.people ?? []).filter { !$0.email.isEmpty }.map { Contact(name: $0.name, role: $0.role, email: $0.email) }
        deals.add(deal)
        navigator.openBuilder(deal.id)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            Text(value).font(.system(size: 14)).foregroundStyle(Theme.text2)
        }
    }

    /// The last time the user marked the proposal as sent.
    private func sentDate(_ deal: Deal) -> Date? {
        deal.events.last { $0.text.localizedCaseInsensitiveContains("proposal sent") }?.date
    }

    // Other files

    private var filesPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Files · \(files.count)")
            Text("Contracts, treatments, call sheets and anything else, from Google Drive or your Mac. The files stay where they are.")
                .font(.system(size: 13)).foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(files) { file in fileRow(file) }
            if addingLink {
                HStack(spacing: 8) {
                    TextField("Name", text: $linkName, prompt: Text("Signed contract")).textFieldStyle(.roundedBorder)
                    TextField("Link", text: $linkURL, prompt: Text("https://drive.google.com/…")).textFieldStyle(.roundedBorder)
                    Picker("", selection: $linkKind) {
                        ForEach(ProjectFile.kinds, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    Button("Add") {
                        let link = linkURL.trimmingCharacters(in: .whitespaces)
                        let name = linkName.trimmingCharacters(in: .whitespaces)
                        add([ProjectFile(name: name.isEmpty ? link : name, kind: linkKind, location: link)])
                        linkName = ""; linkURL = ""; linkKind = "Other"; addingLink = false
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!linkURL.lowercased().hasPrefix("http"))
                    Button("Cancel") { addingLink = false }.buttonStyle(SecondaryButtonStyle())
                }
            }
            HStack(spacing: 10) {
                Button("Add a file from your Mac…") { chooseFiles() }
                    .buttonStyle(SecondaryButtonStyle())
                if !addingLink {
                    Button("Add a link…") { addingLink = true }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .panel(padding: 22)
    }

    private func fileRow(_ file: ProjectFile) -> some View {
        let missing = !file.isWebLink && !FileManager.default.fileExists(atPath: file.location)
        return HStack(spacing: 12) {
            Image(systemName: file.isWebLink ? "link" : "doc")
                .foregroundStyle(Theme.muted).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Text(missing ? "\(file.kind) · Lens can't find this file anymore" : "\(file.kind) · added \(file.added.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 12)).foregroundStyle(missing ? Theme.amber : Theme.muted)
            }
            Spacer()
            Menu {
                ForEach(ProjectFile.kinds, id: \.self) { k in
                    Button(k) { change(file) { $0.kind = k } }
                }
            } label: {
                Text(file.kind)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button("Open") { open(file) }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(missing)
            if !file.isWebLink && !missing {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.location)])
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            Button {
                projects.edit(project.id) { p in p.documents = (p.documents ?? []).filter { $0.id != file.id } }
            } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            .help("Take this off the project. The file itself isn't touched.")
        }
        .padding(.vertical, 4)
    }

    private func open(_ file: ProjectFile) {
        let url = file.isWebLink ? URL(string: file.location) : URL(fileURLWithPath: file.location)
        if let url { NSWorkspace.shared.open(url) }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to project"
        guard panel.runModal() == .OK else { return }
        add(panel.urls.map { ProjectFile(name: $0.lastPathComponent, kind: Self.guessKind($0.lastPathComponent), location: $0.path) })
    }

    private func add(_ new: [ProjectFile]) {
        guard !new.isEmpty else { return }
        projects.edit(project.id) { $0.documents = ($0.documents ?? []) + new }
    }

    private func change(_ file: ProjectFile, _ update: (inout ProjectFile) -> Void) {
        projects.edit(project.id) { p in
            guard var list = p.documents, let i = list.firstIndex(where: { $0.id == file.id }) else { return }
            update(&list[i])
            p.documents = list
        }
    }

    static func guessKind(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("proposal") { return "Proposal" }
        if n.contains("quote") || n.contains("estimate") { return "Quote" }
        if n.contains("contract") || n.contains("agreement") { return "Contract" }
        if n.contains("treatment") { return "Treatment" }
        if n.contains("call sheet") || n.contains("callsheet") || n.contains("call-sheet") { return "Call sheet" }
        if n.contains("script") { return "Script" }
        if n.contains("release") { return "Release form" }
        return "Other"
    }
}

// MARK: - Hours

/// The hours planned in the proposal, by kind of work.
struct ProjectHoursTab: View {
    let project: Project
    @EnvironmentObject private var deals: DealStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Hours")
            if let deal = deals.deals.first(where: { $0.projectID == project.id }),
               let option = deal.chosenOption ?? deal.options.first {
                let e = deals.estimate(option)
                Text("Planned in the proposal (\(option.name), \(option.tagline)).")
                    .font(.system(size: 13)).foregroundStyle(Theme.text3)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    HeadlineNumber(text: Estimate.range(e.teamHoursLow, e.teamHoursHigh), size: 30)
                    Text("hours in all · about \(Int(e.emmaHours.rounded())) of them yours")
                        .font(.system(size: 14)).foregroundStyle(Theme.text3)
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(e.workload) { row in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text2)
                                if !row.detail.isEmpty {
                                    Text(row.detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
                                }
                            }
                            Spacer()
                            Text("\(row.hoursText) hours").font(.system(size: 13)).foregroundStyle(Theme.text2)
                        }
                    }
                }
                .padding(.top, 4)
            } else {
                Text("Planned hours show up here once this project has a proposal with options.")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted)
            }
        }
        .panel(padding: 22)
    }
}

// MARK: - Money

/// The price, money in and out linked to this project in Money, and what's still owed.
struct ProjectMoneyTab: View {
    let project: Project
    @EnvironmentObject private var deals: DealStore
    @EnvironmentObject private var money: MoneyStore
    @EnvironmentObject private var navigator: Navigator

    var body: some View {
        let txns = money.txns.filter { $0.projectID == project.id }.sorted { $0.date > $1.date }
        let owed = money.receivables.filter { $0.projectID == project.id && $0.paidOn == nil }.sorted { $0.due < $1.due }
        let moneyIn = txns.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
        let moneyOut = -txns.filter { $0.amount < 0 }.reduce(0) { $0 + $1.amount }
        let price = deals.deals.first(where: { $0.projectID == project.id }).flatMap { deals.value(of: $0) }

        return VStack(alignment: .leading, spacing: 18) {
            SectionLabel("Money")
            HStack(alignment: .top, spacing: 32) {
                if let price { figure("Price", Money.string(price)) }
                figure("Paid to you", Money.string(moneyIn))
                figure("Spent", Money.string(moneyOut))
                figure("Still owed", Money.string(owed.reduce(0) { $0 + $1.amount }))
            }
            if !owed.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Still owed").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text2)
                    ForEach(owed) { r in
                        HStack {
                            Text(r.label).foregroundStyle(Theme.text2)
                            Spacer()
                            Text("\(Money.string(r.amount)) · due \(r.due.formatted(date: .abbreviated, time: .omitted))")
                                .foregroundStyle(r.due < Date() ? Theme.amber : Theme.muted)
                        }
                        .font(.system(size: 13))
                    }
                }
            }
            if txns.isEmpty {
                Text("Nothing in Money is linked to this project yet. In Money, pick this project on a payment or expense to see it here.")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(txns) { t in
                        HStack {
                            Text(t.date.formatted(.dateTime.month(.abbreviated).day())).foregroundStyle(Theme.muted)
                                .frame(width: 56, alignment: .leading)
                            Text(t.description).foregroundStyle(Theme.text2).lineLimit(1)
                            Spacer()
                            Text(t.category.label).foregroundStyle(Theme.muted)
                            Text(Money.string(t.amount)).foregroundStyle(t.amount > 0 ? Theme.teal : Theme.text2)
                                .frame(width: 90, alignment: .trailing)
                        }
                        .font(.system(size: 13))
                    }
                }
            }
            Button("Open Money") { navigator.open(.money) }
                .buttonStyle(SecondaryButtonStyle())
        }
        .panel(padding: 22)
    }

    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            HeadlineNumber(text: value, size: 24)
        }
    }
}
