import Foundation

/// Emma's prices and rules of thumb. Set once; every proposal is calculated from them.
/// Defaults are worked back from her CEJ options packet (Option B and C budgets).
struct RateCard: Codable, Hashable {
    // Who the proposals come from
    var ownerName = ""
    var businessName = ""
    var email = ""
    var website = ""

    // Day rates charged to the client
    var emmaDayRate: Double = 1500
    var collaboratorDayRate: Double = 1000
    /// What Emma actually pays a collaborator per day. Equal to the rate until she says otherwise.
    var collaboratorDayCost: Double = 1000
    var travelPrepDayFactor: Double = 0.5

    // Hourly rates charged to the client
    var planningHourly: Double = 80
    var editHourly: Double = 100
    var mediaHourly: Double = 100

    // Planning hours
    var planningPerShootDay: Double = 4
    var planningPerInterviewee: Double = 5
    var planningSavedPerClientTask: Double = 2

    // Edit hours
    var editPerFilmMinute: Double = 8
    var editPerCrewDay: Double = 1.5          // more cameras and days = more footage to review
    var editPerRevisionRound: Double = 5
    var trailerHours: Double = 12
    var socialCutHours: Double = 6
    var verticalCutHours: Double = 3
    var interviewExportHoursEach: Double = 2

    // Media management
    var mediaBaseHours: Double = 5
    var mediaPerShootDay: Double = 1
    var rawFootageHandoffHours: Double = 4

    // Equipment and support (drives, music, extra gear, production assistant)
    var equipmentBase: Double = 300
    var equipmentPerShootDay: Double = 300
    var equipmentPerInterviewee: Double = 200
    /// Share of the equipment line that is real out-of-pocket cost.
    var equipmentCostShare: Double = 0.6

    // Time on a shoot day, per person
    var onSetHoursLow: Double = 8
    var onSetHoursHigh: Double = 10
    var localDriveHoursLow: Double = 2
    var localDriveHoursHigh: Double = 3
    var travelPrepHours: Double = 8

    // What Emma pays per hour when she hands work off (she charges the client her rates above)
    var planningCostHourly: Double = 40
    var editCostHourly: Double = 50
    var mediaCostHourly: Double = 30
    /// Time Emma still spends briefing and reviewing handed-off work, as a share of its hours.
    var handOffOversight: Double = 0.1

    var stillEditHours: Double = 0.25

    // Terms she uses unless a deal says otherwise
    var depositPercent: Double = 50
    var paymentSchedule = "A 50% deposit locks the date. The balance is due before final files are released."
    var usageRights = "You can use the finished films anywhere, forever, for your organization. I keep the copyright and may show the work in my portfolio."
    var cancellationPolicy = "The deposit is non-refundable within 14 days of the shoot. Dates can move once at no charge with a week's notice."
    var weatherPolicy = "If weather makes an outdoor shoot unsafe or unusable, we reschedule together at no extra cost."
    var acceptHow = "Reply to say which option you'd like. I'll send the agreement and the deposit invoice the same day."

    // Turnaround, in business days
    var roughCutBusinessDays = 7
    var feedbackBusinessDays = 5
    var finalBusinessDays = 3
    var offerValidDays = 14

    // Proof
    var yearsInBusiness = ""
    var projectsCompleted = ""
    var reviewSummary = ""

    /// Extras priced separately, so scope creep gets paid for instead of eating the margin.
    var addOnMenu: [AddOn] = [
        AddOn(name: "Extra revision round", price: 500, note: "One more round of consolidated feedback"),
        AddOn(name: "Drone footage", price: 400, note: "Where permitted, per shoot day"),
        AddOn(name: "Additional location", price: 350, note: "Per location on an existing shoot day"),
        AddOn(name: "Extra 30 sec social cut", price: 600, note: "Cut from the main film"),
        AddOn(name: "Rush turnaround", price: 1000, note: "Rough cut and final in half the usual time"),
        AddOn(name: "Teleprompter", price: 150, note: "Per shoot day"),
    ]

    /// What Emma wants to clear per hour after paying crew and costs.
    var targetHourly: Double = 100
    /// Quotes are rounded to this.
    var roundTo: Double = 500
}

