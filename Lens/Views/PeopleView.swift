import SwiftUI
import AppKit

/// Everyone the user works with: clients, directors, interviewees, crew, vendors and leads.
struct PeopleView: View {
    @EnvironmentObject private var people: PeopleStore
    @EnvironmentObject private var deals: DealStore
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var navigator: Navigator
    @State private var query = ""
    @State private var tag: String?
    @State private var onID: UUID?
    @State private var creating = false
    @State private var scanning = false
    @State private var bringing: PeopleImport.Kind?

    var body: some View {
        Group {
            if let person = people.person(id: navigator.personID) {
                PersonDetailView(person: person)
            } else {
                list
            }
        }
        .sheet(isPresented: $creating) {
            PersonEditor(initial: nil) { people.add($0); navigator.personID = $0.id }
        }
        .sheet(isPresented: $scanning) { CardScanView() }
        .sheet(item: $bringing) { BringInSheet(kind: $0) }
    }

    private var filtered: [Person] {
        var list = people.search(query)
        if let tag { list = list.filter { $0.tags.contains(tag) } }
        if let onID { list = list.filter { $0.projectIDs.contains(onID) || $0.dealIDs.contains(onID) } }
        return list
    }

    private var onName: String? {
        guard let onID else { return nil }
        return projects.project(id: onID)?.name ?? deals.deal(id: onID)?.title
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("People")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(Theme.text)
                        Text("Everyone you work with, and everything you've done together.")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    HStack(spacing: 10) {
                        Menu("Bring in people") {
                            Button("From LinkedIn") { bringing = .linkedIn }
                            Button("From Facebook or Instagram") { bringing = .meta }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        Button("Clear out junk") { people.tidy() }
                            .buttonStyle(SecondaryButtonStyle())
                            .help("Removes auto-replies, companies and one-way emails Lens added, unless they're on a deal or project or you've added anything to them")
                        Button("Scan a card") { scanning = true }
                            .buttonStyle(SecondaryButtonStyle())
                        Button("Add a person") { creating = true }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                }

                filters

                RecentlyAddedPanel()
                followUps

                if people.people.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No one here yet")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text("Everyone on your deals, projects and Zoom calls shows up here by itself, and so does anyone who emails you about work once Google is connected in Log-ins. You can also scan business cards or bring in LinkedIn, Facebook and Instagram.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.muted)
                    }
                    .panel(padding: 22)
                } else if filtered.isEmpty {
                    Text("No one matches that.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.text3)
                        .panel()
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel("\(title) · \(filtered.count)")
                        VStack(spacing: 0) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, person in
                                if index > 0 { Divider().overlay(Theme.lineSoft) }
                                PersonRow(person: person) { navigator.personID = person.id }
                            }
                        }
                        .background(Theme.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
                    }
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var title: String {
        var parts: [String] = [tag.map { $0 + "s" } ?? "Everyone"]
        if let onName { parts.append("on \(onName)") }
        return parts.joined(separator: " ")
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("Search by name, email, company or notes", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
            .frame(maxWidth: 520)

            HStack(spacing: 8) {
                TagChip(text: "Everyone", color: Theme.teal, selected: tag == nil) { tag = nil }
                ForEach(PersonTag.allCases) { t in
                    TagChip(text: t.rawValue, color: t.color, selected: tag == t.rawValue) {
                        tag = tag == t.rawValue ? nil : t.rawValue
                    }
                }
            }

            let active = projects.projects.filter { $0.stage != .archived }
            if !active.isEmpty || !deals.open.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(active) { p in
                        TagChip(text: p.name, color: p.stage.color, selected: onID == p.id) {
                            onID = onID == p.id ? nil : p.id
                        }
                        .help("\(p.stage.label) · show everyone on this project")
                    }
                    ForEach(deals.open) { d in
                        TagChip(text: d.title, color: ProjectStage.lead.color, selected: onID == d.id) {
                            onID = onID == d.id ? nil : d.id
                        }
                        .help("Open deal · show everyone on it")
                    }
                }
            }
        }
    }

    @ViewBuilder private var followUps: some View {
        let due = people.followUpsDue
        let quiet = people.goneQuiet
        if !due.isEmpty || !quiet.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ColorLabel("Worth a check-in · \(due.count + quiet.count)", Theme.amber)
                ForEach(due) { p in
                    checkInRow(p, detail: followUpText(p))
                }
                ForEach(quiet, id: \.person.id) { item in
                    checkInRow(item.person, detail: "On \(item.deal.title) · not in touch for \(item.days) days")
                }
            }
            .panel()
            .accentBar(Theme.amber)
        }
    }

    private func checkInRow(_ p: Person, detail: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Button("Open") { navigator.personID = p.id }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func followUpText(_ p: Person) -> String {
        guard let date = p.followUp else { return "" }
        let when = Calendar.current.isDateInToday(date) ? "Follow up today" : "Follow up was due \(date.formatted(.dateTime.month(.abbreviated).day()))"
        return p.followUpNote.isEmpty ? when : "\(when) · \(p.followUpNote)"
    }
}

