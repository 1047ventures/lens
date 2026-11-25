import SwiftUI

/// The home screen: only what needs attention right now, built from projects and the last scan.
struct TodayView: View {
    @EnvironmentObject private var viewModel: ScanViewModel
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var deals: DealStore
    @EnvironmentObject private var logins: ConnectionStore
    @EnvironmentObject private var people: PeopleStore
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var appearance: Appearance
    @State private var scanningCard = false

    private typealias Item = TodayItem

    @EnvironmentObject private var money: MoneyStore
    @State private var events: [LensCalendarEvent] = []
    /// The next seven days, for "Your week".
    @State private var weekEvents: [LensCalendarEvent] = []
    @State private var eventsLoaded = false
    @State private var openItems: Set<String> = []
    @State private var showAllItems = false

    var body: some View {
        if appearance.simple { simpleToday } else { everything }
    }

    private var everything: some View {
        let numbers = TodayNumbers(money: money, deals: deals, projects: projects)
        let all = items
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(all)
                ArrangeablePage("today", columns: true, boxes: everythingBoxes(numbers, all))
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 34)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await loadEvents() }
    }

    /// Today's boxes in their usual order; she can rearrange, resize or hide them.
    private func everythingBoxes(_ numbers: TodayNumbers, _ all: [Item]) -> [PageBox] {
        var boxes: [PageBox] = []
        if logins.googleCalendarReady {
            boxes.append(PageBox("calendar", "Today's calendar", color: Palette.blue) {
                DashCard(title: "Today", color: Palette.blue) {
                    DayTimeline(events: events, loaded: eventsLoaded)
                }
            })
        }
        boxes += [
            PageBox("needsYou", "A few things for you", color: Theme.coral) { needsYou(all) },
            PageBox("time", "Where your time went", color: Palette.orchid, half: true) {
                DashCard(title: "Where your time went", color: Palette.orchid, action: { navigator.open(.projects) },
                         takeaway: numbers.timeTakeaway) {
                    HoursDonut(slices: numbers.hoursThisMonth)
                }
            },
            PageBox("week", "The week ahead", color: Theme.teal, half: true) {
                DashCard(title: "The week ahead", color: Theme.teal, takeaway: weekTakeaway) {
                    WeekStrip(projects: projects.active) { navigator.openProject($0) }
                }
            },
            PageBox("moneyIn", "Money in", color: Palette.lime, half: true) {
                DashCard(title: "Money in · last 6 months", color: Palette.lime, action: { navigator.open(.money) },
                         takeaway: numbers.moneyTakeaway) {
                    MoneyInChart(numbers: numbers)
                }
            },
            PageBox("funnel", "Where your jobs are", color: Palette.violet, half: true) {
                DashCard(title: "Where your jobs are", color: Palette.violet, action: { navigator.open(.projects) },
                         takeaway: numbers.funnelTakeaway) {
                    StageFunnel(steps: numbers.funnel)
                }
            },
            PageBox("numbers", "Key numbers", color: Palette.lime) { tiles(numbers).padding(.top, 14) },
            PageBox("autoFiled", "Filed by Lens this week", color: Theme.amber) {
                AutoFiledToday().frame(maxWidth: 720, alignment: .leading)
            },
        ]
        // Extras she can switch on from "Choose boxes".
        boxes += TodayMore.boxes(projects: projects, deals: deals, money: money, navigator: navigator)
        boxes.append(PageBox("ask", "Ask Lens", color: Palette.violet, off: true,
                             about: "Ask Lens a question about your business, right from Today.") { askBox })
        return boxes
    }

    private func loadEvents() async {
        guard logins.googleCalendarReady else { return }
        let start = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        let end = Calendar.current.date(byAdding: .day, value: 7, to: start) ?? start
        let found = await logins.calendarEvents(from: start, to: end)
        var seen = Set<String>()
        weekEvents = found.filter { seen.insert("\($0.title)|\($0.start)").inserted }
        events = weekEvents.filter { $0.start < tomorrow }
        eventsLoaded = true
    }

    /// Two cards side by side, stacked when the window is narrow.
    private func pair<L: View, R: View>(@ViewBuilder _ left: () -> L, @ViewBuilder right: () -> R) -> some View {
        let l = left(), r = right()
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                l.frame(minWidth: 460).layoutPriority(1)
                r.frame(minWidth: 340, maxWidth: 440)
            }
            .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 16) { l; r }
        }
    }

    /// Today's key numbers: the usual five, and more she can pick from.
    private func tiles(_ n: TodayNumbers) -> some View {
        let profit = n.thisMonth?.net ?? 0
        let last = n.months.dropLast().last?.net
        let hoursNow = n.weeksHours.last ?? 0
        let pace = MonthPace(money: money)
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        let week = cal.dateInterval(of: .weekOfYear, for: now)
        let keptWeek = money.income((start: week?.start ?? today, end: week?.end ?? now)).net
        let unpaid = money.receivables.filter { $0.paidOn == nil }
        let onTheWay = unpaid.filter { $0.due >= today }
        let late = unpaid.filter { $0.due < today }.sorted { $0.due < $1.due }
        let hasBooks = !money.data.openings.isEmpty || !money.txns.isEmpty
        let cash = money.balance(.thisMonth).totalCash
        let month = money.income(.thisMonth)
        let year = money.income(.thisYear)
        let hasMonth = !money.txns(in: .thisMonth).isEmpty
        let deliver = JobSpeed.usual(JobSpeed.toDeliver(projects.projects))
        let paid = JobSpeed.usual(JobSpeed.toPaid(projects.projects, money: money))
        let toMoney = { navigator.open(.money) }
        func signed(_ v: Double) -> String { v < 0 ? "-\(Money.short(-v))" : Money.short(v) }

        let options: [TileOption] = [
            TileOption(id: "owed", label: "Owed to you", about: "Money clients still need to pay, and how much of it is late.") {
                StatTile(label: "Owed to you", value: Money.short(n.owed),
                         note: n.owedCount == 0 ? "Nobody owes you" : n.overdueCount > 0 ? "\(n.overdueCount) overdue of \(n.owedCount)" : "\(n.owedCount) on the way",
                         color: Palette.gold, noteColor: n.overdueCount > 0 ? Theme.coral : Theme.text3, action: toMoney)
            },
            TileOption(id: "kept", label: "Kept this month", about: "What you've kept this month after costs, next to last month.") {
                StatTile(label: "Kept this month", value: signed(profit),
                         note: last.map { profit >= $0 ? "Up from \(Money.short($0)) last month" : "Down from \(Money.short($0)) last month" } ?? "After costs",
                         color: Palette.lime, trend: n.months.map(\.net),
                         noteColor: last.map { profit >= $0 ? Palette.lime : Theme.text3 } ?? Theme.text3, action: toMoney)
            },
            TileOption(id: "openDeals", label: "Open deals", about: "What the deals you could still win are worth.") {
                StatTile(label: "Open deals", value: Money.short(n.openDealsValue),
                         note: n.openDealsCount == 0 ? "No deals in play" : "\(n.openDealsCount) in play",
                         color: Palette.blue) { navigator.open(.projects) }
            },
            TileOption(id: "hours", label: "Hours this week", about: "Hours you've logged this week, with the last 8 weeks as a trend.") {
                StatTile(label: "Hours this week", value: Hours.short(hoursNow),
                         note: n.weeksHours.dropLast().isEmpty ? "" : "8 week trend", color: Palette.orchid,
                         trend: n.weeksHours) { navigator.open(.projects) }
            },
            TileOption(id: "winRate", label: "Win rate", about: "How often a quote turns into a booking.") {
                StatTile(label: "Win rate", value: n.winRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "None yet",
                         note: n.winRate == nil ? "Shows once a quote books or doesn't" : "\(n.won) won, \(n.lost) lost",
                         color: Palette.mint) { navigator.open(.projects) }
            },
            TileOption(id: "onPace", label: "On pace for", about: "What you'll keep this month if it carries on the way it's going.") {
                StatTile(label: "On pace for",
                         value: !hasMonth ? "None yet" : pace.ready ? Money.short(pace.pace) : "Early days",
                         note: !hasMonth ? "Shows once money comes in" : !pace.ready ? "Shows from the 5th of the month"
                            : pace.goal.map { pace.pace >= $0 ? "Ahead of your \(Money.short($0)) goal" : "Your goal is \(Money.short($0))" } ?? "this month, at this rate",
                         color: Palette.lime,
                         noteColor: pace.ready && pace.goal.map { pace.pace >= $0 } == true ? Palette.lime : Theme.text3, action: toMoney)
            },
            TileOption(id: "goal", label: "Goal so far", about: "How far you are toward the monthly goal you set.") {
                GoalTile(money: money, navigator: navigator)
            },
            TileOption(id: "perHourWeek", label: "Per hour this week", about: "What you kept this week for every hour you logged.") {
                StatTile(label: "Per hour this week",
                         value: hoursNow > 0.05 ? "\(signed(keptWeek / hoursNow))/hr" : "None yet",
                         note: hoursNow > 0.05 ? "\(signed(keptWeek)) kept over \(Hours.short(hoursNow))" : "Shows once you log hours this week",
                         color: Palette.orchid) { navigator.open(.projects) }
            },
            TileOption(id: "onTheWay", label: "On the way", about: "Money you're owed that isn't late yet, next to what's already in hand.") {
                StatTile(label: "On the way", value: onTheWay.isEmpty ? "None" : Money.short(onTheWay.reduce(0) { $0 + $1.amount }),
                         note: hasBooks ? "\(Money.short(cash)) already in hand" : onTheWay.isEmpty ? "Nothing waiting right now" : "\(onTheWay.count) not due yet",
                         color: Palette.gold, action: toMoney)
            },
            TileOption(id: "cash", label: "In hand", about: "What is in your accounts right now.") {
                StatTile(label: "In hand", value: hasBooks ? Money.short(cash) : "None yet",
                         note: hasBooks ? "checking, Venmo, PayPal" : "Shows once you add an account",
                         color: Theme.amber, action: toMoney)
            },
            TileOption(id: "overdue", label: "Overdue", about: "Money that should already have been paid.") {
                StatTile(label: "Overdue", value: late.isEmpty ? "None" : Money.short(late.reduce(0) { $0 + $1.amount }),
                         note: late.isEmpty ? "nothing late" : late.map(\.client).filter { !$0.isEmpty }.joined(separator: ", "),
                         color: late.isEmpty ? Theme.amber : Theme.coral, noteColor: late.isEmpty ? Theme.text3 : Theme.coral) {
                    if let id = late.first?.projectID { navigator.openProject(id) } else { navigator.open(.money) }
                }
            },
            TileOption(id: "cameIn", label: "Came in this month", about: "Everything clients paid you this month, before costs.") {
                StatTile(label: "Came in this month", value: hasMonth ? Money.short(month.totalRevenue) : "None yet",
                         note: hasMonth ? "before costs" : "Shows once money comes in", color: Palette.lime, action: toMoney)
            },
            TileOption(id: "margin", label: "Profit margin", about: "How many cents of every dollar you keep after costs, this month.") {
                StatTile(label: "Profit margin",
                         value: month.totalRevenue > 0 ? "\(Int((100 * month.net / month.totalRevenue).rounded()))%" : "None yet",
                         note: month.totalRevenue > 0 ? "this month" : "Shows once money comes in", color: Palette.lime, action: toMoney)
            },
            TileOption(id: "yearToDate", label: "Kept this year", about: "What you have kept so far this calendar year.") {
                StatTile(label: "Kept this year",
                         value: year.totalRevenue > 0 || year.totalDirect + year.totalOverhead > 0 ? signed(year.net) : "None yet",
                         note: year.totalRevenue > 0 ? "\(Money.short(year.totalRevenue)) came in" : "Shows once money comes in",
                         color: Palette.violet, action: toMoney)
            },
            TileOption(id: "taxSetAside", label: "About set aside for tax", about: "A rough guess at what to put away for taxes this month. Ask your accountant for the real number.") {
                StatTile(label: "About set aside for tax", value: month.net > 0 ? "About \(Money.short(month.net * 0.25))" : "None yet",
                         note: month.net > 0 ? "roughly a quarter of this month" : "Shows once you have a profit",
                         color: Palette.gold, action: toMoney)
            },
            TileOption(id: "daysToDeliver", label: "Days to deliver", about: "How long it usually takes from the shoot to handing the work over.") {
                StatTile(label: "Days to deliver", value: deliver.map(JobSpeed.daysText) ?? "None yet",
                         note: deliver == nil ? "Shows once a job is marked delivered" : "usually, shoot to delivered",
                         color: Palette.blue) { navigator.open(.projects) }
            },
            TileOption(id: "daysToPaid", label: "Days to get paid", about: "How long it usually takes from delivering a job to being paid for it.") {
                StatTile(label: "Days to get paid", value: paid.map(JobSpeed.daysText) ?? "None yet",
                         note: paid == nil ? "Shows once a delivered job is paid" : "usually, delivered to paid",
                         color: Palette.gold) { navigator.open(.projects) }
            },
        ]
        return ChoosableTiles(key: "today", options: options, defaults: ["owed", "kept", "openDeals", "hours", "winRate"])
    }

    // MARK: - Pieces

    private func header(_ all: [Item]) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                    .font(Theme.font(size: 12, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.muted)
                Text("\(greeting)\(firstName.map { ", \($0)" } ?? "")")
                    .font(Theme.font(size: 32, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(briefing)
                    .font(Theme.font(size: 15))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.text3)
                    .frame(maxWidth: 720, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(all.isEmpty ? "enjoy the quiet" : "you've got this")
                    .font(Theme.script(size: 24)).foregroundStyle(Palette.violet)
            }
            Spacer()
            // Back from a networking event: cards go straight into People.
            Button("Scan a card") { scanningCard = true }
                .buttonStyle(SecondaryButtonStyle())
        }
        .sheet(isPresented: $scanningCard) { CardScanView() }
    }

    /// The same few things as Simple, in the same words: the top four as cards with one button each,
    /// the rest folded away underneath.
    private func needsYou(_ all: [Item]) -> some View {
        let top = Array(all.prefix(4))
        let rest = Array(all.dropFirst(4))
        return VStack(alignment: .leading, spacing: 12) {
            ColorLabel(all.isEmpty ? "Nothing needs you" : "A few things for you", Palette.violet)
            if all.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").foregroundStyle(Theme.teal)
                    Text("All clear. Lens will put anything new here.")
                        .font(Theme.font(size: 14)).foregroundStyle(Theme.text3)
                }
                .panel()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(top) { item in thingCard(item, compact: true) }
                }
                if !rest.isEmpty {
                    foldButton(rest)
                    if showAllItems {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 10, alignment: .top)], alignment: .leading, spacing: 8) {
                            ForEach(rest) { item in needRow(item) }
                        }
                        .transition(.opacity)
                    }
                }
            }
        }
    }

    /// "And 8 more that can wait": opens or folds away everything after the first four.
    private func foldButton(_ rest: [Item]) -> some View {
        let late = rest.contains { $0.tone == .overdue }
        let label = showAllItems ? "Show fewer"
            : late ? "And \(rest.count) more to look at when you can" : "And \(rest.count) more that can wait"
        return Button {
            withAnimation(.easeOut(duration: 0.2)) { showAllItems.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(label)
                Image(systemName: "chevron.down")
                    .font(Theme.font(size: 10, weight: .bold))
                    .rotationEffect(.degrees(showAllItems ? 180 : 0))
            }
            .font(Theme.font(size: 13, weight: .semibold))
            .foregroundStyle(Theme.teal)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// One thing for her: an icon, what it is, and the one button that deals with it.
    private func thingCard(_ item: Item, compact: Bool = false) -> some View {
        let tint = simpleColor(item.tone)
        return HStack(spacing: compact ? 14 : 16) {
            Image(systemName: item.icon)
                .font(.system(size: compact ? 14 : 16, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: compact ? 34 : 40, height: compact ? 34 : 40)
                .background(tint.opacity(Theme.look == .daylight ? 0.14 : 0.22))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(Theme.font(size: compact ? 14.5 : 16, weight: .bold)).foregroundStyle(Theme.text)
                    .lineLimit(compact ? 1 : 2)
                Text("\(item.kicker). \(item.detail)")
                    .font(Theme.font(size: compact ? 12.5 : 14)).foregroundStyle(Theme.muted)
                    .lineLimit(compact ? 2 : nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(item.actionTitle, action: item.action).buttonStyle(PrimaryButtonStyle())
        }
        .panel(padding: compact ? 14 : 18)
    }

    private var askBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            askBar
            FlowLayout(spacing: 8) {
                ForEach(["Who should I follow up with this week?", "How did last month go?", "Which jobs paid best this year?"], id: \.self) { q in
                    Button {
                        navigator.askDraft = q
                        navigator.askOpen = true
                    } label: {
                        Text(q)
                            .font(Theme.font(size: 12.5)).foregroundStyle(Theme.text2)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Theme.panel)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Theme.line))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// One thin line per thing; click it to see the detail and the button.
    private func needRow(_ item: Item) -> some View {
        let open = openItems.contains(item.id)
        let tint = color(for: item.tone)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    if open { openItems.remove(item.id) } else { openItems.insert(item.id) }
                }
            } label: {
                HStack(spacing: 10) {
                    Circle().fill(tint).frame(width: 7, height: 7)
                    Text(item.title)
                        .font(Theme.font(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(item.kicker)
                        .font(Theme.font(size: 12))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.down")
                        .font(Theme.font(size: 10, weight: .bold))
                        .foregroundStyle(Theme.muted)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.horizontal, 14)
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                HStack(alignment: .center, spacing: 12) {
                    Text(item.detail)
                        .font(Theme.font(size: 12.5))
                        .foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(item.actionTitle, action: item.action).buttonStyle(PrimaryButtonStyle())
                }
                .padding(.leading, 31).padding(.trailing, 12).padding(.bottom, 12)
                .transition(.opacity)
            }
        }
        .background(open ? tint.opacity(0.07) : Color.clear)
        .background(Theme.panel)
        .accentBar(tint, cornerRadius: 10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(open ? tint.opacity(0.35) : Theme.line))
    }

    // MARK: - Simple

    /// Simple: "What do I do today, and is my week okay?" A greeting, the day in time order, the few things
    /// that need her (each with one button), the rest of the week, and a way to ask Lens. Numbers and charts
    /// live in Money and Projects.
    private var simpleToday: some View {
        let all = items.filter { !$0.admin }
        return ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                        .font(Theme.font(size: 13, weight: .bold)).tracking(0.8).foregroundStyle(Theme.muted)
                    Text("\(greeting)\(firstName.map { ", \($0)" } ?? "").")
                        .font(Theme.display(size: 40)).foregroundStyle(Theme.text)
                    Text(briefing)
                        .font(Theme.font(size: 17)).lineSpacing(4).foregroundStyle(Theme.text2)
                        .frame(maxWidth: 640, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(all.isEmpty ? "enjoy the quiet" : "you've got this")
                        .font(Theme.script(size: 26)).foregroundStyle(Palette.violet)
                }
                ArrangeablePage("today", columns: true, spacing: 30, boxes: simpleBoxes(all))
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .task { await loadEvents() }
    }

    private func simpleBoxes(_ all: [Item]) -> [PageBox] {
        var boxes: [PageBox] = []
        if logins.googleCalendarReady { boxes.append(PageBox("yourDay", "Your day", color: Palette.blue, half: true) { yourDay }) }
        boxes.append(PageBox("things", "A few things for you", color: Theme.coral, half: logins.googleCalendarReady) { thingsForYou(all) })
        boxes.append(PageBox("week", "Your week", color: Theme.teal) { restOfWeek })
        boxes.append(PageBox("ask", "Ask Lens", color: Palette.violet) { askBar })
        return boxes
    }

    private var askBar: some View {
                Button { navigator.askOpen = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles").foregroundStyle(Palette.violet)
                        Text("Ask Lens anything, like \u{201C}what should I charge for a half-day shoot?\u{201D}")
                            .font(Theme.font(size: 15)).foregroundStyle(Theme.muted)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .frame(minHeight: 54)
                    .background(Theme.panel)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Theme.line, lineWidth: 1.5))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
    }

    private var yourDay: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your day").font(Theme.display(size: 22)).foregroundStyle(Theme.text)
            if !eventsLoaded {
                ProgressView().controlSize(.small)
            } else if events.isEmpty {
                Text("Nothing on your calendar today.").font(Theme.font(size: 15)).foregroundStyle(Theme.muted)
            } else {
                ForEach(Array(events.sorted { ($0.allDay ? 0 : 1, $0.start) < ($1.allDay ? 0 : 1, $1.start) }.enumerated()), id: \.element.id) { i, e in
                    if i > 0 { Divider().overlay(Theme.lineSoft) }
                    HStack(alignment: .firstTextBaseline, spacing: 18) {
                        Text(e.allDay ? "All day" : e.start.formatted(date: .omitted, time: .shortened))
                            .font(Theme.font(size: 15, weight: .bold)).foregroundStyle(Palette.mint)
                            .frame(width: 76, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).font(Theme.font(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                            if let place = e.location, !place.isEmpty {
                                Text(place).font(Theme.font(size: 14)).foregroundStyle(Theme.muted).lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                }
            }
        }
        .panel(padding: 26)
    }

    private func thingsForYou(_ all: [Item]) -> some View {
        let rest = Array(all.dropFirst(4))
        return VStack(alignment: .leading, spacing: 14) {
            Text(all.isEmpty ? "Nothing needs you" : "A few things for you")
                .font(Theme.display(size: 22)).foregroundStyle(Theme.text)
            if all.isEmpty {
                Text("All clear. Lens will put anything new here.")
                    .font(Theme.font(size: 15)).foregroundStyle(Theme.muted)
            }
            ForEach(all.prefix(4)) { item in thingCard(item) }
            if !rest.isEmpty {
                foldButton(rest)
                if showAllItems {
                    ForEach(rest) { item in thingCard(item) }
                }
            }
        }
    }

    private var restOfWeek: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        // Seven days, today first, all in one row when there's room.
        let days = (0...6).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
        return VStack(alignment: .leading, spacing: 14) {
            Text("Your week").font(Theme.display(size: 22)).foregroundStyle(Theme.text)
            // One row of seven when it fits; on a narrow window the days wrap.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(days, id: \.self) { weekDay($0).frame(minWidth: 112) }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(days, id: \.self) { weekDay($0) }
                }
            }
        }
    }

    private func weekDay(_ day: Date) -> some View {
        let cal = Calendar.current
        return Group {
                    let plan = plans(on: day)
                    let shoot = projects.active.contains { $0.shootDate.map { cal.isDate($0, inSameDayAs: day) } ?? false }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(cal.isDateInToday(day) ? "Today" : day.formatted(.dateTime.weekday(.wide)))
                            .font(Theme.font(size: 13, weight: .bold))
                            .foregroundStyle(shoot ? Palette.mint : Theme.muted)
                        if plan.isEmpty {
                            Text("Nothing booked").font(Theme.font(size: 15, weight: .semibold)).foregroundStyle(Theme.text3)
                        } else {
                            ForEach(plan.prefix(3), id: \.self) { line in
                                Text(line).font(Theme.font(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if plan.count > 3 {
                                Text("and \(plan.count - 3) more").font(Theme.font(size: 13)).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
                    .padding(14)
                    .background(shoot ? Palette.mint.opacity(Theme.look == .daylight ? 0.12 : 0.18) : Theme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.look == .daylight || shoot ? Color.clear : Theme.line))
        }
    }

    /// One line for "The week ahead": how many shoots, and the first one.
    private var weekTakeaway: String {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 7, to: start) ?? start
        let shoots = projects.active
            .filter { $0.shootDate.map { $0 >= start && $0 < end } ?? false }
            .sorted { ($0.shootDate ?? .distantFuture) < ($1.shootDate ?? .distantFuture) }
        guard let first = shoots.first, let date = first.shootDate else {
            return "No shoots in the next seven days. A good week to edit or catch up."
        }
        let day = cal.isDateInToday(date) ? "today" : cal.isDateInTomorrow(date) ? "tomorrow"
            : "on " + date.formatted(.dateTime.weekday(.wide))
        return shoots.count == 1 ? "One shoot this week: \(first.name) \(day)."
                                 : "\(shoots.count) shoots this week. First up is \(first.name) \(day)."
    }

    /// What's on a day: shoots, proposals due, and calendar events.
    private func plans(on day: Date) -> [String] {
        let cal = Calendar.current
        var lines: [String] = []
        for p in projects.active where p.shootDate.map({ cal.isDate($0, inSameDayAs: day) }) ?? false {
            lines.append("Shoot: \(p.name)")
        }
        for d in deals.open where d.proposalDue.map({ cal.isDate($0, inSameDayAs: day) }) ?? false {
            lines.append("Proposal due: \(d.title)")
        }
        for e in weekEvents where cal.isDate(e.start, inSameDayAs: day) {
            if !lines.contains(where: { $0.hasSuffix(e.title) }) { lines.append(e.title) }
        }
        return lines
    }

    private func simpleColor(_ tone: Item.Tone) -> Color {
        switch tone {
        case .overdue: return Theme.coral
        case .soon: return Palette.violet
        case .neutral: return Palette.mint
        }
    }

    // MARK: - Data

    private var items: [Item] {
        TodayItem.build(viewModel: viewModel, projects: projects, deals: deals, logins: logins, people: people, navigator: navigator)
    }

    private var briefing: String {
        var parts: [String] = []
        let soon = projects.active.filter { isSoon($0.shootDate) && $0.stage != .lead && $0.stage.rawValue <= ProjectStage.shoot.rawValue }
        if let next = soon.first, let date = next.shootDate {
            parts.append("\(next.name) shoots \(relativeDay(date).lowercased()).")
        }
        let waiting = projects.active.filter { $0.stage == .delivered }
        if !waiting.isEmpty {
            parts.append(waiting.count == 1 ? "\(waiting[0].name) is delivered and waiting on payment."
                                            : "\(waiting.count) delivered projects are waiting on payment.")
        }
        let editing = projects.active.filter { $0.stage == .edit }
        if !editing.isEmpty {
            parts.append(editing.count == 1 ? "\(editing[0].name) is in the edit." : "\(editing.count) projects are in the edit.")
        }
        let nudges = deals.open.filter(\.isStale)
        if let top = nudges.max(by: { (deals.value(of: $0) ?? 0) < (deals.value(of: $1) ?? 0) }) {
            parts.append(nudges.count == 1 ? "\(top.title) has gone quiet for \(top.daysSinceTouch()) days, worth a nudge."
                                           : "\(nudges.count) quotes need a nudge, starting with \(top.title).")
        }
        let due = people.followUpsDue
        if !due.isEmpty {
            parts.append(due.count == 1 ? "\(due[0].name) is due a follow-up." : "\(due.count) people are due a follow-up.")
        }
        if viewModel.hasScanned {
            let reclaim = viewModel.overview.cacheBytes + viewModel.overview.duplicateWastedBytes
            if reclaim > 0 { parts.append("About \(ByteFormat.string(reclaim)) of the SSD is safe to clear.") }
        }
        if parts.isEmpty {
            return projects.projects.isEmpty
                ? "Start by adding your drive in Library, then turn its folders into projects."
                : "Nothing urgent today."
        }
        return parts.joined(separator: " ")
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var firstName: String? {
        NSFullUserName().split(separator: " ").first.map(String.init)
    }

    private func isSoon(_ date: Date?) -> Bool { TodayItem.isSoon(date) }
    private func relativeDay(_ date: Date) -> String { TodayItem.relativeDay(date) }

    private func color(for tone: Item.Tone) -> Color {
        switch tone {
        case .overdue: return Theme.coral
        case .soon: return Theme.amber
        case .neutral: return Palette.slate
        }
    }
}
