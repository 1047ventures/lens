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

    @AppStorage("moneyPeriod") private var periodRaw = MoneyStore.Period.thisYear.rawValue
    @State private var onlyUnsorted = false
    @State private var toast: String?
    @State private var importURL: URL?
    /// Which groups in the books are open. Closed by default so only the main numbers show.
    @AppStorage("moneyOpenGroups") private var openGroupsRaw = ""

    private var period: MoneyStore.Period { MoneyStore.Period(rawValue: periodRaw) ?? .thisYear }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if money.unsortedCount > 0 { unsortedBanner }
                books
                numbers
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) { comingIn; accounts.frame(width: 320) }
                    VStack(alignment: .leading, spacing: 16) { comingIn; accounts }
                }
                transactions
            }
            .padding(36)
            .frame(maxWidth: 1240, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast).font(.system(size: 13, weight: .semibold))
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

    private func show(_ message: String) {
        withAnimation { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withAnimation { if toast == message { toast = nil } } }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Money").font(.system(size: 30, weight: .bold)).foregroundStyle(Theme.text)
                Text(subtitle).font(.system(size: 14)).foregroundStyle(Theme.muted)
            }
            Spacer()
            Picker("", selection: $periodRaw) {
                ForEach(MoneyStore.Period.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 380)
            Button("Import statement…") { pickStatement() }.buttonStyle(SecondaryButtonStyle())
        }
    }

    private var subtitle: String {
        let i = money.income(period)
        if i.totalRevenue == 0 && money.txns.isEmpty { return "Import a bank, card, Venmo or PayPal statement to start the books." }
        return i.net >= 0 ? "You kept \(Money.string(i.net)) of the \(Money.string(i.totalRevenue)) that came in."
                          : "You spent \(Money.string(-i.net)) more than came in."
    }

    private var unsortedBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.full").foregroundStyle(Theme.amber)
            Text("\(money.unsortedCount) transaction\(money.unsortedCount == 1 ? "" : "s") need\(money.unsortedCount == 1 ? "s" : "") sorting. Pick a category once and Lens sorts the rest like it.")
                .font(.system(size: 13)).foregroundStyle(Theme.text2)
            Spacer()
            Button(onlyUnsorted ? "Show all" : "Sort them") { onlyUnsorted.toggle() }.buttonStyle(SecondaryButtonStyle())
        }
        .panel(padding: 14)
        .accentBar(Theme.amber)
    }

    // MARK: The books

    private var books: some View {
        let inc = money.income(period), cash = money.cashFlow(period), bal = money.balance(period)
        let rev = inc.totalRevenue
        func pct(_ v: Double) -> String? { rev > 0 ? "\(Int((100 * v / rev).rounded()))%" : nil }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                ColorLabel("The books", Palette.lime)
                Spacer()
                Text(period.rawValue).font(.system(size: 12)).foregroundStyle(Theme.muted)
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
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panel()
        .accentBar(Palette.lime)
    }

    private func column<Content: View>(_ question: String, _ formal: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(question).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
            Text(formal).font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.bottom, 8)
            content()
        }
        .padding(16)
        .frame(minWidth: 260, maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.raised.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private enum RowStyle { case item, sub, total }

    private func row(_ label: String, _ amount: Double, _ style: RowStyle = .item, pct: String? = nil, good: Bool? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: style == .item ? 13 : 13, weight: style == .item ? .regular : .semibold))
                .foregroundStyle(style == .item ? Theme.text3 : Theme.text)
                .padding(.leading, style == .item ? 10 : 0)
            Spacer(minLength: 8)
            if let pct { Text(pct).font(.system(size: 11).italic()).foregroundStyle(Theme.muted) }
            Text(signed(amount))
                .font(.system(size: style == .total ? 15 : 13, weight: style == .item ? .regular : .semibold))
                .monospacedDigit()
                .foregroundStyle(good == nil ? Theme.text2 : (good! ? Theme.teal : Theme.coral))
        }
        .padding(.vertical, style == .total ? 6 : 3)
        .overlay(alignment: .top) { if style != .item { Rectangle().fill(Theme.line).frame(height: 1).offset(y: -2) } }
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
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                Text(title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.8)
                Spacer(minLength: 8)
                if !open, let total {
                    Text(signed(total)).font(.system(size: 13)).monospacedDigit().foregroundStyle(Theme.text2)
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
        column("Did I make money?", "Income statement") {
            group("Revenue") {
                if i.revenue.isEmpty { Text("Nothing yet").font(.system(size: 12)).foregroundStyle(Theme.muted) }
                ForEach(i.revenue) { row($0.label, $0.amount, pct: pct($0.amount)) }
            }
            row("Total revenue", i.totalRevenue, .sub)
            group("Project costs", total: -i.direct.reduce(0) { $0 + $1.amount }) {
                ForEach(i.direct) { row($0.label, -$0.amount, pct: pct($0.amount)) }
            }
            row("Gross profit", i.gross, .sub, pct: pct(i.gross))
            group("Running the business") {
                ForEach(i.overhead) { row($0.label, -$0.amount, pct: pct($0.amount)) }
            }
            row("Total overhead", -i.totalOverhead, .sub, pct: pct(i.totalOverhead))
            row("You kept", i.net, .total, pct: pct(i.net), good: i.net >= 0)
        }
    }

    private func cashColumn(_ c: MoneyStore.CashFlow) -> some View {
        column("Where did the cash go?", "Cash flow · checking, Venmo, PayPal") {
            row("Started with", c.start, .sub)
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
            row("Ended with", c.end, .total, good: c.end >= c.start)
            row("Change", c.end - c.start)
        }
    }

    private func balanceColumn(_ b: MoneyStore.Balance) -> some View {
        column("What's it all worth?", "Balance sheet · end of period") {
            group("What you have") {
                ForEach(b.cash) { row($0.label, $0.amount) }
                row("Clients owe you", b.owed)
                row("Gear at today's value", b.gear)
            }
            row("Total", b.assets, .sub)
            group("What you owe", total: -b.card) {
                row("Credit card", -b.card)
            }
            row("Your business is worth", b.worth, .total, good: b.worth >= 0)
        }
    }

    // MARK: Numbers

    private struct Tile: Identifiable {
        let id = UUID()
        let label: String, value: String, sub: String
        var tone: Color? = nil
    }

    private var numbers: some View {
        let inc = money.income(period), range = period.range()
        let list = money.txns(in: period)
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
        let bal = money.balance(period)
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
                Text(period.rawValue).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            ForEach(groups, id: \.0) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.0.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(group.1)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], alignment: .leading, spacing: 10) {
                        ForEach(group.2) { tile in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(tile.label).font(.system(size: 11)).foregroundStyle(Theme.muted)
                                Text(tile.value).font(.system(size: 20, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(tile.tone ?? Theme.text).lineLimit(1).minimumScaleFactor(0.6)
                                Text(tile.sub).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(2)
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
                Text(Money.string(open.reduce(0) { $0 + $1.amount })).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text2)
            }
            if open.isEmpty { Text("Nobody owes you anything right now.").font(.system(size: 13)).foregroundStyle(Theme.muted) }
            ForEach(open) { r in
                HStack(spacing: 12) {
                    Text(r.due.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(r.due < today ? Theme.coral : Theme.muted).frame(width: 52, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(r.client).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                            if r.due < today {
                                Text("Overdue").font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Theme.coral.opacity(0.2)).foregroundStyle(Theme.coral).clipShape(Capsule())
                            }
                        }
                        Text(r.label).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Text(Money.string(r.amount)).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text2)
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
                    Text(a.label).font(.system(size: 13)).foregroundStyle(Theme.text3)
                    Spacer()
                    Text(signed(money.accountBalance(a, before: now))).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(a.isCash ? Theme.text2 : Theme.coral)
                }
            }
            Text("Read-only. Statements come in through Import or the statements folder in Log-ins; Lens can't move money.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .panel()
        .accentBar(Palette.mint)
    }

    // MARK: Transactions

    private var transactions: some View {
        let list = money.txns(in: period).filter { !onlyUnsorted || $0.category == .uncategorized }
        let total = list.reduce(0) { $0 + $1.amount }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                ColorLabel("All transactions", Palette.blue)
                Text("\(list.count) · \(period.rawValue.lowercased())").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                Toggle("Only unsorted", isOn: $onlyUnsorted).toggleStyle(.checkbox).font(.system(size: 12))
            }
            HStack {
                Text("Date").frame(width: 64, alignment: .leading)
                Text("Description").frame(maxWidth: .infinity, alignment: .leading)
                Text("Account").frame(width: 90, alignment: .leading)
                Text("Category").frame(width: 190, alignment: .leading)
                Text("Amount").frame(width: 96, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(Theme.muted)
            ForEach(list.prefix(300)) { t in
                HStack(alignment: .center) {
                    Text(t.date.formatted(.dateTime.month(.abbreviated).day())).font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(Theme.muted).frame(width: 64, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.description).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                        if let p = projects.project(id: t.projectID) {
                            Button(p.name) { navigator.openProject(p.id) }.buttonStyle(.plain)
                                .font(.system(size: 11)).foregroundStyle(Palette.blue)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(t.account.label).font(.system(size: 12)).foregroundStyle(Theme.text3).frame(width: 90, alignment: .leading)
                    Menu {
                        ForEach(MoneyCategory.pickable) { cat in
                            Button(cat.label) {
                                let n = money.setCategory(t, cat)
                                show(n > 0 ? "Sorted, plus \(n) like it. Lens will remember." : "Sorted. Lens will remember \(MoneyStore.ruleKey(t.description).map { "\"\($0)\"" } ?? "this").")
                            }
                        }
                    } label: {
                        Text(t.category.label).font(.system(size: 12))
                            .foregroundStyle(t.category == .uncategorized ? Theme.amber : Theme.text2)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 190, alignment: .leading)
                    Text(cents(t.amount)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(t.amount > 0 ? Theme.teal : Theme.text2).frame(width: 96, alignment: .trailing)
                }
                .padding(.vertical, 5)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.lineSoft).frame(height: 1) }
            }
            if !list.isEmpty {
                HStack {
                    Text("Net").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    Text(cents(total)).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.text)
                }
                .padding(.top, 4)
            }
        }
        .panel()
        .accentBar(Palette.blue)
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
            Text("Import \(url.lastPathComponent)").font(.system(size: 17, weight: .bold))
            Picker("Which account is this?", selection: $account) {
                ForEach(MoneyAccount.allCases) { Text($0.label).tag($0) }
            }
            if account == .card {
                Toggle("Charges show as positive numbers in this file", isOn: $chargesPositive).toggleStyle(.checkbox)
            }
            Text("Lens skips anything already in the books, and sorts what it recognizes. You'll sort the rest once; it learns from each one.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.coral) }
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
