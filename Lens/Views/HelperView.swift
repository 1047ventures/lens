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
                         "Lens reads your Zelle emails. When a payment clearly matches an unpaid invoice, it marks it paid. Otherwise it asks you.",
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
    @State private var choice: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "dollarsign.circle.fill")
                    .foregroundStyle(payment.status == .markedPaid ? Theme.teal : Theme.amber)
                Text("\(Money.string(payment.amount)) from \(payment.payer.isEmpty ? "someone" : payment.payer)")
                    .font(Theme.font(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Text(payment.date.formatted(date: .abbreviated, time: .omitted))
                    .font(Theme.font(size: 13)).foregroundStyle(Theme.muted)
                Spacer()
            }
            switch payment.status {
            case .markedPaid:
                HStack {
                    Text("Marked paid: \(payment.matchedLabel ?? "the matching invoice")")
                        .font(Theme.font(size: 13)).foregroundStyle(Theme.text2)
                    Spacer()
                    Button("Undo") { office.undo(payment) }.buttonStyle(SecondaryButtonStyle())
                }
            case .needsYou:
                HStack(spacing: 10) {
                    Picker("Which invoice was this for?", selection: $choice) {
                        Text("Choose an invoice").tag(UUID?.none)
                        ForEach(office.openInvoices) { r in
                            Text("\(r.client), \(r.label), \(Money.string(r.amount))").tag(UUID?.some(r.id))
                        }
                    }
                    .font(Theme.font(size: 13))
                    .frame(maxWidth: 460)
                    Button("Mark paid") { if let choice { office.match(payment, to: choice) } }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(choice == nil)
                    Button("Not a client payment") { office.dismiss(payment) }.buttonStyle(SecondaryButtonStyle())
                    Spacer()
                }
                if office.openInvoices.isEmpty {
                    Text("No unpaid invoices in Lens yet. Connect FreshBooks in Log-ins and they'll show up here.")
                        .font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
                }
            case .dismissed:
                Text("Set aside").font(Theme.font(size: 13)).foregroundStyle(Theme.muted)
            }
        }
        .panel(padding: 16)
    }
}
