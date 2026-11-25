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

    private struct Item: Identifiable {
        enum Tone { case overdue, soon, neutral }
        /// Stable across redraws so an opened row stays open.
        var id: String { "\(actionTitle)|\(title)" }
        let tone: Tone
        let kicker: String
        let title: String
        let detail: String
        let actionTitle: String
        let action: () -> Void

        /// Behind-the-scenes jobs (drives, log-ins). Simple leaves them to Library and Log-ins.
        var admin: Bool { ["Go to Library", "Open Library", "Open Log-ins"].contains(actionTitle) }
        var icon: String {
            switch actionTitle {
            case "Build proposal": return "doc.text"
            case "Open deal": return "envelope"
            case "Open person": return "person"
            case "Open project": return kicker.contains("payment") ? "dollarsign.circle" : "camera"
            default: return "sparkles"
            }
        }
    }

    @EnvironmentObject private var money: MoneyStore
    @State private var events: [LensCalendarEvent] = []
    /// The next seven days, for "The rest of your week".
    @State private var weekEvents: [LensCalendarEvent] = []
    @State private var eventsLoaded = false
    @State private var openItems: Set<String> = []
    @State private var showAllItems = false

    var body: some View {
        if appearance.simple { simpleToday } else { everything }
    }

    private var everything: some View {
        let numbers = TodayNumbers(money: money, deals: deals, projects: projects)
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                ArrangeablePage("today", columns: true, boxes: everythingBoxes(numbers))
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 34)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await loadEvents() }
    }

    /// Today's boxes in their usual order; she can rearrange, resize or hide them.
    private func everythingBoxes(_ numbers: TodayNumbers) -> [PageBox] {
        var boxes: [PageBox] = []
        if logins.googleCalendarReady {
            boxes.append(PageBox("calendar", "Today's calendar", color: Palette.blue) {
                DashCard(title: "Today", color: Palette.blue) {
                    DayTimeline(events: events, loaded: eventsLoaded)
                }
            })
        }
        boxes += [
            PageBox("needsYou", "Needs you", color: Theme.coral) { needsYou },
            PageBox("time", "Where your time went", color: Palette.orchid, half: true) {
                DashCard(title: "Where your time went", color: Palette.orchid, action: { navigator.open(.projects) }) {
                    HoursDonut(slices: numbers.hoursThisMonth)
                }
            },
            PageBox("week", "The week ahead", color: Theme.teal, half: true) {
                DashCard(title: "The week ahead", color: Theme.teal) {
                    WeekStrip(projects: projects.active) { navigator.openProject($0) }
                }
            },
            PageBox("moneyIn", "Money in", color: Palette.lime, half: true) {
                DashCard(title: "Money in · last 6 months", color: Palette.lime, action: { navigator.open(.money) }) {
                    MoneyInChart(numbers: numbers)
                }
            },
            PageBox("funnel", "Where your jobs are", color: Palette.violet, half: true) {
                DashCard(title: "Where your jobs are", color: Palette.violet, action: { navigator.open(.projects) }) {
                    StageFunnel(steps: numbers.funnel)
                }
            },
            PageBox("numbers", "Key numbers", color: Palette.lime) { tiles(numbers).padding(.top, 14) },
            PageBox("autoFiled", "Filed by Lens this week", color: Theme.amber) {
                AutoFiledToday().frame(maxWidth: 720, alignment: .leading)
            },
        ]
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

    private func tiles(_ n: TodayNumbers) -> some View {
        let profit = n.thisMonth?.net ?? 0
        let last = n.months.dropLast().last?.net
        let hoursNow = n.weeksHours.last ?? 0
        let cards = Group {
            StatTile(label: "Owed to you", value: Money.short(n.owed),
                     note: n.owedCount == 0 ? "Nobody owes you" : n.overdueCount > 0 ? "\(n.overdueCount) overdue of \(n.owedCount)" : "\(n.owedCount) on the way",
                     color: Palette.gold, noteColor: n.overdueCount > 0 ? Theme.coral : Theme.text3) { navigator.open(.money) }
            StatTile(label: "Kept this month", value: profit < 0 ? "-\(Money.short(-profit))" : Money.short(profit),
                     note: last.map { profit >= $0 ? "Up from \(Money.short($0)) last month" : "Down from \(Money.short($0)) last month" } ?? "After costs",
                     color: Palette.lime, trend: n.months.map(\.net),
                     noteColor: last.map { profit >= $0 ? Palette.lime : Theme.text3 } ?? Theme.text3) { navigator.open(.money) }
            StatTile(label: "Open deals", value: Money.short(n.openDealsValue),
                     note: n.openDealsCount == 0 ? "No deals in play" : "\(n.openDealsCount) in play",
                     color: Palette.blue) { navigator.open(.pipeline) }
            StatTile(label: "Hours this week", value: Hours.short(hoursNow),
                     note: n.weeksHours.dropLast().isEmpty ? "" : "8 week trend", color: Palette.orchid,
                     trend: n.weeksHours) { navigator.open(.projects) }
            StatTile(label: "Win rate", value: n.winRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "None yet",
                     note: n.winRate == nil ? "Shows once a deal is won or lost" : "\(n.won) won, \(n.lost) lost",
                     color: Palette.mint) { navigator.open(.pipeline) }
        }
        // One row of five when there's room, otherwise they wrap.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { cards.frame(minWidth: 170, maxWidth: .infinity) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) { cards }
        }
    }

    // MARK: - Pieces

    private var header: some View {
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
            }
            Spacer()
            // Back from a networking event: cards go straight into People.
            Button("Scan a card") { scanningCard = true }
                .buttonStyle(SecondaryButtonStyle())
        }
        .sheet(isPresented: $scanningCard) { CardScanView() }
    }

    private var needsYou: some View {
        let all = items
        let shown = showAllItems ? all : Array(all.prefix(4))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                ColorLabel("Needs you · \(all.count)", all.contains { $0.tone == .overdue } ? Theme.coral : Theme.amber)
                Spacer()
                if all.count > 4 {
                    Button(showAllItems ? "Show fewer" : "Show all \(all.count)") {
                        withAnimation(.easeOut(duration: 0.2)) { showAllItems.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(Theme.font(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.teal)
                }
            }
            if all.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").foregroundStyle(Theme.teal)
                    Text("All clear. Nothing needs you right now.")
                        .font(Theme.font(size: 14)).foregroundStyle(Theme.text3)
                }
                .panel()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 10, alignment: .top)], alignment: .leading, spacing: 8) {
                    ForEach(shown) { item in needRow(item) }
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
    /// live in Money and Pipeline.
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
                ArrangeablePage("today", spacing: 30, boxes: simpleBoxes(all))
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.horizontal, 48)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .task { await loadEvents() }
    }

    private func simpleBoxes(_ all: [Item]) -> [PageBox] {
        var boxes: [PageBox] = []
        if logins.googleCalendarReady { boxes.append(PageBox("yourDay", "Your day", color: Palette.blue) { yourDay }) }
        boxes.append(PageBox("things", "A few things for you", color: Theme.coral) { thingsForYou(all) })
        boxes.append(PageBox("week", "The rest of your week", color: Theme.teal) { restOfWeek })
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
        let shown = showAllItems ? all : Array(all.prefix(4))
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(all.isEmpty ? "Nothing needs you" : "A few things for you")
                    .font(Theme.display(size: 22)).foregroundStyle(Theme.text)
                if all.count > 4 {
                    Button(showAllItems ? "Show fewer" : "See all \(all.count)") {
                        withAnimation(.easeOut(duration: 0.2)) { showAllItems.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(Theme.font(size: 14, weight: .bold))
                    .foregroundStyle(Theme.teal)
                }
            }
            if all.isEmpty {
                Text("All clear. Lens will put anything new here.")
                    .font(Theme.font(size: 15)).foregroundStyle(Theme.muted)
            }
            ForEach(shown) { item in
                let tint = simpleColor(item.tone)
                HStack(spacing: 16) {
                    Image(systemName: item.icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(tint)
                        .frame(width: 40, height: 40)
                        .background(tint.opacity(Theme.look == .daylight ? 0.14 : 0.22))
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(Theme.font(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                            .lineLimit(2)
                        Text("\(item.kicker). \(item.detail)")
                            .font(Theme.font(size: 14)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button(item.actionTitle, action: item.action).buttonStyle(PrimaryButtonStyle())
                }
                .panel(padding: 18)
            }
        }
    }

    private var restOfWeek: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let days = (1...6).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
        return VStack(alignment: .leading, spacing: 14) {
            Text("The rest of your week").font(Theme.display(size: 22)).foregroundStyle(Theme.text)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                ForEach(days, id: \.self) { day in
                    let plan = plans(on: day)
                    let shoot = projects.active.contains { $0.shootDate.map { cal.isDate($0, inSameDayAs: day) } ?? false }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(day.formatted(.dateTime.weekday(.wide)))
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
                    .padding(16)
                    .background(shoot ? Palette.mint.opacity(Theme.look == .daylight ? 0.12 : 0.18) : Theme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.look == .daylight || shoot ? Color.clear : Theme.line))
                }
            }
        }
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
        var result: [Item] = []

        if viewModel.roots.isEmpty && DriveCatalog.shared.outside.isEmpty {
            result.append(Item(tone: .neutral, kicker: "Getting started", title: "Add your drive",
                               detail: "Point Lens at the SSD so it can see the footage",
                               actionTitle: "Go to Library") { navigator.open(.footage) })
        } else if !viewModel.pluggedRoots.isEmpty && !viewModel.hasScanned {
            result.append(Item(tone: .neutral, kicker: "Getting started", title: "Scan the drive",
                               detail: "See what's on it and how much space can come back",
                               actionTitle: "Go to Library") { navigator.open(.footage) })
        }

        for project in projects.active {
            if let date = project.shootDate, isSoon(date), project.stage.rawValue <= ProjectStage.shoot.rawValue {
                result.append(Item(tone: .soon, kicker: relativeDay(date), title: project.name,
                                   detail: project.location.isEmpty ? "Shoot day" : "Shoot at \(project.location)",
                                   actionTitle: "Open project") { navigator.openProject(project.id) })
            }
            if project.stage == .delivered {
                result.append(Item(tone: .overdue, kicker: "Waiting on payment", title: project.name,
                                   detail: "Delivered. Mark it paid when the money lands",
                                   actionTitle: "Open project") { navigator.openProject(project.id) })
            }
            if project.stage == .paid, !project.isOnServer, project.folderPath != nil {
                result.append(Item(tone: .neutral, kicker: "Ready for the server", title: project.name,
                                   detail: "Delivered and paid. Its footage can leave the SSD",
                                   actionTitle: "Go to Library") { navigator.open(.footage) })
            }
        }

        for deal in deals.open where deal.stage == .inquiry {
            guard let due = deal.proposalDue, due < Date().addingTimeInterval(36 * 3600) else { continue }
            let late = due < Date()
            result.append(Item(tone: late ? .overdue : .soon,
                               kicker: late ? "Proposal overdue" : "Proposal due \(due.formatted(.dateTime.weekday(.wide).hour().minute()))",
                               title: deal.title,
                               detail: "\(BuilderStep.progress(deal)) of \(BuilderStep.allCases.count) sections done",
                               actionTitle: "Build proposal") { navigator.openBuilder(deal.id) })
        }

        for deal in deals.open.filter({ $0.isStale && !($0.stage == .inquiry && $0.proposalDue != nil) }).sorted(by: { (deals.value(of: $0) ?? 0) > (deals.value(of: $1) ?? 0) }) {
            result.append(Item(tone: .soon, kicker: "\(deal.stage.label) · \(deals.valueText(of: deal))", title: deal.title,
                               detail: DealCard.nextMove(deal),
                               actionTitle: "Open deal") { navigator.openDeal(deal.id) })
        }

        for person in people.followUpsDue {
            let date = person.followUp ?? Date()
            let late = !Calendar.current.isDateInToday(date)
            let detail = [person.followUpNote, person.subtitle].first { !$0.isEmpty } ?? "Time to check in"
            result.append(Item(tone: late ? .overdue : .soon,
                               kicker: late ? "Follow-up was due \(date.formatted(.dateTime.month(.abbreviated).day()))" : "Follow up today",
                               title: person.name, detail: detail,
                               actionTitle: "Open person") { navigator.openPerson(person.id) })
        }

        for item in people.goneQuiet.prefix(4) {
            result.append(Item(tone: .neutral, kicker: "Not in touch for \(item.days) days", title: item.person.name,
                               detail: "On \(item.deal.title), still open. Worth a hello?",
                               actionTitle: "Open person") { navigator.openPerson(item.person.id) })
        }

        if viewModel.hasScanned {
            let reclaim = viewModel.overview.cacheBytes + viewModel.overview.duplicateWastedBytes
            if reclaim > 0 {
                let full = viewModel.roots.first.flatMap(DriveInfo.capacity(for:)).map { "\(Int(($0.fractionUsed * 100).rounded()))% full" }
                result.append(Item(tone: .soon, kicker: full.map { "SSD \($0)" } ?? "Space to reclaim",
                                   title: "\(ByteFormat.string(reclaim)) can come back today",
                                   detail: "Premiere cache and duplicate copies",
                                   actionTitle: "Open Library") { navigator.open(.footage) })
            }
        }
        let p = logins.progress
        if p.done < p.total {
            result.append(Item(tone: .neutral, kicker: "Log-ins · \(p.done) of \(p.total) connected",
                               title: "Finish connecting your accounts",
                               detail: logins.googleConnected ? "Google is in. A few small ones left." : "Start with Google: it unlocks email, Zoom summaries and payments",
                               actionTitle: "Open Log-ins") { navigator.open(.logins) })
        }
        // Most urgent first, otherwise keep the order above.
        func rank(_ t: Item.Tone) -> Int { t == .overdue ? 0 : t == .soon ? 1 : 2 }
        return result.enumerated().sorted { (rank($0.element.tone), $0.offset) < (rank($1.element.tone), $1.offset) }.map(\.element)
    }

    private var briefing: String {
        var parts: [String] = []
        let soon = projects.active.filter { isSoon($0.shootDate) && $0.stage.rawValue <= ProjectStage.shoot.rawValue }
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
                                           : "\(nudges.count) deals need a nudge, starting with \(top.title).")
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

    private func isSoon(_ date: Date?) -> Bool {
        guard let date else { return false }
        let start = Calendar.current.startOfDay(for: Date())
        guard let end = Calendar.current.date(byAdding: .day, value: 7, to: start) else { return false }
        return date >= start && date < end
    }

    private func relativeDay(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today · \(date.formatted(date: .omitted, time: .shortened))" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow · \(date.formatted(date: .omitted, time: .shortened))" }
        return date.formatted(.dateTime.weekday(.wide).hour().minute())
    }

    private func color(for tone: Item.Tone) -> Color {
        switch tone {
        case .overdue: return Theme.coral
        case .soon: return Theme.amber
        case .neutral: return Palette.slate
        }
    }
}
