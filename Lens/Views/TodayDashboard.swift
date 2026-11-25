import SwiftUI
import Charts

// The "how are we doing" pieces on Today. Each one is a glance and a door: the detail lives on
// Money, Pipeline or Projects, and clicking takes you there.

// MARK: - Numbers

@MainActor
struct TodayNumbers {
    struct Month: Identifiable { let start: Date; let income: Double; let net: Double; var id: Date { start } }
    struct Step: Identifiable { let stage: ProjectStage; let count: Int; let value: Double; var id: Int { stage.rawValue } }
    struct Slice: Identifiable { let id: UUID; let name: String; let hours: Double }

    let months: [Month]          // oldest first, this month last
    let owed: Double
    let owedCount: Int
    let overdueCount: Int
    let openDealsValue: Double
    let openDealsCount: Int
    let won: Int
    let lost: Int
    var winRate: Double? { won + lost == 0 ? nil : Double(won) / Double(won + lost) }
    let weeksHours: [Double]     // last 8 weeks, this week last
    let funnel: [Step]
    let hoursThisMonth: [Slice]

    var thisMonth: Month? { months.last }
    var bestMonth: Double { months.dropLast().map(\.income).max() ?? 0 }
    var averageIncome: Double {
        let past = months.dropLast().map(\.income).filter { $0 > 0 }
        return past.isEmpty ? 0 : past.reduce(0, +) / Double(past.count)
    }
    var hasMoney: Bool { months.contains { $0.income != 0 || $0.net != 0 } }

    init(money: MoneyStore, deals: DealStore, projects: ProjectStore, now: Date = Date()) {
        let cal = Calendar.current
        let monthStart = cal.dateInterval(of: .month, for: now)?.start ?? now
        months = (0..<6).reversed().compactMap { back in
            guard let start = cal.date(byAdding: .month, value: -back, to: monthStart),
                  let end = cal.date(byAdding: .month, value: 1, to: start) else { return nil }
            let txns = money.txns.filter { $0.date >= start && $0.date < end }
            let income = txns.filter { $0.category.group == .income }.reduce(0) { $0 + $1.amount }
            let costs = txns.filter { $0.category.group == .direct || $0.category.group == .overhead }.reduce(0) { $0 + $1.amount }
            return Month(start: start, income: income, net: income + costs)
        }

        let unpaid = money.receivables.filter { $0.paidOn == nil }
        owed = unpaid.reduce(0) { $0 + $1.amount }
        owedCount = unpaid.count
        overdueCount = unpaid.filter { $0.due < now }.count

        let open = deals.open.filter { $0.stage != .won }
        openDealsCount = open.count
        openDealsValue = open.compactMap { deals.value(of: $0) }.reduce(0, +)
        won = deals.deals.filter { $0.stage == .won }.count
        lost = deals.deals.filter { $0.stage == .lost }.count

        let all = projects.projects
        let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        weeksHours = (0..<8).reversed().map { back in
            guard let start = cal.date(byAdding: .weekOfYear, value: -back, to: weekStart),
                  let end = cal.date(byAdding: .weekOfYear, value: 1, to: start) else { return 0 }
            let logged = all.flatMap(\.times).filter { $0.date >= start && $0.date < end }.reduce(0) { $0 + $1.hours }
            let running = back == 0 ? all.compactMap(\.timerStartedAt).reduce(0) { $0 + now.timeIntervalSince(max($1, start)) / 3600 } : 0
            return logged + running
        }

        let active = projects.active
        let leadValue = open.compactMap { deals.value(of: $0) }.reduce(0, +)
        funnel = ProjectStage.allCases.filter { $0 != .archived }.map { stage in
            let here = active.filter { $0.stage == stage }
            let value = here.compactMap { ProjectBooks.make($0, money: money, deals: deals).base }.reduce(0, +)
            if stage == .lead { return Step(stage: stage, count: here.count + open.count, value: value + leadValue) }
            return Step(stage: stage, count: here.count, value: value)
        }

        hoursThisMonth = all.compactMap { p in
            let h = p.times.filter { $0.date >= monthStart }.reduce(0) { $0 + $1.hours }
                + (p.timerStartedAt.map { now.timeIntervalSince(max($0, monthStart)) / 3600 } ?? 0)
            return h > 0.05 ? Slice(id: p.id, name: p.name, hours: h) : nil
        }.sorted { $0.hours > $1.hours }
    }
}

