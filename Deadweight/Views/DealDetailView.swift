import SwiftUI

/// One potential gig: the options and their live prices, the budget and workload the
/// proposal will show, what Emma actually keeps, and the words of the pitch.
struct DealDetailView: View {
    @EnvironmentObject private var deals: DealStore
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var navigator: Navigator
    let dealID: UUID

    @State private var selectedOptionID: UUID?
    @State private var showStory = false
    @State private var showFollowUp = false
    @State private var showLost = false
    @State private var showWon = false

    private var deal: Deal? { deals.deal(id: dealID) }

    var body: some View {
        if navigator.builderDealID == dealID {
            ProposalBuilderView(dealID: dealID)
        } else if let deal {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Button {
                        navigator.dealID = nil
                    } label: {
                        Label("Pipeline", systemImage: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.text3)
                    }
                    .buttonStyle(.plain)

                    header(deal)
                    actions(deal)
                    checks(deal)
                    optionsSection(deal)
                    if let option = selectedOption(deal) {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 18) {
                                budget(option).frame(minWidth: 380)
                                workload(option).frame(minWidth: 380)
                            }
                            VStack(alignment: .leading, spacing: 18) {
                                budget(option)
                                workload(option)
                            }
                        }
                    }
                    storySection(deal)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) {
                            planColumn(deal).frame(minWidth: 380)
                            peopleColumn(deal).frame(minWidth: 380)
                        }
                        VStack(alignment: .leading, spacing: 18) {
                            planColumn(deal)
                            peopleColumn(deal)
                        }
                    }
                }
                .padding(40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .sheet(isPresented: $showStory) { StoryEditor(dealID: dealID) }
            .sheet(isPresented: $showFollowUp) { FollowUpSheet(dealID: dealID) }
            .sheet(isPresented: $showLost) { LostSheet(dealID: dealID) }
            .sheet(isPresented: $showWon) { WonSheet(dealID: dealID) }
        }
    }

    private func selectedOption(_ deal: Deal) -> ScopeOption? {
        deal.options.first { $0.id == selectedOptionID } ?? deal.chosenOption ?? deal.options.first
    }

    // MARK: - Header and actions

    private func header(_ deal: Deal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(deal.client) · came in by \(deal.source.lowercased())")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.muted)
            HStack(alignment: .firstTextBaseline) {
                Text(deal.title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 20)
                HeadlineNumber(text: deals.valueText(of: deal), size: 30)
            }
            HStack(spacing: 6) {
                ForEach([DealStage.inquiry, .proposalOut, .talking, deal.stage == .lost ? .lost : .won]) { stage in
                    Text(stage.label)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(stage == deal.stage ? (stage == .lost ? Theme.coral.opacity(0.25) : Theme.teal.opacity(0.22)) : Theme.raised)
                        .foregroundStyle(stage == deal.stage ? Theme.text : (stage.rawValue < deal.stage.rawValue ? Theme.text3 : Theme.muted))
                        .clipShape(Capsule())
                }
                Spacer()
                Text(DealCard.nextMove(deal))
                    .font(.system(size: 13))
                    .foregroundStyle(deal.isStale ? Theme.amber : Theme.muted)
            }
        }
    }

    private func actions(_ deal: Deal) -> some View {
        HStack(spacing: 10) {
            switch deal.stage {
            case .inquiry:
                EmptyView()
            case .proposalOut:
                Button("They're talking terms") { deals.setStage(.talking, for: deal, note: "Talking terms") }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Mark won…") { showWon = true }.buttonStyle(SecondaryButtonStyle())
            case .talking:
                Button("Mark won…") { showWon = true }.buttonStyle(PrimaryButtonStyle())
            case .won:
                if let id = deal.projectID {
                    Button("Open the project") { navigator.openProject(id) }.buttonStyle(PrimaryButtonStyle())
                }
            case .lost:
                Button("Reopen") { deals.setStage(.talking, for: deal, note: "Reopened") }.buttonStyle(SecondaryButtonStyle())
            }
            Button("Build proposal · \(BuilderStep.progress(deal))/\(BuilderStep.allCases.count)") { navigator.builderDealID = deal.id }
                .buttonStyle(deal.stage == .inquiry ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(SecondaryButtonStyle()))
            Button("Preview proposal") { ProposalRenderer.open(deal, store: deals, projects: projects) }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(deal.options.isEmpty)
            if deal.stage.isOpen {
                Button("Log a follow-up") { showFollowUp = true }.buttonStyle(SecondaryButtonStyle())
                Button("Mark lost…") { showLost = true }.buttonStyle(SecondaryButtonStyle())
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func checks(_ deal: Deal) -> some View {
        let found = deal.options.flatMap { option in deals.estimate(option).checks.map { "\(option.name): \($0)" } }
        if !found.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ColorLabel("Worth a second look", Theme.amber)
                ForEach(found, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Theme.amber).frame(width: 6, height: 6)
                        Text(line).font(.system(size: 13)).foregroundStyle(Theme.text2)
                    }
                }
            }
            .panel(padding: 18)
            .accentBar(Theme.amber)
        }
    }

    // MARK: - Options

    private func optionsSection(_ deal: Deal) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ColorLabel(deal.options.count > 1 ? "Options · \(deal.options.count)" : "Scope", Palette.blue)
                Spacer()
                if deal.options.count == 1 {
                    Button("Offer three options") {
                        var d = deal
                        d.options = d.options[0].threeWays()
                        selectedOptionID = d.options.first?.id
                        deals.update(d)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Button("Add option") {
                    var d = deal
                    var option = d.options.last ?? .starter()
                    option.id = UUID()
                    option.name = "Option \(Character(UnicodeScalar(65 + min(d.options.count, 25))!))"
                    d.options.append(option)
                    deals.update(d)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            if deal.options.isEmpty {
                Text("No scope yet. Add an option to start pricing this job.")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted).panel()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(deal.options) { option in
                        OptionColumn(dealID: deal.id, optionID: option.id,
                                     isSelected: selectedOption(deal)?.id == option.id,
                                     isChosen: deal.chosenOptionID == option.id,
                                     canRemove: deal.options.count > 1) {
                            selectedOptionID = option.id
                        }
                    }
                }
            }
        }
    }

    // MARK: - Budget and workload

    private func budget(_ option: ScopeOption) -> some View {
        let est = deals.estimate(option)
        return VStack(alignment: .leading, spacing: 12) {
            ColorLabel("Budget · \(option.name)", Palette.lime)
            VStack(spacing: 0) {
                ForEach(est.clientLines) { line in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.category).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                            if !line.detail.isEmpty {
                                Text(line.detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                        }
                        Spacer()
                        Text(Money.string(line.amount)).font(.system(size: 13)).monospacedDigit().foregroundStyle(Theme.text2)
                    }
                    .padding(.vertical, 8)
                    Divider().overlay(Theme.lineSoft)
                }
                if est.travelAllowance > 0 {
                    row("Travel allowance", Money.string(est.travelAllowance))
                    Divider().overlay(Theme.lineSoft)
                }
                row("Total to the client", Money.string(est.total), bold: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                ColorLabel("What you keep", Palette.lime)
                row("Collaborators", "−\(Money.string(est.collaboratorCost))")
                row("Drives, music, gear, assistant", "−\(Money.string(est.hardCosts))")
                if est.handOffCost > 0 {
                    row("Handed-off work (\(Int(est.handOffHours.rounded())) h)", "−\(Money.string(est.handOffCost))")
                }
                row("Your take-home", Money.string(est.takeHome), bold: true)
                if est.handOffCost > 0 {
                    Text("You net \(Money.string(est.handOffMargin)) on handed-off work without doing the hours yourself.")
                        .font(.system(size: 12)).foregroundStyle(Theme.teal)
                }
                HStack {
                    Text("About \(Int(est.emmaHours.rounded())) of your hours")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    Spacer()
                    Text("\(Money.string(est.takeHomePerHour))/hr")
                        .font(.system(size: 15, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(est.takeHomePerHour >= deals.rates.targetHourly ? Theme.teal : Theme.amber)
                }
            }
            .padding(.top, 6)
        }
        .panel()
        .accentBar(Palette.lime)
    }

    private func row(_ label: String, _ value: String, bold: Bool = false) -> some View {
        HStack {
            Text(label).font(.system(size: 13, weight: bold ? .semibold : .regular)).foregroundStyle(bold ? Theme.text : Theme.text3)
            Spacer()
            Text(value).font(.system(size: 13, weight: bold ? .semibold : .regular)).monospacedDigit().foregroundStyle(Theme.text)
        }
        .padding(.vertical, 6)
    }

    private func workload(_ option: ScopeOption) -> some View {
        let est = deals.estimate(option)
        return VStack(alignment: .leading, spacing: 12) {
            ColorLabel("Workload · \(option.name)", Palette.gold)
            VStack(spacing: 0) {
                ForEach(est.workload) { item in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                            Text(item.detail).font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Text("\(item.hoursText) h").font(.system(size: 13)).monospacedDigit().foregroundStyle(Theme.text2)
                    }
                    .padding(.vertical, 8)
                    Divider().overlay(Theme.lineSoft)
                }
                row("Combined team hours", "\(Estimate.range(est.teamHoursLow, est.teamHoursHigh)) h", bold: true)
            }
            Text("Calculated from your rate card. This is the table the proposal shows the client.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
        .panel()
        .accentBar(Palette.gold)
    }

    // MARK: - Story

    private func storySection(_ deal: Deal) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ColorLabel("The pitch", Palette.violet)
                Spacer()
                Button("Draft from call notes") {}
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(true)
                    .help("Needs the home server: the local AI drafts these words from the inquiry and call notes")
                Button(deal.story.isEmpty ? "Write it" : "Edit words") { showStory = true }
                    .buttonStyle(SecondaryButtonStyle())
            }
            if deal.story.isEmpty {
                Text("No words yet. The proposal will use the job title as its headline until you add some.")
                    .font(.system(size: 14)).foregroundStyle(Theme.muted)
            } else {
                Text(deal.story.headline)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if !deal.story.logline.isEmpty {
                    Text(deal.story.logline).font(.system(size: 14)).foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 12) {
                    ForEach(deal.story.pillars) { pillar in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(pillar.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                            Text(pillar.text).font(.system(size: 12)).foregroundStyle(Theme.muted)
                                .lineLimit(4)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .background(Theme.raised)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
        .panel()
        .accentBar(Palette.violet)
    }

    // MARK: - Plan and people

    private func planColumn(_ deal: Deal) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            if !deal.milestones.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ColorLabel("Timeline", Palette.orchid)
                    ForEach(deal.milestones) { m in
                        HStack {
                            Text(m.phase).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                            Spacer()
                            Text(m.when).font(.system(size: 13)).foregroundStyle(Theme.muted)
                        }
                    }
                }
                .panel()
                .accentBar(Palette.orchid)
            }
            if !deal.nextSteps.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ColorLabel("Next steps", Palette.mint)
                    ForEach(deal.nextSteps) { step in
                        Button {
                            var d = deal
                            if let i = d.nextSteps.firstIndex(where: { $0.id == step.id }) {
                                d.nextSteps[i].done.toggle()
                                if d.nextSteps[i].done { d.events.append(ProjectEvent(text: "Done: \(step.text)")) }
                                deals.update(d)
                            }
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(step.done ? Theme.teal : Theme.muted)
                                Text(step.text).font(.system(size: 13))
                                    .foregroundStyle(step.done ? Theme.muted : Theme.text2)
                                    .strikethrough(step.done)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .panel()
                .accentBar(Palette.mint)
            }
            VStack(alignment: .leading, spacing: 10) {
                ColorLabel("The story so far", Palette.slate)
                ForEach(deal.events.reversed()) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(event.date.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.system(size: 12)).foregroundStyle(Theme.muted).frame(width: 52, alignment: .leading)
                        Text(event.text).font(.system(size: 13)).foregroundStyle(Theme.text2)
                    }
                }
            }
            .panel()
            .accentBar(Palette.slate)
        }
    }

    private func peopleColumn(_ deal: Deal) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                ColorLabel("Details", Palette.sand)
                if !deal.contacts.isEmpty {
                    ForEach(deal.contacts) { c in
                        HStack(alignment: .firstTextBaseline) {
                            Text(c.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                            Text(c.role).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            Spacer()
                            if !c.email.isEmpty { Text(c.email).font(.system(size: 12)).foregroundStyle(Theme.text3) }
                        }
                    }
                }
                if !deal.location.isEmpty { detail("Where", deal.location) }
                if let date = deal.eventDate { detail("When", date.formatted(date: .abbreviated, time: .omitted)) }
                if !deal.budgetHint.isEmpty { detail("Budget they mentioned", deal.budgetHint) }
                ForEach(deal.originalLinks, id: \.self) { link in
                    if let url = URL(string: link) {
                        Link("Original deck ↗", destination: url).font(.system(size: 13))
                    }
                }
            }
            .panel()
            .accentBar(Palette.sand)
            if !deal.callNotes.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ColorLabel("Notes", Palette.rose)
                    Text(deal.callNotes).font(.system(size: 13)).foregroundStyle(Theme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .panel()
                .accentBar(Palette.rose)
            }
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.muted).frame(width: 140, alignment: .leading)
            Text(value).font(.system(size: 13)).foregroundStyle(Theme.text2)
            Spacer()
        }
    }
}

