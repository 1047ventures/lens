import SwiftUI

/// The home screen: only what needs attention right now, built from projects and the last scan.
struct TodayView: View {
    @EnvironmentObject private var viewModel: ScanViewModel
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var deals: DealStore
    @EnvironmentObject private var logins: ConnectionStore
    @EnvironmentObject private var people: PeopleStore
    @EnvironmentObject private var navigator: Navigator
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
    }

    @EnvironmentObject private var money: MoneyStore
    @State private var events: [LensCalendarEvent] = []
    @State private var eventsLoaded = false
    @State private var openItems: Set<String> = []
    @State private var showAllItems = false

    var body: some View {
        let numbers = TodayNumbers(money: money, deals: deals, projects: projects)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if logins.googleCalendarReady {
                    DashCard(title: "Today", color: Palette.blue) {
                        DayTimeline(events: events, loaded: eventsLoaded)
                    }
                }
                needsYou
                tiles(numbers)
                    .padding(.top, 14)
                pair {
                    DashCard(title: "Money in · last 6 months", color: Palette.lime, action: { navigator.open(.money) }) {
                        MoneyInChart(numbers: numbers)
                    }
                } right: {
                    DashCard(title: "Where your time went", color: Palette.orchid, action: { navigator.open(.projects) }) {
                        HoursDonut(slices: numbers.hoursThisMonth)
                    }
                }
                pair {
                    DashCard(title: "Lead to paid", color: Palette.violet, action: { navigator.open(.projects) }) {
                        StageFunnel(steps: numbers.funnel)
                    }
                } right: {
                    DashCard(title: "The week ahead", color: Theme.teal) {
                        WeekStrip(projects: projects.active) { navigator.openProject($0) }
                    }
                }
                AutoFiledToday()
                    .frame(maxWidth: 720, alignment: .leading)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 34)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await loadEvents() }
    }

    private func loadEvents() async {
        guard logins.googleCalendarReady else { return }
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        let found = await logins.calendarEvents(from: start, to: end)
        var seen = Set<String>()
        events = found.filter { seen.insert("\($0.title)|\($0.start)").inserted }
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
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.muted)
                Text("\(greeting)\(firstName.map { ", \($0)" } ?? "")")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(Theme.text)
                Text(briefing)
                    .font(.system(size: 15))
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.teal)
                }
            }
            if all.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle").foregroundStyle(Theme.teal)
                    Text("All clear. Nothing needs you right now.")
                        .font(.system(size: 14)).foregroundStyle(Theme.text3)
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
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(item.kicker)
                        .font(.system(size: 12))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
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
                        .font(.system(size: 12.5))
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
                                   detail: "Delivered — mark it paid when the money lands",
                                   actionTitle: "Open project") { navigator.openProject(project.id) })
            }
            if project.stage == .paid, !project.isOnServer, project.folderPath != nil {
                result.append(Item(tone: .neutral, kicker: "Ready for the server", title: project.name,
                                   detail: "Delivered and paid — its footage can leave the SSD",
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
