import SwiftUI

/// One thing that needs her. Today's "A few things for you" and the morning cards both come from
/// `TodayItem.build`, so there is one way to work out what needs her.
struct TodayItem: Identifiable {
    enum Tone { case overdue, soon, neutral }
    /// Stable across redraws so an opened row stays open.
    var id: String { "\(actionTitle)|\(title)" }
    let tone: Tone
    let kicker: String
    let title: String
    let detail: String
    let actionTitle: String
    /// The project this is about, so a card can show its picture.
    var projectID: UUID? = nil
    let action: () -> Void

    /// Behind-the-scenes jobs (drives, log-ins). Simple leaves them to Library and Log-ins.
    var admin: Bool { ["Go to Library", "Open Library", "Open Log-ins"].contains(actionTitle) }
    var icon: String {
        switch actionTitle {
        case "Build proposal": return "doc.text"
        case "Open project": return "envelope"
        case "Open person": return "person"
        case "Open Helper": return kicker.contains("Zelle") ? "dollarsign.circle" : kicker == "New prospects" ? "person.crop.circle.badge.plus" : "envelope"
        case "Open project": return kicker.contains("payment") ? "dollarsign.circle" : "camera"
        default: return "sparkles"
        }
    }
}

extension TodayItem {
    @MainActor static func build(viewModel: ScanViewModel, projects: ProjectStore, deals: DealStore, logins: ConnectionStore, people: PeopleStore, navigator: Navigator) -> [TodayItem] {
        var result: [TodayItem] = []

        if viewModel.roots.isEmpty && DriveCatalog.shared.outside.isEmpty {
            result.append(TodayItem(tone: .neutral, kicker: "Getting started", title: "Add your drive",
                               detail: "Point Lens at the SSD so it can see the footage",
                               actionTitle: "Go to Library") { navigator.open(.footage) })
        } else if !viewModel.pluggedRoots.isEmpty && !viewModel.hasScanned {
            result.append(TodayItem(tone: .neutral, kicker: "Getting started", title: "Scan the drive",
                               detail: "See what's on it and how much space can come back",
                               actionTitle: "Go to Library") { navigator.open(.footage) })
        }

        for project in projects.active {
            if let date = project.shootDate, TodayItem.isSoon(date), project.stage != .lead, project.stage.order <= ProjectStage.shoot.order {
                result.append(TodayItem(tone: .soon, kicker: TodayItem.relativeDay(date), title: project.name,
                                   detail: project.location.isEmpty ? "Shoot day" : "Shoot at \(project.location)",
                                   actionTitle: "Open project", projectID: project.id) { navigator.openProject(project.id) })
            }
            if project.stage == .delivered {
                result.append(TodayItem(tone: .overdue, kicker: "Waiting on payment", title: project.name,
                                   detail: "Delivered. Mark it paid when the money lands",
                                   actionTitle: "Open project", projectID: project.id) { navigator.openProject(project.id) })
            }
            if project.stage == .paid, !project.isOnServer, project.folderPath != nil {
                result.append(TodayItem(tone: .neutral, kicker: "Ready for the server", title: project.name,
                                   detail: "Delivered and paid. Its footage can leave the SSD",
                                   actionTitle: "Go to Library") { navigator.open(.footage) })
            }
        }

        for deal in deals.open where deal.stage == .inquiry {
            guard let due = deal.proposalDue, due < Date().addingTimeInterval(36 * 3600) else { continue }
            let late = due < Date()
            result.append(TodayItem(tone: late ? .overdue : .soon,
                               kicker: late ? "Proposal overdue" : "Proposal due \(due.formatted(.dateTime.weekday(.wide).hour().minute()))",
                               title: deal.title,
                               detail: "\(BuilderStep.progress(deal)) of \(BuilderStep.allCases.count) sections done",
                               actionTitle: "Build proposal", projectID: deal.projectID) { navigator.openBuilder(deal.id) })
        }

        for deal in deals.open.filter({ $0.isStale && !($0.stage == .inquiry && $0.proposalDue != nil) }).sorted(by: { (deals.value(of: $0) ?? 0) > (deals.value(of: $1) ?? 0) }) {
            result.append(TodayItem(tone: .soon, kicker: "\(deal.stage.label) · \(deals.valueText(of: deal))", title: deal.title,
                               detail: DealCard.nextMove(deal),
                               actionTitle: "Open project", projectID: deal.projectID) { navigator.openDeal(deal.id) })
        }

        for person in people.followUpsDue {
            let date = person.followUp ?? Date()
            let late = !Calendar.current.isDateInToday(date)
            let detail = [person.followUpNote, person.subtitle].first { !$0.isEmpty } ?? "Time to check in"
            result.append(TodayItem(tone: late ? .overdue : .soon,
                               kicker: late ? "Follow-up was due \(date.formatted(.dateTime.month(.abbreviated).day()))" : "Follow up today",
                               title: person.name, detail: detail,
                               actionTitle: "Open person") { navigator.openPerson(person.id) })
        }

        for item in people.goneQuiet.prefix(4) {
            result.append(TodayItem(tone: .neutral, kicker: "Not in touch for \(item.days) days", title: item.person.name,
                               detail: "On \(item.deal.title), still open. Worth a hello?",
                               actionTitle: "Open person") { navigator.openPerson(item.person.id) })
        }

        // The Helper: replies, pitches and payments waiting for her.
        let office = BackOffice.shared
        for payment in office.paymentsNeedingYou.prefix(3) {
            result.append(TodayItem(tone: .soon, kicker: "Zelle payment",
                               title: "\(Money.string(payment.amount)) from \(payment.payer.isEmpty ? "someone" : payment.payer)",
                               detail: "Which invoice was this for?",
                               actionTitle: "Open Helper") { navigator.open(.helper) })
        }
        for payment in office.recentlyMatched.prefix(3) {
            result.append(TodayItem(tone: .neutral, kicker: "Paid by Zelle",
                               title: "\(Money.string(payment.amount)) from \(payment.payer.isEmpty ? "someone" : payment.payer)",
                               detail: "Lens marked \(payment.matchedLabel ?? "the invoice") paid",
                               actionTitle: "Open Helper") { navigator.open(.helper) })
        }
        for reply in office.readyReplies.prefix(3) {
            result.append(TodayItem(tone: .soon, kicker: "Reply ready", title: reply.person,
                               detail: reply.title.isEmpty ? "A first reply is written. Check it and put it in Gmail." : "About \(reply.title). Check it and put it in Gmail.",
                               actionTitle: "Open Helper") { navigator.open(.helper) })
        }
        let pitches = office.readyProspects.count
        if pitches > 0 {
            result.append(TodayItem(tone: .neutral, kicker: "New prospects",
                               title: "\(pitches) pitch\(pitches == 1 ? "" : "es") ready to read",
                               detail: office.readyProspects.prefix(3).map(\.organization).joined(separator: ", "),
                               actionTitle: "Open Helper") { navigator.open(.helper) })
        }

        if viewModel.hasScanned {
            let reclaim = viewModel.overview.cacheBytes + viewModel.overview.duplicateWastedBytes
            if reclaim > 0 {
                let full = viewModel.roots.first.flatMap(DriveInfo.capacity(for:)).map { "\(Int(($0.fractionUsed * 100).rounded()))% full" }
                result.append(TodayItem(tone: .soon, kicker: full.map { "SSD \($0)" } ?? "Space to reclaim",
                                   title: "\(ByteFormat.string(reclaim)) can come back today",
                                   detail: "Premiere cache and duplicate copies",
                                   actionTitle: "Open Library") { navigator.open(.footage) })
            }
        }
        let p = logins.progress
        if p.done < p.total {
            result.append(TodayItem(tone: .neutral, kicker: "Log-ins · \(p.done) of \(p.total) connected",
                               title: "Finish connecting your accounts",
                               detail: logins.googleConnected ? "Google is in. A few small ones left." : "Start with Google: it unlocks email, Zoom summaries and payments",
                               actionTitle: "Open Log-ins") { navigator.open(.logins) })
        }
        // Most urgent first, otherwise keep the order above.
        func rank(_ t: TodayItem.Tone) -> Int { t == .overdue ? 0 : t == .soon ? 1 : 2 }
        return result.enumerated().sorted { (rank($0.element.tone), $0.offset) < (rank($1.element.tone), $1.offset) }.map(\.element)
    }

    static func isSoon(_ date: Date?) -> Bool {
        guard let date else { return false }
        let start = Calendar.current.startOfDay(for: Date())
        guard let end = Calendar.current.date(byAdding: .day, value: 7, to: start) else { return false }
        return date >= start && date < end
    }

    static func relativeDay(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today · \(date.formatted(date: .omitted, time: .shortened))" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow · \(date.formatted(date: .omitted, time: .shortened))" }
        return date.formatted(.dateTime.weekday(.wide).hour().minute())
    }
}
