import Foundation

/// The seven steps every gig moves through. Order matters: it drives the progress bar
/// shown wherever a project appears.
enum ProjectStage: Int, Codable, CaseIterable, Identifiable {
    case lead, booked, shoot, edit, delivered, paid, archived

    var id: Int { rawValue }

    /// The step's name everywhere in Lens, read as what's happening now.
    var label: String {
        switch self {
        case .lead: return "Quoting"
        case .booked: return "Planning"
        case .shoot: return "Shooting"
        case .edit: return "Editing"
        case .delivered: return "Getting paid"
        case .paid: return "Wrapping up"
        case .archived: return "Put away"
        }
    }

    /// What the step means, in one plain sentence.
    var meaning: String {
        switch self {
        case .lead: return "Someone asked about it and it isn't booked yet. Quotes and first conversations live here."
        case .booked: return "They said yes, and the shoot hasn't happened yet."
        case .shoot: return "Being filmed or photographed now."
        case .edit: return "Shot, and you're editing it."
        case .delivered: return "They have it, and you're waiting to be paid."
        case .paid: return "Paid, and not put away on the server yet."
        case .archived: return "Finished and put away on the server."
        }
    }

    /// What gathers in this step, for a step that hasn't started or has nothing in it yet.
    var collects: String {
        switch self {
        case .lead: return "The inquiry, your quote, and the first emails and calls land here."
        case .booked: return "The shoot date and place, who's involved, the contract, call sheets and planning calls land here."
        case .shoot: return "Shoot day: the photos and videos, and the hours you spend shooting."
        case .edit: return "The footage sorted by scene, camera or person, and the hours you spend editing."
        case .delivered: return "What you delivered, the invoice, and anything still owed."
        case .paid: return "Payments in, what you kept, a testimonial, and moving the footage to the server."
        case .archived: return "Where the footage went, and the final numbers."
        }
    }

    /// The button that moves a project into this step.
    var moveLabel: String {
        switch self {
        case .lead: return "Back to quoting"
        case .booked: return "Mark as booked"
        case .shoot: return "Start shooting"
        case .edit: return "Start editing"
        case .delivered: return "Mark as delivered"
        case .paid: return "Mark as paid"
        case .archived: return "Put it away"
        }
    }

    var next: ProjectStage? { ProjectStage(rawValue: rawValue + 1) }

    /// The step a history line is about ("Paid", "Moved to Edit", "Shoot day at…"), if any.
    static func mentioned(in text: String) -> ProjectStage? {
        var t = text.lowercased().trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("moved to ") { t.removeFirst(9) }
        let starts: [(String, ProjectStage)] = [
            ("paid", .paid), ("deliver", .delivered), ("shot", .shoot), ("shoot", .shoot),
            ("edit", .edit), ("booked", .booked), ("lead", .lead), ("inquiry", .lead), ("archiv", .archived),
            ("quoting", .lead), ("planning", .booked), ("getting paid", .delivered), ("wrapping up", .paid), ("put away", .archived)
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
    /// The picture she picked for this project's tile. Nil means Lens picks one from the footage folder.
    var coverPath: String?

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
