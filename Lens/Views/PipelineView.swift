import SwiftUI

/// Every gig before it's booked: a board from first message to won or lost.
struct PipelineView: View {
    @EnvironmentObject private var deals: DealStore
    @EnvironmentObject private var navigator: Navigator
    @EnvironmentObject private var appearance: Appearance
    @State private var showNew = false
    @State private var closedOpen: Set<String> = []
    @State private var showRates = false
    @State private var showQuotes = false

    var body: some View {
        if let id = navigator.dealID, deals.deal(id: id) != nil {
            DealDetailView(dealID: id)
        } else if appearance.simple {
            simpleInquiries
        } else {
            board
        }
    }

    // MARK: - Simple

    private enum SimpleKind { case reply, quote, waiting, booked, lost }

    private func simpleGroup(_ title: String, _ kind: SimpleKind, _ items: [Deal], collapsible: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if collapsible {
                Button {
                    withAnimation { if closedOpen.contains(title) { closedOpen.remove(title) } else { closedOpen.insert(title) } }
                } label: {
                    HStack(spacing: 8) {
                        Text("\(title) · \(items.count)")
                            .font(Theme.display(size: 20)).foregroundStyle(Theme.text)
                        Image(systemName: closedOpen.contains(title) ? "chevron.down" : "chevron.right")
                            .font(Theme.font(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if closedOpen.contains(title) { ForEach(items) { simpleCard($0, kind) } }
            } else {
                Text(title).font(Theme.display(size: 20)).foregroundStyle(Theme.text)
                ForEach(items) { simpleCard($0, kind) }
            }
        }
    }

    /// The groups that have someone in them, in their usual order; she can rearrange or hide them.
    private func simpleBoxes(needReply: [Deal], needQuote: [Deal], waiting: [Deal], booked: [Deal], lost: [Deal]) -> [PageBox] {
        var boxes: [PageBox] = []
        if !needReply.isEmpty { boxes.append(PageBox("reply", "Reply to these", color: Theme.coral) { simpleGroup("Reply to these", .reply, needReply) }) }
        if !needQuote.isEmpty { boxes.append(PageBox("quote", "Send a quote", color: Theme.amber) { simpleGroup("Send a quote", .quote, needQuote) }) }
        if !waiting.isEmpty { boxes.append(PageBox("waiting", "Waiting to hear back", color: Palette.blue) { simpleGroup("Waiting to hear back", .waiting, waiting) }) }
        if !booked.isEmpty { boxes.append(PageBox("booked", "Booked", color: Palette.lime) { simpleGroup("Booked", .booked, booked, collapsible: true) }) }
        if !lost.isEmpty { boxes.append(PageBox("lost", "Didn't go ahead", color: Palette.slate) { simpleGroup("Didn't go ahead", .lost, lost, collapsible: true) }) }
        return boxes
    }

    private var simpleInquiries: some View {
        let inquiries = deals.deals(in: .inquiry)
        // A call has happened (or is booked): the next job is the quote itself.
        let needQuote = inquiries.filter { $0.disc.callDate != nil }
        let needReply = inquiries.filter { $0.disc.callDate == nil }
        let waiting = (deals.deals(in: .proposalOut) + deals.deals(in: .talking)).sorted { $0.lastTouch < $1.lastTouch }
        let booked = deals.deals(in: .won)
        let lost = deals.deals(in: .lost)
        let anyOpen = !(needReply.isEmpty && needQuote.isEmpty && waiting.isEmpty)
        return ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Inquiries")
                            .font(Theme.display(size: 34))
                            .foregroundStyle(Theme.text)
                        Text("People who've asked about working with you, and what each one needs next.")
                            .font(Theme.font(size: 15))
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button("New inquiry") { showNew = true }
                        .buttonStyle(PrimaryButtonStyle())
                }
                EmailSuggestionsPanel(place: .pipeline)
                UnmatchedNotesPanel()
                if !anyOpen {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No one is waiting on you")
                            .font(Theme.display(size: 20)).foregroundStyle(Theme.text)
                        Text("When someone asks about working with you, they will show up here. You can also add one with New inquiry.")
                            .font(Theme.font(size: 14)).foregroundStyle(Theme.muted)
                    }
                    .panel(padding: 22)
                }
                ArrangeablePage("inquiries", spacing: 28, boxes: simpleBoxes(needReply: needReply, needQuote: needQuote,
                                                                           waiting: waiting, booked: booked, lost: lost))
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 40)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showNew) { NewDealSheet() }
    }

    private func simpleAgo(_ deal: Deal) -> String {
        let days = deal.daysSinceTouch()
        return days == 0 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"
    }

    /// The price line for a card: the quoted amount, else "Budget: <what they said>", else nothing.
    private func simplePrice(_ deal: Deal) -> String? {
        if !deal.options.isEmpty || deal.chosenOption != nil { return deals.valueText(of: deal) }
        let hint = deal.budgetHint.trimmingCharacters(in: .whitespaces)
        return hint.isEmpty ? nil : "Budget: \(hint)"
    }

    private func simpleCard(_ deal: Deal, _ kind: SimpleKind) -> some View {
        let days = deal.daysSinceTouch()
        let nudge = kind == .waiting && days >= 7
        let heard: String
        switch kind {
        case .reply: heard = "Came in \(simpleAgo(deal))"
        case .quote: heard = "Ready for a quote. Last talked \(simpleAgo(deal))"
        case .waiting: heard = "Quote sent, last heard \(simpleAgo(deal))" + (nudge ? ". It may be time for a gentle nudge." : "")
        case .booked: heard = "Booked, now a project"
        case .lost: heard = deal.lostReason.map { "Didn't go ahead: \($0)" } ?? "Didn't go ahead"
        }
        let action: (title: String, run: () -> Void)? = {
            switch kind {
            case .reply: return ("Open deal", { navigator.openDeal(deal.id) })
            case .quote: return ("Build proposal", { navigator.openDeal(deal.id); navigator.openBuilder(deal.id) })
            case .waiting: return (nudge ? "Nudge them" : "Open deal", { navigator.openDeal(deal.id) })
            default: return nil
            }
        }()
        return Button {
            navigator.openDeal(deal.id)
        } label: {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(deal.client.isEmpty ? deal.title : deal.client)
                        .font(Theme.display(size: 19)).foregroundStyle(Theme.text)
                    if !deal.client.isEmpty && !deal.title.isEmpty {
                        Text(deal.title)
                            .font(Theme.font(size: 14)).foregroundStyle(Theme.text2)
                            .lineLimit(1)
                    }
                    if kind != .lost, let price = simplePrice(deal) {
                        Text(price)
                            .font(Theme.font(size: 13)).foregroundStyle(Theme.muted)
                    }
                    Text(heard)
                        .font(Theme.font(size: 13)).foregroundStyle(nudge ? Theme.amber : Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if let action {
                    Button(action.title, action: action.run)
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .panel(padding: 20)
    }

    private var board: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pipeline")
                            .font(Theme.font(size: 30, weight: .bold))
                            .foregroundStyle(Theme.text)
                        Text(summary)
                            .font(Theme.font(size: 15))
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 16)
                    Button("Past quotes") { showQuotes = true }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Rates & profile") { showRates = true }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("New inquiry") { showNew = true }
                        .buttonStyle(PrimaryButtonStyle())
                }

                EmailSuggestionsPanel(place: .pipeline)
                UnmatchedNotesPanel()

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        // Inquiry, then quote, then (once booked) it becomes a project and leaves Pipeline.
                        column("New inquiries", deals.deals(in: .inquiry), color: DealStage.inquiry.color)
                        column("Quote sent", deals.deals(in: .proposalOut) + deals.deals(in: .talking), color: DealStage.proposalOut.color)
                        column("Booked or passed lately", deals.recentlyClosed, color: Palette.slate, showTotal: false)
                    }
                    .padding(.bottom, 4)
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showNew) { NewDealSheet() }
        .sheet(isPresented: $showRates) { RateCardSheet() }
        .sheet(isPresented: $showQuotes) { QuoteHistoryView() }
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
                        .font(Theme.font(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text3)
                }
            }
            if items.isEmpty {
                Text("Nothing here")
                    .font(Theme.font(size: 13))
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
                    .font(Theme.font(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                Text(deal.title)
                    .font(Theme.font(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(deals.valueText(of: deal))
                        .font(Theme.font(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text2)
                    if deal.options.count > 1 && deal.chosenOption == nil {
                        Text("\(deal.options.count) options")
                            .font(Theme.font(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.raised)
                            .clipShape(Capsule())
                            .foregroundStyle(Theme.text3)
                    }
                    Spacer()
                }
                Text(DealCard.nextMove(deal))
                    .font(Theme.font(size: 12))
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
            return "Booked"
        case .lost:
            return deal.lostReason.map { "Didn't book: \($0)" } ?? "Didn't book"
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
                .font(Theme.font(size: 20, weight: .bold))
            Text("Once the home server is running, inquiries from email and the website land here on their own, already filled in.")
                .font(Theme.font(size: 12))
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
                .font(Theme.font(size: 20, weight: .bold))
            Text("Every proposal is calculated from these. The starting numbers were worked back from the CEJ options budgets.")
                .font(Theme.font(size: 12))
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
                    money("Your half day rate", $card.halfDay)
                    money("Your hourly filming rate", $card.shootHourly)
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
