import Foundation

/// The seven steps every gig moves through. Order matters: it drives the progress bar
/// shown wherever a project appears.
enum ProjectStage: Int, Codable, CaseIterable, Identifiable {
    case lead, booked, shoot, edit, delivered, paid, archived

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .lead: return "Lead"
        case .booked: return "Booked"
        case .shoot: return "Shoot"
        case .edit: return "Edit"
        case .delivered: return "Delivered"
        case .paid: return "Paid"
        case .archived: return "Archived"
        }
    }

    var next: ProjectStage? { ProjectStage(rawValue: rawValue + 1) }
}

/// One line in a project's running history ("Booked", "Footage moved to the server"…).
struct ProjectEvent: Codable, Identifiable, Hashable {
    let id: UUID
    let date: Date
    let text: String

    init(date: Date = Date(), text: String) {
        self.id = UUID()
        self.date = date
        self.text = text
    }
}

/// A gig. Footage, history and (later) money and gear all hang off this.
struct Project: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var client: String
    var shootDate: Date?
    var location: String
    /// The project's footage folder on the working drive.
    var folderPath: String?
    /// Where the footage went when it was moved to the server.
    var archivedPath: String?
    var stage: ProjectStage
    var events: [ProjectEvent]
    let createdAt: Date
    /// Proof for future proposals.
    var testimonial: String?
    var portfolioURL: String?

    init(name: String, client: String = "", shootDate: Date? = nil, location: String = "",
         folderPath: String? = nil, stage: ProjectStage = .lead) {
        self.id = UUID()
        self.name = name
        self.client = client
        self.shootDate = shootDate
        self.location = location
        self.folderPath = folderPath
        self.archivedPath = nil
        self.stage = stage
        self.events = [ProjectEvent(text: "Project created")]
        self.createdAt = Date()
    }

    var folderURL: URL? { folderPath.map { URL(fileURLWithPath: $0) } }

    /// True once the footage has been moved off the working drive.
    var isOnServer: Bool { archivedPath != nil }

    /// Files from the latest scan that live inside this project's folder.
    func files(in all: [MediaFile]) -> [MediaFile] {
        guard let folderPath else { return [] }
        let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        return all.filter { $0.path.hasPrefix(prefix) }
    }
}
