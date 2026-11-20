import Foundation
import SwiftUI

/// The kinds of people the user works with. Stored as their label, so a person's tags read plainly in the file.
enum PersonTag: String, CaseIterable, Identifiable {
    case client = "Client"
    case director = "Director"
    case interviewee = "Interviewee"
    case crew = "Crew"
    case vendor = "Vendor"
    case lead = "Lead"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .client: return Palette.mint
        case .director: return Palette.violet
        case .interviewee: return Palette.orchid
        case .crew: return Palette.blue
        case .vendor: return Palette.sand
        case .lead: return Palette.gold
        }
    }

    static func color(for tag: String) -> Color {
        PersonTag(rawValue: tag)?.color ?? Palette.slate
    }
}

/// Someone the user works with: a client, a director, an interviewee, crew, a vendor or a lead.
/// Deals, projects, emails and Zoom notes are linked to them, so their page shows the whole story.
/// Every field decodes with a default, so a file written by a newer or older Lens always loads.
struct Person: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var emails: [String] = []
    var phone = ""
    var company = ""
    var role = ""
    /// Instagram handle or website.
    var link = ""
    /// How the user met them: Referral, Website, Instagram, Email, Event…
    var met = ""
    var tags: [String] = []
    var notes = ""
    /// "Follow up on" date, and what it's about.
    var followUp: Date?
    var followUpNote = ""
    /// Calls, chats and coffees the user logged by hand.
    var touches: [ProjectEvent] = []
    var dealIDs: [UUID] = []
    var projectIDs: [UUID] = []
    /// Deals or projects the user took this person off, so Lens doesn't link them again.
    var unlinked: [UUID] = []
    /// Gmail conversations with this person that aren't on a deal or project.
    var threads: [EmailThread] = []
    /// People the user split from this one, so Lens never merges them back together.
    var notSame: [UUID] = []
    /// True when Lens made this person from a deal, project or email rather than the user adding them.
    var automatic = false
    var createdAt = Date()
    // Added for "Added recently", imports and business cards. Optional so older files still load.
    /// Where Lens found them: "Gmail", "your website", "Instagram", "LinkedIn", "a business card"…
    var addedFrom: String?
    /// When Lens added them by itself. Only these show in "Added recently".
    var addedOn: Date?
    /// the user tapped Keep, so they leave "Added recently".
    var reviewed: Bool?
    /// Photos of their business card, kept in Application Support/Lens/CardPhotos.
    var cardPhotos: [String]?
    /// The day the user met them (from a business card).
    var metOn: Date?
    /// The day they connected on LinkedIn.
    var connectedOn: Date?

    init(name: String, emails: [String] = [], automatic: Bool = false) {
        self.name = name
        self.emails = emails
        self.automatic = automatic
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, emails, phone, company, role, link, met, tags, notes, followUp, followUpNote, touches,
             dealIDs, projectIDs, unlinked, threads, notSame, automatic, createdAt,
             addedFrom, addedOn, reviewed, cardPhotos, metOn, connectedOn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
        id = get(.id, UUID())
        name = get(.name, "")
        emails = get(.emails, [])
        phone = get(.phone, "")
        company = get(.company, "")
        role = get(.role, "")
        link = get(.link, "")
        met = get(.met, "")
        tags = get(.tags, [])
        notes = get(.notes, "")
        followUp = (try? c.decodeIfPresent(Date.self, forKey: .followUp)) ?? nil
        followUpNote = get(.followUpNote, "")
        touches = get(.touches, [])
        dealIDs = get(.dealIDs, [])
        projectIDs = get(.projectIDs, [])
        unlinked = get(.unlinked, [])
        threads = get(.threads, [])
        notSame = get(.notSame, [])
        automatic = get(.automatic, false)
        createdAt = get(.createdAt, Date())
        addedFrom = (try? c.decodeIfPresent(String.self, forKey: .addedFrom)) ?? nil
        addedOn = (try? c.decodeIfPresent(Date.self, forKey: .addedOn)) ?? nil
        reviewed = (try? c.decodeIfPresent(Bool.self, forKey: .reviewed)) ?? nil
        cardPhotos = (try? c.decodeIfPresent([String].self, forKey: .cardPhotos)) ?? nil
        metOn = (try? c.decodeIfPresent(Date.self, forKey: .metOn)) ?? nil
        connectedOn = (try? c.decodeIfPresent(Date.self, forKey: .connectedOn)) ?? nil
    }

    /// "From Gmail", "From your website"…
    var fromText: String? { addedFrom.map { "From \($0)" } }

    /// Lens added them by itself in the last two weeks and the user hasn't looked yet.
    func isRecentlyAdded(now: Date = Date()) -> Bool {
        guard let addedOn, reviewed != true else { return false }
        return now.timeIntervalSince(addedOn) < 14 * 86_400
    }

    var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap(\.first).map(String.init).joined()
        return s.isEmpty ? "?" : s.uppercased()
    }

    var primaryEmail: String { emails.first ?? "" }

    /// "Director at CU Boulder", "CU Boulder", "Director"…
    var subtitle: String {
        switch (role.isEmpty, company.isEmpty) {
        case (false, false): return "\(role) at \(company)"
        case (true, false): return company
        case (false, true): return role
        default: return primaryEmail
        }
    }

    func has(_ tag: PersonTag) -> Bool { tags.contains(tag.rawValue) }

    mutating func addTag(_ tag: String) {
        if !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { tags.append(tag) }
    }

    func isFollowUpDue(now: Date = Date()) -> Bool {
        guard let followUp else { return false }
        let endOfToday = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? now
        return followUp < endOfToday
    }

    /// For matching "the same person" by name: lowercased, no punctuation, single spaces.
    static func nameKey(_ name: String) -> String {
        let scalars = name.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }
}

/// Someone Lens found in Gmail who wasn't in People yet. Older versions asked the user to tap Add or Ignore;
/// Lens now adds them by itself, and any left in an older file are added when it loads.
struct PersonSuggestion: Codable, Identifiable, Hashable {
    var id: String { email }
    var name: String
    var email: String
    var thread: EmailThread?
    var found = Date()
}
