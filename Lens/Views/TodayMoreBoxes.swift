import SwiftUI
import Charts

// Extra boxes she can switch on for the Today page (Everything view). Each one is a glance and a
// door: one sentence that says what it means, a little detail, and a click to its home page.
// They all start off the page; she turns them on from "Choose boxes".

@MainActor
enum TodayMore {
    static func boxes(projects: ProjectStore, deals: DealStore, money: MoneyStore, navigator: Navigator) -> [PageBox] {
        [
            PageBox("monthGoal", "This month's goal", color: Palette.lime, half: true, off: true,
                    about: "How much you've kept this month next to a goal you set, and where the month is heading.") {
                MonthGoalBox(money: money, navigator: navigator)
            },
            PageBox("weekChecks", "This week's checklist", color: Palette.mint, half: true, off: true,
                    about: "A few simple checks for the week, ticked off as you go, with what to do for any that aren't.") {
                WeekChecklistBox(projects: projects, deals: deals, money: money, navigator: navigator)
            },
            PageBox("next30", "Shoots in the next 30 days", color: Theme.teal, half: true, off: true,
                    about: "Every shoot coming up in the next month, with its date.") {
                ShootsAheadBox(projects: projects, navigator: navigator)
            },
            PageBox("owedAging", "Who owes you", color: Palette.gold, half: true, off: true,
                    about: "Money you're waiting on, and how long each one has been waiting.") {
                OwedAgingBox(money: money, navigator: navigator)
            },
            PageBox("bestClients", "Your best clients this year", color: Palette.mint, half: true, off: true,
                    about: "Who has paid you the most so far this year.") {
                BestClientsBox(projects: projects, money: money, navigator: navigator)
            },
            PageBox("leadSources", "Where your leads come from", color: Palette.blue, half: true, off: true,
                    about: "Which places send you work, and how many of those jobs booked.") {
                LeadSourcesBox(deals: deals, navigator: navigator)
            },
            PageBox("avgPrice", "Your average job price", color: Palette.rose, half: true, off: true,
                    about: "What a typical job pays you, and whether that's going up.") {
                AveragePriceBox(projects: projects, deals: deals, money: money, navigator: navigator)
            },
            PageBox("yearOnYear", "This year and last year", color: Palette.lime, half: true, off: true,
                    about: "Money in so far this year, next to the same time last year.") {
                YearOnYearBox(money: money, navigator: navigator)
            },
            PageBox("perHour", "What you really earn per hour", color: Palette.orchid, half: true, off: true,
                    about: "What each job paid you for every hour you worked on it, after its costs.") {
                PerHourBox(projects: projects, deals: deals, money: money, navigator: navigator)
            },
            PageBox("quotesWaiting", "Quotes waiting for an answer", color: Palette.violet, half: true, off: true,
                    about: "Quotes you've sent, and how long each one has waited for a yes or no.") {
                QuotesWaitingBox(deals: deals, navigator: navigator)
            },
            PageBox("busyMonths", "Your busiest months", color: Palette.sand, half: true, off: true,
                    about: "Which months of the year you shoot the most. Handy for planning time off.") {
                BusyMonthsBox(projects: projects, navigator: navigator)
            },
            PageBox("unfiled", "Footage not filed yet", color: Theme.amber, half: true, off: true,
                    about: "Folders of photos and video on your drives that aren't part of a shoot yet.") {
                UnfiledFootageBox(projects: projects, navigator: navigator)
            },
            PageBox("driveSpace", "Drive space", color: Palette.slate, half: true, off: true,
                    about: "How full each of your drives is.") {
                DriveSpaceBox(navigator: navigator)
            },
        ]
    }
}

// MARK: - Small shared pieces

/// A label, a bar for how big it is, and its number.
private struct MoreBar: View {
    let label: String
    let value: String
    let fraction: Double
    let color: Color
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).font(Theme.font(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text2).lineLimit(1)
                if let note {
                    Text(note).font(Theme.font(size: 11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(value).font(Theme.font(size: 12)).monospacedDigit().foregroundStyle(Theme.text3).lineLimit(1)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track.opacity(0.45))
                    Capsule().fill(color).frame(width: max(4, geo.size.width * CGFloat(min(1, max(0, fraction)))))
                }
            }
            .frame(height: 7)
        }
    }
}