// MARK: - One option's dials and live price

struct OptionColumn: View {
    @EnvironmentObject private var deals: DealStore
    let dealID: UUID
    let optionID: UUID
    let isSelected: Bool
    let isChosen: Bool
    let canRemove: Bool
    let onSelect: () -> Void

    private var option: ScopeOption? { deals.deal(id: dealID)?.options.first { $0.id == optionID } }

    var body: some View {
        if let option {
            let est = deals.estimate(option)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Name", text: bind(\.name))
                            .textFieldStyle(.plain)
                            .font(.system(size: 15, weight: .bold))
                        TextField("Tagline", text: bind(\.tagline))
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                    }
                    if isChosen {
                        Text("Chosen").font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.teal.opacity(0.25)).clipShape(Capsule())
                    }
                    if canRemove {
                        Button {
                            guard var d = deals.deal(id: dealID) else { return }
                            d.options.removeAll { $0.id == optionID }
                            deals.update(d)
                        } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.muted)
                        .help("Remove this option")
                    }
                }

                VStack(spacing: 6) {
                    Dial("Local days", bind(\.localDays), 0...30)
                    Dial("Out-of-state days", bind(\.travelDays), 0...10)
                    Dial("Crew beside you", bind(\.localCrew), 0...6)
                    Dial("Cameras", bind(\.cameraCount), 1...6)
                    Dial("Interviewees", bind(\.interviewees), 0...20)
                    Dial("Film minutes", bind(\.filmMinutes), 1...60)
                    Dial("Revision rounds", bind(\.revisionRounds), 0...6)
                }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Extra.allCases) { extra in
                        Toggle(isOn: Binding(
                            get: { option.extras.contains(extra) },
                            set: { on in
                                update { o in
                                    if on { o.extras.append(extra) } else { o.extras.removeAll { $0 == extra } }
                                    o.extras = Extra.allCases.filter(o.extras.contains)
                                }
                            })) {
                            Text(extra.shortLabel).font(.system(size: 12)).foregroundStyle(Theme.text3)
                        }
                        .toggleStyle(.checkbox)
                    }
                    if !option.clientTakesOn.isEmpty {
                        Text("Client takes on \(option.clientTakesOn.count) planning tasks")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted).padding(.top, 4)
                    }
                    Text("Hand off").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted).padding(.top, 6)
                    HStack(spacing: 6) {
                        ForEach(WorkType.allCases) { work in
                            let on = option.handedOff.contains(work)
                            Button {
                                update { o in
                                    var set = o.handedOff
                                    if on { set.remove(work) } else { set.insert(work) }
                                    o.handOff = WorkType.allCases.filter(set.contains)
                                }
                            } label: {
                                Text(work.shortLabel)
                                    .font(.system(size: 10, weight: .semibold))
                                    .lineLimit(1)
                                    .fixedSize()
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(on ? Theme.teal.opacity(0.25) : Theme.raised)
                                    .foregroundStyle(on ? Theme.text : Theme.muted)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help(on ? "Someone cheaper does the \(work.label.lowercased()); you keep the difference" : "You do the \(work.label.lowercased()) yourself")
                        }
                    }
                    if option.travelDays > 0 {
                        HStack {
                            Text("Travel allowance").font(.system(size: 12)).foregroundStyle(Theme.text3)
                            Spacer()
                            TextField("0", value: bind(\.travelAllowance), format: .number)
                                .textFieldStyle(.roundedBorder).frame(width: 80).multilineTextAlignment(.trailing)
                        }
                        .padding(.top, 4)
                    }
                }

                Divider().overlay(Theme.line)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Your rates say").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        Spacer()
                        Text(Money.string(est.calculated)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.text3)
                    }
                    HStack {
                        Text("Quote").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        Spacer()
                        TextField(Money.string(est.calculated), text: quoteText)
                            .textFieldStyle(.roundedBorder).frame(width: 96).multilineTextAlignment(.trailing)
                    }
                    if option.quote != nil, abs(est.difference) >= 0.01 {
                        Text("\(est.difference > 0 ? "+" : "")\(Int((est.difference * 100).rounded()))% vs your rates")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(est.difference < -0.05 ? Theme.amber : Theme.text3)
                    }
                    HeadlineNumber(text: Money.string(est.total), size: 26)
                    if est.travelAllowance > 0 {
                        Text("incl. \(Money.string(est.travelAllowance)) travel").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                    HStack {
                        Text("You keep").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        Spacer()
                        Text("\(Money.short(est.takeHome)) · \(Money.string(est.takeHomePerHour))/hr")
                            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(est.takeHomePerHour >= deals.rates.targetHourly ? Theme.teal : Theme.amber)
                    }
                }
            }
            .padding(16)
            .frame(width: 236, alignment: .topLeading)
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(isSelected ? Theme.teal.opacity(0.7) : Theme.line, lineWidth: isSelected ? 1.5 : 1))
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
        }
    }

    private func update(_ change: (inout ScopeOption) -> Void) {
        guard var d = deals.deal(id: dealID), let i = d.options.firstIndex(where: { $0.id == optionID }) else { return }
        change(&d.options[i])
        deals.update(d)
    }

    private func bind<T>(_ path: WritableKeyPath<ScopeOption, T>) -> Binding<T> {
        // The option can vanish mid-update (removed, or replaced by "Offer three options"),
        // so reads fall back to a placeholder instead of force-unwrapping.
        Binding(get: { (option ?? ScopeOption.starter())[keyPath: path] },
                set: { value in update { $0[keyPath: path] = value } })
    }

    private var quoteText: Binding<String> {
        Binding(
            get: { option?.quote.map { String(Int($0)) } ?? "" },
            set: { text in
                let digits = text.filter(\.isNumber)
                update { $0.quote = digits.isEmpty ? nil : Double(digits) }
            })
    }
}

