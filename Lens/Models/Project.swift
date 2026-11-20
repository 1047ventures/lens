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

    /// The step a history line is about ("Paid", "Moved to Edit", "Shoot day at…"), if any.
    static func mentioned(in text: String) -> ProjectStage? {
        var t = text.lowercased().trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("moved to ") { t.removeFirst(9) }
        let starts: [(String, ProjectStage)] = [
            ("paid", .paid), ("deliver", .delivered), ("shot", .shoot), ("shoot", .shoot),
            ("edit", .edit), ("booked", .booked), ("lead", .lead), ("inquiry", .lead), ("archiv", .archived)
        ]
        return starts.first { t.hasPrefix($0.0) }?.1
    }
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

/// Someone working on or appearing in a project: the client, directors, interviewees, crew.
/// Meeting notes and emails that involve any of them land on the project.
struct ProjectPerson: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var email: String
    var role: String

    static let roles = ["Client", "Director", "Producer", "Interviewee", "Crew", "Editor", "Planning"]
}

/// A contract, treatment, call sheet or other file for a project: a link to Google Drive or
/// the web, or a file on the user's Mac. Lens only remembers where it is; the file stays put.
struct ProjectFile: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var kind: String
    /// A web address, or the full path of a file on the Mac.
    var location: String
    var added = Date()

    var isWebLink: Bool { location.lowercased().hasPrefix("http") }

    static let kinds = ["Proposal", "Quote", "Contract", "Treatment", "Call sheet", "Script", "Release form", "Other"]
}

/// Something Lens put on a project by itself (a Zoom note, an email, a person), so the user can see it
/// on the project and undo it with Move or Not this project.
struct AutoFiled: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case note, email, person }

    var id = UUID()
    var kind: Kind
    /// The meeting note's id, the email conversation's id, or the person's email address.
    var itemID: String
    var title: String
    /// Where it came from, as the user sees it: "Zoom call", "Email", "Emails and calls".
    var source: String
    var date = Date()
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
    /// Gmail conversations about this project. Optional so older saved projects still load.
    var emails: [EmailThread]?
    /// Zoom meeting summaries for this project. Optional so older saved projects still load.
    var meetingNotes: [MeetingNote]?
    /// The people on this project. Optional so older saved projects still load.
    var people: [ProjectPerson]?
    /// Words that point to this project in meeting titles and notes ("CU", "documentary").
    var keywords: [String]?
    /// Contracts, treatments, call sheets and other files. Optional so older saved projects still load.
    var documents: [ProjectFile]?
    /// Hours spent on this project. Optional so older saved projects still load.
    var timeEntries: [TimeEntry]?
    /// When the running timer started, if it's running. Saved so it survives quitting Lens.
    var timerStartedAt: Date?
    /// What the running timer is counting (Shoot, Edit…).
    var timerKind: TimeKind?
    /// Zoom calls and calendar events the user said not to count as time.
    var skippedTimeSources: [String]?
    /// What the user is charging, when it isn't already on a won deal in Pipeline.
    var price: Double?
    /// What Lens filed on this project by itself lately, newest first. Optional so older saved projects still load.
    var autoFiled: [AutoFiled]?
    /// Email addresses the user said aren't on this project, so Lens doesn't add them again.
    var notPeople: [String]?

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
