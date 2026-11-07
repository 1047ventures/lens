import Foundation

/// Footage that hasn't been touched in a long time and isn't referenced by any
/// known Premiere project — a candidate to move off the SSD.
struct ArchiveCandidate: Identifiable {
    let id = UUID()
    let file: MediaFile
    let daysSinceModified: Int

    var reason: String {
        "Untouched for \(daysSinceModified) days, not linked in any Premiere project"
    }
}
