import Foundation

/// Where a potential gig is before it becomes a booked project.
enum DealStage: Int, Codable, CaseIterable, Identifiable {
    case inquiry, proposalOut, talking, won, lost

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .inquiry: return "New inquiry"
        case .proposalOut: return "Proposal out"
        case .talking: return "Talking terms"
        case .won: return "Won"
        case .lost: return "Lost"
        }
    }

    var isOpen: Bool { self == .inquiry || self == .proposalOut || self == .talking }

    /// Days without contact before a deal at this stage needs a nudge.
    var staleAfterDays: Int {
        switch self {
        case .inquiry: return 2
        case .proposalOut: return 7
        case .talking: return 10
        default: return .max
        }
    }
}

/// Add-ons beyond the main film. Each carries its own edit time.
enum Extra: String, Codable, CaseIterable, Identifiable {
    case trailer, socialCut, verticalCut, stills, interviewLibrary, rawFootage

    var id: String { rawValue }

    var label: String {
        switch self {
        case .trailer: return "60–90 sec trailer"
        case .socialCut: return "30 sec social cut"
        case .verticalCut: return "Vertical version"
        case .stills: return "Edited stills"
        case .interviewLibrary: return "Edited interview library"
        case .rawFootage: return "Raw footage + project files"
        }
    }

    var shortLabel: String {
        switch self {
        case .trailer: return "Trailer"
        case .socialCut: return "Social cut"
        case .verticalCut: return "Vertical"
        case .stills: return "Stills"
        case .interviewLibrary: return "Interview library"
        case .rawFootage: return "Raw footage"
        }
    }

    /// Extras that come in a number ("3 vertical clips", "10 stills").
    var hasQuantity: Bool { self == .socialCut || self == .verticalCut || self == .stills }

    var defaultQuantity: Int { self == .stills ? 10 : 1 }

    /// How the deliverable reads on the proposal, with its quantity.
    func deliverable(_ quantity: Int) -> String {
        switch self {
        case .socialCut: return quantity == 1 ? "30 sec social cut" : "\(quantity) × 30 sec social cuts"
        case .verticalCut: return quantity == 1 ? "Vertical version" : "\(quantity) vertical clips"
        case .stills: return "\(quantity) edited stills"
        default: return label
        }
    }
}

/// Kinds of work Emma can hand to someone cheaper and net the difference.
enum WorkType: String, Codable, CaseIterable, Identifiable {
    case planning, editing, extras, media
    var id: String { rawValue }
    var label: String {
        switch self {
        case .planning: return "Planning"
        case .editing: return "Editing"
        case .extras: return "Extras"
        case .media: return "Media"
        }
    }

    var shortLabel: String {
        switch self {
        case .planning: return "Plan"
        case .editing: return "Edit"
        case .extras: return "Extras"
        case .media: return "Media"
        }
    }
}

/// One way of doing the job. A deal usually carries one (simple gigs) or three
/// (full vision / close to it / bare bones). Every number on the proposal comes from these dials.
struct ScopeOption: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String            // "Option A"
    var tagline: String         // "Full vision"
    var pitch: String           // one sentence for the comparison table

    var localDays: Int
    var travelDays: Int         // out-of-state shoot days
    var travelPlaces: String    // "Nevada, Cincinnati"
    var localCrew: Int          // collaborators beside Emma on local days
    var travelCrew: Int         // collaborators beside Emma on travel days
    var interviewees: Int       // upper bound shown as "up to N"
    var filmMinutes: Int        // upper bound of the main film
    var revisionRounds: Int
    var extras: [Extra]
    var clientTakesOn: [String] // work shifted to the client to bring the price down
    var travelAllowance: Double // passed through on top of the fee
    var quote: Double?          // what Emma actually charges; nil = use the calculated price
    var note: String            // fine print about trade-offs
    /// Work handed to someone cheaper on this option. Optional so older saved deals still load.
    var handOff: [WorkType]? = nil

    var handedOff: Set<WorkType> { Set(handOff ?? []) }

    /// Cameras rolling on a local day. Defaults to one per person, up to three.
    var cameras: Int? = nil
    var cameraCount: Int {
        get { cameras ?? min(1 + localCrew, 3) }
        set { cameras = newValue }
    }

    /// How many of each countable extra, keyed by Extra raw value.
    var quantities: [String: Int]? = nil
    func quantity(_ extra: Extra) -> Int { quantities?[extra.rawValue] ?? extra.defaultQuantity }
    mutating func setQuantity(_ extra: Extra, _ n: Int) {
        var q = quantities ?? [:]
        q[extra.rawValue] = n
        quantities = q
    }

    var shootDays: Int { localDays + travelDays }
}

struct Contact: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var role: String
    var email: String
}

struct Milestone: Codable, Hashable, Identifiable {
    var id = UUID()
    var phase: String
    var when: String
}

struct ChecklistItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var text: String
    var done: Bool
}

/// A titled paragraph: creative pillars, choices to make together.
struct Point: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var text: String
}

/// The words of the proposal. Today Emma writes or pastes them; once the home server is
/// running, the local AI drafts them from the inquiry and call notes for her to approve.
struct ProposalStory: Codable, Hashable {
    var headline = ""
    var logline = ""
    var callout = ""
    var whyTitle = ""
    var why: [String] = []
    var feelings: [String] = []
    var approachTitle = ""
    var pillars: [Point] = []
    var choices: [Point] = []

    var isEmpty: Bool { headline.isEmpty && logline.isEmpty && why.isEmpty && pillars.isEmpty }
}