// MARK: - What each card means, in one sentence

extension TodayNumbers {
    /// "$1.1k in so far this month. $3.5k more beats June, your best lately."
    var moneyTakeaway: String? {
        guard hasMoney else { return nil }
        let now = thisMonth?.income ?? 0
        let past = months.dropLast()
        let best = past.max { $0.income < $1.income }
        let bestName = best.map { $0.start.formatted(.dateTime.month(.wide)) } ?? ""
        if now <= 0 {
            return bestMonth > 0 ? "Nothing in yet this month. \(bestName) was your best lately, with \(Money.short(bestMonth))."
                                 : "Nothing in yet this month. It will show here as it lands."
        }
        if bestMonth <= 0 { return "\(Money.short(now)) in so far this month. A good start." }
        if now >= bestMonth { return "\(Money.short(now)) in this month. Your best month of the last six." }
        return "\(Money.short(now)) in so far this month. \(Money.short(bestMonth - now)) more beats \(bestName), your best lately."
    }

    /// "18 h so far this month. Most of it went to Hartley wedding."
    var timeTakeaway: String? {
        let total = hoursThisMonth.reduce(0) { $0 + $1.hours }
        guard total > 0, let top = hoursThisMonth.first else { return nil }
        if hoursThisMonth.count == 1 { return "\(Hours.short(total)) so far this month, all on \(top.name)." }
        if top.hours / total > 0.5 { return "\(Hours.short(total)) so far this month. Most of it went to \(top.name)." }
        return "\(Hours.short(total)) so far this month, across \(hoursThisMonth.count) jobs. \(top.name) took the most."
    }

    /// "6 jobs on the go. 2 are delivered and waiting to be paid."
    var funnelTakeaway: String? {
        let total = funnel.reduce(0) { $0 + $1.count }
        guard total > 0 else { return nil }
        let count: (ProjectStage) -> Int = { stage in funnel.first { $0.stage == stage }?.count ?? 0 }
        let going = total - count(.paid)
        guard going > 0 else { return "Everything here is done and paid. Nicely done." }
        let jobs = going == 1 ? "One job on the go." : "\(going) jobs on the go."
        let waiting = count(.delivered), editing = count(.edit), leads = count(.lead), booked = count(.booked)
        if waiting > 0 { return jobs + (waiting == 1 ? " One is delivered and waiting to be paid." : " \(waiting) are delivered and waiting to be paid.") }
        if editing > 0 { return jobs + (editing == 1 ? " One is in the edit." : " \(editing) are in the edit.") }
        if booked > 0 { return jobs + (booked == 1 ? " One is booked and coming up." : " \(booked) are booked and coming up.") }
        if leads > 0 { return jobs + (leads == 1 ? " One person is still deciding." : " \(leads) people are still deciding.") }
        return jobs
    }
}

// MARK: - Shared card

/// A dashboard card: coloured heading, content, and the whole thing opens its home page.
struct DashCard<Content: View>: View {
    let title: String
    let color: Color
    var action: (() -> Void)? = nil
    /// One plain sentence under the title that says what the card means.
    var takeaway: String? = nil
    @ViewBuilder let content: Content
    @State private var hover = false

    var body: some View {
        Button { action?() } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    ColorLabel(title, color)
                    Spacer()
                    if action != nil {
                        Image(systemName: "arrow.up.right")
                            .font(Theme.font(size: 11, weight: .semibold))
                            .foregroundStyle(hover ? color : Theme.muted.opacity(0.6))
                    }
                }
                if let takeaway, !takeaway.isEmpty {
                    Text(takeaway)
                        .font(Theme.font(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, -6)
                }
                content
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(hover && action != nil ? Theme.raised : Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(hover && action != nil ? color.opacity(0.5) : Theme.line))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

struct DashEmpty: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(Theme.font(size: 13))
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
            .multilineTextAlignment(.center)
    }
}

// MARK: - Headline tiles

