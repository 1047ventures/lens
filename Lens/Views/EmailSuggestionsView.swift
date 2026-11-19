import SwiftUI

/// "From your email": new inquiries (on Pipeline) or booked work (on Projects) that Lens spotted in Gmail.
/// Each one waits for Emma to tap Add or Ignore.
struct EmailSuggestionsPanel: View {
    enum Place { case pipeline, projects }

    @EnvironmentObject private var gmail: GmailSync
    @EnvironmentObject private var logins: ConnectionStore
    @EnvironmentObject private var navigator: Navigator
    let place: Place

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
                    .font(.system(size: 13)).foregroundStyle(Theme.text3)
                Spacer()
                Button("Open Log-ins") { navigator.open(.logins) }.buttonStyle(SecondaryButtonStyle())
            }
            .panel(padding: 14)
            .accentBar(Palette.blue)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    ColorLabel(items.isEmpty ? "From your email" : "From your email · \(items.count)", Palette.blue)
                    Text(statusText).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Spacer()
                    if gmail.checking { ProgressView().controlSize(.small) }
                    Button("Check email now") { Task { await gmail.check() } }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(gmail.checking)
                }
                if let problem = gmail.problem {
                    Text(problem).font(.system(size: 13)).foregroundStyle(Theme.amber)
                }
                if !gmail.canSortWithClaude {
                    Text(place == .pipeline
                         ? "Lens is only picking up website form and directory emails for now. Connect Claude in Log-ins and it will read the rest too."
                         : "Connect Claude in Log-ins and Lens can spot booked projects in your email.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(items) { item in
                    SuggestionRow(item: item, place: place)
                }
            }
            .panel(padding: 18)
            .accentBar(Palette.blue)
        }
    }

    private var statusText: String {
        if gmail.checking { return "Checking your email…" }
        if let last = gmail.lastChecked {
            let when = last.formatted(.relative(presentation: .named))
            return items.isEmpty ? "Nothing new. Checked \(when)." : "Checked \(when). Nothing is added until you say so."
        }
        return "Lens looks every hour."
    }
}

private struct SuggestionRow: View {
    @EnvironmentObject private var gmail: GmailSync
    @EnvironmentObject private var navigator: Navigator
    let item: EmailSuggestion
    let place: EmailSuggestionsPanel.Place

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(badge)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Palette.blue.opacity(0.18))
                    .foregroundStyle(Palette.blue)
                    .clipShape(Capsule())
                Text(item.kind == .attach ? item.thread.subject : item.displayTitle)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(byline).font(.system(size: 12)).foregroundStyle(Theme.muted)
                let text = item.kind == .attach || item.wants.isEmpty ? item.thread.snippet : item.wants
                if !text.isEmpty {
                    Text(text).font(.system(size: 13)).foregroundStyle(Theme.text3).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let url = URL(string: item.thread.link) {
                    Link("Open the email ↗", destination: url).font(.system(size: 12))
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button("Ignore") { gmail.ignore(item) }.buttonStyle(SecondaryButtonStyle())
                Button("Add") {
                    guard let id = gmail.add(item) else { return }
                    if item.kind == .project || item.targetProjectID != nil { navigator.openProject(id) } else { navigator.openDeal(id) }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(12)
        .background(Theme.raised.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var badge: String {
        switch item.kind {
        case .inquiry: return "New inquiry"
        case .project: return "Booked work"
        case .attach: return "Belongs to \(item.targetName ?? "a gig")"
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(threads) { thread in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                            .lineLimit(2)
                        Spacer()
                        Text(thread.lastDate.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Text("\(thread.from) · \(thread.messageCount) message\(thread.messageCount == 1 ? "" : "s")")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    if !thread.snippet.isEmpty {
                        Text(thread.snippet).font(.system(size: 12)).foregroundStyle(Theme.text3).lineLimit(2)
                    }
                    if let url = URL(string: thread.link) {
                        Link("Open in Gmail ↗", destination: url).font(.system(size: 12))
                    }
                }
            }
        }
    }
}
