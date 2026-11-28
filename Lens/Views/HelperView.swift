import SwiftUI

/// Helper: the back office. Replies to new inquiries, pitches to new prospects and Zelle payments, each
/// ready for Emma to check. Nothing is sent: "Put in Gmail drafts" is as far as Lens goes.
struct HelperView: View {
    @ObservedObject private var office = BackOffice.shared
    @EnvironmentObject private var navigator: Navigator
    @State private var showDone = false
    @State private var editingBrief = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header
                if let problem = office.problem { problemBox(problem) }
                setupNotes
                repliesSection
                prospectsSection
                zelleSection
            }
            .padding(40)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Top

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Helper").font(Theme.display(size: 34)).foregroundStyle(Theme.text)
                Text(office.waitingCount == 0
                     ? "Lens handles the busywork here. Nothing new to look at right now."
                     : "\(office.waitingCount) thing\(office.waitingCount == 1 ? "" : "s") ready for you to look over. Lens never sends anything.")
                    .font(Theme.font(size: 15)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Toggle("Show done", isOn: $showDone).toggleStyle(.switch).font(Theme.font(size: 13))
            Button("Check now") { Task { await office.runOnce() } }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(office.drafting || office.checkingZelle)
        }
    }

    private func problemBox(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.amber)
            Text(text).font(Theme.font(size: 14)).foregroundStyle(Theme.text)
            Spacer()
            if text.contains("Log-ins") {
                Button("Open Log-ins") { navigator.open(.logins) }.buttonStyle(SecondaryButtonStyle())
            }
        }
        .panel(padding: 16)
    }

    @ViewBuilder
    private var setupNotes: some View {
        let missing: [String] = [
            office.hasClaude ? nil : "Connect Claude in Log-ins so Lens can write and research.",
            office.gmailReady ? nil : "Sign in with Google in Log-ins so Lens can read your email.",
            (office.gmailReady && !office.canDraft) ? "Sign in with Google once more in Log-ins so Lens can put drafts in Gmail." : nil,
        ].compactMap { $0 }
        if !missing.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("A couple of things first").font(Theme.display(size: 18)).foregroundStyle(Theme.text)
                ForEach(missing, id: \.self) { line in
                    Label(line, systemImage: "key").font(Theme.font(size: 14)).foregroundStyle(Theme.text2)
                }
                Button("Open Log-ins") { navigator.open(.logins) }.buttonStyle(PrimaryButtonStyle()).padding(.top, 4)
            }
            .panel(padding: 20)
        }
    }

    private func sectionTitle(_ title: String, _ line: String, busy: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title).font(Theme.display(size: 22)).foregroundStyle(Theme.text)
                if busy { ProgressView().controlSize(.small) }
            }
            Text(line).font(Theme.font(size: 14)).foregroundStyle(Theme.muted)
        }
    }

    // MARK: Replies

    private var repliesSection: some View {
        let list = office.replies.filter { showDone || $0.status == .ready }
        return VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Replies to new inquiries",
                         "When Lens spots a new inquiry in Gmail, it writes a first reply for you to check.",
                         busy: office.drafting)
            if list.isEmpty {
                emptyLine("No replies waiting. New inquiries get one within the hour.")
            }
            ForEach(list) { reply in
                ReplyCard(reply: reply).id(reply.id + reply.status.rawValue)
            }
        }
    }

    // MARK: Prospects

    private var prospectsSection: some View {
        let list = office.prospects.filter { showDone || $0.status == .ready }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                sectionTitle("New prospects",
                             office.lastProspectRun.map { "Lens last looked \($0.formatted(.relative(presentation: .named))). It looks again each week." }
                                ?? "Each week Lens finds a few organizations that fit your work and writes a pitch for each.",
                             busy: office.findingProspects)
                Spacer()
                Button(editingBrief ? "Done" : "Who to look for") { editingBrief.toggle() }
                    .buttonStyle(SecondaryButtonStyle())
                Button(office.findingProspects ? "Looking…" : "Find prospects now") {
                    Task { await office.findProspects() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(office.findingProspects || !office.hasClaude)
            }
            if editingBrief { briefEditor }
            if office.findingProspects {
                emptyLine("Lens is reading websites and writing pitches. This takes a few minutes, and you can keep working.")
            } else if list.isEmpty {
                emptyLine("No pitches waiting. Click Find prospects now, or Lens will look on its own this week.")
            }
            ForEach(list) { prospect in
                ProspectCard(prospect: prospect).id(prospect.id.uuidString + prospect.status.rawValue)
            }
        }
    }

    private var briefEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Who Lens looks for, in your words").font(Theme.font(size: 13, weight: .semibold)).foregroundStyle(Theme.text2)
            TextEditor(text: $office.brief)
                .font(Theme.font(size: 14))
                .frame(minHeight: 110)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Theme.raised)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 16) {
                Stepper("\(office.perWeek) prospects each time", value: $office.perWeek, in: 1...10)
                Toggle("Look on its own each week", isOn: $office.weekly).toggleStyle(.switch)
                Spacer()
                Button("Back to the usual") { office.brief = BackOffice.defaultBrief }.buttonStyle(.link)
            }
            .font(Theme.font(size: 13))
        }
        .panel(padding: 18)
    }

    // MARK: Zelle

    private var zelleSection: some View {
        let recent = Set(office.recentlyMatched.map(\.id))
        let list = office.zelle.filter { showDone || $0.status == .needsYou || recent.contains($0.id) }
        return VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Zelle payments",
                         "Lens reads your Zelle emails. When a payment clearly matches an unpaid invoice, it marks it paid. Otherwise it asks you which invoice or project it was for.",
                         busy: office.checkingZelle)
            if list.isEmpty {
                emptyLine("No Zelle payments to look at.")
            }
            ForEach(list) { payment in
                ZelleRow(payment: payment)
            }
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text).font(Theme.font(size: 14)).foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel(padding: 16)
    }
}