struct StatTile: View {
    let label: String
    let value: String
    let note: String
    let color: Color
    var trend: [Double] = []
    var noteColor: Color = Theme.text3
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(label.uppercased())
                        .font(Theme.font(size: 10.5, weight: .bold)).tracking(0.8)
                        .foregroundStyle(Theme.muted)
                }
                HStack(alignment: .bottom) {
                    Text(value)
                        .font(Theme.font(size: 28, weight: .light)).monospacedDigit()
                        .foregroundStyle(Theme.text)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Spacer(minLength: 8)
                    if trend.count > 1 && trend.contains(where: { $0 != 0 }) {
                        Sparkline(values: trend, color: color).frame(width: 70, height: 28)
                    }
                }
                Text(note)
                    .font(Theme.font(size: 12))
                    .foregroundStyle(noteColor)
                    .lineLimit(1)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hover ? Theme.raised : Theme.panel)
            .overlay(alignment: .top) { Rectangle().fill(color).frame(height: 3) }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(hover ? color.opacity(0.5) : Theme.line))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { i, v in
            AreaMark(x: .value("i", i), y: .value("v", v))
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("i", i), y: .value("v", v))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .interpolationMethod(.catmullRom)
            if i == values.count - 1 {
                PointMark(x: .value("i", i), y: .value("v", v)).foregroundStyle(color).symbolSize(22)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }
}

// MARK: - Money

struct MoneyInChart: View {
    let numbers: TodayNumbers

    var body: some View {
        if !numbers.hasMoney {
            DashEmpty("Your money in will show here, month by month. Bring in a bank statement on Money to start.")
        } else {
            HStack(alignment: .center, spacing: 22) {
                Chart {
                    ForEach(numbers.months) { m in
                        let isNow = m.id == numbers.thisMonth?.id
                        BarMark(x: .value("Month", m.start, unit: .month), y: .value("In", max(0, m.income)))
                            .foregroundStyle(isNow ? Palette.lime : Palette.lime.opacity(0.35))
                            .cornerRadius(5)
                            .annotation(position: .top, spacing: 4) {
                                if m.income > 0 {
                                    Text(Money.short(m.income))
                                        .font(Theme.font(size: 10.5, weight: isNow ? .bold : .regular)).monospacedDigit()
                                        .foregroundStyle(isNow ? Theme.text : Theme.muted)
                                }
                            }
                    }
                    if numbers.averageIncome > 0 {
                        RuleMark(y: .value("Average", numbers.averageIncome))
                            .foregroundStyle(Theme.muted.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .annotation(position: .top, alignment: .leading, spacing: 2) {
                                Text("Average").font(Theme.font(size: 10)).foregroundStyle(Theme.muted)
                            }
                    }
                }
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated), centered: true)
                            .foregroundStyle(Theme.muted)
                    }
                }
                .frame(height: 170)

                GoalRing(now: numbers.thisMonth?.income ?? 0, best: numbers.bestMonth)
                    .frame(width: 130)
            }
        }
    }
}

/// How this month is doing against the best of the last five.
struct GoalRing: View {
    let now: Double
    let best: Double

    private var fraction: Double { best > 0 ? min(1, max(0, now / best)) : (now > 0 ? 1 : 0) }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(Theme.track, lineWidth: 11)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(AngularGradient(colors: [Palette.mint, Palette.lime, Palette.gold], center: .center),
                            style: StrokeStyle(lineWidth: 11, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(Theme.font(size: 24, weight: .light)).monospacedDigit()
                        .foregroundStyle(Theme.text)
                    Text("of best").font(Theme.font(size: 10.5)).foregroundStyle(Theme.muted)
                }
            }
            .frame(width: 104, height: 104)
            Text(best > 0 ? (now >= best ? "Best month yet" : "\(Money.short(best - now)) to beat it") : "This month")
                .font(Theme.font(size: 11.5, weight: .semibold))
                .foregroundStyle(now >= best && best > 0 ? Palette.lime : Theme.text3)
        }
    }
}

// MARK: - Pipeline funnel

struct StageFunnel: View {
    let steps: [TodayNumbers.Step]

