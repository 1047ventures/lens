import SwiftUI

/// Every gig before it's booked: a board from first message to won or lost.
struct PipelineView: View {
    @EnvironmentObject private var deals: DealStore
    @EnvironmentObject private var navigator: Navigator
    @State private var showNew = false
    @State private var showRates = false

    var body: some View {
        if let id = navigator.dealID, deals.deal(id: id) != nil {
            DealDetailView(dealID: id)
        } else {
            board
        }
    }

    private var board: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pipeline")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(Theme.text)
                        Text(summary)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 16)
                    Button("Rates & profile") { showRates = true }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("New inquiry") { showNew = true }
                        .buttonStyle(PrimaryButtonStyle())
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        column("New inquiry", deals.deals(in: .inquiry), color: DealStage.inquiry.color)
                        column("Proposal out", deals.deals(in: .proposalOut), color: DealStage.proposalOut.color)
                        column("Talking terms", deals.deals(in: .talking), color: DealStage.talking.color)
                        column("Closed lately", deals.recentlyClosed, color: Palette.slate, showTotal: false)
                    }
                    .padding(.bottom, 4)
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showNew) { NewDealSheet() }
        .sheet(isPresented: $showRates) { RateCardSheet() }
    }

    private var summary: String {
        let open = deals.open
        let total = open.compactMap { deals.value(of: $0) }.reduce(0, +)
        let stale = open.filter(\.isStale).count
        var text = "\(Money.string(total)) in play across \(open.count) open deal\(open.count == 1 ? "" : "s")"
        if stale > 0 { text += " · \(stale) need\(stale == 1 ? "s" : "") a nudge" }
        return text
    }

    private func column(_ title: String, _ items: [Deal], color: Color, showTotal: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ColorLabel("\(title) · \(items.count)", color)
                Spacer()
                if showTotal, !items.isEmpty {
                    Text(Money.short(items.compactMap { deals.value(of: $0) }.reduce(0, +)))
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text3)
                }
            }
            if items.isEmpty {
                Text("Nothing here")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            }
            Rectangle().fill(color.opacity(0.6)).frame(height: 2)
            ForEach(items) { deal in
                DealCard(deal: deal, accent: color)
            }
        }
        .frame(width: 250, alignment: .top)
    }
}

struct DealCard: View {
    @EnvironmentObject private var deals: DealStore
    @EnvironmentObject private var navigator: Navigator
    let deal: Deal
    var accent: Color = Palette.slate