/// One line in a list: a coloured dot, a name with a smaller line under it, and a number on the right.
private struct MoreLine: View {
    let color: Color
    let title: String
    var detail: String = ""
    var value: String = ""
    var valueColor: Color = Theme.text3

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.font(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                if !detail.isEmpty {
                    Text(detail).font(Theme.font(size: 11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !value.isEmpty {
                Text(value).font(Theme.font(size: 12.5, weight: .semibold)).monospacedDigit().foregroundStyle(valueColor).lineLimit(1)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

/// "and 3 more", under a list that was cut short.
private struct MoreCount: View {
    let count: Int
    var body: some View {
        if count > 0 {
            Text("and \(count) more").font(Theme.font(size: 12)).foregroundStyle(Theme.muted).padding(.top, 2)
        }
    }
}

private enum Ago {
    /// Whole days from one date to another, by the calendar.
    static func days(from: Date, to: Date = Date()) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: from), to: cal.startOfDay(for: to)).day ?? 0
    }

    static func daysText(_ n: Int) -> String { n == 1 ? "1 day" : "\(n) days" }

    /// "today", "tomorrow", "on Friday", "on Dec 12".
    static func when(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "today" }
        if cal.isDateInTomorrow(date) { return "tomorrow" }
        if days(from: Date(), to: date) < 7 { return "on " + date.formatted(.dateTime.weekday(.wide)) }
        return "on " + date.formatted(.dateTime.month(.abbreviated).day())
    }
}

private func signedShort(_ value: Double) -> String {
    value < 0 ? "-" + Money.short(-value) : Money.short(value)
}

// MARK: - 1. Shoots in the next 30 days

private struct ShootsAheadBox: View {
    @ObservedObject var projects: ProjectStore
    let navigator: Navigator

    var body: some View {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 30, to: start) ?? start
        let shoots = projects.projects
            .filter { p in p.stage != .archived && (p.shootDate.map { $0 >= start && $0 < end } ?? false) }
            .sorted { ($0.shootDate ?? .distantFuture) < ($1.shootDate ?? .distantFuture) }
        DashCard(title: "Shoots in the next 30 days", color: Theme.teal, action: { navigator.open(.projects) },
                 takeaway: takeaway(shoots)) {
            if shoots.isEmpty {
                DashEmpty("Nothing booked for the next 30 days yet. Give a project a shoot date and it shows up here.")
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(shoots.prefix(6)) { p in
                        Button { navigator.openProject(p.id) } label: {
                            HStack(spacing: 12) {
                                VStack(spacing: 0) {
                                    Text((p.shootDate ?? Date()).formatted(.dateTime.weekday(.abbreviated)).uppercased())
                                        .font(Theme.font(size: 9.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.muted)
                                    Text((p.shootDate ?? Date()).formatted(.dateTime.day()))
                                        .font(Theme.font(size: 16, weight: .light)).monospacedDigit().foregroundStyle(Theme.text)
                                }
                                .frame(width: 38)
                                MoreLine(color: p.stage.color, title: p.name,
                                         detail: [p.client, p.location].filter { !$0.isEmpty }.joined(separator: ", "),
                                         value: p.stage.label, valueColor: p.stage.color)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Open \(p.name)")
                    }
                    MoreCount(count: shoots.count - 6)
                }
            }
        }
    }

    private func takeaway(_ shoots: [Project]) -> String? {
        guard let first = shoots.first, let date = first.shootDate else { return nil }
        if shoots.count == 1 { return "One shoot coming up: \(first.name) \(Ago.when(date))." }
        return "\(shoots.count) shoots coming up. The next is \(first.name) \(Ago.when(date))."
    }
}

// MARK: - 2. Who owes you, and for how long

private struct OwedAgingBox: View {
    @ObservedObject var money: MoneyStore
    let navigator: Navigator

    private struct Bucket: Identifiable {
        let id: Int
        let label: String
        let color: Color
        var total: Double = 0
        var count = 0
    }

    var body: some View {
        let unpaid = money.receivables.filter { $0.paidOn == nil }.sorted { $0.due < $1.due }
        let total = unpaid.reduce(0) { $0 + $1.amount }
        var buckets = [Bucket(id: 0, label: "Not due yet", color: Palette.mint),
                       Bucket(id: 1, label: "Up to 30 days late", color: Palette.gold),
                       Bucket(id: 2, label: "30 to 60 days late", color: Theme.amber),
                       Bucket(id: 3, label: "Over 60 days late", color: Theme.coral)]
        for r in unpaid {
            let late = Ago.days(from: r.due)
            let i = late <= 0 ? 0 : late <= 30 ? 1 : late <= 60 ? 2 : 3
            buckets[i].total += r.amount
            buckets[i].count += 1
        }
        let biggest = max(1, buckets.map(\.total).max() ?? 1)
        return DashCard(title: "Who owes you", color: Palette.gold, action: { navigator.open(.money) },
                        takeaway: takeaway(total: total, buckets: buckets)) {
            if unpaid.isEmpty {
                DashEmpty("Nobody owes you anything right now. Invoices you add on Money stay here until they're paid.")
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(buckets.filter { $0.count > 0 }) { b in
                        MoreBar(label: b.label, value: Money.short(b.total), fraction: b.total / biggest, color: b.color,
                                note: b.count == 1 ? "1 invoice" : "\(b.count) invoices")
                    }
                    Divider().overlay(Theme.lineSoft).padding(.vertical, 2)
                    ForEach(unpaid.prefix(3)) { r in
                        let late = Ago.days(from: r.due)
                        MoreLine(color: late > 0 ? (late > 30 ? Theme.coral : Palette.gold) : Palette.mint,
                                 title: r.client.isEmpty ? r.label : r.client,
                                 detail: late > 0 ? "\(Ago.daysText(late)) late" : "Due \(Ago.when(r.due).replacingOccurrences(of: "on ", with: ""))",
                                 value: Money.short(r.amount), valueColor: Theme.text2)
                    }
                    MoreCount(count: unpaid.count - 3)
                }
            }
        }
    }

    private func takeaway(total: Double, buckets: [Bucket]) -> String? {
        guard total > 0 else { return nil }
        let late = buckets.dropFirst().reduce(0) { $0 + $1.total }
        let over30 = buckets.dropFirst(2).reduce(0) { $0 + $1.total }
        if late == 0 { return "\(Money.short(total)) owed to you, and none of it is late." }
        if over30 > 0 { return "\(Money.short(total)) owed to you. \(Money.short(over30)) has waited over 30 days, so a friendly reminder could help." }
        return "\(Money.short(total)) owed to you. \(Money.short(late)) is a little late."
    }
}

// MARK: - 3. Your best clients this year

private struct BestClientsBox: View {
    @ObservedObject var projects: ProjectStore
    @ObservedObject var money: MoneyStore
    let navigator: Navigator

    var body: some View {
        let cal = Calendar.current
        let yearStart = cal.dateInterval(of: .year, for: Date())?.start ?? Date()
        let income = money.txns.filter { $0.date >= yearStart && $0.category.group == .income && $0.amount > 0 }
        var byClient: [String: Double] = [:]
        var unlinked = 0.0
        for t in income {
            if let p = projects.project(id: t.projectID) {
                let name = p.client.trimmingCharacters(in: .whitespaces)
                byClient[name.isEmpty ? p.name : name, default: 0] += t.amount
            } else {
                unlinked += t.amount
            }
        }
        let top = byClient.sorted { $0.value > $1.value }
        let biggest = max(1, top.first?.value ?? 1)
        return DashCard(title: "Your best clients this year", color: Palette.mint, action: { navigator.open(.money) },
                        takeaway: top.first.map { "\($0.key) brought in \(Money.short($0.value)) this year, the most of anyone." }) {
            if top.isEmpty {
                DashEmpty(unlinked > 0
                          ? "You've had \(Money.short(unlinked)) in this year. Link it to projects on Money and your best clients show up here."
                          : "Once money comes in this year and is linked to a project, your best clients show up here.")
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(top.prefix(5)), id: \.key) { name, amount in
                        MoreBar(label: name, value: Money.short(amount), fraction: amount / biggest, color: Palette.mint)
                    }
                    MoreCount(count: top.count - 5)
                    if unlinked > 0 {
                        Text("\(Money.short(unlinked)) more came in that isn't linked to a project yet.")
                            .font(Theme.font(size: 11.5)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

// MARK: - 4. Where your leads come from

private struct LeadSourcesBox: View {
    @ObservedObject var deals: DealStore
    let navigator: Navigator

    private struct Source: Identifiable {
        let id: String
        var name: String
        var leads = 0
        var booked = 0
    }

    var body: some View {
        var found: [String: Source] = [:]
        for d in deals.deals {
            let raw = d.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = raw.isEmpty ? "" : raw.lowercased()
            var s = found[key] ?? Source(id: key, name: raw.isEmpty ? "Not noted" : raw)
            s.leads += 1
            if d.stage == .won || d.projectID != nil { s.booked += 1 }
            found[key] = s
        }
        let sources = found.values.sorted { ($0.leads, $0.booked) > ($1.leads, $1.booked) }
        let total = sources.reduce(0) { $0 + $1.leads }
        let biggest = Double(max(1, sources.first?.leads ?? 1))
        return DashCard(title: "Where your leads come from", color: Palette.blue, action: { navigator.open(.projects) },
                        takeaway: takeaway(sources, total: total)) {
            if sources.isEmpty {
                DashEmpty("When a new project notes where it came from, you'll see which places bring you work.")
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(sources.prefix(5)) { s in
                        MoreBar(label: s.name, value: s.leads == 1 ? "1 lead" : "\(s.leads) leads",
                                fraction: Double(s.leads) / biggest, color: s.id.isEmpty ? Palette.slate : Palette.blue,
                                note: s.booked > 0 ? "\(s.booked) booked" : nil)
                    }
                    MoreCount(count: sources.count - 5)
                }
            }
        }
    }

    private func takeaway(_ sources: [Source], total: Int) -> String? {
        guard let top = sources.first(where: { !$0.id.isEmpty }) else {
            return total > 0 ? "Note where each deal came from in Projects and Lens will show which places work best." : nil
        }
        var line = "\(top.name) brings you the most leads, \(top.leads) of \(total)."
        if top.booked > 0 { line += top.booked == 1 ? " One of those booked." : " \(top.booked) of those booked." }
        return line
    }
}

// MARK: - 5. Your average job price

private struct AveragePriceBox: View {
    @ObservedObject var projects: ProjectStore
    @ObservedObject var deals: DealStore
    @ObservedObject var money: MoneyStore
    let navigator: Navigator

    var body: some View {
        let priced: [(date: Date, price: Double)] = projects.projects
            .filter { $0.stage != .lead }
            .compactMap { p in
                guard let price = ProjectBooks.make(p, money: money, deals: deals).price, price > 0 else { return nil }
                return (p.shootDate ?? p.createdAt, price)
            }
            .sorted { $0.date < $1.date }
        let prices = priced.map(\.price)
        let average = prices.isEmpty ? 0 : prices.reduce(0, +) / Double(prices.count)
        return DashCard(title: "Your average job price", color: Palette.rose, action: { navigator.open(.projects) },
                        takeaway: takeaway(prices)) {
            if prices.isEmpty {
                DashEmpty("Give a project a price and Lens works out your average job, and whether it's going up.")
            } else {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Money.short(average))
                            .font(Theme.font(size: 30, weight: .light)).monospacedDigit().foregroundStyle(Theme.text)
                        Text(prices.count == 1 ? "from 1 job" : "average of \(prices.count) jobs")
                            .font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 12)
                    if prices.count > 1 {
                        Sparkline(values: prices, color: Palette.rose).frame(width: 140, height: 46)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func takeaway(_ prices: [Double]) -> String? {
        guard !prices.isEmpty else { return nil }
        guard prices.count >= 4 else {
            return "From your \(prices.count == 1 ? "first priced job" : "\(prices.count) priced jobs") so far. A few more and Lens can show the trend."
        }
        let recent = prices.suffix(3), earlier = prices.dropLast(3)
        let r = recent.reduce(0, +) / 3
        let e = earlier.reduce(0, +) / Double(earlier.count)
        if r > e * 1.05 { return "Your last 3 jobs averaged \(Money.short(r)), up from \(Money.short(e)) before. Nice work." }
        if r < e * 0.95 { return "Your last 3 jobs averaged \(Money.short(r)), a little under the \(Money.short(e)) before." }
        return "Your last 3 jobs averaged \(Money.short(r)), about the same as before."
    }
}

// MARK: - 6. This year compared with last year

private struct YearOnYearBox: View {
    @ObservedObject var money: MoneyStore
    let navigator: Navigator

    private struct Point: Identifiable {
        let year: String
        let month: Date
        let total: Double
        var id: String { year + month.description }
    }

    var body: some View {
        let cal = Calendar.current
        let now = Date()
        let thisStart = cal.dateInterval(of: .year, for: now)?.start ?? now
        let lastStart = cal.date(byAdding: .year, value: -1, to: thisStart) ?? thisStart
        let sameDayLastYear = cal.date(byAdding: .year, value: -1, to: now) ?? now
        let income = money.txns.filter { $0.category.group == .income && $0.date >= lastStart }
        let thisYTD = income.filter { $0.date >= thisStart }.reduce(0) { $0 + $1.amount }
        let lastYTD = income.filter { $0.date < sameDayLastYear }.reduce(0) { $0 + $1.amount }
        let lastAll = income.filter { $0.date < thisStart }.reduce(0) { $0 + $1.amount }
        let currentMonth = cal.component(.month, from: now)

        // Running totals by month, both drawn on this year's months so they line up.
        var points: [Point] = []
        var runThis = 0.0, runLast = 0.0
        for m in 0..<12 {
            guard let month = cal.date(byAdding: .month, value: m, to: thisStart),
                  let next = cal.date(byAdding: .month, value: 1, to: month),
                  let lastMonth = cal.date(byAdding: .year, value: -1, to: month),
                  let lastNext = cal.date(byAdding: .year, value: -1, to: next) else { continue }
            if lastAll > 0 {
                runLast += income.filter { $0.date >= lastMonth && $0.date < lastNext }.reduce(0) { $0 + $1.amount }
                points.append(Point(year: "Last year", month: month, total: runLast))
            }
            if m < currentMonth {
                runThis += income.filter { $0.date >= month && $0.date < next }.reduce(0) { $0 + $1.amount }
                points.append(Point(year: "This year", month: month, total: runThis))
            }
        }

        return DashCard(title: "This year and last year", color: Palette.lime, action: { navigator.open(.money) },
                        takeaway: takeaway(thisYTD: thisYTD, lastYTD: lastYTD, lastAll: lastAll)) {
            if thisYTD <= 0 && lastAll <= 0 {
                DashEmpty("Bring in your bank statements on Money, last year's too, and you'll see the two years side by side.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Chart(points) { p in
                        LineMark(x: .value("Month", p.month, unit: .month), y: .value("Money in", p.total),
                                 series: .value("Year", p.year))
                            .foregroundStyle(p.year == "This year" ? Palette.lime : Theme.muted.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: p.year == "This year" ? 2.4 : 1.6, lineCap: .round,
                                                   dash: p.year == "This year" ? [] : [4, 3]))
                            .interpolationMethod(.monotone)
                    }
                    .chartYAxis(.hidden)
                    .chartLegend(.hidden)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .month, count: 2)) { _ in
                            AxisValueLabel(format: .dateTime.month(.abbreviated)).foregroundStyle(Theme.muted)
                        }
                    }
                    .frame(height: 130)
                    HStack(spacing: 14) {
                        legend("This year", Palette.lime)
                        if lastAll > 0 { legend("Last year", Theme.muted.opacity(0.6)) }
                    }
                }
            }
        }
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 14, height: 3)
            Text(text).font(Theme.font(size: 11.5)).foregroundStyle(Theme.muted)
        }
    }

    private func takeaway(thisYTD: Double, lastYTD: Double, lastAll: Double) -> String? {
        guard thisYTD > 0 || lastAll > 0 else { return nil }
        let now = Money.short(max(0, thisYTD))
        if lastAll <= 0 { return "\(now) in so far this year. Bring in last year's statements on Money to compare." }
        if thisYTD >= lastYTD { return "\(now) in so far this year, \(Money.short(thisYTD - lastYTD)) ahead of this time last year." }
        return "\(now) in so far this year. This time last year it was \(Money.short(lastYTD))."
    }
}

// MARK: - 7. What you really earn per hour

private struct PerHourBox: View {
    @ObservedObject var projects: ProjectStore
    @ObservedObject var deals: DealStore
    @ObservedObject var money: MoneyStore
    let navigator: Navigator