    var body: some View {
        let maxCount = max(1, steps.map(\.count).max() ?? 1)
        if steps.allSatisfy({ $0.count == 0 }) {
            DashEmpty("Add a deal or a project and you'll see each job's step, from first inquiry to paid.")
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(steps) { step in
                    HStack(spacing: 10) {
                        Text(step.stage.label)
                            .font(Theme.font(size: 12, weight: .semibold))
                            .foregroundStyle(step.count > 0 ? step.stage.color : Theme.muted)
                            .frame(width: 68, alignment: .leading)
                        GeometryReader { geo in
                            let w = step.count == 0 ? 6 : max(10, geo.size.width * CGFloat(step.count) / CGFloat(maxCount))
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 6).fill(Theme.track.opacity(0.45))
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(LinearGradient(colors: [step.stage.color.opacity(0.95), step.stage.color.opacity(0.6)],
                                                         startPoint: .leading, endPoint: .trailing))
                                    .frame(width: w)
                            }
                        }
                        .frame(height: 16)
                        Text(summary(step))
                            .font(Theme.font(size: 12)).monospacedDigit()
                            .foregroundStyle(step.count > 0 ? Theme.text2 : Theme.muted)
                            .frame(width: 112, alignment: .trailing)
                    }
                    .help(Self.meaning(step.stage))
                }
            }
        }
    }

    private func summary(_ step: TodayNumbers.Step) -> String {
        guard step.count > 0 else { return "none" }
        let jobs = "\(step.count) job\(step.count == 1 ? "" : "s")"
        return step.value > 0 ? jobs + " · " + Money.short(step.value) : jobs
    }

    /// What each step means, shown when she rests the pointer on it.
    static func meaning(_ stage: ProjectStage) -> String {
        switch stage {
        case .lead: return "Leads: people who asked about a job but haven't booked yet. The money is what you've quoted them."
        case .booked: return "Booked: they said yes, and the shoot hasn't happened yet."
        case .shoot: return "Shoot: being filmed or photographed now."
        case .edit: return "Edit: shot, and you're editing it."
        case .delivered: return "Delivered: they have it, and you're waiting to be paid."
        case .paid: return "Paid: done and paid, not put away on the server yet."
        case .archived: return "Put away on the server."
        }
    }
}

// MARK: - Hours donut

struct HoursDonut: View {
    let slices: [TodayNumbers.Slice]
    private static let colors: [Color] = [Palette.orchid, Palette.violet, Palette.blue, Palette.mint, Palette.gold, Palette.rose]

    private var shown: [(name: String, hours: Double, color: Color)] {
        var out = slices.prefix(5).enumerated().map { (name: $1.name, hours: $1.hours, color: Self.colors[$0]) }
        let rest = slices.dropFirst(5).reduce(0) { $0 + $1.hours }
        if rest > 0 { out.append((name: "Everything else", hours: rest, color: Palette.slate)) }
        return out
    }

