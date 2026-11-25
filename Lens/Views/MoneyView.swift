import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Money, laid out like the Profit tab in List That Shit, Yo!: the three statements side by
/// side for any period, the numbers that matter in coloured groups, what's coming in, and
/// every transaction (sortable in one click, and Lens learns from each correction).
struct MoneyView: View {
    @EnvironmentObject private var money: MoneyStore
    @EnvironmentObject private var deals: DealStore
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var appearance: Appearance

    /// The books' tab: day, week, month or year. `back` steps to earlier ones (0 is the current one).
    @AppStorage("money.span") private var spanRaw = BooksSpan.month.rawValue
    @State private var back = 0
    @State private var onlyUnsorted = false
    @State private var toast: String?
    @State private var importURL: URL?
    /// Which groups in the books are open. Closed by default so only the main numbers show.
    @AppStorage("moneyOpenGroups") private var openGroupsRaw = ""

    private var span: BooksSpan { BooksSpan(rawValue: spanRaw) ?? .month }
    private var range: MoneyStore.Span { span.range(back: back) }
    private var rangeTitle: String { span.title(back: back) }

    var body: some View {
        if appearance.simple { simpleMoney } else { everything }
    }

    private var everything: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                ArrangeablePage("money", columns: true, spacing: 20, boxes: everythingBoxes)
            }
            .padding(36)
            .frame(maxWidth: 1240, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast).font(Theme.font(size: 13, weight: .semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Theme.raised).clipShape(Capsule())
                    .overlay(Capsule().stroke(Theme.line))
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: Binding(get: { importURL.map(ImportTarget.init) }, set: { importURL = $0?.url })) { target in
            ImportSheet(url: target.url) { message in show(message) }
        }
    }

    /// The Everything boxes in their usual order; she can rearrange, resize or hide them.
    private var everythingBoxes: [PageBox] {
        var boxes: [PageBox] = []
        if money.unsortedCount > 0 {
            boxes.append(PageBox("unsorted", "Things to sort", color: Theme.amber) { unsortedBanner })
        }
        boxes += [
            PageBox("books", "The books", color: Palette.violet) { books },
            PageBox("numbers", "The numbers that matter", color: Palette.lime) { numbers },
            PageBox("comingIn", "Coming in", color: Theme.amber, half: true) { comingIn },
            PageBox("accounts", "Accounts", color: Palette.mint, half: true) { accounts },
            PageBox("transactions", "All transactions", color: Palette.blue) { transactions },
        ]
        return boxes
    }

    // MARK: Simple

    /// Simple's boxes in their usual order; she can rearrange or hide them.
    private var simpleBoxes: [PageBox] {
        let inc = money.income(.thisMonth)
        let cameIn = inc.totalRevenue
        let unpaid = money.receivables.filter { $0.paidOn == nil }.sorted { $0.due < $1.due }
        let owed = unpaid.reduce(0) { $0 + $1.amount }
        let hasMonthActivity = !money.txns(in: .thisMonth).isEmpty
        let hasBank = !money.data.openings.isEmpty
        let bank = money.balance(.thisMonth).totalCash
        let sortCount = money.unsortedCount
        var boxes: [PageBox] = []
        boxes.append(PageBox("cameIn", "Came in this month", color: Palette.lime) {
        simplePanel("Came in this month") {
            HeadlineNumber(text: dollars(cameIn), size: 44)
            if let usual = usualMonth {
                let ratio = cameIn / usual
                Text(ratio > 1.15 ? "A bit more than usual" : ratio < 0.85 ? "A bit less than usual so far" : "About usual")
                    .font(Theme.font(size: 15)).foregroundStyle(Theme.text2)
            }
        }
        })
        boxes.append(PageBox("owed", "Waiting to be paid", color: Theme.amber) {
        simplePanel("Waiting to be paid") {
            HeadlineNumber(text: dollars(owed), size: 44)
            if unpaid.isEmpty {
                Text("Nobody owes you anything right now.")
                    .font(Theme.font(size: 15)).foregroundStyle(Theme.text2)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(unpaid.prefix(3))) { r in
                        let (when, late) = dueText(r)
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.client.isEmpty ? r.label : r.client)
                                    .font(Theme.font(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                                Text("\(dollars(r.amount)), \(when)")
                                    .font(Theme.font(size: 14))
                                    .foregroundStyle(late ? Theme.coral : Theme.muted)
                            }
                            Spacer()
                            if late {
                                Button("See it") {
                                    if let id = r.projectID { navigator.openProject(id) }
                                    else { Appearance.shared.detail = .everything }
                                }
                                .buttonStyle(SecondaryButtonStyle())
                            }
                        }
                    }
                    if unpaid.count > 3 {
                        Text("and \(unpaid.count - 3) more")
                            .font(Theme.font(size: 14)).foregroundStyle(Theme.muted)
                    }
                }
                .padding(.top, 4)
            }
        }
        })
        if hasMonthActivity {
            boxes.append(PageBox("kept", "What you kept", color: Palette.violet) {
                    simplePanel("What you kept") {
                        HeadlineNumber(text: dollars(inc.net), size: 44)
                        Text(inc.net >= 0 ? "After costs you kept \(dollars(inc.net)) this month."
                                          : "Costs ran \(dollars(-inc.net)) more than came in this month.")
                            .font(Theme.font(size: 15)).foregroundStyle(Theme.text2)
                    }
            })
        }
        if hasBank {
            boxes.append(PageBox("bank", "In the bank", color: Palette.blue) {
                    simplePanel("In the bank") {
                        HeadlineNumber(text: dollars(bank), size: 44)
                        Text("Across your accounts and cash on hand.")
                            .font(Theme.font(size: 15)).foregroundStyle(Theme.text2)
                    }
            })
        }
        if sortCount > 0 {
            boxes.append(PageBox("unsorted", "Things to sort", color: Theme.amber) {
                    HStack(spacing: 12) {
                        Image(systemName: "tray.full").foregroundStyle(Theme.amber)
                        Text("\(sortCount) to sort when you have a minute")
                            .font(Theme.font(size: 15)).foregroundStyle(Theme.text2)
                        Spacer()
                        Button("Sort them") {
                            onlyUnsorted = true
                            Appearance.shared.detail = .everything
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    .panel(padding: 16)
            })
        }
        return boxes
    }

    private func dollars(_ v: Double) -> String {
        (v < 0 ? "-" : "") + abs(v).formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }

    /// Money received in the three calendar months before this one, averaged. Nil when there's no history.
    private var usualMonth: Double? {
        let cal = Calendar.current
        let thisStart = MoneyStore.Period.thisMonth.range().start
        guard let from = cal.date(byAdding: .month, value: -3, to: thisStart) else { return nil }
        let past = money.txns.filter { $0.category.group == .income && $0.date >= from && $0.date < thisStart }
        guard !past.isEmpty else { return nil }
        let avg = past.reduce(0) { $0 + $1.amount } / 3
        return avg > 0 ? avg : nil
    }

    private func dueText(_ r: Receivable) -> (String, Bool) {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: r.due), to: cal.startOfDay(for: Date())).day ?? 0
        if days > 0 { return ("\(days) day\(days == 1 ? "" : "s") late", true) }
        return ("due \(r.due.formatted(.dateTime.month(.abbreviated).day()))", false)
    }

    private func simplePanel<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.font(size: 13, weight: .bold)).tracking(0.8).textCase(.uppercase)
                .foregroundStyle(Theme.muted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 24)
    }

    private var simpleMoney: some View {
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Money").font(Theme.display(size: 34)).foregroundStyle(Theme.text)
                    Text("A quick look at how this month is going.")
                        .font(Theme.font(size: 15)).foregroundStyle(Theme.muted)
                }

                ArrangeablePage("money", spacing: 22, boxes: simpleBoxes)

                HStack(spacing: 0) {
                    Text("Statements, charts and every transaction are in ")
                    Button { Appearance.shared.detail = .everything } label: {
                        Text("Everything").underline().foregroundStyle(Palette.violet)
                    }
                    .buttonStyle(.plain)
                    Text(".")
                }
                .font(Theme.font(size: 14)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 48)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
    }

    private func show(_ message: String) {
        withAnimation { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withAnimation { if toast == message { toast = nil } } }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Money").font(Theme.font(size: 30, weight: .bold)).foregroundStyle(Theme.text)
                Text(subtitle).font(Theme.font(size: 14)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Menu {
                Button("Bank + credit card") { navigator.bankLogin = .bank }
                Button("Venmo") { navigator.bankLogin = .venmo }
                Button("PayPal") { navigator.bankLogin = .paypal }
                Divider()
                Button("Import a file I already downloaded…") { pickStatement() }
            } label: {
                Text("Update from bank")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Theme.raised).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
        }
    }

    private var subtitle: String {
        let i = money.income(range)
        if i.totalRevenue == 0 && money.txns.isEmpty { return "Tap Update from bank to bring in your transactions and start the books." }
        return i.net >= 0 ? "\(rangeTitle): you kept \(Money.string(i.net)) of the \(Money.string(i.totalRevenue)) that came in."
                          : "\(rangeTitle): you spent \(Money.string(-i.net)) more than came in."
    }

    private var unsortedBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.full").foregroundStyle(Theme.amber)
            Text("\(money.unsortedCount) transaction\(money.unsortedCount == 1 ? "" : "s") need\(money.unsortedCount == 1 ? "s" : "") sorting. Pick a category once and Lens sorts the rest like it.")
                .font(Theme.font(size: 13)).foregroundStyle(Theme.text2)
            Spacer()
            Button(onlyUnsorted ? "Show all" : "Sort them") { onlyUnsorted.toggle() }.buttonStyle(SecondaryButtonStyle())
        }
        .panel(padding: 14)
        .accentBar(Theme.amber)
    }

    // MARK: The books

    /// Day, Week, Month, Year, with arrows to step back and forward and the dates showing.
    private var spanTabs: some View {
        HStack(spacing: 10) {
            Picker("", selection: Binding(get: { spanRaw }, set: { spanRaw = $0; back = 0 })) {
                ForEach(BooksSpan.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 240)
            Button { back += 1 } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).help("Earlier")
            Text(rangeTitle).font(Theme.font(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                .monospacedDigit().lineLimit(1).fixedSize().frame(minWidth: 130)
            Button { back -= 1 } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless).help("Later").disabled(back == 0)
            if back > 0 {
                Button { back = 0 } label: {
                    Text("Back to now").font(Theme.font(size: 12, weight: .semibold)).foregroundStyle(Theme.teal)
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
                .fixedSize()
            }
        }
    }

    private var books: some View {
        let inc = money.income(range), cash = money.cashFlow(range), bal = money.balance(range)
        let rev = inc.totalRevenue
        func pct(_ v: Double) -> String? { rev > 0 ? "\(Int((100 * v / rev).rounded()))%" : nil }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                ColorLabel("The books", Palette.lime)
                Spacer()
                spanTabs
                Button(openGroups.isEmpty ? "Show every line" : "Main numbers only") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        openGroupsRaw = openGroups.isEmpty ? Self.allGroups.joined(separator: ",") : ""
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    incomeColumn(inc, pct: pct)
                    cashColumn(cash)
                    balanceColumn(bal)
                }
                VStack(alignment: .leading, spacing: 14) {
                    incomeColumn(inc, pct: pct)
                    cashColumn(cash)
                    balanceColumn(bal)
                }
            }
            Text("Gear purchases show in cash flow and on the balance sheet at today's value, not as an expense. Card charges count when they happen; paying the card shows in cash flow.")
                .font(Theme.font(size: 11)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panel()
        .accentBar(Palette.lime)
    }

    private func column<Content: View>(_ question: String, _ formal: String, color: Color, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(formal.uppercased()).font(Theme.font(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(color)
            Text(question).font(Theme.display(size: 20)).foregroundStyle(Theme.text).padding(.bottom, 10)
            content()
        }
        .padding(16)
        .frame(minWidth: 260, maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.raised.opacity(0.5))
        .overlay(alignment: .top) { Rectangle().fill(color.opacity(0.8)).frame(height: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private enum RowStyle { case item, sub, total }

    private func row(_ label: String, _ amount: Double, _ style: RowStyle = .item, pct: String? = nil,
                     good: Bool? = nil, meaning: String? = nil) -> some View {
        let tone = good == nil ? (style == .item ? Theme.text2 : Theme.text) : (good! ? Theme.teal : Theme.coral)
        return HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(Theme.font(size: style == .total ? 15 : (style == .sub ? 14 : 13),
                                 weight: style == .total ? .bold : (style == .sub ? .semibold : .regular)))
                .foregroundStyle(style == .item ? Theme.text3 : Theme.text)
                .lineLimit(1)
                .padding(.leading, style == .item ? 10 : 0)
            Spacer(minLength: 8)
            if let pct {
                Text(pct).font(Theme.font(size: 11)).foregroundStyle(Theme.muted)
                    .help("Share of total revenue")
            }
            Text(signed(amount))
                .font(style == .total ? Theme.display(size: 22) : Theme.font(size: style == .sub ? 14 : 13, weight: style == .item ? .regular : .semibold))
                .monospacedDigit()
                .foregroundStyle(tone)
        }
        .padding(.vertical, style == .item ? 3 : 7)
        .padding(.horizontal, style == .total ? 10 : 0)
        .background {
            if style == .total {
                RoundedRectangle(cornerRadius: 8).fill((good == false ? Theme.coral : Theme.teal).opacity(0.12))
            }
        }
        .overlay(alignment: .top) { if style == .sub { Rectangle().fill(Theme.line).frame(height: 1) } }
        .padding(.top, style == .total ? 6 : 0)
        .contentShape(Rectangle())
        .help(meaning ?? "")
    }

    private static let allGroups = ["Revenue", "Project costs", "Running the business", "Working",
                                    "Investing + owner", "What you have", "What you owe"]

    private var openGroups: Set<String> {
        Set(openGroupsRaw.split(separator: ",").map(String.init))
    }

    /// A group of line items that opens and closes. Closed, it shows just its total (if it has one).
    @ViewBuilder
    private func group<Content: View>(_ title: String, total: Double? = nil, @ViewBuilder _ items: () -> Content) -> some View {
        let open = openGroups.contains(title)
        Button {
            var set = openGroups
            if open { set.remove(title) } else { set.insert(title) }
            withAnimation(.easeInOut(duration: 0.2)) { openGroupsRaw = set.sorted().joined(separator: ",") }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(Theme.font(size: 8, weight: .bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                Text(title).font(Theme.font(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                if !open, let total {
                    Text(signed(total)).font(Theme.font(size: 13)).monospacedDigit().foregroundStyle(Theme.text2)
                }
            }
            .foregroundStyle(Theme.muted)
            .padding(.top, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(open ? "Hide these lines" : "Show these lines")
        if open { items() }
    }

    private func cents(_ v: Double) -> String {
        (v < -0.004 ? "−" : "") + abs(v).formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    private func signed(_ v: Double) -> String {
        (v < -0.004 ? "−" : "") + Money.string(abs(v))
    }

    private func incomeColumn(_ i: MoneyStore.Income, pct: @escaping (Double) -> String?) -> some View {
        column("Did I make money?", "Income statement", color: Palette.lime) {
            group("Revenue") {
                if i.revenue.isEmpty { Text("Nothing yet").font(Theme.font(size: 12)).foregroundStyle(Theme.muted) }
                ForEach(i.revenue) { row($0.label, $0.amount, pct: pct($0.amount)) }
            }
            row("Total revenue", i.totalRevenue, .sub, meaning: "Everything clients paid you")
            group("Project costs", total: -i.direct.reduce(0) { $0 + $1.amount }) {
                ForEach(i.direct) { row($0.label, -$0.amount, pct: pct($0.amount)) }
            }
            row("Gross profit", i.gross, .sub, pct: pct(i.gross), meaning: "What's left after each shoot's own costs")
            group("Running the business") {
                ForEach(i.overhead) { row($0.label, -$0.amount, pct: pct($0.amount)) }
            }
            row("Total overhead", -i.totalOverhead, .sub, pct: pct(i.totalOverhead), meaning: "What the business costs to run, shoot or no shoot")
            row("You kept", i.net, .total, pct: pct(i.net), good: i.net >= 0, meaning: "Your profit: revenue minus every cost")
        }
    }

    private func cashColumn(_ c: MoneyStore.CashFlow) -> some View {
        column("Where did the cash go?", "Cash flow · checking, Venmo, PayPal", color: Theme.amber) {
            row("Started with", c.start, .sub, meaning: "Cash in your accounts at the start")
            group("Working", total: c.clientsPaid + c.projectCosts + c.runningCosts + c.cardAndTransfers + c.taxes) {
                row("Clients paid you", c.clientsPaid)
                if c.projectCosts != 0 { row("Crew and project costs", c.projectCosts) }
                if c.runningCosts != 0 { row("Running the business", c.runningCosts) }
                if c.cardAndTransfers != 0 { row("Paid the card / moved money", c.cardAndTransfers) }
                if c.taxes != 0 { row("Taxes", c.taxes) }
            }
            group("Investing + owner", total: c.gear + c.owner + c.unsorted) {
                if c.gear != 0 { row("Bought gear", c.gear) }
                row("Paid to you / put in", c.owner)
                if abs(c.unsorted) > 0.004 { row("Not sorted yet", c.unsorted) }
            }
            row("Ended with", c.end, .total, meaning: "Cash in your accounts at the end")
            row(abs(c.end - c.start) < 0.005 ? "No change" : (c.end > c.start ? "Up by" : "Down by"), abs(c.end - c.start))
        }
    }

    private func balanceColumn(_ b: MoneyStore.Balance) -> some View {
        column("What's it all worth?", "Balance sheet · end of period", color: Palette.blue) {
            group("What you have") {
                ForEach(b.cash) { row($0.label, $0.amount) }
                row("Clients owe you", b.owed)
                row("Gear at today's value", b.gear)
            }
            row("Total you have", b.assets, .sub, meaning: "Cash, money owed to you and your gear")
            group("What you owe", total: -b.card) {
                row("Credit card", -b.card)
            }
            row("Your business is worth", b.worth, .total, good: b.worth >= 0, meaning: "What you have minus what you owe")
        }
    }

    // MARK: Numbers

    private struct Tile: Identifiable {
        let id = UUID()
        let label: String, value: String, sub: String
        var tone: Color? = nil
    }

    private var numbers: some View {
        let inc = money.income(range)
        let list = money.txns(in: range)
        let rev = inc.totalRevenue
        // Revenue
        let projectRevenue = Dictionary(grouping: list.filter { $0.category.group == .income && $0.projectID != nil }, by: { $0.projectID! })
            .mapValues { $0.reduce(0) { $0 + $1.amount } }
        let biggest = projectRevenue.max { $0.value < $1.value }
        // Pipeline
        let closed = deals.deals.filter { ($0.stage == .won || $0.stage == .lost) && $0.lastTouch >= range.start && $0.lastTouch < range.end }
        let won = closed.filter { $0.stage == .won }
        let wonValue = won.compactMap { deals.value(of: $0) }
        let inPlay = deals.open.compactMap { deals.value(of: $0) }.reduce(0, +)
        let daysToClose = won.map { Calendar.current.dateComponents([.day], from: $0.createdAt, to: $0.lastTouch).day ?? 0 }
        let bySource = Dictionary(grouping: deals.deals.filter { $0.stage == .won }, by: \.source).mapValues { $0.compactMap { deals.value(of: $0) }.reduce(0, +) }
        // Projects
        let crew = list.filter { $0.category == .crew }.reduce(0) { $0 - $1.amount }
        let delivered = projects.active.filter { $0.stage == .delivered }.count
        let rates = deals.deals.filter { $0.stage == .won }.compactMap { $0.chosenOption }.map { deals.estimate($0).takeHomePerHour }
        // Cash
        let bal = money.balance(range)
        let overdue = money.receivables.filter { $0.paidOn == nil && $0.due < Calendar.current.startOfDay(for: Date()) }
        // Gear
        let gearBought = list.filter { $0.category == .gear }.reduce(0) { $0 - $1.amount }

        let groups: [(String, Color, [Tile])] = [
            ("Revenue", Palette.lime, [
                Tile(label: "Revenue", value: Money.short(rev), sub: "\(projectRevenue.count) paying project\(projectRevenue.count == 1 ? "" : "s")"),
                Tile(label: "You kept", value: Money.short(inc.net), sub: rev > 0 ? "\(Int((100 * inc.net / rev).rounded()))% margin" : "—", tone: inc.net >= 0 ? Theme.teal : Theme.coral),
                Tile(label: "Avg per project", value: projectRevenue.isEmpty ? "—" : Money.short(projectRevenue.values.reduce(0, +) / Double(projectRevenue.count)), sub: "money in, this period"),
                Tile(label: "Biggest client", value: biggest.flatMap { projects.project(id: $0.key)?.client } ?? "—", sub: biggest.map { Money.string($0.value) } ?? ""),
            ]),
            ("Pipeline", Palette.violet, [
                Tile(label: "In play", value: Money.short(inPlay), sub: "\(deals.open.count) open deals"),
                Tile(label: "Win rate", value: closed.isEmpty ? "—" : "\(Int((100 * Double(won.count) / Double(closed.count)).rounded()))%", sub: "\(won.count) won of \(closed.count) closed"),
                Tile(label: "Avg deal won", value: wonValue.isEmpty ? "—" : Money.short(wonValue.reduce(0, +) / Double(wonValue.count)), sub: "this period"),
                Tile(label: "Days to close", value: daysToClose.isEmpty ? "—" : "\(daysToClose.reduce(0, +) / daysToClose.count)", sub: "inquiry to booked"),
                Tile(label: "Best source", value: bySource.max { $0.value < $1.value }?.key ?? "—", sub: bySource.max { $0.value < $1.value }.map { "\(Money.short($0.value)) won, all time" } ?? ""),
            ]),
            ("Projects", Palette.blue, [
                Tile(label: "Active", value: "\(projects.active.count)", sub: "\(delivered) delivered, awaiting payment"),
                Tile(label: "Crew share", value: rev > 0 ? "\(Int((100 * crew / rev).rounded()))%" : "—", sub: "\(Money.string(crew)) to collaborators"),
                Tile(label: "Your rate", value: rates.isEmpty ? "—" : "\(Money.string(rates.reduce(0, +) / Double(rates.count)))/hr", sub: "take-home, on booked quotes"),
            ]),
            ("Cash", Theme.amber, [
                Tile(label: "Cash on hand", value: Money.short(bal.totalCash), sub: "checking, Venmo, PayPal"),
                Tile(label: "Clients owe you", value: Money.short(bal.owed), sub: "\(money.receivables.filter { $0.paidOn == nil }.count) open invoices"),
                Tile(label: "Overdue", value: Money.short(overdue.reduce(0) { $0 + $1.amount }), sub: overdue.isEmpty ? "nothing late" : overdue.map(\.client).joined(separator: ", "), tone: overdue.isEmpty ? nil : Theme.coral),
                Tile(label: "Card balance", value: Money.short(bal.card), sub: "owed on the card"),
            ]),
            ("Gear", Palette.gold, [
                Tile(label: "Gear worth", value: Money.short(bal.gear), sub: "\(money.gear.count) items, today's value"),
                Tile(label: "Bought", value: Money.short(gearBought), sub: "this period"),
                Tile(label: "Needs service", value: "\(money.gear.filter(\.needsService).count)", sub: "no check-up in a year", tone: money.gear.contains(where: \.needsService) ? Theme.amber : nil),
            ]),
        ]

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                ColorLabel("Numbers", Palette.violet)
                Spacer()
                Text(rangeTitle).font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
            }
            ForEach(groups, id: \.0) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.0.uppercased()).font(Theme.font(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(group.1)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], alignment: .leading, spacing: 10) {
                        ForEach(group.2) { tile in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tile.label).font(Theme.font(size: 11)).foregroundStyle(Theme.muted)
                                Text(tile.value).font(Theme.font(size: 20, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(tile.tone ?? Theme.text).lineLimit(1).minimumScaleFactor(0.6)
                                Text(tile.sub).font(Theme.font(size: 11)).foregroundStyle(Theme.muted).lineLimit(2)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
                            .background(Theme.raised.opacity(0.5))
                            .overlay(alignment: .leading) { Rectangle().fill(group.1.opacity(0.7)).frame(width: 2) }
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
        .panel()
        .accentBar(Palette.violet)
    }

    // MARK: Coming in

    private var comingIn: some View {
        let open = money.receivables.filter { $0.paidOn == nil }.sorted { $0.due < $1.due }
        let today = Calendar.current.startOfDay(for: Date())
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                ColorLabel("Coming in", Theme.amber)
                Spacer()
                Text(Money.string(open.reduce(0) { $0 + $1.amount })).font(Theme.font(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text2)
            }
            if open.isEmpty { Text("Nobody owes you anything right now.").font(Theme.font(size: 13)).foregroundStyle(Theme.muted) }
            ForEach(open) { r in
                HStack(spacing: 12) {
                    Text(r.due.formatted(.dateTime.month(.abbreviated).day()))
                        .font(Theme.font(size: 12)).monospacedDigit().foregroundStyle(r.due < today ? Theme.coral : Theme.muted).frame(width: 52, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(r.client).font(Theme.font(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                            if r.due < today {
                                Text("Overdue").font(Theme.font(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Theme.coral.opacity(0.2)).foregroundStyle(Theme.coral).clipShape(Capsule())
                            }
                        }
                        Text(r.label).font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Text(Money.string(r.amount)).font(Theme.font(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text2)
                    Button("Paid") { money.markPaid(r); show("Marked \(r.client) paid") }.buttonStyle(SecondaryButtonStyle())
                }
                .padding(.vertical, 4)
            }
        }
        .panel()
        .accentBar(Theme.amber)
    }

    private var accounts: some View {
        let now = Date().addingTimeInterval(86400)
        return VStack(alignment: .leading, spacing: 10) {
            ColorLabel("Accounts", Palette.mint)
            ForEach(MoneyAccount.allCases.filter { a in money.txns.contains { $0.account == a } || money.data.openings[a.rawValue] != nil }) { a in
                HStack {
                    Text(a.label).font(Theme.font(size: 13)).foregroundStyle(Theme.text3)
                    Spacer()
                    Text(signed(money.accountBalance(a, before: now))).font(Theme.font(size: 13, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(a.isCash ? Theme.text2 : Theme.coral)
                }
            }
            Text("Transactions come in through Update from bank. Lens only reads statements; it never moves money.")
                .font(Theme.font(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .panel()
        .accentBar(Palette.mint)
    }

    // MARK: Transactions

    private var transactions: some View {
        let list = money.txns(in: range).filter { !onlyUnsorted || $0.category == .uncategorized }
        let total = list.reduce(0) { $0 + $1.amount }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                ColorLabel("All transactions", Palette.blue)
                Text("\(list.count) · \(rangeTitle)").font(Theme.font(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                Toggle("Only unsorted", isOn: $onlyUnsorted).toggleStyle(.checkbox).font(Theme.font(size: 12))
            }
            HStack {
                Text("Date").frame(width: 64, alignment: .leading)
                Text("Description").frame(maxWidth: .infinity, alignment: .leading)
                Text("Account").frame(width: 90, alignment: .leading)
                Text("Category").frame(width: 190, alignment: .leading)
                Text("Amount").frame(width: 96, alignment: .trailing)
            }
            .font(Theme.font(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(Theme.muted)
            ForEach(list.prefix(300)) { t in
                HStack(alignment: .center) {
                    Text(t.date.formatted(.dateTime.month(.abbreviated).day())).font(Theme.font(size: 12)).monospacedDigit()
                        .foregroundStyle(Theme.muted).frame(width: 64, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.description).font(Theme.font(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                        projectTag(t)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(t.account.label).font(Theme.font(size: 12)).foregroundStyle(Theme.text3).frame(width: 90, alignment: .leading)
                    Menu {
                        ForEach(MoneyCategory.pickable) { cat in
                            Button(cat.label) {
                                let n = money.setCategory(t, cat)
                                show(n > 0 ? "Sorted, plus \(n) like it. Lens will remember." : "Sorted. Lens will remember \(MoneyStore.ruleKey(t.description).map { "\"\($0)\"" } ?? "this").")
                            }
                        }
                    } label: {
                        Text(t.category.label).font(Theme.font(size: 12))
                            .foregroundStyle(t.category == .uncategorized ? Theme.amber : Theme.text2)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 190, alignment: .leading)
                    Text(cents(t.amount)).font(Theme.font(size: 13, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(t.amount > 0 ? Theme.teal : Theme.text2).frame(width: 96, alignment: .trailing)
                }
                .padding(.vertical, 5)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.lineSoft).frame(height: 1) }
            }
            if !list.isEmpty {
                HStack {
                    Text("Net").font(Theme.font(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    Text(cents(total)).font(Theme.font(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text)
                }
                .padding(.top, 4)
            }
        }
        .panel()
        .accentBar(Palette.blue)
    }

    /// The project a transaction belongs to, picked in one click from the open projects.
    /// When the description or date clearly fits one, Lens offers it.
    @ViewBuilder private func projectTag(_ t: Txn) -> some View {
        let open = projects.active
        HStack(spacing: 10) {
            Menu {
                if let p = projects.project(id: t.projectID) {
                    Button("Open \(p.name)") { navigator.openProject(p.id) }
                    Button("Take off \(p.name)") { money.setProject(t, nil) }
                    Divider()
                }
                ForEach(open.filter { $0.id != t.projectID }) { p in
                    Button(p.name) { money.setProject(t, p.id); show("Added to \(p.name)") }
                }
            } label: {
                Text(projects.project(id: t.projectID)?.name ?? "Add to project")
                    .font(Theme.font(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(t.projectID == nil ? Theme.muted : Palette.blue)
            if t.projectID == nil, let guess = MoneyStore.suggestedProject(for: t, in: open) {
                Button("\(guess.name)?") { money.setProject(t, guess.id); show("Added to \(guess.name)") }
                    .buttonStyle(.plain)
                    .font(Theme.font(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.teal)
                    .help("Looks like it's for \(guess.name). Click to add it.")
            }
        }
    }

    // MARK: Import

    private func pickStatement() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.message = "Choose a statement exported as CSV from your bank, card, Venmo or PayPal."
        panel.prompt = "Import"
        if panel.runModal() == .OK, let url = panel.url { importURL = url }
    }
}

private struct ImportTarget: Identifiable {
    let url: URL
    var id: String { url.path }
}

private struct ImportSheet: View {
    @EnvironmentObject private var money: MoneyStore
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let done: (String) -> Void
    @State private var account: MoneyAccount = .checking
    @State private var chargesPositive = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import \(url.lastPathComponent)").font(Theme.font(size: 17, weight: .bold))
            Picker("Which account is this?", selection: $account) {
                ForEach(MoneyAccount.allCases) { Text($0.label).tag($0) }
            }
            if account == .card {
                Toggle("Charges show as positive numbers in this file", isOn: $chargesPositive).toggleStyle(.checkbox)
            }
            Text("Lens skips anything already in the books, and sorts what it recognizes. You'll sort the rest once; it learns from each one.")
                .font(Theme.font(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(Theme.font(size: 12)).foregroundStyle(Theme.coral) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button("Import") {
                    do {
                        let (added, skipped) = try money.importCSV(url, account: account, chargesArePositive: chargesPositive)
                        done("Imported \(added) transaction\(added == 1 ? "" : "s")" + (skipped > 0 ? ", skipped \(skipped) already in the books" : ""))
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

/// The tabs on the books: one day, week, month or year at a time.
enum BooksSpan: String, CaseIterable, Identifiable {
    case day, week, month, year
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    private var unit: Calendar.Component {
        switch self { case .day: return .day; case .week: return .weekOfYear; case .month: return .month; case .year: return .year }
    }

    /// The `back`-th one before the current one (0 is today, this week, this month, this year).
    func range(back: Int, now: Date = Date()) -> MoneyStore.Span {
        let cal = Calendar.current
        let current = cal.dateInterval(of: unit, for: now)!.start
        let start = cal.date(byAdding: unit, value: -back, to: current)!
        return (start, cal.date(byAdding: unit, value: 1, to: start)!)
    }

    func title(back: Int, now: Date = Date()) -> String {
        let r = range(back: back, now: now)
        let cal = Calendar.current
        switch self {
        case .day:
            if back == 0 { return "Today" }
            if back == 1 { return "Yesterday" }
            return r.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        case .week:
            if back == 0 { return "This week" }
            if back == 1 { return "Last week" }
            let last = cal.date(byAdding: .day, value: -1, to: r.end)!
            return "\(r.start.formatted(.dateTime.month(.abbreviated).day())) to \(last.formatted(.dateTime.month(.abbreviated).day()))"
        case .month:
            return cal.isDate(r.start, equalTo: now, toGranularity: .year)
                ? r.start.formatted(.dateTime.month(.wide)) : r.start.formatted(.dateTime.month(.wide).year())
        case .year:
            return r.start.formatted(.dateTime.year())
        }
    }
}
