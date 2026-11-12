import SwiftUI

/// The home screen: only what needs attention right now, built from projects and the last scan.
struct TodayView: View {
    @EnvironmentObject private var viewModel: ScanViewModel
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var deals: DealStore
    @EnvironmentObject private var logins: ConnectionStore
    @EnvironmentObject private var navigator: Navigator

    private struct Item: Identifiable {
        enum Tone { case overdue, soon, neutral }
        let id = UUID()
        let tone: Tone
        let kicker: String
        let title: String
        let detail: String
        let actionTitle: String
        let action: () -> Void
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header
                Text(briefing)
                    .font(.system(size: 19))
                    .lineSpacing(5)
                    .foregroundStyle(Theme.text2)
                    .frame(maxWidth: 720, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) {
                        needsYou.frame(minWidth: 420)
                        thisWeek.frame(width: 300)
                    }
                    VStack(alignment: .leading, spacing: 28) {
                        needsYou
                        thisWeek
                    }
                }
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.muted)
            Text("\(greeting)\(firstName.map { ", \($0)" } ?? "")")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(Theme.text)
        }
    }

    private var needsYou: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Needs you · \(items.count)")
            if items.isEmpty {
                Text("Nothing needs you right now.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text3)
                    .panel()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().overlay(Theme.lineSoft) }
                        HStack(alignment: .center, spacing: 16) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.kicker)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(color(for: item.tone))
                                Text(item.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                Text(item.detail)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.muted)
                            }
                            Spacer(minLength: 12)
                            Button(item.actionTitle, action: item.action)
                                .buttonStyle(SecondaryButtonStyle())
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                    }
                }
                .background(Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
            }
        }
    }

    private var thisWeek: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Coming up")
            let upcoming = projects.active.filter { $0.shootDate.map { $0 >= Calendar.current.startOfDay(for: Date()) } ?? false }
            if upcoming.isEmpty {
                Text("No shoots on the calendar.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text3)
            } else {
                VStack(spacing: 0) {
                    ForEach(upcoming.prefix(5)) { project in
                        Button {
                            navigator.openProject(project.id)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(project.shootDate?.formatted(.dateTime.weekday(.abbreviated).day()) ?? "")
                                    .font(.system(size: 13))
                                    .foregroundStyle(isSoon(project.shootDate) ? Theme.amber : Theme.muted)
                                    .frame(width: 54, alignment: .leading)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(project.name)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Theme.text)
                                    StageBar(stage: project.stage).frame(maxWidth: 160)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Theme.lineSoft)
                    }
                }
            }
        }
    }

    // MARK: - Data

    private var items: [Item] {
        var result: [Item] = []

        if viewModel.roots.isEmpty && DriveCatalog.shared.outside.isEmpty {
            result.append(Item(tone: .neutral, kicker: "Getting started", title: "Add Emma's drive",
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
                               title: "Finish connecting Emma's accounts",
                               detail: logins.googleConnected ? "Google is in. A few small ones left." : "Start with Google: it unlocks email, Zoom summaries and payments",
                               actionTitle: "Open Log-ins") { navigator.open(.logins) })
        }
        return result
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
        if viewModel.hasScanned {
            let reclaim = viewModel.overview.cacheBytes + viewModel.overview.duplicateWastedBytes
            if reclaim > 0 { parts.append("About \(ByteFormat.string(reclaim)) of the SSD is safe to clear.") }
        }
        if parts.isEmpty {
            return projects.projects.isEmpty
                ? "Start by adding Emma's drive in Library, then turn its folders into projects."
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
        case .neutral: return Theme.muted
        }
    }
}