/// The six questions from the discovery call. Everything else in the proposal flows from these.
struct Discovery: Codable, Hashable {
    var goal = ""           // what the video has to do, in their words
    var audience = ""
    var whereWatched = ""
    var onCamera = ""
    var locations = ""
    var formats = ""
    var goLive: Date?
    var callDate: Date?

    var answered: Int {
        [goal, audience, whereWatched, onCamera, locations, formats]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count + (goLive == nil ? 0 : 1)
    }
    static let questionCount = 7
}

/// Money and promises in writing: deposit, payments, rights, what happens if plans change.
struct DealTerms: Codable, Hashable {
    var depositPercent: Double
    var paymentSchedule: String
    var usageRights: String
    var cancellation: String
    var weather: String
}

/// Something extra the client can add, priced separately so scope creep gets paid for.
struct AddOn: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var price: Double
    var note: String
}

struct Deal: Codable, Identifiable, Hashable {
    var id = UUID()
    var client: String
    var title: String
    var source: String              // "Email", "Website form", "Referral"…
    var stage: DealStage
    var contacts: [Contact] = []
    var location: String = ""
    var eventDate: Date?
    var budgetHint: String = ""     // what the client said about money, verbatim-ish
    var callNotes: String = ""
    var options: [ScopeOption] = []
    var chosenOptionID: UUID?
    var story = ProposalStory()
    var milestones: [Milestone] = []
    var nextSteps: [ChecklistItem] = []
    var originalLinks: [String] = []  // decks made outside the app
    var events: [ProjectEvent] = []
    var lastTouch: Date
    var lostReason: String?
    var projectID: UUID?
    var createdAt: Date

    // Filled in by the proposal builder. Optional so older saved deals still load.
    var discovery: Discovery?
    var exclusions: [String]?
    var formats: [String]?
    var approachNote: String?
    var shootStart: Date?
    var addOns: [AddOn]?
    var terms: DealTerms?
    var proofProjectIDs: [UUID]?
    var testimonial: String?
    var acceptHow: String?
    var expiresOn: Date?
    var nameChecked: Bool?
    var shortProposal: Bool?

    var disc: Discovery {
        get { discovery ?? Discovery() }
        set { discovery = newValue }
    }

    /// When the proposal should go out: 48 hours after the discovery call.
    var proposalDue: Date? {
        disc.callDate.map { $0.addingTimeInterval(48 * 3600) }
    }

    var chosenOption: ScopeOption? {
        options.first { $0.id == chosenOptionID }
    }

    func daysSinceTouch(now: Date = Date()) -> Int {
        Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: lastTouch),
                                        to: Calendar.current.startOfDay(for: now)).day ?? 0
    }

    var isStale: Bool { stage.isOpen && daysSinceTouch() >= stage.staleAfterDays }
}

extension ScopeOption {
    static func starter() -> ScopeOption {
        ScopeOption(name: "Option A", tagline: "The plan", pitch: "", localDays: 1, travelDays: 0, travelPlaces: "",
                    localCrew: 1, travelCrew: 1, interviewees: 2, filmMinutes: 3, revisionRounds: 2, extras: [],
                    clientTakesOn: [], travelAllowance: 0, quote: nil, note: "")
    }

    static let standardClientTasks = [
        "Pick the interviewees with the strongest stories and share their backgrounds",
        "Arrange participants, interview times, quiet rooms and filming access",
        "Supply background materials and archives, with permission information",
    ]

    /// Emma's usual trio, spun out of one scope: the full vision with every extra,
    /// a leaner version of the main film, and a bare-bones version where the client
    /// takes on some of the planning.
    func threeWays() -> [ScopeOption] {
        var full = self
        full.id = UUID()
        full.name = "Option A"; full.tagline = "Full vision"
        full.pitch = "The full vision, plus every asset for a multi-channel campaign."
        full.extras = Extra.allCases
        full.revisionRounds = max(revisionRounds, 3)
        full.clientTakesOn = []
        full.quote = nil

        var close = self
        close.id = UUID()
        close.name = "Option B"; close.tagline = "Close to full vision"
        close.pitch = "Close to the full vision, with a smaller team and fewer days. The main film only."
        close.localDays = max(1, localDays - 1)
        close.travelDays = max(0, travelDays - 1)
        close.travelAllowance = travelDays > 0 ? (travelAllowance * Double(close.travelDays) / Double(travelDays)).rounded() : 0
        close.interviewees = max(1, interviewees - 1)
        close.filmMinutes = max(1, filmMinutes - 1)
        close.revisionRounds = 2
        close.extras = []
        close.clientTakesOn = []
        close.quote = nil

        var bare = self
        bare.id = UUID()
        bare.name = "Option C"; bare.tagline = "Bare bones"
        bare.pitch = "The essentials, simply told. The main film only."
        bare.localDays = max(1, localDays - 2)
        bare.travelDays = 0
        bare.travelPlaces = ""
        bare.travelAllowance = 0
        bare.localCrew = max(0, localCrew - 1)
        bare.interviewees = max(1, interviewees - 2)
        bare.filmMinutes = max(1, filmMinutes - 2)
        bare.revisionRounds = 2
        bare.extras = []
        bare.clientTakesOn = interviewees > 0 ? Self.standardClientTasks : []
        bare.note = "With a smaller crew, camera, sound and lighting overlap while you direct: setups are more sequential and the edit is simpler."
        bare.quote = nil

        return [full, close, bare]
    }
}