struct BudgetLine: Identifiable, Hashable {
    let id = UUID()
    let category: String
    let covers: String
    let detail: String
    var amount: Double
}

struct WorkloadRow: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let detail: String
    let low: Double
    let high: Double

    var hoursText: String { Estimate.range(low, high) }
    var daysText: String { Estimate.range(low / 8, high / 8, decimals: 1) }
}

struct Estimate {
    let lines: [BudgetLine]          // at Emma's rates
    let clientLines: [BudgetLine]    // scaled so they add up to the quote, like her packet
    let calculated: Double
    let quote: Double
    let travelAllowance: Double
    let workload: [WorkloadRow]
    let emmaHours: Double
    let collaboratorCost: Double
    let hardCosts: Double
    let handOffCost: Double
    let handOffHours: Double
    let handOffCharged: Double
    let checks: [String]

    /// What Emma nets on work someone else does.
    var handOffMargin: Double { handOffCharged - handOffCost }

    var total: Double { quote + travelAllowance }
    var takeHome: Double { quote - collaboratorCost - hardCosts - handOffCost }
    var takeHomePerHour: Double { emmaHours > 0 ? takeHome / emmaHours : 0 }
    var difference: Double { calculated > 0 ? (quote - calculated) / calculated : 0 }
    var teamHoursLow: Double { workload.reduce(0) { $0 + $1.low } }
    var teamHoursHigh: Double { workload.reduce(0) { $0 + $1.high } }

    static func range(_ low: Double, _ high: Double, decimals: Int = 0) -> String {
        let f = { (v: Double) in decimals == 0 ? String(Int(v.rounded())) : String(format: "%.\(decimals)f", v) }
        return f(low) == f(high) ? f(low) : "\(f(low))–\(f(high))"
    }
}

enum Money {
    static func string(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }

    /// "$44k", "$4.5k", "$600" for tight spaces.
    static func short(_ value: Double) -> String {
        if value >= 10_000 { return "$\(Int((value / 1000).rounded()))k" }
        if value >= 1_000 {
            let k = (value / 100).rounded() / 10
            return k == k.rounded() ? "$\(Int(k))k" : "$\(k)k"
        }
        return "$\(Int(value))"
    }
}