    var body: some View {
        let total = slices.reduce(0) { $0 + $1.hours }
        if total == 0 {
            DashEmpty("Start a timer on any project and you'll see where this month's hours go.")
        } else {
            HStack(spacing: 18) {
                ZStack {
                    Chart(Array(shown.enumerated()), id: \.offset) { _, s in
                        SectorMark(angle: .value("Hours", s.hours), innerRadius: .ratio(0.64), angularInset: 1.5)
                            .foregroundStyle(s.color)
                            .cornerRadius(3)
                    }
                    .chartLegend(.hidden)
                    VStack(spacing: 0) {
                        Text(Hours.short(total)).font(Theme.font(size: 20, weight: .light)).monospacedDigit().foregroundStyle(Theme.text)
                        Text("this month").font(Theme.font(size: 10.5)).foregroundStyle(Theme.muted)
                    }
                }
                .frame(width: 124, height: 124)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, s in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(s.color).frame(width: 9, height: 9)
                            Text(s.name).font(Theme.font(size: 12.5)).foregroundStyle(Theme.text2).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(Hours.short(s.hours)).font(Theme.font(size: 12)).monospacedDigit().foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Today's timeline

struct DayTimeline: View {
    let events: [LensCalendarEvent]
    let loaded: Bool
    var now = Date()
    private static let colors: [Color] = [Palette.blue, Palette.violet, Palette.orchid, Palette.mint, Palette.gold]

    private var range: (start: Date, end: Date) {
        let cal = Calendar.current
        let day = cal.startOfDay(for: now)
        let timed = events.filter { !$0.allDay }
        let firstHour = min(8, timed.map { cal.component(.hour, from: $0.start) }.min() ?? 8)
        let lastHour = max(20, (timed.map { cal.component(.hour, from: $0.end) + 1 }.max() ?? 20))
        return (cal.date(byAdding: .hour, value: firstHour, to: day)!, cal.date(byAdding: .hour, value: min(24, lastHour), to: day)!)
    }

    var body: some View {
        let timed = events.filter { !$0.allDay }.sorted { $0.start < $1.start }
        let allDay = events.filter(\.allDay)
        VStack(alignment: .leading, spacing: 10) {
            if !allDay.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(allDay) { e in
                        Text(e.title).font(Theme.font(size: 11.5, weight: .semibold))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Palette.gold.opacity(0.18)).foregroundStyle(Palette.gold)
                            .clipShape(Capsule())
                    }
                }
            }
            GeometryReader { geo in
                let r = range
                let span = r.end.timeIntervalSince(r.start)
                let x: (Date) -> CGFloat = { d in geo.size.width * CGFloat(max(0, min(1, d.timeIntervalSince(r.start) / span))) }
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.raised)
                    // Hour ticks
                    ForEach(0...Int(span / 3600), id: \.self) { h in
                        Rectangle().fill(Theme.line).frame(width: 1)
                            .offset(x: geo.size.width * CGFloat(Double(h) * 3600 / span))
                    }
                    ForEach(Array(timed.enumerated()), id: \.element.id) { i, e in
                        let color = Self.colors[i % Self.colors.count]
                        let lane = CGFloat(i % 2)
                        let past = e.end < now
                        HStack(spacing: 0) {
                            Rectangle().fill(color).frame(width: 3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.title).font(Theme.font(size: 11.5, weight: .semibold)).lineLimit(1)
                                Text(e.start.formatted(date: .omitted, time: .shortened)).font(Theme.font(size: 10)).opacity(0.75)
                            }
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 6)
                            Spacer(minLength: 0)
                        }
                        .frame(width: max(40, x(e.end) - x(e.start)), height: 34)
                        .background(color.opacity(past ? 0.12 : 0.26))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .opacity(past ? 0.6 : 1)
                        .offset(x: x(e.start), y: 6 + lane * 38)
                        .help("\(e.title), \(e.start.formatted(date: .omitted, time: .shortened)) to \(e.end.formatted(date: .omitted, time: .shortened))")
                    }
                    if now > r.start && now < r.end {
                        ZStack(alignment: .top) {
                            Rectangle().fill(Theme.coral).frame(width: 2)
                            Circle().fill(Theme.coral).frame(width: 8, height: 8).offset(y: -3)
                        }
                        .offset(x: x(now) - 1)
                    }
                }
            }
            .frame(height: timed.count > 1 ? 88 : 48)
            HStack {
                let r = range
                Text(r.start.formatted(date: .omitted, time: .shortened))
                Spacer()
                if timed.isEmpty {
                    Text(loaded ? "Nothing booked today. Clear runway." : "Checking your calendar…")
                }
                Spacer()
                Text(r.end.formatted(date: .omitted, time: .shortened))
            }
            .font(Theme.font(size: 11))
            .foregroundStyle(Theme.muted)
        }
    }
}

// MARK: - The week ahead

struct WeekStrip: View {
    let projects: [Project]
    let onOpen: (UUID) -> Void

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { offset in
                let day = cal.date(byAdding: .day, value: offset, to: today)!
                let shoots = projects.filter { $0.shootDate.map { cal.isDate($0, inSameDayAs: day) } ?? false }
                VStack(spacing: 6) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(Theme.font(size: 10, weight: .bold)).tracking(0.6)
                        .foregroundStyle(offset == 0 ? Theme.teal : Theme.muted)
                    Text(day.formatted(.dateTime.day()))
                        .font(Theme.font(size: 17, weight: offset == 0 ? .bold : .light)).monospacedDigit()
                        .foregroundStyle(offset == 0 ? Theme.text : Theme.text3)
                    VStack(spacing: 3) {
                        if shoots.isEmpty {
                            Capsule().fill(Theme.track.opacity(0.5)).frame(height: 5)
                        }
                        ForEach(shoots) { p in
                            Button { onOpen(p.id) } label: {
                                Text(p.name)
                                    .font(Theme.font(size: 10, weight: .semibold)).lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(Theme.ground)
                                    .padding(.horizontal, 4).padding(.vertical, 4)
                                    .frame(maxWidth: .infinity)
                                    .background(p.stage.color)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)
                            .help("\(p.name), \(p.stage.label)")
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .padding(.vertical, 10).padding(.horizontal, 5)
                .frame(maxWidth: .infinity, minHeight: 110, alignment: .top)
                .background(offset == 0 ? Theme.teal.opacity(0.08) : Theme.raised.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(offset == 0 ? Theme.teal.opacity(0.4) : .clear))
            }
        }
    }
}
