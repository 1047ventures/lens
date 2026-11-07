import Foundation
import SwiftUI

/// Where money sits. Checking, Venmo and PayPal are cash; the card is money owed.
enum MoneyAccount: String, Codable, CaseIterable, Identifiable {
    case checking, card, venmo, paypal, cash
    var id: String { rawValue }
    var label: String {
        switch self {
        case .checking: return "Checking"
        case .card: return "Credit card"
        case .venmo: return "Venmo"
        case .paypal: return "PayPal"
        case .cash: return "Cash"
        }
    }
    var isCash: Bool { self != .card }
}

/// Every transaction lands in one of these. The group decides where it shows up in the books.
enum MoneyCategory: String, Codable, CaseIterable, Identifiable {
    // Income
    case weddings, brand, documentary, portraits, otherIncome
    // Direct project costs
    case crew, rentals, travel, music
    // Running the business
    case software, insurance, storage, marketing, meals, fees, office
    // Not profit or loss
    case gear, ownerDraw, ownerIn, transfer, taxes, uncategorized

    var id: String { rawValue }

    enum Group: String { case income, direct, overhead, capital, owner, transfer, taxes, unsorted }

    var group: Group {
        switch self {
        case .weddings, .brand, .documentary, .portraits, .otherIncome: return .income
        case .crew, .rentals, .travel, .music: return .direct
        case .software, .insurance, .storage, .marketing, .meals, .fees, .office: return .overhead
        case .gear: return .capital
        case .ownerDraw, .ownerIn: return .owner
        case .transfer: return .transfer
        case .taxes: return .taxes
        case .uncategorized: return .unsorted
        }
    }

    var label: String {
        switch self {
        case .weddings: return "Weddings + events"
        case .brand: return "Brand + commercial"
        case .documentary: return "Documentary"
        case .portraits: return "Portraits + sessions"
        case .otherIncome: return "Other income"
        case .crew: return "Crew + collaborators"
        case .rentals: return "Gear rentals"
        case .travel: return "Travel"
        case .music: return "Music licensing"
        case .software: return "Software + subscriptions"
        case .insurance: return "Insurance"
        case .storage: return "Storage + drives"
        case .marketing: return "Website + marketing"
        case .meals: return "Client meals"
        case .fees: return "Payment fees"
        case .office: return "Office + supplies"
        case .gear: return "Gear bought"
        case .ownerDraw: return "Paid to Emma"
        case .ownerIn: return "Put in by Emma"
        case .transfer: return "Transfer between accounts"
        case .taxes: return "Taxes"
        case .uncategorized: return "Not sorted yet"
        }
    }

    static var pickable: [MoneyCategory] { allCases.filter { $0 != .uncategorized } }
}

struct Txn: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    /// Positive = money in, negative = money out (for the card: negative = a charge, positive = a payment).
    var amount: Double
    var description: String
    var account: MoneyAccount
    var category: MoneyCategory
    var projectID: UUID?
    var note: String?
}

/// Money a client owes: a deposit or a balance, with a due date.
struct Receivable: Codable, Identifiable, Hashable {
    var id = UUID()
    var projectID: UUID?
    var client: String
    var label: String
    var amount: Double
    var due: Date
    var paidOn: Date?
}

/// Learned from Emma's corrections: anything whose description contains `match` gets `category`.
struct CategoryRule: Codable, Hashable {
    var match: String
    var category: MoneyCategory
}

struct GearItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case camera, lens, audio, lighting, drone, support, computer, storage, other
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var icon: String {
            switch self {
            case .camera: return "camera"
            case .lens: return "camera.aperture"
            case .audio: return "mic"
            case .lighting: return "lightbulb"
            case .drone: return "airplane"
            case .support: return "move.3d"
            case .computer: return "laptopcomputer"
            case .storage: return "externaldrive"
            case .other: return "shippingbox"
            }
        }
    }

    var id = UUID()
    var name: String
    var kind: Kind
    var bought: Date
    var paid: Double
    /// Years until it's worth only its resale floor (20% of what was paid).
    var lifeYears: Double
    var serial: String?
    var lastService: Date?
    var serviceNote: String?
    var shoots: Int?

    func value(at date: Date = Date()) -> Double {
        let years = max(0, date.timeIntervalSince(bought) / (365.25 * 86400))
        return paid * max(0.2, 1 - 0.8 * years / max(lifeYears, 0.5))
    }

    /// Cameras, lenses and drones want a clean or check-up at least once a year.
    var needsService: Bool {
        guard [.camera, .lens, .drone, .support].contains(kind) else { return false }
        // Counted from the last check-up, or from the day it was bought if it's never had one.
        return Date().timeIntervalSince(lastService ?? bought) > 365 * 86400
    }
}

/// Everything the Money and Gear screens keep, in one file.
struct MoneyData: Codable {
    var txns: [Txn] = []
    var openingDate: Date?
    var openings: [String: Double] = [:]   // MoneyAccount raw value → balance on openingDate
    var rules: [CategoryRule] = []
    var receivables: [Receivable] = []
    var gear: [GearItem] = []
}
