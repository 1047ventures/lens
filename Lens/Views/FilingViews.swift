import SwiftUI

// MARK: - "Which project is this for?"

/// Lens's question when it isn't sure where something goes: a picker of open projects with its best
/// guess listed first (never pre-picked), "Add project" for new work, and "Not for a project".
struct WhichProjectMenu: View {
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var deals: DealStore
    /// Lens's best guess, listed first.
    var guess: UUID?
    /// Also offer open deals in Pipeline (for Zoom notes).
    var includeDeals = false
    let onPick: (UUID) -> Void
    var onPickDeal: ((UUID) -> Void)? = nil
    /// Opens the new-project sheet, filled in.
    var onNew: (() -> Void)? = nil
    let onNone: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text("Which project is this for?")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text2)
            Menu {
                let open = projects.active
                if let guess, let p = open.first(where: { $0.id == guess }) {
                    Section("Lens's best guess") {
                        Button(label(p)) { onPick(p.id) }
                    }
                }
                let others = open.filter { $0.id != guess }
                if !others.isEmpty {
                    Section(guess == nil ? "Projects" : "Other projects") {
                        ForEach(others) { p in Button(label(p)) { onPick(p.id) } }
                    }
                }
                if includeDeals, let onPickDeal {
                    let pipeline = deals.deals.filter { $0.stage.isOpen && $0.projectID == nil }.sorted { $0.lastTouch > $1.lastTouch }
                    if !pipeline.isEmpty {
                        Section("Pipeline") {
                            ForEach(pipeline) { d in Button("\(d.client) · \(d.title)") { onPickDeal(d.id) } }
                        }
                    }
                }
                Divider()
                if let onNew { Button("Add project…") { onNew() } }
                Button("Not for a project") { onNone() }
            } label: {
                Text("Pick a project")
            }
            .menuStyle(.borderedButton)
            .fixedSize()
        }
    }

    private func label(_ p: Project) -> String { p.client.isEmpty ? p.name : "\(p.client) · \(p.name)" }
}

// MARK: - Add project, filled in

/// A new project Lens filled in from a call or an email, waiting in the new-project sheet.
struct ProjectDraft: Identifiable {
    let id = UUID()
    var project: Project
    var note: MeetingNote? = nil
    var email: EmailSuggestion? = nil
}

@MainActor
enum Filing {
    /// the user saved a project Lens filled in: add it, file the call or email it came from, then file any
    /// other waiting calls and emails from the same people or meeting series. Opens the new project.
    static func created(_ project: Project, from draft: ProjectDraft, projects: ProjectStore, zoom: ZoomNotes,
                        gmail: GmailSync, navigator: Navigator) {
        projects.add(project)
        if let note = draft.note { zoom.assign(note, toProject: project.id) }
        if let email = draft.email { gmail.file(email, into: project.id) }
        zoom.refile(into: project.id)
        gmail.refile(into: project.id)
        navigator.openProject(project.id)
    }
}

/// The new-project sheet, filled in from a draft.
struct ProjectDraftSheet: View {
    let draft: ProjectDraft
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var zoom: ZoomNotes
    @EnvironmentObject private var gmail: GmailSync
    @EnvironmentObject private var navigator: Navigator

    var body: some View {
        ProjectEditor(initial: nil, prefill: draft.project) { saved in
            Filing.created(saved, from: draft, projects: projects, zoom: zoom, gmail: gmail, navigator: navigator)
        }
    }
}

// MARK: - Filed automatically

/// On a project: what Lens filed here by itself lately, each with Move and Not this project.
/// Shows nothing when there's nothing.
struct AutoFiledPanel: View {
    let project: Project
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var zoom: ZoomNotes
    @EnvironmentObject private var gmail: GmailSync

    private var items: [AutoFiled] {
        let since = Date().addingTimeInterval(-30 * 86400)
        return (project.autoFiled ?? []).filter { $0.date > since }.sorted { $0.date > $1.date }.prefix(8).map { $0 }
    }

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ColorLabel("Filed automatically · \(items.count)", Palette.violet)
                Text("Lens put these here by itself. If one is wrong, move it or take it off.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(items) { item in row(item) }
            }
            .panel(padding: 18)
            .accentBar(Palette.violet)
        }
    }

    private func row(_ item: AutoFiled) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: AutoFiledRow.icon(item.kind)).font(.system(size: 11)).foregroundStyle(Palette.violet)
                Text(item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    .lineLimit(2)
            }
            Text("\(item.source) · \(item.date.formatted(.dateTime.month(.abbreviated).day()))")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            HStack(spacing: 14) {
                let others = projects.active.filter { $0.id != project.id }
                if !others.isEmpty {
                    Menu("Move") {
                        ForEach(others) { p in Button(p.name) { move(item, to: p.id) } }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .font(.system(size: 12))
                    .help("Put this on another project. Lens remembers for next time.")
                }
                Button("Not this project") { notThis(item) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .help(item.kind == .person ? "Take this person off. Lens won't add them here again."
                                               : "Take this off. Lens will ask you where it goes.")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raised.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func move(_ item: AutoFiled, to id: UUID) {
        switch item.kind {
        case .note:
            if let note = zoom.note(id: item.itemID) { zoom.move(note, toProject: id) }
            else { projects.dropAutoFiled(.note, itemID: item.itemID, from: project.id) }
        case .email: gmail.move(item.itemID, from: project.id, to: id)
        case .person: projects.moveAutoPerson(item.itemID, from: project.id, to: id)
        }
    }

    private func notThis(_ item: AutoFiled) {
        switch item.kind {
        case .note: zoom.notThisProject(item.itemID)
        case .email: gmail.notThisProject(item.itemID, from: project.id)
        case .person: projects.removeAutoPerson(item.itemID, from: project.id)
        }
    }
}

/// On Today: a short list of what Lens filed by itself this week, each one tap from its project.
struct AutoFiledToday: View {
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var navigator: Navigator

    var body: some View {
        let recent = Array(projects.recentlyAutoFiled().prefix(5))
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Filed by Lens this week")
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(recent, id: \.item.id) { entry in
                        HStack(spacing: 12) {
                            Image(systemName: AutoFiledRow.icon(entry.item.kind)).font(.system(size: 12)).foregroundStyle(Palette.violet)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.item.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                Text("\(entry.item.source) · on \(entry.project.name) · \(entry.item.date.formatted(.dateTime.month(.abbreviated).day()))")
                                    .font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Button("Open project") { navigator.openProject(entry.project.id) }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
                .panel(padding: 18)
            }
        }
    }
}

enum AutoFiledRow {
    static func icon(_ kind: AutoFiled.Kind) -> String {
        switch kind {
        case .note: return "video.fill"
        case .email: return "envelope.fill"
        case .person: return "person.fill"
        }
    }
}