struct Dial: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1

    init(_ label: String, _ value: Binding<Int>, _ range: ClosedRange<Int>, step: Int = 1) {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.text3)
            Spacer()
            stepButton("minus", enabled: value > range.lowerBound) { value = max(range.lowerBound, value - step) }
            Text("\(value)")
                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.text)
                .frame(minWidth: 20)
            stepButton("plus", enabled: value < range.upperBound) { value = min(range.upperBound, value + step) }
        }
    }

    private func stepButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .background(Theme.raised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Theme.text2 : Theme.track)
        .disabled(!enabled)
    }
}

// MARK: - Sheets

struct StoryEditor: View {
    @EnvironmentObject private var deals: DealStore
    @Environment(\.dismiss) private var dismiss
    let dealID: UUID
    @State private var story = ProposalStory()
    @State private var why = ""
    @State private var feelings = ""
    @State private var pillars = ""
    @State private var choices = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The pitch").font(.system(size: 20, weight: .bold))
            Text("Paragraphs are separated by a blank line. For pillars and choices, start each paragraph with its title followed by a colon.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            Form {
                TextField("Headline", text: $story.headline)
                TextField("One-line pitch", text: $story.logline, axis: .vertical).lineLimit(2...4)
                TextField("Callout", text: $story.callout, axis: .vertical).lineLimit(2...4)
                TextField("“Why this matters” title", text: $story.whyTitle)
                TextField("Why this matters", text: $why, axis: .vertical).lineLimit(4...10)
                TextField("What viewers should feel (one per line)", text: $feelings, axis: .vertical).lineLimit(2...5)
                TextField("Creative approach title", text: $story.approachTitle)
                TextField("Pillars", text: $pillars, axis: .vertical).lineLimit(4...10)
                TextField("Choices to make together", text: $choices, axis: .vertical).lineLimit(4...10)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button("Save") {
                    guard var d = deals.deal(id: dealID) else { return }
                    story.why = paragraphs(why)
                    story.feelings = feelings.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    story.pillars = points(pillars)
                    story.choices = points(choices)
                    d.story = story
                    deals.update(d)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(24)
        .frame(width: 640, height: 720)
        .onAppear {
            guard let d = deals.deal(id: dealID) else { return }
            story = d.story
            why = d.story.why.joined(separator: "\n\n")
            feelings = d.story.feelings.joined(separator: "\n")
            pillars = d.story.pillars.map { "\($0.title): \($0.text)" }.joined(separator: "\n\n")
            choices = d.story.choices.map { "\($0.title): \($0.text)" }.joined(separator: "\n\n")
        }
    }

    private func paragraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func points(_ text: String) -> [Point] {
        paragraphs(text).map { para in
            if let colon = para.firstIndex(of: ":") {
                return Point(title: String(para[..<colon]).trimmingCharacters(in: .whitespaces),
                             text: String(para[para.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            }
            return Point(title: para, text: "")
        }
    }
}

struct FollowUpSheet: View {
    @EnvironmentObject private var deals: DealStore
    @Environment(\.dismiss) private var dismiss
    let dealID: UUID
    @State private var text = "Followed up by email"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Log a follow-up").font(.system(size: 18, weight: .bold))
            TextField("What happened", text: $text, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
            Text("Once the home server is running, a follow-up draft will be waiting here for you to send.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button("Log it") {
                    if let d = deals.deal(id: dealID) { deals.logTouch(text, for: d) }
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(24).frame(width: 420)
    }
}

struct LostSheet: View {
    @EnvironmentObject private var deals: DealStore
    @Environment(\.dismiss) private var dismiss
    let dealID: UUID
    @State private var reason = "Went with someone cheaper"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Mark lost").font(.system(size: 18, weight: .bold))
            Picker("Why", selection: $reason) {
                ForEach(["Went with someone cheaper", "Budget fell through", "Dates didn't work", "Went quiet", "Not a fit"], id: \.self) { Text($0) }
            }
            Text("Reasons add up over time and show which jobs and prices you tend to win.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button("Mark lost") {
                    if let d = deals.deal(id: dealID) { deals.markLost(d, reason: reason) }
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(24).frame(width: 420)
    }
}

struct WonSheet: View {
    @EnvironmentObject private var deals: DealStore
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var navigator: Navigator
    @Environment(\.dismiss) private var dismiss
    let dealID: UUID
    @State private var optionID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Mark won").font(.system(size: 18, weight: .bold))
            if let deal = deals.deal(id: dealID) {
                Text("Which option did they pick?").font(.system(size: 13)).foregroundStyle(Theme.text3)
                ForEach(deal.options) { option in
                    Button {
                        optionID = option.id
                    } label: {
                        HStack {
                            Image(systemName: optionID == option.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(optionID == option.id ? Theme.teal : Theme.muted)
                            Text("\(option.name) · \(option.tagline)").font(.system(size: 14))
                            Spacer()
                            Text(Money.string(deals.estimate(option).total)).monospacedDigit()
                        }
                        .padding(10)
                        .background(Theme.raised)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Text("This creates the project at Booked, carrying over the timeline and history. Later, the contract, payment schedule and deposit invoice will be drafted here too.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                    Button("Book it") {
                        guard let option = deal.options.first(where: { $0.id == optionID }) else { return }
                        let projectID = deals.markWon(deal, option: option, projects: projects)
                        dismiss()
                        navigator.openProject(projectID)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(optionID == nil)
                }
                .onAppear { optionID = deal.chosenOptionID ?? (deal.options.count == 1 ? deal.options.first?.id : nil) }
            }
        }
        .padding(24).frame(width: 460)
    }
}


/// Lets a button switch between the primary and secondary look.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
