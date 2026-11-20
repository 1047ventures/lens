import SwiftUI
import AppKit

/// The Zoom meeting summaries on a deal or project, newest first. Long summaries fold up.
struct MeetingNotesList: View {
    @EnvironmentObject private var zoom: ZoomNotes
    @EnvironmentObject private var projects: ProjectStore
    let notes: [MeetingNote]
    /// The project these notes are on, so it isn't offered in "Move to".
    var projectID: UUID? = nil
    @State private var open: Set<String> = []
    @State private var reading: MeetingNote?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Button { reading = note } label: {
                            Text(note.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                                .lineLimit(2).multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain)
                        .help("Read the whole summary")
                        Spacer()
                        Text("\(note.sourceLabel) · \(note.date.formatted(date: .abbreviated, time: .omitted))")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            .help(note.fromRecording ? "Lens listened to your recording and wrote this up" : "Written by Zoom's AI Companion")
                    }
                    if !note.summary.isEmpty {
                        Text(note.summary).font(.system(size: 12)).foregroundStyle(Theme.text3)
                            .lineLimit(open.contains(note.id) ? nil : 6)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    HStack(spacing: 14) {
                        if note.hasDetails {
                            Button("Read the whole summary") { reading = note }
                                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.violet)
                        } else if note.summary.count > 300 {
                            Button(open.contains(note.id) ? "Show less" : "Show all") {
                                if open.contains(note.id) { open.remove(note.id) } else { open.insert(note.id) }
                            }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.violet)
                        }
                        if let url = URL(string: note.link) {
                            Link(note.linkLabel, destination: url).font(.system(size: 12))
                        }
                        Spacer()
                        let others = projects.active.filter { $0.id != projectID }
                        if !others.isEmpty {
                            Menu("Move to…") {
                                ForEach(others) { p in
                                    Button(p.name) { zoom.move(note, toProject: p.id) }
                                }
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .font(.system(size: 12))
                            .help("Put this note on another project. Lens remembers, so calls with the same people go there too.")
                        }
                        Button("Wrong place?") { zoom.unassign(note) }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            .help("Take this note off and pick where it goes")
                    }
                }
            }
        }
        .sheet(item: $reading) { note in
            MeetingNoteView(note: note)
        }
    }
}