    var body: some View {
        Button {
            navigator.openDeal(deal.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(deal.client)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                Text(deal.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(deals.valueText(of: deal))
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text2)
                    if deal.options.count > 1 && deal.chosenOption == nil {
                        Text("\(deal.options.count) options")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.raised)
                            .clipShape(Capsule())
                            .foregroundStyle(Theme.text3)
                    }
                    Spacer()
                }
                Text(DealCard.nextMove(deal))
                    .font(.system(size: 12))
                    .foregroundStyle(moveColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel)
            .accentBar(accent, cornerRadius: 12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(deal.isStale ? Theme.amber.opacity(0.55) : Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var moveColor: Color {
        switch deal.stage {
        case .won: return Theme.teal
        case .lost: return Theme.coral
        default: return deal.isStale ? Theme.amber : Theme.muted
        }
    }

    /// The one thing to do next, in plain words. Shared with Today.
    static func nextMove(_ deal: Deal) -> String {
        let days = deal.daysSinceTouch()
        let ago = days == 0 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"
        switch deal.stage {
        case .inquiry:
            if let due = deal.proposalDue {
                return due < Date() ? "Proposal was due \(due.formatted(.relative(presentation: .named)))"
                                    : "Call done · proposal due \(due.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
            }
            return deal.isStale ? "Came in \(ago). Reply and set up a call" : "Came in \(ago). Set up a call"
        case .proposalOut:
            return "Proposal sent \(ago)" + (deal.isStale ? ". Nudge them" : "")
        case .talking:
            if deal.options.count > 1 && deal.chosenOption == nil {
                return "Choosing between \(deal.options.count) options · last heard \(ago)" + (deal.isStale ? ". Nudge them" : "")
            }
            return "Last heard \(ago)" + (deal.isStale ? ". Nudge them" : "")
        case .won:
            return "Won · now a project"
        case .lost:
            return deal.lostReason.map { "Lost: \($0)" } ?? "Lost"
        }
    }
}

// MARK: - New inquiry

struct NewDealSheet: View {
    @EnvironmentObject private var deals: DealStore
    @EnvironmentObject private var navigator: Navigator
    @Environment(\.dismiss) private var dismiss

    @State private var client = ""
    @State private var title = ""
    @State private var source = "Email"
    @State private var budget = ""
    @State private var location = ""
    @State private var hasDate = false
    @State private var date = Date()
    @State private var notes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New inquiry")
                .font(.system(size: 20, weight: .bold))
            Text("Once the home server is running, inquiries from email and the website land here on their own, already filled in.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            Form {
                TextField("Client", text: $client)
                TextField("What's the job?", text: $title)
                Picker("Came in by", selection: $source) {
                    ForEach(["Email", "Website form", "Referral", "Instagram", "Phone"], id: \.self) { Text($0) }
                }
                TextField("What they said about budget", text: $budget)
                TextField("Location", text: $location)
                Toggle("Has a date", isOn: $hasDate)
                if hasDate { DatePicker("Date", selection: $date, displayedComponents: .date) }
                TextField("Notes from the message", text: $notes, axis: .vertical)
                    .lineLimit(3...6)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button("Add to pipeline") {
                    var deal = Deal(client: client, title: title.isEmpty ? client : title, source: source, stage: .inquiry,
                                    location: location, eventDate: hasDate ? date : nil, budgetHint: budget, callNotes: notes,
                                    lastTouch: Date(), createdAt: Date())
                    deal.events = [ProjectEvent(text: "Inquiry came in by \(source.lowercased())")]
                    deal.options = [ScopeOption.starter()]
                    deals.add(deal)
                    navigator.openDeal(deal.id)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(client.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

// MARK: - Rate card

struct RateCardSheet: View {
    @EnvironmentObject private var deals: DealStore
    @Environment(\.dismiss) private var dismiss
    @State private var card = RateCard()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rates & profile")
                .font(.system(size: 20, weight: .bold))
            Text("Every proposal is calculated from these. The starting numbers were worked back from the CEJ options budgets.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            Form {
                Section("Proposals come from") {
                    TextField("Your name", text: $card.ownerName)
                    TextField("Business name", text: $card.businessName)
                    TextField("Email", text: $card.email)
                    TextField("Website", text: $card.website)
                }
                Section("Day rates") {
                    money("Your day rate", $card.emmaDayRate)
                    money("Collaborator day rate (charged)", $card.collaboratorDayRate)
                    money("Collaborator day cost (what you pay)", $card.collaboratorDayCost)
                }
                Section("Hourly rates") {
                    money("Planning", $card.planningHourly)
                    money("Editing", $card.editHourly)
                    money("Media management", $card.mediaHourly)
                }
                Section("When you hand work off (what you pay per hour)") {
                    money("Planning and research", $card.planningCostHourly)
                    money("Editing", $card.editCostHourly)
                    money("Media management", $card.mediaCostHourly)
                }
                Section("Rules of thumb (hours)") {
                    number("Edit hours per finished minute", $card.editPerFilmMinute)
                    number("Edit hours per revision round", $card.editPerRevisionRound)
                    number("Planning hours per shoot day", $card.planningPerShootDay)
                    number("Planning hours per interviewee", $card.planningPerInterviewee)
                }
                Section("Goals") {
                    money("Take-home per hour you aim for", $card.targetHourly)
                    money("Round quotes to", $card.roundTo)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button("Save") { deals.rates = card; dismiss() }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(24)
        .frame(width: 520, height: 640)
        .onAppear { card = deals.rates }
    }

    private func money(_ label: String, _ value: Binding<Double>) -> some View {
        TextField(label, value: value, format: .currency(code: "USD").precision(.fractionLength(0)))
            .multilineTextAlignment(.trailing)
    }

    private func number(_ label: String, _ value: Binding<Double>) -> some View {
        TextField(label, value: value, format: .number)
            .multilineTextAlignment(.trailing)
    }
}


extension DealStage {
    /// Each column of the board has its own colour, carried onto its cards.
    var color: Color {
        switch self {
        case .inquiry: return Palette.blue
        case .proposalOut: return Palette.violet
        case .talking: return Palette.orchid
        case .won: return Palette.mint
        case .lost: return Palette.slate
        }
    }
}
