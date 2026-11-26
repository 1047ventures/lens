import SwiftUI
import AppKit

/// Moving a project to any step, forward or back, and deleting it. Used on the project page and when
/// right-clicking a project, so it works the same everywhere.
enum ProjectMoves {
    /// Puts the project at `stage`. Going back to Quoting reopens its quote; moving a quote past Quoting books it
    /// (its price, people and emails go onto the project).
    @MainActor static func move(_ project: Project, to stage: ProjectStage, projects: ProjectStore, deals: DealStore) {
        guard project.stage != stage else { return }
        let quote = deals.quote(for: project)
        if stage == .lead {
            if let quote, quote.stage == .won || quote.stage == .lost {
                deals.setStage(.talking, for: quote, note: "Back to quoting")
            }
        } else if stage != .archived, let quote, quote.stage != .won {
            deals.link(quote, to: project.id, option: nil, projects: projects)
        }
        let back = stage.order < project.stage.order
        projects.setStage(stage, for: project, note: back ? "Moved back to \(stage.label)" : nil)
    }

    /// Asks first, then removes the project (and a quote that never booked). Footage, emails and invoices stay put.
    @MainActor static func confirmDelete(_ project: Project, projects: ProjectStore, deals: DealStore, navigator: Navigator) {
        let alert = NSAlert()
        alert.messageText = "Delete \(project.name)?"
        alert.informativeText = "This removes the project from Lens. Its footage folder, emails and invoices stay where they are."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete project")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if navigator.projectID == project.id { navigator.projectID = nil }
        if let quote = deals.quote(for: project), quote.stage != .won { deals.delete(quote) }
        projects.delete(project)
    }
}

/// "Move to" with every step, for a project's right-click menu or a button's menu.
struct ProjectMoveItems: View {
    let project: Project
    var includeDelete = true
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var deals: DealStore
    @EnvironmentObject private var navigator: Navigator

    var body: some View {
        Menu("Move to") {
            ForEach(ProjectStage.allCases) { step in
                Button {
                    ProjectMoves.move(project, to: step, projects: projects, deals: deals)
                } label: {
                    if step == project.stage { Label(step.label, systemImage: "checkmark") } else { Text(step.label) }
                }
                .disabled(step == project.stage)
            }
        }
        if includeDelete {
            Button("Delete project…", role: .destructive) {
                ProjectMoves.confirmDelete(project, projects: projects, deals: deals, navigator: navigator)
            }
        }
    }
}

/// A small button that opens the same "Move to" list, for the project page.
struct ProjectMoveButton: View {
    let project: Project
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var deals: DealStore

    var body: some View {
        Menu {
            ForEach(ProjectStage.allCases) { step in
                Button {
                    ProjectMoves.move(project, to: step, projects: projects, deals: deals)
                } label: {
                    if step == project.stage { Label(step.label, systemImage: "checkmark") } else { Text(step.label) }
                }
                .disabled(step == project.stage)
            }
        } label: {
            Label("Move to any step", systemImage: "arrow.left.arrow.right")
                .font(Theme.font(size: 13))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Put this project at any step, earlier or later")
    }
}