    private struct Row: Identifiable {
        let id: UUID
        let name: String
        let rate: Double
        let hours: Double
        let kept: Double
    }

    var body: some View {
        let rows: [Row] = projects.projects.compactMap { p in
            let b = ProjectBooks.make(p, money: money, deals: deals)
            guard let rate = b.perHour, let price = b.price else { return nil }
            return Row(id: p.id, name: p.name, rate: rate, hours: b.hours, kept: price - b.spent)
        }
        .sorted { $0.rate > $1.rate }
        let hours = rows.reduce(0) { $0 + $1.hours }
        let overall = hours > 0 ? rows.reduce(0) { $0 + $1.kept } / hours : 0
        let biggest = max(1, rows.map(\.rate).max() ?? 1)
        return DashCard(title: "What you really earn per hour", color: Palette.orchid, action: { navigator.open(.projects) },
                        takeaway: takeaway(rows, overall: overall)) {
            if rows.isEmpty {
                DashEmpty("Give a job a price and log your hours on it, and you'll see what each hour really paid you.")
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(rows.prefix(5)) { r in
                        Button { navigator.openProject(r.id) } label: {
                            MoreBar(label: r.name, value: "\(signedShort(r.rate)) an hour", fraction: r.rate / biggest,
                                    color: r.rate < 0 ? Theme.coral : Palette.orchid, note: "\(Hours.short(r.hours)) logged")
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open \(r.name)")
                    }
                    MoreCount(count: rows.count - 5)
                }
            }
        }
    }

