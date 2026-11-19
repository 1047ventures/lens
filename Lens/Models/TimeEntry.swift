import Foundation

/// What an hour on a project went on.
enum TimeKind: String, Codable, CaseIterable, Identifiable {
    case shoot, edit, planning, travel, calls, admin

    var id: String { rawValue }

    var label: String {
        switch self {
        case .shoot: return "Shoot"
        case .edit: return "Edit"
        case .planning: return "Planning"
        case .travel: return "Travel"
        case .calls: return "Calls"
        case .admin: return "Admin"
        }
    }

    /// A sensible default for the timer, from where the project is.
    static func guess(for stage: ProjectStage) -> TimeKind {
        switch stage {
        case .shoot: return .shoot
        case .edit, .delivered: return .edit
        case .paid, .archived: return .admin
        case .lead, .booked: return .planning
        }
    }

    // Tolerant: a kind this version doesn't know loads as Admin instead of failing the whole file.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TimeKind(rawValue: raw) ?? .admin
    }
}

/// Time spent on a project, from the timer, added by hand, or from a Zoom call or calendar event.
struct TimeEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var hours: Double
    var kind: TimeKind
    var note: String?
    /// Where it came from ("zoom:<id>", "calendar:<id>"), so the same meeting isn't suggested twice.
    var source: String?
}

enum Hours {
    /// "45 min", "2.5 h", "12 h".
    static func short(_ h: Double) -> String {
        if h > 0 && h < 1 { return "\(max(1, Int((h * 60).rounded()))) min" }
        let rounded = (h * 10).rounded() / 10
        return rounded == rounded.rounded() ? "\(Int(rounded)) h" : "\(rounded) h"
    }

    /// "1:05:12" for the running timer.
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

extension Project {
    var times: [TimeEntry] { timeEntries ?? [] }
    var isTiming: Bool { timerStartedAt != nil }

    /// Logged hours, plus the running timer so far.
    var totalHours: Double {
        times.reduce(0) { $0 + $1.hours } + (timerStartedAt.map { Date().timeIntervalSince($0) / 3600 } ?? 0)
    }

    var hoursThisWeek: Double {
        guard let week = Calendar.current.dateInterval(of: .weekOfYear, for: Date()) else { return 0 }
        return times.filter { week.contains($0.date) }.reduce(0) { $0 + $1.hours }
            + (timerStartedAt.map { Date().timeIntervalSince(max($0, week.start)) / 3600 } ?? 0)
    }

    var hoursByKind: [(kind: TimeKind, hours: Double)] {
        TimeKind.allCases.compactMap { kind in
            let h = times.filter { $0.kind == kind }.reduce(0) { $0 + $1.hours }
            return h > 0 ? (kind, h) : nil
        }
    }
}

/// One project's hours and money, worked out from the project, the books and the pipeline.
struct ProjectBooks {
    let price: Double?
    let received: Double
    let expenses: [Txn]
    let hours: Double

    var spent: Double { expenses.reduce(0) { $0 - $1.amount } }
    /// The price if there is one, otherwise what's come in so far.
    var base: Double? { price ?? (received > 0 ? received : nil) }
    var keep: Double? { base.map { $0 - spent } }
    /// What she keeps per hour so far, once there's a price and some real time logged.
    var perHour: Double? {
        guard let price, hours >= 0.5 else { return nil }
        return (price - spent) / hours
    }

    @MainActor
    static func make(_ project: Project, money: MoneyStore, deals: DealStore) -> ProjectBooks {
        let mine = money.txns.filter { $0.projectID == project.id }
        let dealPrice = deals.deals.first { $0.projectID == project.id }.flatMap { deals.value(of: $0) }
        return ProjectBooks(
            price: project.price ?? dealPrice,
            received: mine.filter { $0.amount > 0 && $0.category.group == .income }.reduce(0) { $0 + $1.amount },
            expenses: MoneyStore.expenses(in: mine),
            hours: project.totalHours)
    }
}

extension Project {
    /// Words that point at this project in a bank line or a calendar title: its name, its client,
    /// and their longer words ("Hartley" from "Hartley wedding"). Leaves out everyday words.
    var matchWords: [String] {
        let common: Set<String> = ["wedding", "weddings", "studio", "studios", "media", "films", "video", "videos",
                                   "project", "documentary", "company", "group", "brand", "shoot", "events",
                                   "event", "photo", "photos", "session", "portrait", "portraits", "interview"]
        var out = [name, client].map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        out += (name + " " + client).lowercased().split { !$0.isLetter }.map(String.init)
        return Array(Set(out.filter { $0.count >= 5 && !common.contains($0) }))
    }

    func matches(_ text: String) -> Bool {
        let t = text.lowercased()
        return matchWords.contains { t.contains($0) }
    }
}