/// One meeting summary on its own page: overview, every topic, next steps and who was there.
struct MeetingNoteView: View {
    let note: MeetingNote
    @Environment(\.dismiss) private var dismiss
    @State private var showTranscript = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    ColorLabel(note.sourceLabel, Palette.violet)
                    Text(note.title).font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(note.date.formatted(date: .complete, time: .shortened))
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
            .padding(24)
            Divider().overlay(Theme.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let people = note.people, !people.isEmpty {
                        block("Who was there") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(people, id: \.self) { p in
                                    HStack(spacing: 8) {
                                        Image(systemName: "person.fill").font(.system(size: 11)).foregroundStyle(Palette.violet)
                                        Text(p.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                                        if !p.email.isEmpty && p.email != p.name {
                                            Text(p.email).font(.system(size: 12)).foregroundStyle(Theme.muted).textSelection(.enabled)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    let overview = (note.overview ?? "").isEmpty ? note.summary : (note.overview ?? "")
                    if !overview.isEmpty {
                        block(note.fromZoom || note.fromRecording ? "Overview" : "Summary") { FormattedText(text: overview) }
                    }
                    ForEach(Array((note.sections ?? []).enumerated()), id: \.offset) { _, section in
                        block(section.title.isEmpty ? "More" : section.title) { FormattedText(text: section.text) }
                    }
                    if let steps = note.nextSteps, !steps.isEmpty {
                        block("Next steps") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Image(systemName: "arrow.right.circle").font(.system(size: 12)).foregroundStyle(Palette.violet)
                                        Text(FormattedText.inline(step)).font(.system(size: 14)).foregroundStyle(Theme.text2)
                                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                    if let transcript = note.transcript, !transcript.isEmpty {
                        block("Everything that was said") {
                            DisclosureGroup(showTranscript ? "Hide the transcript" : "Show the transcript", isExpanded: $showTranscript) {
                                Text(transcript).font(.system(size: 13)).foregroundStyle(Theme.text2)
                                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                    .padding(.top, 8)
                            }
                            .font(.system(size: 13)).foregroundStyle(Theme.text)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(Theme.line)
            HStack {
                if let url = URL(string: note.link) {
                    Link(note.linkLabel, destination: url).font(.system(size: 13))
                }
                Spacer()
                Text(note.fromRecording ? "Written by Lens from your recording" : "Written by Zoom's AI Companion")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 480, idealHeight: 680)
        .background(Theme.ground)
    }

    private func block<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundStyle(Palette.violet)
            content()
        }
    }
}

/// A few lines of Zoom's text, with its bullet points and bold words shown properly.
private struct FormattedText: View {
    let text: String

    static func inline(_ line: String) -> AttributedString {
        (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(line)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if let bullet = line.bullet {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Theme.muted).frame(width: 4, height: 4)
                        Text(Self.inline(bullet)).font(.system(size: 14)).foregroundStyle(Theme.text2)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    .padding(.leading, CGFloat(line.indent) * 14)
                } else {
                    Text(Self.inline(line.text)).font(.system(size: 14)).foregroundStyle(Theme.text2)
                        .lineSpacing(3).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
    }

    private struct Line {
        let text: String
        let bullet: String?
        let indent: Int
    }

    private var lines: [Line] {
        text.components(separatedBy: .newlines).compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let indent = min((raw.prefix(while: { $0 == " " || $0 == "\t" }).count) / 2, 3)
            for marker in ["- ", "* ", "• "] where trimmed.hasPrefix(marker) {
                return Line(text: trimmed, bullet: String(trimmed.dropFirst(marker.count)), indent: indent)
            }
            return Line(text: trimmed, bullet: nil, indent: 0)
        }
    }
}

/// Zoom summaries Lens wasn't sure about. For each one Lens asks "Which project is this for?", with its
/// best guess first, and offers Add project when the call looks like new work. Shows nothing when there are none.
struct UnmatchedNotesPanel: View {
    @EnvironmentObject private var zoom: ZoomNotes
    @State private var reading: MeetingNote?
    @State private var drafting: ProjectDraft?

    var body: some View {
        if !zoom.unmatched.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    ColorLabel("Unmatched notes · \(zoom.unmatched.count)", Palette.violet)
                    Text("Calls Lens wasn't sure about. Tell it where each one goes and it remembers.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                ForEach(zoom.unmatched) { note in
                    row(note)
                }
            }
            .panel(padding: 18)
            .accentBar(Palette.violet)
            .sheet(item: $reading) { note in
                MeetingNoteView(note: note)
            }
            .sheet(item: $drafting) { draft in
                ProjectDraftSheet(draft: draft)
            }
        }
    }

    private func row(_ note: MeetingNote) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(note.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                Text("\(note.sourceLabel) · \(note.date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                if !note.summary.isEmpty {
                    Text(note.summary).font(.system(size: 13)).foregroundStyle(Theme.text3).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 14) {
                    Button("Read the whole summary") { reading = note }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.violet)
                    if let url = URL(string: note.link) {
                        Link(note.fromRecording || note.fromZoom ? note.linkLabel : "Open the email ↗", destination: url).font(.system(size: 12))
                    }
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

/// In Log-ins › Zoom, until Zoom is connected: whether any summaries have reached Gmail yet.
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

/// "Which project is this for?" for one Zoom note, plus Add project when Lens has no guess
/// (it looks like new work).
struct NoteQuestion: View {
    @EnvironmentObject private var zoom: ZoomNotes
    let note: MeetingNote
    @Binding var drafting: ProjectDraft?

    var body: some View {
        let guess = zoom.bestGuess(for: note)
        HStack(alignment: .bottom, spacing: 8) {
            if guess == nil {
                Button("Add project") { drafting = ProjectDraft(project: zoom.draft(for: note), note: note) }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Looks like new work. Make a project for it, filled in from this call.")
            }
            WhichProjectMenu(guess: guess, includeDeals: true,
                             onPick: { zoom.assign(note, toProject: $0) },
                             onPickDeal: { zoom.assign(note, toDeal: $0) },
                             onNew: { drafting = ProjectDraft(project: zoom.draft(for: note), note: note) },
                             onNone: { zoom.dismiss(note) })
        }
    }
}

/// On the Meeting notes tab: Lens turning her Zoom recordings into notes. Shows progress while it
/// listens ("Listening to your recordings… 3 of 12"), where it looks, and lets her add a folder.
struct RecordingsStatus: View {
    @EnvironmentObject private var recordings: RecordingNotes

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if recordings.working, let progress = recordings.progress {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                } else {
                    Image(systemName: "waveform").font(.system(size: 12)).foregroundStyle(Palette.violet)
                    Text(summary).font(.system(size: 13)).foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Add a folder…") { pickFolder() }
                    .buttonStyle(SecondaryButtonStyle())
                    .help("Pick another folder where you keep recordings of your calls")
                Button("Look now") { Task { await recordings.check() } }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(recordings.working)
            }
            if !recordings.folders.isEmpty {
                HStack(spacing: 8) {
                    Text("Also looking in").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    ForEach(recordings.folders, id: \.self) { path in
                        HStack(spacing: 4) {
                            Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 12)).foregroundStyle(Theme.text3)
                            Button { recordings.removeFolder(path) } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.muted)
                            }
                            .buttonStyle(.plain)
                            .help("Stop looking in this folder")
                        }
                        .help(path)
                    }
                }
            }
            if let problem = recordings.problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var summary: String {
        let n = recordings.written
        let done = n == 0 ? "" : " \(n) written up so far."
        return "Lens listens to your Zoom recordings in Documents, Zoom and writes them up as notes.\(done)"
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Look here"
        panel.message = "Pick the folder where you keep recordings of your calls."
        if panel.runModal() == .OK, let url = panel.url { recordings.addFolder(url) }
    }
}