// MARK: - Cards

/// Status line for something already in Gmail or skipped.
private struct DoneLine: View {
    let status: Prospect.Status
    var body: some View {
        HStack(spacing: 8) {
            if status == .inGmail {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.teal)
                Text("In your Gmail drafts. Read it once more there and send when you're happy.")
                    .font(Theme.font(size: 13)).foregroundStyle(Theme.text2)
                Spacer()
                Button("Open Gmail drafts") { BackOffice.openGmailDrafts() }.buttonStyle(SecondaryButtonStyle())
            } else {
                Text("Skipped").font(Theme.font(size: 13)).foregroundStyle(Theme.muted)
                Spacer()
            }
        }
    }
}

private struct EmailEditor: View {
    @Binding var subject: String
    @Binding var bodyText: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Subject", text: $subject)
                .textFieldStyle(.roundedBorder)
                .font(Theme.font(size: 14, weight: .semibold))
            TextEditor(text: $bodyText)
                .font(Theme.font(size: 14))
                .frame(minHeight: 170)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Theme.raised)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct ReplyCard: View {
    let reply: InquiryReply
    @ObservedObject private var office = BackOffice.shared
    @State private var subject: String
    @State private var text: String
    @State private var working = false

    init(reply: InquiryReply) {
        self.reply = reply
        _subject = State(initialValue: reply.subject)
        _text = State(initialValue: reply.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Reply to \(reply.person)").font(Theme.font(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                Text([reply.title, reply.to].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(Theme.font(size: 13)).foregroundStyle(Theme.muted)
            }
            if reply.status == .ready {
                EmailEditor(subject: $subject, bodyText: $text)
                HStack {
                    Button(working ? "Putting it in Gmail…" : "Put in Gmail drafts") {
                        working = true
                        Task { await office.putInGmail(reply, subject: subject, body: text); working = false }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(working || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Not needed") { office.skip(reply) }.buttonStyle(SecondaryButtonStyle())
                    Spacer()
                }
            } else {
                DoneLine(status: reply.status)
            }
        }
        .panel(padding: 20)
    }
}

private struct ProspectCard: View {
    let prospect: Prospect
    @ObservedObject private var office = BackOffice.shared
    @State private var to: String
    @State private var subject: String
    @State private var text: String
    @State private var working = false

    init(prospect: Prospect) {
        self.prospect = prospect
        _to = State(initialValue: prospect.contactEmail)
        _subject = State(initialValue: prospect.subject)
        _text = State(initialValue: prospect.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(prospect.organization).font(Theme.font(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                    if !prospect.contactName.isEmpty {
                        Text(prospect.contactName).font(Theme.font(size: 13)).foregroundStyle(Theme.muted)
                    }
                }
                Spacer()
                if let url = URL(string: prospect.website), !prospect.website.isEmpty {
                    Link("Website", destination: url).font(Theme.font(size: 13))
                }
            }
            if !prospect.why.isEmpty {
                Text(prospect.why).font(Theme.font(size: 14)).foregroundStyle(Theme.text2)
            }
            if !prospect.idea.isEmpty {
                Label(prospect.idea, systemImage: "lightbulb").font(Theme.font(size: 14)).foregroundStyle(Theme.text2)
            }
            if !prospect.sources.isEmpty {
                HStack(spacing: 10) {
                    Text("Read:").font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
                    ForEach(Array(prospect.sources.prefix(4).enumerated()), id: \.offset) { _, source in
                        if let url = URL(string: source) {
                            Link(url.host ?? source, destination: url).font(Theme.font(size: 12))
                        }
                    }
                }
            }
            if prospect.status == .ready {
                TextField("Their email (Lens couldn't find one, add it if you have it)", text: $to)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.font(size: 14))
                EmailEditor(subject: $subject, bodyText: $text)
                HStack {
                    Button(working ? "Putting it in Gmail…" : "Put in Gmail drafts") {
                        working = true
                        Task { await office.putInGmail(prospect, to: to, subject: subject, body: text); working = false }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(working || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Skip") { office.skip(prospect) }.buttonStyle(SecondaryButtonStyle())
                    Spacer()
                }
            } else {
                DoneLine(status: prospect.status)
            }
        }
        .panel(padding: 20)
    }
}

private struct ZelleRow: View {
    let payment: ZellePayment
    @ObservedObject private var office = BackOffice.shared
    // Watched so the lists and totals here stay up to date.
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var people: PeopleStore
    @EnvironmentObject private var money: MoneyStore
    @EnvironmentObject private var navigator: Navigator
    @State private var choice: Target?
    @State private var picked = false

    /// What a payment was for: an unpaid invoice, or one of her projects.
    enum Target: Hashable { case invoice(UUID), project(UUID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "dollarsign.circle.fill")
                    .foregroundStyle(payment.status == .markedPaid ? Theme.teal : Theme.amber)
                Text("\(Money.string(payment.amount)) from \(payment.payer.isEmpty ? "someone" : BackOffice.pretty(payment.payer))")
                    .font(Theme.font(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Text(payment.date.formatted(date: .abbreviated, time: .omitted))
                    .font(Theme.font(size: 13)).foregroundStyle(Theme.muted)
                Spacer()
            }
            switch payment.status {
            case .markedPaid:
                HStack {
                    Text(paidLine).font(Theme.font(size: 13)).foregroundStyle(Theme.text2)
                    Spacer()
                    if let id = payment.projectID, projects.project(id: id) != nil {
                        Button("Open project") { navigator.openProject(id) }.buttonStyle(SecondaryButtonStyle())
                    }
                    Button("Undo") { office.undo(payment) }.buttonStyle(SecondaryButtonStyle())
                }
            case .needsYou:
                needsYou
            case .dismissed:
                Text("Set aside").font(Theme.font(size: 13)).foregroundStyle(Theme.muted)
            }
        }
        .panel(padding: 16)
        .onAppear {
            guard !picked, choice == nil, payment.status == .needsYou,
                  let p = office.suggestedProject(for: payment) else { return }
            choice = .project(p.id)
        }
    }

    private var paidLine: String {
        guard let id = payment.projectID, let p = projects.project(id: id) else {
            return "Marked paid: \(payment.matchedLabel ?? "the matching invoice")"
        }
        var line = "Paid toward \(payment.matchedLabel ?? p.name)."
        if let owed = office.stillOwed(on: p) {
            line += owed > 0.01 ? " \(Money.string(owed)) still owed." : " Paid in full."
        }
        return line
    }

    @ViewBuilder private var needsYou: some View {
        let invoices = office.openInvoices
        let choices = office.projectChoices(for: payment)
        let suggested = office.suggestedProject(for: payment)
        HStack(spacing: 10) {
            Picker("What was this for?", selection: Binding(get: { choice }, set: { choice = $0; picked = true })) {
                Text("Choose one").tag(Target?.none)
                if !invoices.isEmpty {
                    Section("Unpaid invoices") {
                        ForEach(invoices) { r in
                            Text("\(r.client), \(r.label), \(Money.string(r.amount))").tag(Target?.some(.invoice(r.id)))
                        }
                    }
                }
                if !choices.isEmpty {
                    Section("Projects") {
                        ForEach(choices) { p in
                            Text(projectLine(p)).tag(Target?.some(.project(p.id)))
                        }
                    }
                }
            }
            .font(Theme.font(size: 13))
            .frame(maxWidth: 520)
            Button("Mark paid") {
                switch choice {
                case .invoice(let id): office.match(payment, to: id)
                case .project(let id): office.match(payment, toProject: id)
                case nil: break
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(choice == nil)
            Button("Not a client payment") { office.dismiss(payment) }.buttonStyle(SecondaryButtonStyle())
            Spacer()
        }
        if let suggested, choice == .project(suggested.id), !picked {
            Text("Lens thinks this is for \(suggested.name). Pick something else if it isn't.")
                .font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
        } else if invoices.isEmpty && choices.isEmpty {
            Text("No unpaid invoices or projects in Lens yet. Add the project in Projects, or connect FreshBooks in Log-ins.")
                .font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
        }
        senderLine
    }

    /// Who sent it: someone in People, or a way to say who it is or add them.
    @ViewBuilder private var senderLine: some View {
        if !payment.payer.isEmpty {
            if let person = office.sender(of: payment) {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle").foregroundStyle(Theme.muted)
                    Text("From \(person.name), in People.").font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
                    Button("Not them") { office.setSender(nil, for: payment) }.buttonStyle(.link).font(Theme.font(size: 12))
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.questionmark").foregroundStyle(Theme.muted)
                    Text("\(BackOffice.pretty(payment.payer)) isn't in People yet.")
                        .font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
                    Picker("They're", selection: Binding<UUID?>(
                        get: { nil },
                        set: { id in if let id, let p = people.person(id: id) { office.setSender(p, for: payment) } })) {
                        Text("Someone already in People…").tag(UUID?.none)
                        ForEach(people.sorted) { p in
                            Text(p.company.isEmpty || p.company == p.name ? p.name : "\(p.name), \(p.company)").tag(UUID?.some(p.id))
                        }
                    }
                    .labelsHidden()
                    .font(Theme.font(size: 12))
                    .frame(maxWidth: 240)
                    Button("Add to People") { office.addSender(of: payment) }.buttonStyle(SecondaryButtonStyle())
                    Spacer()
                }
            }
        }
    }

    private func projectLine(_ p: Project) -> String {
        var parts = [p.client.trimmingCharacters(in: .whitespaces), p.name].filter { !$0.isEmpty }
        if let price = office.price(of: p) {
            var money = Money.string(price)
            if let owed = office.stillOwed(on: p), owed > 0.01, owed < price - 0.01 { money += ", \(Money.string(owed)) owed" }
            else if let owed = office.stillOwed(on: p), owed <= 0.01 { money += ", paid" }
            parts.append(money)
        }
        return parts.joined(separator: ", ")
    }
}
