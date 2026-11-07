import Foundation

/// A proposed move for a loose file into a `<Root>/Organized/<Project>/<Date>/` structure.
struct OrganizeProposal: Identifiable {
    let id = UUID()
    let file: MediaFile
    let proposedPath: String

    var proposedURL: URL { URL(fileURLWithPath: proposedPath) }
}