/// Turns one option's dials into hours, a budget, a price, and what Emma actually keeps.
/// Pure arithmetic: no AI, so every number can be traced back to a rate on the rate card.
enum Estimator {
    static func estimate(_ o: ScopeOption, rates r: RateCard) -> Estimate {
        let localPeople = Double(1 + o.localCrew)
        let travelPeople = Double(1 + o.travelCrew)
        let local = Double(o.localDays), travel = Double(o.travelDays)
        let crewDays = local * localPeople + travel * travelPeople

        // Hours
        let planning = max(4, r.planningPerShootDay * Double(o.shootDays)
                              + r.planningPerInterviewee * Double(o.interviewees)
                              - r.planningSavedPerClientTask * Double(o.clientTakesOn.count))
        let mainEdit = r.editPerFilmMinute * Double(o.filmMinutes)
                     + r.editPerCrewDay * crewDays
                     + r.editPerRevisionRound * Double(o.revisionRounds)
        var extrasEdit = 0.0
        for extra in o.extras {
            switch extra {
            case .trailer: extrasEdit += r.trailerHours
            case .socialCut: extrasEdit += r.socialCutHours * Double(o.quantity(.socialCut))
            case .verticalCut: extrasEdit += r.verticalCutHours * Double(o.quantity(.verticalCut))
            case .stills: extrasEdit += r.stillEditHours * Double(o.quantity(.stills))
            case .interviewLibrary: extrasEdit += r.interviewExportHoursEach * Double(o.interviewees)
            case .rawFootage: break
            }
        }
        let media = r.mediaBaseHours + r.mediaPerShootDay * Double(o.shootDays)
                  + (o.extras.contains(.rawFootage) ? r.rawFootageHandoffHours : 0)

        // Money at Emma's rates
        let localDayCost = r.emmaDayRate + Double(o.localCrew) * r.collaboratorDayRate
        let travelDayCost = r.emmaDayRate + Double(o.travelCrew) * r.collaboratorDayRate
        let production = local * localDayCost + travel * travelDayCost * (1 + r.travelPrepDayFactor)
        let equipment = r.equipmentBase + r.equipmentPerShootDay * Double(o.shootDays)
                      + r.equipmentPerInterviewee * Double(o.interviewees)

        var productionDetail = "\(o.localDays) local day\(o.localDays == 1 ? "" : "s"), Emma + \(o.localCrew)"
        if o.travelDays > 0 {
            productionDetail += "; \(o.travelDays) out-of-state day\(o.travelDays == 1 ? "" : "s") + travel/prep, Emma + \(o.travelCrew)"
        }
        let editDetail = "\(Estimate.range(mainEdit * 0.95, mainEdit * 1.05)) hours, \(o.revisionRounds) revision round\(o.revisionRounds == 1 ? "" : "s")"
            + (extrasEdit > 0 ? " + \(Int(extrasEdit.rounded())) hours of extras" : "")

        let lines = [
            BudgetLine(category: "Pre-production", covers: "Research, story development and planning",
                       detail: "\(Estimate.range(round5(planning * 0.9), round5(planning * 1.05))) hours",
                       amount: planning * r.planningHourly),
            BudgetLine(category: "Production", covers: "Filming days", detail: productionDetail, amount: production),
            BudgetLine(category: "Post-production", covers: o.extras.isEmpty ? "Editing and finishing" : "Editing, finishing and extras",
                       detail: editDetail, amount: (mainEdit + extrasEdit) * r.editHourly),
            BudgetLine(category: "Media management", covers: "Transfers, organization and verified backups",
                       detail: "\(Int(media.rounded())) hours", amount: media * r.mediaHourly),
            BudgetLine(category: "Equipment and support", covers: "Drives, music, supplemental gear, production assistant on select days",
                       detail: "", amount: equipment),
        ]
        let sum = lines.reduce(0) { $0 + $1.amount }
        let calculated = (sum / r.roundTo).rounded() * r.roundTo
        let quote = o.quote ?? calculated

        // Workload table, same shape as the one in her proposal
        var workload = [
            WorkloadRow(label: "Research, story development + pre-production", detail: "Planning calls, scouting, interview prep, scheduling",
                        low: round5(planning * 0.9), high: round5(planning * 1.05)),
            WorkloadRow(label: "\(o.localDays) local filming day\(o.localDays == 1 ? "" : "s")",
                        detail: "\(Int(localPeople))-person crew; \(Int(r.onSetHoursLow))–\(Int(r.onSetHoursHigh)) hours on set plus driving",
                        low: local * localPeople * (r.onSetHoursLow + r.localDriveHoursLow),
                        high: local * localPeople * (r.onSetHoursHigh + r.localDriveHoursHigh)),
        ]
        if o.travelDays > 0 {
            workload.append(WorkloadRow(label: "\(o.travelDays) out-of-state filming day\(o.travelDays == 1 ? "" : "s")",
                                        detail: o.travelPlaces.isEmpty ? "\(Int(travelPeople)) crew" : "\(o.travelPlaces); \(Int(travelPeople)) crew",
                                        low: travel * travelPeople * r.onSetHoursLow, high: travel * travelPeople * r.onSetHoursHigh))
            workload.append(WorkloadRow(label: "Outbound travel + preparation", detail: "One day per trip",
                                        low: travel * travelPeople * r.travelPrepHours, high: travel * travelPeople * r.travelPrepHours))
        }
        workload.append(WorkloadRow(label: "Media organization + backups", detail: "Transfers, verified backups, project prep",
                                    low: (media * 0.75).rounded(), high: media.rounded()))
        workload.append(WorkloadRow(label: "Main film post-production", detail: "Story edit, sound, color, titles, \(o.revisionRounds) revision rounds",
                                    low: round5(mainEdit * 0.95), high: round5(mainEdit * 1.05)))
        if extrasEdit > 0 {
            workload.append(WorkloadRow(label: "Extras", detail: o.extras.filter { $0 != .rawFootage }.map(\.shortLabel).joined(separator: ", "),
                                        low: round5(extrasEdit * 0.85), high: round5(extrasEdit * 1.05)))
        }

        // What Emma keeps
        let emmaShoot = local * (r.onSetHoursLow + r.onSetHoursHigh + r.localDriveHoursLow + r.localDriveHoursHigh) / 2
                      + travel * ((r.onSetHoursLow + r.onSetHoursHigh) / 2 + r.travelPrepHours)
        // Handed-off work: someone cheaper does the hours, Emma pays their rate and keeps the difference
        let hours: [WorkType: Double] = [.planning: planning, .editing: mainEdit, .extras: extrasEdit, .media: media]
        let charge: [WorkType: Double] = [.planning: r.planningHourly, .editing: r.editHourly, .extras: r.editHourly, .media: r.mediaHourly]
        let cost: [WorkType: Double] = [.planning: r.planningCostHourly, .editing: r.editCostHourly, .extras: r.editCostHourly, .media: r.mediaCostHourly]
        var handOffHours = 0.0, handOffCost = 0.0, handOffCharged = 0.0
        for work in o.handedOff {
            let h = hours[work] ?? 0
            handOffHours += h
            handOffCost += h * (cost[work] ?? 0)
            handOffCharged += h * (charge[work] ?? 0)
        }
        let emmaHours = planning + emmaShoot + mainEdit + extrasEdit + media - handOffHours * (1 - r.handOffOversight)
        let collaboratorCost = (local * Double(o.localCrew) + travel * Double(o.travelCrew) * (1 + r.travelPrepDayFactor)) * r.collaboratorDayCost
        let hardCosts = equipment * r.equipmentCostShare

        // Client-facing budget: Emma's lines scaled to the quote, rounded to $100, adding up exactly
        let factor = sum > 0 ? quote / sum : 1
        var clientLines = lines.map { line -> BudgetLine in
            var l = line
            l.amount = (line.amount * factor / 100).rounded() * 100
            return l
        }
        let drift = quote - clientLines.reduce(0) { $0 + $1.amount }
        if drift != 0, let biggest = clientLines.indices.max(by: { clientLines[$0].amount < clientLines[$1].amount }) {
            clientLines[biggest].amount += drift
        }

        let takeHome = quote - collaboratorCost - hardCosts - handOffCost
        var checks: [String] = []
        let diff = calculated > 0 ? (quote - calculated) / calculated : 0
        if diff < -0.05 { checks.append("Quoted \(Int((-diff * 100).rounded()))% under your rates (\(Money.string(calculated))). On purpose?") }
        if emmaHours > 0, takeHome / emmaHours < r.targetHourly {
            checks.append("You'd clear about \(Money.string(takeHome / emmaHours))/hr, under your \(Money.string(r.targetHourly)) target.")
        }
        if o.travelDays > 0 && o.travelAllowance == 0 { checks.append("Out-of-state days but no travel allowance.") }
        if o.revisionRounds > 3 { checks.append("More than 3 revision rounds: each one adds about \(Int(r.editPerRevisionRound)) edit hours.") }

        return Estimate(lines: lines, clientLines: clientLines, calculated: calculated, quote: quote,
                        travelAllowance: o.travelAllowance, workload: workload, emmaHours: emmaHours,
                        collaboratorCost: collaboratorCost, hardCosts: hardCosts,
                        handOffCost: handOffCost, handOffHours: handOffHours, handOffCharged: handOffCharged, checks: checks)
    }