    private func takeaway(_ rows: [Row], overall: Double) -> String? {
        guard let top = rows.first else { return nil }
        if rows.count == 1 { return "On \(top.name) you've kept about \(signedShort(top.rate)) an hour so far, after costs." }
        return "Across these jobs you keep about \(signedShort(overall)) an hour, after costs. \(top.name) paid best."
    }
}

// MARK: - 8. Quotes waiting for an answer

private struct QuotesWaitingBox: View {
    @ObservedObject var deals: DealStore
    let navigator: Navigator

    var body: some View {
        let waiting = deals.deals.filter { $0.stage == .proposalOut || $0.stage == .talking }
            .map { (deal: $0, days: Ago.days(from: sent($0))) }
            .sorted { $0.days > $1.days }
        let worth = waiting.compactMap { deals.value(of: $0.deal) }.reduce(0, +)
        return DashCard(title: "Quotes waiting for an answer", color: Palette.violet, action: { navigator.open(.projects) },
                        takeaway: takeaway(waiting.map(\.days), worth: worth, anyQuiet: waiting.contains { $0.deal.isStale })) {
            if waiting.isEmpty {
                DashEmpty("No quotes waiting right now. When you send one from Projects, it waits here until they answer.")
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(waiting.prefix(5), id: \.deal.id) { w in
                        Button { navigator.openDeal(w.deal.id) } label: {
                            MoreLine(color: w.deal.isStale ? Theme.amber : Palette.violet, title: w.deal.title,
                                     detail: "\(deals.valueText(of: w.deal)) · " + (w.days == 0 ? "sent today" : "sent \(Ago.daysText(w.days)) ago"),
                                     value: w.days == 0 ? "today" : Ago.daysText(w.days),
                                     valueColor: w.deal.isStale ? Theme.amber : Theme.text3)
                        }
                        .buttonStyle(.plain)
                        .help("Open \(w.deal.title)")
                    }
                    MoreCount(count: waiting.count - 5)
                }
            }
        }
    }

