import SwiftUI

/// The Zoom meeting summaries on a deal or project, newest first. Long summaries fold up.
struct MeetingNotesList: View {
    @EnvironmentObject private var zoom: ZoomNotes
    let notes: [MeetingNote]
    @State private var open: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(note.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                            .lineLimit(2)
                        Spacer()
                        Text(note.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    if !note.summary.isEmpty {
                        Text(note.summary).font(.system(size: 12)).foregroundStyle(Theme.text3)
                            .lineLimit(open.contains(note.id) ? nil : 6)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 14) {
                        if note.summary.count > 300 {
                            Button(open.contains(note.id) ? "Show less" : "Show all") {
                                if open.contains(note.id) { open.remove(note.id) } else { open.insert(note.id) }
                            }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.violet)
                        }
                        if let url = URL(string: note.link) {
                            Link("Open in Gmail ↗", destination: url).font(.system(size: 12))
                        }
                        Spacer()
                        Button("Wrong place?") { zoom.unassign(note) }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            .help("Take this note off and pick where it goes")
                    }
                }
            }
        }
    }
}

/// Zoom summaries Lens couldn't match to a client. Emma picks the deal or project for each one.
/// Shows nothing when there are none.
struct UnmatchedNotesPanel: View {
    @EnvironmentObject private var zoom: ZoomNotes
    @EnvironmentObject private var deals: DealStore
    @EnvironmentObject private var projects: ProjectStore

    var body: some View {
        if !zoom.unmatched.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    ColorLabel("Unmatched notes · \(zoom.unmatched.count)", Palette.violet)
                    Text("Zoom call summaries Lens couldn't place. Pick where each one goes.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                ForEach(zoom.unmatched) { note in
                    row(note)
                }
            }
            .panel(padding: 18)
            .accentBar(Palette.violet)
        }
    }

    private func row(_ note: MeetingNote) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(note.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Zoom call · \(note.date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                if !note.summary.isEmpty {
                    Text(note.summary).font(.system(size: 13)).foregroundStyle(Theme.text3).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let url = URL(string: note.link) {
                    Link("Open the email ↗", destination: url).font(.system(size: 12))
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button("Not for a client") { zoom.dismiss(note) }.buttonStyle(SecondaryButtonStyle())
                Menu {
                    let open = deals.deals.filter { $0.stage.isOpen }.sorted { $0.lastTouch > $1.lastTouch }
                    if !open.isEmpty {
                        Section("Pipeline") {
                            ForEach(open) { d in
                                Button("\(d.client) · \(d.title)") { zoom.assign(note, toDeal: d.id) }
                            }
                        }
                    }
                    let active = projects.active
                    if !active.isEmpty {
                        Section("Projects") {
                            ForEach(active) { p in
                                Button(p.client.isEmpty ? p.name : "\(p.client) · \(p.name)") { zoom.assign(note, toProject: p.id) }
                            }
                        }
                    }
                    if open.isEmpty && active.isEmpty {
                        Text("No deals or projects yet")
                    }
                } label: {
                    Text("Pick a deal or project")
                }
                .menuStyle(.borderedButton)
                .fixedSize()
            }
        }
        .padding(12)
        .background(Theme.raised.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// In Log-ins › Zoom: whether any summaries have reached Gmail yet.
struct ZoomCheck: View {
    @EnvironmentObject private var zoom: ZoomNotes
    @EnvironmentObject private var logins: ConnectionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: arrived ? "checkmark.circle.fill" : "clock")
                    .foregroundStyle(arrived ? Theme.teal : Theme.amber)
                Text(message).font(.system(size: 13)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if logins.gmailReady {
                HStack(spacing: 10) {
                    Button("Check now") { Task { await zoom.check() } }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(zoom.checking)
                    if zoom.checking { ProgressView().controlSize(.small) }
                }
            }
            if let problem = zoom.problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Theme.amber)
            }
        }
    }

    private var arrived: Bool { zoom.foundCount > 0 }

    private var message: String {
        if !logins.gmailReady { return "Sign in with Google above first. Lens finds your Zoom summaries in Gmail." }
        if zoom.checking { return "Looking for Zoom summaries…" }
        if arrived {
            let n = zoom.foundCount
            let when = zoom.newestSummary.map { " The newest is from \($0.formatted(date: .abbreviated, time: .omitted))." } ?? ""
            return "Working. Lens has found \(n) Zoom summar\(n == 1 ? "y" : "ies").\(when)"
        }
        if zoom.lastChecked != nil { return "No summaries yet. They arrive a few minutes after your next Zoom call ends." }
        return "Lens hasn't looked yet. Click Check now."
    }
}
