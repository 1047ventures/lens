import SwiftUI

/// "From your email": new inquiries (on Pipeline) or booked work (on Projects) that Lens spotted in Gmail.
/// Inquiries wait for Add or Ignore. On Projects, new work offers Add project (filled in), and emails Lens
/// wasn't sure about ask "Which project is this for?". Ones it's sure about are filed by themselves.
struct EmailSuggestionsPanel: View {
    enum Place { case pipeline, projects }

    @EnvironmentObject private var gmail: GmailSync
    @EnvironmentObject private var logins: ConnectionStore
    @EnvironmentObject private var navigator: Navigator
    let place: Place
    @State private var teaching = false

    private var items: [EmailSuggestion] {
        place == .pipeline ? gmail.suggestions(for: [.inquiry, .attach], deals: true)
                           : gmail.suggestions(for: [.project, .attach], deals: false)
    }

    var body: some View {
        if !logins.gmailReady {
            HStack(spacing: 12) {
                Image(systemName: "envelope").foregroundStyle(Palette.blue)
                Text(place == .pipeline ? "Sign in with Google in Log-ins and Lens will bring new inquiries in from your email."
                                        : "Sign in with Google in Log-ins and Lens will spot booked work in your email.")
                    .font(Theme.font(size: 13)).foregroundStyle(Theme.text3)
                Spacer()
                Button("Open Log-ins") { navigator.open(.logins) }.buttonStyle(SecondaryButtonStyle())
            }
            .panel(padding: 14)
            .accentBar(Palette.blue)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    ColorLabel(items.isEmpty ? "From your email" : "From your email · \(items.count)", Palette.blue)
                    Text(statusText).font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
                    Spacer()
                    if gmail.checking { ProgressView().controlSize(.small) }
                    Button("Teach Lens") { teaching = true }
                        .buttonStyle(SecondaryButtonStyle())
                        .help("Go through your recent email and tell Lens what matters, so it sorts better")
                    Button("Check email now") { Task { await gmail.check() } }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(gmail.checking)
                }
                if let problem = gmail.problem {
                    Text(problem).font(Theme.font(size: 13)).foregroundStyle(Theme.amber)
                }
                if !gmail.canSortWithClaude {
                    Text(place == .pipeline
                         ? "Lens is only picking up website form and directory emails for now. Connect Claude in Log-ins and it will read the rest too."
                         : "Connect Claude in Log-ins and Lens can spot booked projects in your email.")
                        .font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(items) { item in
                    SuggestionRow(item: item, place: place)
                }
            }
            .panel(padding: 18)
            .accentBar(Palette.blue)
            .sheet(isPresented: $teaching) { TeachLensView() }
        }
    }

    private var statusText: String {
        if gmail.checking { return "Checking your email…" }
        if let last = gmail.lastChecked {
            let when = last.formatted(.relative(presentation: .named))
            if items.isEmpty { return "Nothing new. Checked \(when)." }
            return place == .pipeline ? "Checked \(when). Nothing is added until you say so."
                                      : "Checked \(when). Emails Lens is sure about go on their project by themselves."
        }
        return "Lens looks every hour."
    }
}