    /// When the quote went out: the latest "Quote sent" or "Proposal sent" line, or failing that the last touch.
    private func sent(_ deal: Deal) -> Date {
        deal.events.last { e in
            let t = e.text.lowercased()
            return t.hasPrefix("quote sent") || t.hasPrefix("proposal sent")
        }?.date ?? deal.lastTouch
    }

    private func takeaway(_ days: [Int], worth: Double, anyQuiet: Bool) -> String? {
        guard let oldest = days.max() else { return nil }
        let nudge = anyQuiet ? " A friendly nudge might help." : ""
        if days.count == 1 {
            return (oldest == 0 ? "One quote out, sent today." : "One quote out, waiting \(Ago.daysText(oldest)) for an answer.") + nudge
        }
        let value = worth > 0 ? ", worth \(Money.short(worth))" : ""
        return "\(days.count) quotes out\(value). The oldest has waited \(Ago.daysText(oldest))." + nudge
    }
}

// MARK: - 9. Your busiest months

private struct BusyMonthsBox: View {
    @ObservedObject var projects: ProjectStore
    let navigator: Navigator

    private struct Month: Identifiable {
        let id: Int
        let name: String
        let count: Int
    }

    var body: some View {
        let cal = Calendar.current
        let names = cal.shortMonthSymbols
        var counts = Array(repeating: 0, count: 12)
        for p in projects.projects where p.stage != .lead {
            if let date = p.shootDate { counts[cal.component(.month, from: date) - 1] += 1 }
        }
        let months = (0..<12).map { Month(id: $0, name: names.indices.contains($0) ? names[$0] : "\($0 + 1)", count: counts[$0]) }
        let most = counts.max() ?? 0
        return DashCard(title: "Your busiest months", color: Palette.sand, action: { navigator.open(.projects) },
                        takeaway: takeaway(months, most: most)) {
            if most == 0 {
                DashEmpty("Once your projects have shoot dates, you'll see which months are busiest. Handy for planning time off.")
            } else {
                Chart(months) { m in
                    BarMark(x: .value("Month", m.name), y: .value("Shoots", m.count))
                        .foregroundStyle(m.count == most ? Palette.sand : Palette.sand.opacity(0.35))
                        .cornerRadius(4)
                        .annotation(position: .top, spacing: 3) {
                            if m.count > 0 {
                                Text("\(m.count)").font(Theme.font(size: 10, weight: m.count == most ? .bold : .regular))
                                    .monospacedDigit().foregroundStyle(m.count == most ? Theme.text : Theme.muted)
                            }
                        }
                }
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks { _ in AxisValueLabel().foregroundStyle(Theme.muted) }
                }
                .frame(height: 140)
            }
        }
    }

    private func takeaway(_ months: [Month], most: Int) -> String? {
        let total = months.reduce(0) { $0 + $1.count }
        guard total > 0 else { return nil }
        let top = months.filter { $0.count == most }
        let full = Calendar.current.monthSymbols
        let name: (Month) -> String = { full.indices.contains($0.id) ? full[$0.id] : $0.name }
        if most > 1 && top.count == 1 { return "\(name(top[0])) is your busiest month, with \(most) shoots." }
        if most > 1 && top.count == 2 { return "\(name(top[0])) and \(name(top[1])) are your busiest months, with \(most) shoots each." }
        return total == 1 ? "One shoot so far. As more go in, your busy months will show." : "\(total) shoots, spread across the year so far."
    }
}

// MARK: - 10. Footage not filed to a project yet

private struct UnfiledFootageBox: View {
    @ObservedObject var projects: ProjectStore
    let navigator: Navigator
    @ObservedObject private var index = LibraryIndex.shared
    @ObservedObject private var links = LibraryLinks.shared
    @ObservedObject private var catalog = DriveCatalog.shared

