import SwiftUI

/// "Teach Lens": the last month of email Lens treated as work, one at a time. Each card shows what Lens did with it;
/// the user says whether that was right or fixes it, and Lens sorts her email by those answers from then on.
struct TeachLensView: View {
    @EnvironmentObject private var gmail: GmailSync
    @EnvironmentObject private var deals: DealStore
    @EnvironmentObject private var projects: ProjectStore
    @Environment(\.dismiss) private var dismiss

    @State private var cards: [GmailSync.TeachCard] = []
    @State private var index = 0
    @State private var loading = true
    @State private var problem: String?
    @State private var note = ""
    @State private var right = 0
    @State private var fixed = 0
    @State private var loader: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if let problem {
                Text(problem).font(.system(size: 13)).foregroundStyle(Theme.amber)
                Spacer()
            } else if index < cards.count {
                card(cards[index])
            } else if loading {
                Spacer()
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Finding the emails Lens thought were work…").font(.system(size: 13)).foregroundStyle(Theme.text3)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                done
            }
        }
        .padding(26)
        .frame(width: 640, height: 560)
        .background(Theme.ground)
        .onAppear { load() }
        .onDisappear { loader?.cancel() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Teach Lens what matters").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.text)
                Text("These are the emails Lens thought were work. Tell it when it got one right, and fix it when it didn't.")
                    .font(.system(size: 13)).foregroundStyle(Theme.text3)
            }
            Spacer()
            if index < cards.count {
                Text("\(index + 1) of \(cards.count)\(loading ? "+" : "")")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            Button("Close") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
        }
    }

    // MARK: One conversation

    private func card(_ c: GmailSync.TeachCard) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(c.senderName.isEmpty ? c.senderEmail : c.senderName)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Text("\(c.senderEmail) · \(c.thread.lastDate.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                Text(c.thread.subject.isEmpty ? "(no subject)" : c.thread.subject)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text2)
                    .padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)
                if !c.thread.snippet.isEmpty {
                    Text(c.thread.snippet).font(.system(size: 13)).foregroundStyle(Theme.text3).lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let url = URL(string: c.thread.link) {
                    Link("Open the email ↗", destination: url).font(.system(size: 12))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel(padding: 16)

            VStack(alignment: .leading, spacing: 8) {
                ColorLabel("What Lens did", takeColor(c.take))
                Text(takeText(c.take)).font(.system(size: 14)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Anything Lens should know? (optional, like \"venues are always work\")", text: $note)
                .textFieldStyle(.roundedBorder)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button("Skip") { next() }.buttonStyle(SecondaryButtonStyle())
                Spacer()
                notWorkMenu(c)
                workMenu(c)
                if c.take != .notSorted {
                    Button("That's right") { answer(c, .right) }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func workMenu(_ c: GmailSync.TeachCard) -> some View {
        Menu {
            Button("A new inquiry") { answer(c, .inquiry) }
            Button("Booked work (a new project)") { answer(c, .project) }
            let openProjects = projects.active
            let openDeals = deals.deals.filter { $0.stage.isOpen && $0.projectID == nil }
            if !openProjects.isEmpty || !openDeals.isEmpty {
                Divider()
                Section("It's for") {
                    ForEach(openProjects) { p in Button(p.name) { answer(c, .belongsToProject(p.id)) } }
                    ForEach(openDeals) { d in
                        Button(d.title.isEmpty ? d.client : d.title) { answer(c, .belongsToDeal(d.id)) }
                    }
                }
            }
        } label: { Text("It's work") }
            .menuStyle(.button).buttonStyle(SecondaryButtonStyle()).menuIndicator(.visible).fixedSize()
    }

    private func notWorkMenu(_ c: GmailSync.TeachCard) -> some View {
        let (sender, domain) = gmail.blockable(c)
        return Menu {
            ForEach(GmailSync.IgnoreReason.allCases, id: \.self) { reason in
                Button(reason.rawValue) { answer(c, .notWork(reason, blockSender: false, blockDomain: false)) }
            }
            if sender != nil {
                Divider()
                Button("Always ignore this sender") { answer(c, .notWork(nil, blockSender: true, blockDomain: false)) }
                if let domain {
                    Button("Always ignore everyone at \(domain)") { answer(c, .notWork(nil, blockSender: false, blockDomain: true)) }
                }
            }
        } label: { Text("Not work") }
            .menuStyle(.button).buttonStyle(SecondaryButtonStyle()).menuIndicator(.visible).fixedSize()
    }

    private func takeText(_ take: GmailSync.TeachCard.Take) -> String {
        switch take {
        case .onProject(_, let name): return "Put it on the project \(name)."
        case .onDeal(_, let name): return "Put it on \(name) in Pipeline."
        case .waiting(.inquiry, _): return "Suggested it as a new inquiry. It's waiting for you in Pipeline."
        case .waiting(.project, _): return "Suggested it as booked work. It's waiting for you in Projects."
        case .waiting(.attach, let name):
            return name.map { "Thinks it might belong to \($0), and is asking you." } ?? "Thinks it's work, and is asking which job it's for."
        case .leftOut: return "Left it out. Lens thought it wasn't work."
        case .notSorted: return "Hasn't sorted this one yet. Tell Lens what it is."
        }
    }

    private func takeColor(_ take: GmailSync.TeachCard.Take) -> Color {
        switch take {
        case .onProject, .onDeal: return Theme.teal
        case .waiting: return Palette.blue
        case .leftOut, .notSorted: return Theme.muted
        }
    }

    // MARK: Done

    private var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer()
            if cards.isEmpty {
                Text("Nothing new to go through.").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Lens hasn't treated any new emails from the last month as work. Come back after more comes in.")
                    .font(.system(size: 13)).foregroundStyle(Theme.text3)
            } else {
                Text("Thanks, that's all of them.").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.text)
                Text(summary).font(.system(size: 14)).foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Lens sorts your email by these answers from now on. Anything you said is work is waiting for you in Pipeline or Projects.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var summary: String {
        var parts: [String] = []
        if right > 0 { parts.append("Lens got \(right) right") }
        if fixed > 0 { parts.append("you fixed \(fixed)") }
        return parts.isEmpty ? "You skipped them all, which is fine." : parts.joined(separator: " and ") + "."
    }

    // MARK: Actions

    private func load() {
        guard loader == nil else { return }
        loader = Task {
            do {
                try await gmail.teachCards { card in
                    Task { @MainActor in cards.append(card) }
                }
            } catch is CancellationError {
            } catch {
                if cards.isEmpty {
                    problem = (error as? LocalizedError)?.errorDescription ?? "Lens couldn't read your email just now. Try again in a minute."
                }
            }
            loading = false
        }
    }

    private func answer(_ c: GmailSync.TeachCard, _ a: GmailSync.TeachAnswer) {
        gmail.teach(c, a, note: note)
        if case .right = a { right += 1 } else { fixed += 1 }
        next()
    }

    private func next() {
        note = ""
        index += 1
    }
}