/// A small round tag button used for filters and on a person's page.
struct TagChip: View {
    let text: String
    let color: Color
    var selected = false
    var action: (() -> Void)?

    var body: some View {
        let label = Text(text)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(selected ? 0.32 : 0.12))
            .foregroundStyle(selected ? Theme.text : color)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(color.opacity(selected ? 0.7 : 0.3)))
        if let action {
            Button(action: action) { label }.buttonStyle(.plain)
        } else {
            label
        }
    }
}

/// A round badge with someone's initials.
struct PersonBadge: View {
    let person: Person
    var size: CGFloat = 34

    var body: some View {
        let color = person.tags.first.map(PersonTag.color(for:)) ?? Palette.slate
        Text(person.initials)
            .font(.system(size: size * 0.38, weight: .bold))
            .frame(width: size, height: size)
            .background(color.opacity(0.22))
            .foregroundStyle(color)
            .clipShape(Circle())
    }
}

struct PersonRow: View {
    @EnvironmentObject private var people: PeopleStore
    let person: Person
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                PersonBadge(person: person)
                VStack(alignment: .leading, spacing: 3) {
                    Text(person.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(person.subtitle.isEmpty ? "No details yet" : person.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 16)
                HStack(spacing: 6) {
                    ForEach(person.tags.prefix(3), id: \.self) { TagChip(text: $0, color: PersonTag.color(for: $0)) }
                }
                Text(lastText)
                    .font(.system(size: 12))
                    .foregroundStyle(person.isFollowUpDue() ? Theme.amber : Theme.text3)
                    .frame(width: 120, alignment: .trailing)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var lastText: String {
        if person.isFollowUpDue() { return "Follow up due" }
        guard let last = people.lastInTouch(person) else { return "" }
        return "In touch \(last.formatted(.dateTime.month(.abbreviated).day()))"
    }
}

// MARK: - One person's page

struct PersonDetailView: View {
    let person: Person
    @EnvironmentObject private var people: PeopleStore
    @EnvironmentObject private var navigator: Navigator
    @State private var editing = false
    @State private var settingFollowUp = false
    @State private var logging = false
    @State private var merging = false
    @State private var linking = false
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Button {
                    navigator.personID = nil
                } label: {
                    Label("All people", systemImage: "chevron.left")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)

                header
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) {
                        timeline.frame(minWidth: 420)
                        VStack(alignment: .leading, spacing: 18) { followUpPanel; details; cardPanel; workPanel; paidPanel; notesPanel }
                            .frame(width: 320)
                    }
                    VStack(alignment: .leading, spacing: 18) { followUpPanel; details; cardPanel; workPanel; paidPanel; notesPanel; timeline }
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $editing) {
            PersonEditor(initial: person) { people.update($0) }
        }
        .sheet(isPresented: $settingFollowUp) {
            PersonFollowUpSheet(person: person)
        }
        .sheet(isPresented: $logging) {
            LogTouchSheet(person: person)
        }
        .sheet(isPresented: $merging) {
            PersonPicker(title: "Merge \(person.name) with…",
                         note: "Pick the same person. Their emails, tags, notes, deals and projects all end up here.",
                         excluding: [person.id]) { other in
                people.merge(other, into: person)
            }
        }
        .sheet(isPresented: $linking) {
            ProjectPickerSheet(person: person)
        }
        .confirmationDialog("Remove \(person.name) from People?", isPresented: $confirmDelete) {
            Button("Remove", role: .destructive) {
                navigator.personID = nil
                people.delete(person)
            }
        } message: {
            Text("Their deals, projects and emails stay where they are. Lens won't add them back by itself.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            PersonBadge(person: person, size: 60)
            VStack(alignment: .leading, spacing: 8) {
                Text(person.name)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                if !person.subtitle.isEmpty, person.subtitle != person.primaryEmail {
                    Text(person.subtitle).font(.system(size: 15)).foregroundStyle(Theme.muted)
                }
                HStack(spacing: 6) {
                    ForEach(person.tags, id: \.self) { TagChip(text: $0, color: PersonTag.color(for: $0)) }
                    Text(lastText).font(.system(size: 13)).foregroundStyle(Theme.text3).padding(.leading, person.tags.isEmpty ? 0 : 6)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    Button("Log a chat") { logging = true }.buttonStyle(SecondaryButtonStyle())
                    Button(person.followUp == nil ? "Follow up on…" : "Change follow-up") { settingFollowUp = true }
                        .buttonStyle(PrimaryButtonStyle())
                }
                HStack(spacing: 8) {
                    Button("Edit") { editing = true }.buttonStyle(SecondaryButtonStyle())
                    Menu("More") {
                        Button("Merge with someone…") { merging = true }
                        if person.emails.count > 1 {
                            Menu("Split off an email") {
                                ForEach(person.emails, id: \.self) { email in
                                    Button(email) {
                                        if let id = people.split(person, email: email) { navigator.personID = id }
                                    }
                                }
                            }
                        }
                        if let email = person.emails.first {
                            Button("Write an email") {
                                if let url = URL(string: "mailto:\(email)") { NSWorkspace.shared.open(url) }
                            }
                        }
                        Button("Ask Lens about \(person.name)") {
                            navigator.askDraft = "What's going on with \(person.name)? Anything I should follow up on?"
                            navigator.askOpen = true
                        }
                        Divider()
                        Button("Remove from People", role: .destructive) { confirmDelete = true }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
    }

    private var lastText: String {
        guard let last = people.lastInTouch(person) else { return "No contact on file yet" }
        let days = people.daysQuiet(person) ?? 0
        let ago = days == 0 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"
        return "Last in touch \(ago) (\(last.formatted(date: .abbreviated, time: .omitted)))"
    }

    // MARK: Timeline

    private var timeline: some View {
        let moments = people.timeline(for: person)
        return VStack(alignment: .leading, spacing: 14) {
            ColorLabel("Everything together · \(moments.count)", Palette.slate)
            if moments.isEmpty {
                Text("Nothing yet. Deals, projects, emails, Zoom notes and payments with \(person.name) show up here.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            ForEach(moments.prefix(120)) { m in
                MomentRow(moment: m)
            }
        }
        .panel()
        .accentBar(Palette.slate)
    }

    // MARK: Side panels

    @ViewBuilder private var followUpPanel: some View {
        if let date = person.followUp {
            let due = person.isFollowUpDue()
            VStack(alignment: .leading, spacing: 8) {
                ColorLabel(due ? "Follow up now" : "Follow up", due ? Theme.amber : Palette.gold)
                Text(date.formatted(date: .complete, time: .omitted))
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                if !person.followUpNote.isEmpty {
                    Text(person.followUpNote).font(.system(size: 13)).foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Done") {
                        people.logTouch(person.followUpNote.isEmpty ? "Followed up" : "Followed up: \(person.followUpNote)", for: person)
                        if let p = people.person(id: person.id) { people.setFollowUp(nil, for: p) }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Button("Change") { settingFollowUp = true }.buttonStyle(SecondaryButtonStyle())
                }
                .padding(.top, 2)
            }
            .panel()
            .accentBar(due ? Theme.amber : Palette.gold)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            ColorLabel("Details", Palette.sand)
            ForEach(person.emails, id: \.self) { email in
                row("Email", email, url: URL(string: "mailto:\(email)"))
            }
            if !person.phone.isEmpty { row("Phone", person.phone, url: URL(string: "tel:\(person.phone.filter { $0.isNumber || $0 == "+" })")) }
            if !person.company.isEmpty { row("Company", person.company) }
            if !person.role.isEmpty { row("Role", person.role) }
            if !person.link.isEmpty { row(person.link.contains("instagram") || person.link.hasPrefix("@") ? "Instagram" : "Website", person.link, url: linkURL) }
            if !person.met.isEmpty { row("How you met", person.met) }
            if let on = person.metOn { row("Met on", on.formatted(date: .abbreviated, time: .omitted)) }
            if let on = person.connectedOn { row("Connected on", on.formatted(date: .abbreviated, time: .omitted)) }
            if let from = person.addedFrom { row("Added from", from.prefix(1).uppercased() + from.dropFirst()) }
            row("In People since", person.createdAt.formatted(date: .abbreviated, time: .omitted))
        }
        .panel()
        .accentBar(Palette.sand)
    }

    /// The business card photos the user scanned for this person.
    @ViewBuilder private var cardPanel: some View {
        let photos = (person.cardPhotos ?? []).filter { FileManager.default.fileExists(atPath: CardReader.photoURL($0).path) }
        if !photos.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ColorLabel("Their card", Palette.gold)
                ForEach(photos, id: \.self) { file in
                    if let image = NSImage(contentsOf: CardReader.photoURL(file)) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .onTapGesture { NSWorkspace.shared.open(CardReader.photoURL(file)) }
                            .help("Open the photo")
                    }
                }
            }
            .panel()
            .accentBar(Palette.gold)
        }
    }

    private var linkURL: URL? {
        let l = person.link.trimmingCharacters(in: .whitespaces)
        if l.hasPrefix("@") { return URL(string: "https://instagram.com/\(l.dropFirst())") }
        if l.hasPrefix("http") { return URL(string: l) }
        return URL(string: "https://\(l)")
    }

    private func row(_ label: String, _ value: String, url: URL? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted).frame(width: 96, alignment: .leading)
            if let url {
                Link(value, destination: url).font(.system(size: 13)).lineLimit(1)
            } else {
                Text(value).font(.system(size: 13)).foregroundStyle(Theme.text2).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }

    private var workPanel: some View {
        let theirDeals = people.deals(for: person)
        let theirProjects = people.projects(for: person)
        return VStack(alignment: .leading, spacing: 10) {
            ColorLabel("Deals and projects · \(theirDeals.count + theirProjects.count)", Palette.blue)
            ForEach(theirDeals) { d in
                workRow(title: d.title, detail: "Deal · \(d.stage.label)", id: d.id) { navigator.openDeal(d.id) }
            }
            ForEach(theirProjects) { p in
                workRow(title: p.name, detail: "Project · \(p.stage.label)", id: p.id) { navigator.openProject(p.id) }
            }
            Button("Add to a project") { linking = true }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.teal)
                .padding(.top, 2)
        }
        .panel()
        .accentBar(Palette.blue)
    }

    private func workRow(title: String, detail: String, id: UUID, open: @escaping () -> Void) -> some View {
        HStack(alignment: .center) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Menu {
                Button("Take \(person.name) off this") { people.unlink(person, from: id) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    @ViewBuilder private var paidPanel: some View {
        let payments = people.payments(for: person)
        if !payments.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ColorLabel("Paid you", Palette.lime)
                HeadlineNumber(text: Money.string(payments.reduce(0) { $0 + $1.amount }), size: 26)
                ForEach(payments.prefix(6)) { p in
                    HStack {
                        Text(p.label).font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(1)
                        Spacer()
                        Text(Money.string(p.amount)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.text2)
                    }
                }
            }
            .panel()
            .accentBar(Palette.lime)
        }
    }

    @ViewBuilder private var notesPanel: some View {
        if !person.notes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ColorLabel("Notes", Palette.rose)
                Text(person.notes).font(.system(size: 13)).foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .panel()
            .accentBar(Palette.rose)
        }
    }
}

/// One line on a person's timeline.
struct MomentRow: View {
    let moment: PeopleStore.Moment
    @EnvironmentObject private var navigator: Navigator

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
                .background(color.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(moment.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(2)
                    Spacer()
                    Text(moment.date.formatted(.dateTime.month(.abbreviated).day().year()))
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Text(moment.detail).font(.system(size: 12)).foregroundStyle(stage == nil ? Theme.text3 : color).lineLimit(3)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .help(hasTarget ? "Open" : "")
    }

    private var hasTarget: Bool { moment.dealID != nil || moment.projectID != nil || moment.link != nil }

    private func open() {
        if let id = moment.dealID { navigator.openDeal(id) }
        else if let id = moment.projectID { navigator.openProject(id) }
        else if let link = moment.link, let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    private var icon: String {
        switch moment.kind {
        case .deal: return "line.3.horizontal.decrease"
        case .project: return "folder"
        case .email: return "envelope"
        case .meeting: return "video"
        case .money: return "dollarsign"
        case .touch: return "bubble.left"
        }
    }

    private var stage: ProjectStage? {
        moment.kind == .project || moment.kind == .deal ? ProjectStage.mentioned(in: moment.detail) : nil
    }

    private var color: Color {
        if let stage { return stage.color }
        switch moment.kind {
        case .deal: return Palette.gold
        case .project: return Palette.mint
        case .email: return Palette.blue
        case .meeting: return Palette.violet
        case .money: return Palette.lime
        case .touch: return Palette.rose
        }
    }
}

// MARK: - Sheets

struct PersonEditor: View {
    let initial: Person?
    let onSave: (Person) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var emails = ""
    @State private var phone = ""
    @State private var company = ""
    @State private var role = ""
    @State private var link = ""
    @State private var met = ""
    @State private var tags: [String] = []
    @State private var notes = ""

    static let metOptions = ["Referral", "Website", "Instagram", "Facebook", "LinkedIn", "Email", "Event", "Networking event", "Festival", "Repeat client"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(initial == nil ? "Add a person" : "Edit \(initial!.name)")
                .font(.system(size: 20, weight: .bold))
            Form {
                TextField("Name", text: $name, prompt: Text("Jordan Reyes"))
                TextField("Email", text: $emails, prompt: Text("Separate more than one with commas"))
                TextField("Phone", text: $phone)
                TextField("Company", text: $company)
                TextField("Role", text: $role, prompt: Text("Director, producer, bride…"))
                TextField("Instagram or website", text: $link, prompt: Text("@handle or website"))
                HStack {
                    TextField("How you met", text: $met)
                    Menu("Pick") {
                        ForEach(Self.metOptions, id: \.self) { option in Button(option) { met = option } }
                    }
                    .fixedSize()
                }
                LabeledContent("Tags") {
                    HStack(spacing: 6) {
                        ForEach(PersonTag.allCases) { t in
                            TagChip(text: t.rawValue, color: t.color, selected: tags.contains(t.rawValue)) {
                                if tags.contains(t.rawValue) { tags.removeAll { $0 == t.rawValue } } else { tags.append(t.rawValue) }
                            }
                        }
                    }
                }
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(3...8)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(initial == nil ? "Add person" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear(perform: loadInitial)
    }

    private func loadInitial() {
        guard let p = initial else { return }
        name = p.name
        emails = p.emails.joined(separator: ", ")
        phone = p.phone
        company = p.company
        role = p.role
        link = p.link
        met = p.met
        tags = p.tags
        notes = p.notes
    }

    private func save() {
        var p = initial ?? Person(name: name)
        p.name = name.trimmingCharacters(in: .whitespaces)
        p.emails = emails.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { $0.contains("@") }
        p.phone = phone
        p.company = company
        p.role = role
        p.link = link
        p.met = met
        // Keep any tags that aren't one of the standard six.
        p.tags = tags
        p.notes = notes
        onSave(p)
        dismiss()
    }
}

struct PersonFollowUpSheet: View {
    let person: Person
    @EnvironmentObject private var people: PeopleStore
    @Environment(\.dismiss) private var dismiss
    @State private var date = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Follow up with \(person.name)").font(.system(size: 20, weight: .bold))
            Text("Lens puts them on Today when the day comes.").font(.system(size: 13)).foregroundStyle(Theme.muted)
            HStack(spacing: 8) {
                ForEach([("Tomorrow", 1), ("In a week", 7), ("In two weeks", 14), ("In a month", 30)], id: \.1) { label, days in
                    Button(label) { date = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? date }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            Form {
                DatePicker("On", selection: $date, displayedComponents: .date)
                TextField("About", text: $note, prompt: Text("Send the edit, ask about the next shoot…"))
            }
            .formStyle(.grouped)
            HStack {
                if person.followUp != nil {
                    Button("Clear follow-up") { people.setFollowUp(nil, for: person); dismiss() }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { people.setFollowUp(date, note: note, for: person); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            if let f = person.followUp { date = f }
            note = person.followUpNote
        }
    }
}

struct LogTouchSheet: View {
    let person: Person
    @EnvironmentObject private var people: PeopleStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Log a chat with \(person.name)").font(.system(size: 20, weight: .bold))
            Text("A call, a coffee, a hello at an event. It counts as being in touch.")
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
            TextField("What you talked about", text: $text, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { people.logTouch(text.trimmingCharacters(in: .whitespacesAndNewlines), for: person); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

/// Pick someone from People (for merging, or adding to a project).
struct PersonPicker: View {
    let title: String
    var note = ""
    var excluding: Set<UUID> = []
    var allowNew = false
    let onPick: (Person) -> Void
    @EnvironmentObject private var people: PeopleStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 20, weight: .bold))
            if !note.isEmpty { Text(note).font(.system(size: 13)).foregroundStyle(Theme.muted) }
            TextField("Search", text: $query).textFieldStyle(.roundedBorder)
            let matches = people.search(query).filter { !excluding.contains($0.id) }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(matches.prefix(60)) { p in
                        Button {
                            onPick(p)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                PersonBadge(person: p, size: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                                    if !p.subtitle.isEmpty { Text(p.subtitle).font(.system(size: 11)).foregroundStyle(Theme.muted) }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if matches.isEmpty {
                        Text("No one matches.").font(.system(size: 13)).foregroundStyle(Theme.muted).padding(.vertical, 8)
                    }
                }
            }
            .frame(height: 300)
            HStack {
                if allowNew, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("Add \(query.trimmingCharacters(in: .whitespaces)) as someone new") {
                        let p = Person(name: query.trimmingCharacters(in: .whitespaces))
                        people.add(p)
                        onPick(p)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

/// Puts a person on one of the user's projects.
struct ProjectPickerSheet: View {
    let person: Person
    @EnvironmentObject private var people: PeopleStore
    @EnvironmentObject private var projects: ProjectStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add \(person.name) to a project").font(.system(size: 20, weight: .bold))
            let choices = projects.projects.filter { !person.projectIDs.contains($0.id) }
                .sorted { ($0.stage == .archived ? 1 : 0, $0.name) < ($1.stage == .archived ? 1 : 0, $1.name) }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(choices) { p in
                        Button {
                            people.link(person, project: p.id)
                            dismiss()
                        } label: {
                            HStack {
                                Text(p.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                                Spacer()
                                Text(p.stage.label).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if choices.isEmpty {
                        Text("No other projects yet.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    }
                }
            }
            .frame(height: 300)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

/// "Find a person" from anywhere in Lens (toolbar, ⇧⌘P).
struct FindPersonPopover: View {
    @EnvironmentObject private var people: PeopleStore
    @EnvironmentObject private var navigator: Navigator
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Find a person", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if let first = results.first { open(first) } }
            ForEach(results) { p in
                Button { open(p) } label: {
                    HStack(spacing: 10) {
                        PersonBadge(person: p, size: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                            if !p.subtitle.isEmpty { Text(p.subtitle).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1) }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !query.isEmpty && results.isEmpty {
                Text("No one matches.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Button("Open People") {
                navigator.personID = nil
                navigator.open(.people)
                navigator.findingPerson = false
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.teal)
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { focused = true }
    }

    private var results: [Person] {
        query.isEmpty ? [] : Array(people.search(query).prefix(8))
    }

    private func open(_ p: Person) {
        navigator.openPerson(p.id)
        navigator.findingPerson = false
    }
}

/// The people on a project or deal, shown on its page.
struct PeoplePanel: View {
    enum Target { case project(UUID), deal(UUID) }
    let target: Target
    var accent: Color = Palette.orchid
    @EnvironmentObject private var people: PeopleStore
    @EnvironmentObject private var navigator: Navigator
    @State private var adding = false

    private var list: [Person] {
        switch target {
        case .project(let id): return people.people(onProject: id)
        case .deal(let id): return people.people(onDeal: id)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ColorLabel("People · \(list.count)", accent)
            ForEach(list) { p in
                Button { navigator.openPerson(p.id) } label: {
                    HStack(spacing: 10) {
                        PersonBadge(person: p, size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                            Text(([p.role] + p.tags).filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if case .project = target {
                Button("Add someone") { adding = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.teal)
            }
        }
        .panel()
        .accentBar(accent)
        .sheet(isPresented: $adding) {
            PersonPicker(title: "Add someone to this project", note: "Pick someone from People, or type a new name.",
                         excluding: Set(list.map(\.id)), allowNew: true) { p in
                if case .project(let id) = target { people.link(p, project: id) }
            }
        }
    }
}