private struct SuggestionRow: View {
    @EnvironmentObject private var gmail: GmailSync
    @EnvironmentObject private var navigator: Navigator
    let item: EmailSuggestion
    let place: EmailSuggestionsPanel.Place
    @State private var drafting: ProjectDraft?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(badge)
                    .font(Theme.font(size: 10, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Palette.blue.opacity(0.18))
                    .foregroundStyle(Palette.blue)
                    .clipShape(Capsule())
                Text(item.kind == .attach ? item.thread.subject : item.displayTitle)
                    .font(Theme.font(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(byline).font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
                let text = item.kind == .attach || item.wants.isEmpty ? item.thread.snippet : item.wants
                if !text.isEmpty {
                    Text(text).font(Theme.font(size: 13)).foregroundStyle(Theme.text3).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let url = URL(string: item.thread.link) {
                    Link("Open the email ↗", destination: url).font(Theme.font(size: 12))
                }
            }
            Spacer(minLength: 8)
            actions
        }
        .padding(12)
        .background(Theme.raised.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .sheet(item: $drafting) { draft in ProjectDraftSheet(draft: draft) }
    }

    @ViewBuilder private var actions: some View {
        if place == .projects && item.kind == .attach {
            WhichProjectMenu(guess: item.targetProjectID,
                             onPick: { gmail.file(item, into: $0) },
                             onNew: { drafting = ProjectDraft(project: gmail.draft(for: item), email: item) },
                             onNone: { gmail.ignore(item) })
        } else if item.kind == .project {
            HStack(spacing: 8) {
                IgnoreMenu(item: item)
                Button("Add project") { drafting = ProjectDraft(project: gmail.draft(for: item), email: item) }
                    .buttonStyle(PrimaryButtonStyle())
                    .help("Make a project for this, filled in from the email. You can check it before it's saved.")
            }
        } else {
            HStack(spacing: 8) {
                IgnoreMenu(item: item)
                Button("Add") {
                    guard let id = gmail.add(item) else { return }
                    if item.kind == .project || item.targetProjectID != nil { navigator.openProject(id) } else { navigator.openDeal(id) }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private var badge: String {
        switch item.kind {
        case .inquiry: return "New inquiry"
        case .project: return "Booked work"
        case .attach:
            if place == .projects { return "Not sure which project" }
            return "Belongs to \(item.targetName ?? "a gig")"
        }
    }

    private var byline: String {
        var parts: [String] = []
        let who = item.person.isEmpty ? item.thread.from : item.person
        if !who.isEmpty { parts.append(who) }
        if item.kind != .attach && item.source != "Email" { parts.append("via \(item.source)") }
        if let date = item.eventDate { parts.append("for \(date.formatted(date: .abbreviated, time: .omitted))") }
        if !item.location.isEmpty { parts.append(item.location) }
        if !item.budget.isEmpty { parts.append(item.budget) }
        parts.append("emailed \(item.thread.lastDate.formatted(.dateTime.month(.abbreviated).day()))")
        return parts.joined(separator: " · ")
    }
}

/// The Gmail conversations linked to a deal or project, newest first, each opening in Gmail.
struct EmailThreadsList: View {
    let threads: [EmailThread]
    @EnvironmentObject private var history: EmailHistory

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(threads) { thread in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
                            .font(Theme.font(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                            .lineLimit(2)
                        Spacer()
                        Text(thread.lastDate.formatted(.dateTime.month(.abbreviated).day()))
                            .font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Text("\(thread.from) · \(thread.messageCount) message\(thread.messageCount == 1 ? "" : "s")")
                        .font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
                    if let s = history.summary(for: thread.id) {
                        Text(s.summary).font(Theme.font(size: 12)).foregroundStyle(Theme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(s.decisions.prefix(6), id: \.self) { d in
                            Text("• " + d).font(Theme.font(size: 12)).foregroundStyle(Theme.text3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else if !thread.snippet.isEmpty {
                        Text(thread.snippet).font(Theme.font(size: 12)).foregroundStyle(Theme.text3).lineLimit(2)
                    }
                    if let url = URL(string: thread.link) {
                        Link("Open in Gmail ↗", destination: url).font(Theme.font(size: 12))
                    }
                }
            }
        }
    }
}

/// Ignore, with a reason Lens learns from, or "always ignore" for a sender or domain.
private struct IgnoreMenu: View {
    @EnvironmentObject private var gmail: GmailSync
    let item: EmailSuggestion

    var body: some View {
        Menu {
            Button("Ignore") { gmail.ignore(item) }
            Divider()
            ForEach(GmailSync.IgnoreReason.allCases, id: \.self) { reason in
                Button(reason.rawValue) { gmail.ignore(item, reason: reason) }
            }
            if gmail.canBlockSender(item), let email = gmail.senderAddress(of: item) {
                Divider()
                Button("Always ignore this sender") { gmail.ignore(item, blockSender: true) }
                    .help(email)
                if let domain = gmail.blockableDomain(item) {
                    Button("Always ignore \(domain)") { gmail.ignore(item, blockDomain: true) }
                }
            }
        } label: {
            Text("Ignore")
        }
        .menuStyle(.button)
        .buttonStyle(SecondaryButtonStyle())
        .menuIndicator(.visible)
        .fixedSize()
    }
}