    var body: some View {
        // The Photos app and websites hold everyday pictures, not shoots, so they're left out here.
        let skip = Set(catalog.drives.filter { $0.isPhotos || $0.isWebsite }.map(\.id))
        let hasDrives = catalog.drives.contains { !$0.isPhotos && !$0.isWebsite }
        let shelf = index.shelf(projects: projects.projects, links: links, catalog: catalog)
        let loose = shelf.unsorted
            .compactMap { index.folders.indices.contains($0) ? index.folders[$0] : nil }
            .filter { !$0.isPhotosDay && !skip.contains($0.driveID) }
            .sorted { $0.last > $1.last }
        let bytes = loose.reduce(Int64(0)) { $0 + $1.bytes }
        DashCard(title: "Footage not filed yet", color: Theme.amber, action: { navigator.open(.footage) },
                 takeaway: loose.isEmpty ? nil
                    : "\(loose.count == 1 ? "One folder isn't" : "\(loose.count) folders aren't") part of a shoot yet, \(ByteFormat.string(bytes)) in all. Filing them keeps each shoot together.") {
            if !hasDrives {
                DashEmpty("Add a drive in Library and Lens will point out footage that isn't filed to a shoot yet.")
            } else if loose.isEmpty {
                DashEmpty(index.loading || index.folders.isEmpty ? "Looking through your drives…" : "Everything on your drives is filed to a shoot. Nice and tidy.")
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(loose.prefix(5)) { f in
                        Button {
                            navigator.footageRoute = .folder(driveID: f.driveID, path: f.folder)
                            navigator.open(.footage)
                        } label: {
                            MoreLine(color: Theme.amber, title: f.name, detail: detail(f), value: ByteFormat.string(f.bytes))
                        }
                        .buttonStyle(.plain)
                        .help("Open this folder in Library")
                    }
                    MoreCount(count: loose.count - 5)
                }
            }
        }
        .onAppear { index.start() }
    }

    private func detail(_ f: LibraryFolder) -> String {
        var parts: [String] = []
        if f.videos > 0 { parts.append(f.videos == 1 ? "1 video" : "\(f.videos) videos") }
        if f.photos > 0 { parts.append(f.photos == 1 ? "1 photo" : "\(f.photos) photos") }
        if let drive = catalog.drives.first(where: { $0.id == f.driveID }) { parts.append("on \(drive.name)") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - 11. Drive space

private struct DriveSpaceBox: View {
    let navigator: Navigator
    @ObservedObject private var catalog = DriveCatalog.shared

    var body: some View {
        let drives = ([catalog.mac].compactMap { $0 } + catalog.outside).filter { $0.total > 0 }
        let fullest = drives.max { $0.fractionUsed < $1.fractionUsed }
        DashCard(title: "Drive space", color: Palette.slate, action: { navigator.open(.footage) },
                 takeaway: fullest.map(takeaway)) {
            if drives.isEmpty {
                DashEmpty("Add a drive in Library and you'll see how full each one is here.")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(drives.prefix(5)) { d in
                        MoreBar(label: d.name, value: "\(ByteFormat.string(d.free)) free of \(ByteFormat.string(d.total))",
                                fraction: d.fractionUsed, color: color(d.fractionUsed),
                                note: catalog.isPlugged(d) ? nil : "not plugged in")
                    }
                    MoreCount(count: drives.count - 5)
                }
            }
        }
    }

    private func color(_ used: Double) -> Color {
        used >= 0.9 ? Theme.coral : used >= 0.75 ? Theme.amber : Theme.teal
    }

    private func takeaway(_ d: CatalogDrive) -> String {
        let pct = Int((d.fractionUsed * 100).rounded())
        if d.fractionUsed >= 0.85 { return "\(d.name) is \(pct)% full. Library can show you what's safe to clear." }
        return "All your drives have room to spare. The fullest, \(d.name), is \(pct)% full."
    }
}

// MARK: - 12. This month's goal

/// A number field and Save for the monthly goal. The goal box is its home; the goal tile on Today
/// opens the same field when there's no goal yet.
struct GoalSetter: View {
    @ObservedObject var money: MoneyStore
    var onDone: () -> Void = {}
    @State private var text = ""
    @FocusState private var focused: Bool

    private var amount: Double? { MoneyStore.parseAmount(text).flatMap { $0 > 0 ? $0 : nil } }

    var body: some View {
        HStack(spacing: 8) {
            Text("$").font(Theme.font(size: 14, weight: .semibold)).foregroundStyle(Theme.text3)
            TextField("5000", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .focused($focused)
                .onSubmit(save)
            Button("Save", action: save)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(amount == nil)
                .opacity(amount == nil ? 0.5 : 1)
        }
        .onAppear {
            if let goal = money.monthlyGoal { text = String(Int(goal)) }
        }
    }

    private func save() {
        guard let amount else { return }
        money.setMonthlyGoal(amount)
        onDone()
    }
}

private struct MonthGoalBox: View {
    @ObservedObject var money: MoneyStore
    let navigator: Navigator
    @State private var changing = false

    var body: some View {
        let m = MonthPace(money: money)
        let editing = m.goal == nil || changing
        let open: (() -> Void)? = editing ? nil : { navigator.open(.money) }
        DashCard(title: "This month's goal", color: Palette.lime, action: open, takeaway: takeaway(m)) {
            if let goal = m.goal, !changing {
                HStack(alignment: .center, spacing: 22) {
                    GoalRing(now: max(0, m.kept), best: goal, caption: "of goal",
                             footer: m.reached ? "Goal reached" : "\(Money.short(m.left)) to go")
                        .frame(width: 130)
                    VStack(alignment: .leading, spacing: 12) {
                        line("Kept so far", signedShort(m.kept))
                        line("On pace for", m.ready ? Money.short(m.pace) : "Early days",
                             note: m.ready ? "if the month carries on like this" : "shows from the 5th")
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            line("Your goal", Money.short(goal))
                            Button("Change goal") { changing = true }
                                .buttonStyle(.plain)
                                .font(Theme.font(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.teal)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            } else if m.goal != nil {
                VStack(alignment: .leading, spacing: 12) {
                    Text("What would you like to keep each month, after costs?")
                        .font(Theme.font(size: 13)).foregroundStyle(Theme.text2)
                    GoalSetter(money: money) { changing = false }
                    HStack(spacing: 16) {
                        Button("Keep it as it was") { changing = false }
                        Button("Take the goal away") {
                            money.setMonthlyGoal(nil)
                            changing = false
                        }
                    }
                    .buttonStyle(.plain)
                    .font(Theme.font(size: 12))
                    .foregroundStyle(Theme.muted)
                }
                .padding(.vertical, 4)
            } else {
                VStack(spacing: 12) {
                    Text("Pick an amount you'd like to keep each month, after costs. Lens will show how the month is going and what's left to reach it.")
                        .font(Theme.font(size: 13)).foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    GoalSetter(money: money)
                }
                .frame(maxWidth: .infinity, minHeight: 90)
            }
        }
    }

    private func line(_ label: String, _ value: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(Theme.font(size: 10, weight: .bold)).tracking(0.7).foregroundStyle(Theme.muted)
            Text(value)
                .font(Theme.font(size: 17, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text)
                .lineLimit(1).minimumScaleFactor(0.7)
            if let note {
                Text(note).font(Theme.font(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
        }
    }

    private func takeaway(_ m: MonthPace) -> String? {
        guard let goal = m.goal else {
            return m.kept > 0 ? "You've kept \(Money.short(m.kept)) so far this month." : nil
        }
        if changing { return nil }
        let g = Money.short(goal)
        if m.reached { return "You've reached this month's \(g) goal. Well done." }
        if !m.ready {
            return m.kept > 0 ? "Early days. You've kept \(Money.short(m.kept)) toward your \(g) goal."
                              : "A fresh month. Your goal is to keep \(g)."
        }
        if m.pace >= goal { return "You're on pace to reach your \(g) goal. \(Money.short(m.left)) to go." }
        return "\(Money.short(m.left)) more this month and you'll reach your \(g) goal."
    }
}

// MARK: - 13. This week's checklist

private struct WeekChecklistBox: View {
    @ObservedObject var projects: ProjectStore
    @ObservedObject var deals: DealStore
    @ObservedObject var money: MoneyStore
    let navigator: Navigator
    @ObservedObject private var index = LibraryIndex.shared
    @ObservedObject private var links = LibraryLinks.shared
    @ObservedObject private var catalog = DriveCatalog.shared

    private struct Check: Identifiable {
        let id: String
        let done: Bool
        let text: String
        var fix: String? = nil
        var go: (() -> Void)? = nil
    }

    var body: some View {
        let checks = self.checks
        let done = checks.filter(\.done).count
        DashCard(title: "This week's checklist", color: Palette.mint, takeaway: checks.isEmpty ? nil : takeaway(done, of: checks.count)) {
            if checks.isEmpty {
                DashEmpty("Once you have a few deals and jobs in Lens, a short checklist for the week shows up here.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 4) {
                        ForEach(checks) { c in
                            Capsule().fill(c.done ? Palette.mint : Theme.track.opacity(0.5)).frame(height: 5)
                        }
                    }
                    ForEach(checks) { c in row(c) }
                }
            }
        }
        .onAppear { index.start() }
    }

    private func row(_ c: Check) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: c.done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(c.done ? Palette.mint : Theme.muted)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.text)
                    .font(Theme.font(size: 13, weight: c.done ? .regular : .medium))
                    .foregroundStyle(c.done ? Theme.text3 : Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if !c.done, let fix = c.fix, let go = c.go {
                    Button(action: go) {
                        HStack(spacing: 4) {
                            Text(fix)
                            Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold))
                        }
                        .font(Theme.font(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.teal)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func takeaway(_ done: Int, of total: Int) -> String {
        if done == total { return total == 1 ? "All done. A great week." : "All \(total) done. A great week." }
        if done == 0 { return "A few small jobs this week. Each one below says what to do." }
        if total - done == 1 { return "\(done) of \(total) done. Nice week, just one left." }
        return "\(done) of \(total) done. Nice week so far."
    }

    private var checks: [Check] {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        var list: [Check] = []
        guard !deals.deals.isEmpty || !projects.projects.isEmpty else { return [] }

        // New inquiries answered within 2 days.
        let inquiries = deals.open.filter { $0.stage == .inquiry }
        let slow = inquiries.filter { $0.daysSinceTouch() >= 2 }.sorted { $0.daysSinceTouch() > $1.daysSinceTouch() }
        if let first = slow.first {
            list.append(Check(id: "inquiries", done: false,
                              text: slow.count == 1 ? "\(first.title) has waited \(Ago.daysText(first.daysSinceTouch())) for a reply."
                                                    : "\(slow.count) new inquiries are waiting on a reply.",
                              fix: slow.count == 1 ? "Reply to them" : "Open Projects",
                              go: slow.count == 1 ? { navigator.openDeal(first.id) } : { navigator.open(.projects) }))
        } else {
            list.append(Check(id: "inquiries", done: true,
                              text: inquiries.isEmpty ? "No new inquiries waiting on a reply." : "Every new inquiry got an answer within 2 days."))
        }

        // Quotes followed up within a week.
        let quotes = deals.open.filter { $0.stage == .proposalOut || $0.stage == .talking }
        let quiet = quotes.filter { $0.daysSinceTouch() >= 7 }.sorted { $0.daysSinceTouch() > $1.daysSinceTouch() }
        if let first = quiet.first {
            list.append(Check(id: "quotes", done: false,
                              text: quiet.count == 1 ? "\(first.title) hasn't heard from you in \(Ago.daysText(first.daysSinceTouch())). A quick check-in could help."
                                                     : "\(quiet.count) quotes have gone a week without a follow-up. A quick check-in could help.",
                              fix: quiet.count == 1 ? "Open the project" : "Open Projects",
                              go: quiet.count == 1 ? { navigator.openDeal(first.id) } : { navigator.open(.projects) }))
        } else {
            list.append(Check(id: "quotes", done: true,
                              text: quotes.isEmpty ? "No quotes waiting on a follow-up." : "Every quote out has been followed up within a week."))
        }

        // Invoices: only once she has invoices in Lens (they come in from FreshBooks).
        if !money.receivables.isEmpty {
            let delivered = projects.active.filter { $0.stage == .delivered }
            let missing = delivered.filter { !hasInvoice($0) }
            if let first = missing.first {
                list.append(Check(id: "invoices", done: false,
                                  text: missing.count == 1 ? "\(first.name) is delivered but doesn't have an invoice yet."
                                                           : "\(missing.count) delivered jobs don't have an invoice yet.",
                                  fix: missing.count == 1 ? "Open the project" : "Open Projects",
                                  go: missing.count == 1 ? { navigator.openProject(first.id) } : { navigator.open(.projects) }))
            } else {
                list.append(Check(id: "invoices", done: true,
                                  text: delivered.isEmpty ? "No delivered jobs waiting on an invoice." : "Every delivered job has an invoice out."))
            }

            let late = money.receivables.filter { $0.paidOn == nil && $0.due < today }.sorted { $0.due < $1.due }
            if let first = late.first {
                let who = first.client.isEmpty ? first.label : first.client
                list.append(Check(id: "overdue", done: false,
                                  text: late.count == 1 ? "\(who)'s \(Money.short(first.amount)) is \(Ago.daysText(Ago.days(from: first.due))) late. A friendly reminder could help."
                                                        : "\(late.count) payments are late, \(Money.short(late.reduce(0) { $0 + $1.amount })) in all. A friendly reminder could help.",
                                  fix: late.count == 1 && first.projectID != nil ? "Open the project" : "Open Money",
                                  go: late.count == 1 && first.projectID != nil ? { navigator.openProject(first.projectID!) } : { navigator.open(.money) }))
            } else {
                list.append(Check(id: "overdue", done: true, text: "Nobody is late paying you."))
            }
        }

        // Hours: only if she tracks her time.
        let all = projects.projects
        if all.contains(where: { !$0.times.isEmpty || $0.timerStartedAt != nil }) {
            let week = cal.dateInterval(of: .weekOfYear, for: now)
            let start = week?.start ?? today
            let end = week?.end ?? now
            let hours = all.flatMap(\.times).filter { $0.date >= start && $0.date < end }.reduce(0) { $0 + $1.hours }
                + all.compactMap(\.timerStartedAt).reduce(0) { $0 + now.timeIntervalSince(max($1, start)) / 3600 }
            list.append(hours > 0.05
                        ? Check(id: "hours", done: true, text: "You've logged \(Hours.short(hours)) this week.")
                        : Check(id: "hours", done: false, text: "No hours logged yet this week. Start a timer on a job when you work on it.",
                                fix: "Open Projects", go: { navigator.open(.projects) }))
        }

        // New footage filed to a shoot: only with drives added and looked through.
        let skip = Set(catalog.drives.filter { $0.isPhotos || $0.isWebsite }.map(\.id))
        let hasDrives = catalog.drives.contains { !$0.isPhotos && !$0.isWebsite }
        if hasDrives && !index.folders.isEmpty {
            let since = cal.date(byAdding: .day, value: -14, to: today) ?? today
            let shelf = index.shelf(projects: all, links: links, catalog: catalog)
            let loose = shelf.unsorted
                .compactMap { index.folders.indices.contains($0) ? index.folders[$0] : nil }
                .filter { !$0.isPhotosDay && !skip.contains($0.driveID) && $0.last >= since }
            list.append(loose.isEmpty
                        ? Check(id: "footage", done: true, text: "New footage from the last two weeks is all filed to a shoot.")
                        : Check(id: "footage", done: false,
                                text: loose.count == 1 ? "One new folder of footage isn't filed to a shoot yet."
                                                       : "\(loose.count) new folders of footage aren't filed to a shoot yet.",
                                fix: "Open Library", go: { navigator.open(.footage) }))
        }
        return list
    }

    /// An invoice on the project, or one for the same client that's still open or came after the shoot.
    private func hasInvoice(_ p: Project) -> Bool {
        let client = p.client.trimmingCharacters(in: .whitespaces).lowercased()
        let since = p.shootDate ?? p.createdAt
        return money.receivables.contains { r in
            if r.projectID == p.id { return true }
            guard r.projectID == nil, !client.isEmpty,
                  r.client.trimmingCharacters(in: .whitespaces).lowercased() == client else { return false }
            return r.paidOn == nil || r.due >= since
        }
    }
}

/// The "Goal so far" number on Today. With no goal yet, clicking it opens the same goal field as the box.
struct GoalTile: View {
    @ObservedObject var money: MoneyStore
    let navigator: Navigator
    @State private var setting = false

    var body: some View {
        let m = MonthPace(money: money)
        if let goal = m.goal {
            StatTile(label: "Goal so far", value: "\(Int((m.fraction * 100).rounded()))%",
                     note: m.reached ? "Reached your \(Money.short(goal)) goal" : "\(Money.short(max(0, m.kept))) of \(Money.short(goal))",
                     color: Palette.lime, noteColor: m.reached ? Palette.lime : Theme.text3) { navigator.open(.money) }
        } else {
            StatTile(label: "Goal so far", value: "No goal yet", note: "Click to set a monthly goal",
                     color: Palette.lime) { setting = true }
                .popover(isPresented: $setting, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("What would you like to keep each month, after costs?")
                            .font(Theme.font(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                        GoalSetter(money: money) { setting = false }
                    }
                    .padding(16)
                    .frame(width: 320, alignment: .leading)
                }
        }
    }
}
