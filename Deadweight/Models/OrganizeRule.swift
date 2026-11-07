import Foundation

/// A field footage can be grouped by when building an Organize destination path.
enum OrganizeFactor: String, Codable, CaseIterable, Identifiable {
    case project
    case date
    case camera
    case location

    var id: String { rawValue }

    var label: String {
        switch self {
        case .project: return "Project"
        case .date: return "Date"
        case .camera: return "Camera"
        case .location: return "Location"
        }
    }
}

/// An ordered set of factors that define how footage gets nested into folders.
/// `[.project, .date]` produces `Organized/ProjectA/2026-08-03/`; the order matters.
struct OrganizeRule: Codable, Equatable {
    var factors: [OrganizeFactor]

    static let defaultRule = OrganizeRule(factors: [.project, .date])

    /// Adds a factor if it isn't already present, or removes it (and closes the gap) if it is —
    /// the interaction model behind the rule-builder's tappable chips.
    mutating func toggle(_ factor: OrganizeFactor) {
        if let index = factors.firstIndex(of: factor) {
            factors.remove(at: index)
        } else {
            factors.append(factor)
        }
    }

    func position(of factor: OrganizeFactor) -> Int? {
        factors.firstIndex(of: factor).map { $0 + 1 }
    }
}