    private static func round5(_ v: Double) -> Double { (v / 5).rounded() * 5 }

    /// "Protect the price, scale the scope": when an option is quoted under Emma's rates,
    /// find scope to take out until her rates match the quote, instead of discounting.
    static func suggestCuts(_ option: ScopeOption, rates: RateCard) -> (cuts: [String], option: ScopeOption)? {
        guard let target = option.quote else { return nil }
        guard estimate(option, rates: rates).calculated > target * 1.05 else { return nil }

        typealias Cut = (inout ScopeOption) -> String?
        func dropExtra(_ x: Extra) -> Cut {
            return { o in
                guard o.extras.contains(x) else { return nil }
                o.extras.removeAll { $0 == x }
                return "drop the \(x.shortLabel.lowercased())"
            }
        }
        let fewerRevisions: Cut = { o in
            guard o.revisionRounds > 1 else { return nil }
            o.revisionRounds -= 1
            return "one fewer revision round"
        }
        let fewerLocal: Cut = { o in
            guard o.localDays > 1 else { return nil }
            o.localDays -= 1
            return "one fewer local day"
        }
        let fewerTravel: Cut = { o in
            guard o.travelDays > 0 else { return nil }
            o.travelAllowance = (o.travelAllowance * Double(o.travelDays - 1) / Double(o.travelDays)).rounded()
            o.travelDays -= 1
            return "one fewer out-of-state day"
        }
        let shorterFilm: Cut = { o in
            guard o.filmMinutes > 1 else { return nil }
            o.filmMinutes -= 1
            return "a film one minute shorter"
        }
        let fewerVoices: Cut = { o in
            guard o.interviewees > 1 else { return nil }
            o.interviewees -= 1
            return "one fewer interviewee"
        }
        let smallerCrew: Cut = { o in
            guard o.localCrew > 0 else { return nil }
            o.localCrew -= 1
            return "one fewer crew member"
        }

        let candidates: [Cut] = [fewerRevisions, fewerLocal, fewerTravel, shorterFilm, fewerVoices, smallerCrew]
            + [Extra.rawFootage, .interviewLibrary, .stills, .verticalCut, .socialCut, .trailer].map(dropExtra)

        // Smallest change first: every single cut, then pairs, then threes. Among the changes
        // that reach the quote, keep the one that leaves the most scope in place.
        func apply(_ picks: [Int]) -> (cuts: [String], option: ScopeOption)? {
            var o = option
            var cuts: [String] = []
            for i in picks {
                guard let text = candidates[i](&o) else { return nil }
                cuts.append(text)
            }
            return (cuts, o)
        }
        let n = candidates.count
        var combos: [[Int]] = (0..<n).map { [$0] }
        for _ in 0..<2 {   // singles, then pairs; threes are checked after the loop
            var best: (cuts: [String], option: ScopeOption, value: Double)?
            for picks in combos {
                guard let result = apply(picks) else { continue }
                let value = estimate(result.option, rates: rates).calculated
                if value <= target, value > (best?.value ?? -1) { best = (result.cuts, result.option, value) }
            }
            if let best { return (best.cuts, best.option) }
            combos = combos.flatMap { combo in ((combo.last ?? -1) + 1 ..< n).map { combo + [$0] } }
        }
        var best: (cuts: [String], option: ScopeOption, value: Double)?
        for picks in combos {
            guard let result = apply(picks) else { continue }
            let value = estimate(result.option, rates: rates).calculated
            if value <= target, value > (best?.value ?? -1) { best = (result.cuts, result.option, value) }
        }
        return best.map { ($0.cuts, $0.option) }
    }
}

/// Dated milestones from a shoot date and Emma's turnaround rules: dates, not "4 to 6 weeks".
enum TimelinePlanner {
    struct Plan {
        let milestones: [Milestone]
        let finalDelivery: Date
    }

    static func plan(shootStart: Date, shootDays: Int, rates r: RateCard, now: Date = Date()) -> Plan {
        let kickoffCandidate = addBusinessDays(-10, to: shootStart)
        let kickoff = max(kickoffCandidate, addBusinessDays(2, to: now))
        let shootEnd = addBusinessDays(max(0, shootDays - 1), to: shootStart)
        let roughCut = addBusinessDays(r.roughCutBusinessDays, to: shootEnd)
        let feedback = addBusinessDays(r.feedbackBusinessDays, to: roughCut)
        let final = addBusinessDays(r.finalBusinessDays, to: feedback)
        let filming = shootDays <= 1 ? format(shootStart) : "\(format(shootStart)) – \(format(shootEnd))"
        return Plan(milestones: [
            Milestone(phase: "Kickoff call", when: format(kickoff)),
            Milestone(phase: "Filming", when: filming),
            Milestone(phase: "Rough cut", when: format(roughCut)),
            Milestone(phase: "Your feedback due", when: format(feedback)),
            Milestone(phase: "Final delivery", when: format(final)),
        ], finalDelivery: final)
    }

    static func format(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func addBusinessDays(_ days: Int, to date: Date) -> Date {
        let cal = Calendar.current
        var result = date
        var remaining = abs(days)
        let step = days >= 0 ? 1 : -1
        while remaining > 0 {
            result = cal.date(byAdding: .day, value: step, to: result) ?? result
            if !cal.isDateInWeekend(result) { remaining -= 1 }
        }
        return result
    }
}
