import SwiftUI

// MARK: - Steps

/// The proposal, one section at a time: discovery first, then the nine parts of a proposal
/// that wins (summary, scope, deliverables, approach, timeline, packages, terms, proof,
/// next steps), then a pre-send review.
enum BuilderStep: Int, CaseIterable, Identifiable {
    case discovery, summary, scope, deliverables, approach, timeline, packages, terms, proof, nextSteps, review

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .discovery: return "Discovery"
        case .summary: return "Summary"
        case .scope: return "Scope"
        case .deliverables: return "Deliverables"
        case .approach: return "Approach"
        case .timeline: return "Timeline"
        case .packages: return "Packages"
        case .terms: return "Terms"
        case .proof: return "Proof"
        case .nextSteps: return "Next steps"
        case .review: return "Review & send"
        }
    }

    var guidance: String {
        switch self {
        case .discovery: return "Answer these on the call. Scope first, price second: a price without a scope is a guess."
        case .summary: return "Open with their goal, not your story. They should read the first line and think you listened."
        case .scope: return "Be specific enough that nobody can argue later. Say what isn't included, too."
        case .deliverables: return "Every file they'll receive: length, format and how many."
        case .approach: return "Written for you from the scope. Keep it short: they just need to know the process is under control."
        case .timeline: return "Dates, not \"4 to 6 weeks\". Put their feedback deadline in writing: the project only moves as fast as their review."
        case .packages: return "A few options, each itemized. If the budget is smaller, cut scope, not price. Extras are add-ons."
        case .terms: return "In writing before the shoot: deposit, payments, revisions, turnaround, rights, cancellation."
        case .proof: return "2 or 3 projects like theirs and one real testimonial."
        case .nextSteps: return "How to say yes, what the deposit is, and when the offer expires."
        case .review: return "Send within 48 hours of the call, then follow up. Most proposals are lost to silence, not competitors."
        }
    }

    var example: String? {
        switch self {
        case .summary: return "\"You need a film that makes 25 new hires a year want to work at your plant\" beats \"I'm a full-service production company.\""
        case .scope: return "\"5 local filming days, 3-person crew, 2 cameras, up to 6 interviews. Not included: permits, talent, rush turnaround.\""
        case .deliverables: return "\"1 brand film up to 2 minutes, 3 vertical clips, 10 stills, 4K master and captions file.\""
        default: return nil
        }
    }
}

enum StepStatus { case done, partial, todo }

extension BuilderStep {
    /// Matches the colours of the same sections on the deal page.
    var color: Color {
        switch self {
        case .discovery: return Palette.rose
        case .summary: return Palette.violet
        case .scope, .deliverables, .approach: return Palette.blue
        case .timeline: return Palette.orchid
        case .packages: return Palette.lime
        case .terms: return Palette.sand
        case .proof: return Palette.gold
        case .nextSteps: return Palette.mint
        case .review: return Palette.slate
        }
    }
}

extension BuilderStep {
    func status(_ deal: Deal) -> StepStatus {
        switch self {
        case .discovery:
            let n = deal.disc.answered
            return n >= Discovery.questionCount ? .done : n > 0 ? .partial : .todo
        case .summary:
            let s = deal.story
            if !s.headline.isEmpty && !s.logline.isEmpty { return .done }
            return s.headline.isEmpty && s.logline.isEmpty ? .todo : .partial
        case .scope:
            return deal.options.isEmpty ? .todo : (deal.exclusions ?? []).isEmpty ? .partial : .done
        case .deliverables:
            return deal.options.isEmpty ? .todo : (deal.formats ?? []).isEmpty ? .partial : .done
        case .approach:
            return deal.options.isEmpty ? .todo : .done
        case .timeline:
            if deal.milestones.isEmpty { return .todo }
            return deal.hasFeedbackDeadline && deal.shootStart != nil ? .done : .partial
        case .packages:
            return deal.options.isEmpty ? .todo : (deal.addOns ?? []).isEmpty ? .partial : .done
        case .terms:
            return deal.terms == nil ? .todo : .done
        case .proof:
            let picked = !(deal.proofProjectIDs ?? []).isEmpty, quote = !(deal.testimonial ?? "").isEmpty
            return picked && quote ? .done : (picked || quote) ? .partial : .todo
        case .nextSteps:
            let parts = [deal.expiresOn != nil, !deal.nextSteps.isEmpty, !(deal.acceptHow ?? "").isEmpty]
            return parts.allSatisfy { $0 } ? .done : parts.contains(true) ? .partial : .todo
        case .review:
            let rest = BuilderStep.allCases.filter { $0 != .review }
            return rest.allSatisfy { $0.status(deal) == .done } && (deal.nameChecked ?? false) ? .done : .todo
        }
    }

    static func progress(_ deal: Deal) -> Int {
        allCases.filter { $0.status(deal) == .done }.count
    }
}

extension Deal {
    var hasFeedbackDeadline: Bool { milestones.contains { $0.phase.localizedCaseInsensitiveContains("feedback") } }

    /// True when the headline or pitch opens with Emma instead of the client.
    var opensWithSelf: Bool {
        [story.headline, story.logline].contains { text in
            let t = text.lowercased()
            return ["i ", "i'", "we ", "we'", "my ", "our "].contains { t.hasPrefix($0) }
        }
    }

    var termsValue: DealTerms {
        get { terms ?? DealTerms(depositPercent: 50, paymentSchedule: "", usageRights: "", cancellation: "", weather: "") }
        set { terms = newValue }
    }

    static let placeholder = Deal(client: "", title: "", source: "", stage: .inquiry, lastTouch: Date(), createdAt: Date())
}

// MARK: - Builder

struct ProposalBuilderView: View {
    @EnvironmentObject private var deals: DealStore
    @EnvironmentObject private var projects: ProjectStore
    @EnvironmentObject private var navigator: Navigator
    let dealID: UUID
    @State private var step: BuilderStep = .discovery
    @State private var didPickStart = false

    private var deal: Deal { deals.deal(id: dealID) ?? .placeholder }

    var body: some View {
        HStack(spacing: 0) {
            rail
                .frame(width: 230)
                .background(Theme.sidebar)
            Divider().overlay(Theme.line)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        stepHeader
                        content
                    }
                    .padding(36)
                    .frame(maxWidth: 980, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(step)
                footer
            }
        }
        .onAppear {
            guard !didPickStart else { return }
            didPickStart = true
            step = BuilderStep.allCases.first { $0.status(deal) != .done } ?? .review
        }
    }

    // MARK: Rail and chrome

    private var rail: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                navigator.builderDealID = nil
            } label: {
                Label("Back to the deal", systemImage: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text3)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 14)

            Text(deal.title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("Proposal · \(BuilderStep.progress(deal)) of \(BuilderStep.allCases.count) done")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .padding(.bottom, 14)

            ForEach(BuilderStep.allCases) { s in
                Button {
                    step = s
                } label: {
                    HStack(spacing: 10) {
                        icon(for: s.status(deal))
                        Text("\(s.rawValue + 1)").font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(s.color).frame(width: 16, alignment: .trailing)
                        Text(s.title)
                            .font(.system(size: 13, weight: s == step ? .semibold : .regular))
                            .foregroundStyle(s == step ? Theme.text : Theme.text3)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(s == step ? Theme.raised : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if let due = deal.proposalDue, deal.stage == .inquiry {
                VStack(alignment: .leading, spacing: 4) {
                    Text(due < Date() ? "OVERDUE" : "SEND BY").font(.system(size: 10, weight: .bold)).tracking(0.8)
                        .foregroundStyle(due < Date() ? Theme.coral : Theme.amber)
                    Text(due.formatted(.dateTime.weekday(.wide).hour().minute()))
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("48 hours after the discovery call").font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(18)
    }

    @ViewBuilder
    private func icon(for status: StepStatus) -> some View {
        switch status {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.teal)
        case .partial: Image(systemName: "circle.lefthalf.filled").foregroundStyle(Theme.amber)
        case .todo: Image(systemName: "circle").foregroundStyle(Theme.track)
        }
    }

    private var stepHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            ColorLabel("Step \(step.rawValue + 1) of \(BuilderStep.allCases.count)", step.color)
            Text(step.title)
                .font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.text)
            Text(step.guidance)
                .font(.system(size: 15)).foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
            if let example = step.example {
                Text(example)
                    .font(.system(size: 13).italic()).foregroundStyle(Theme.text2)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.teal).frame(width: 3) }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let prev = BuilderStep(rawValue: step.rawValue - 1) {
                Button("Back: \(prev.title)") { step = prev }.buttonStyle(SecondaryButtonStyle())
            }
            Spacer()
            Button("Preview proposal") { ProposalRenderer.open(deal, store: deals, projects: projects) }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(deal.options.isEmpty)
            if let next = BuilderStep(rawValue: step.rawValue + 1) {
                Button("Next: \(next.title)") { step = next }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(.horizontal, 36).padding(.vertical, 14)
        .background(Theme.sidebar)
        .overlay(alignment: .top) { Divider().overlay(Theme.line) }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .discovery: discoveryStep
        case .summary: summaryStep
        case .scope: scopeStep
        case .deliverables: deliverablesStep
        case .approach: approachStep
        case .timeline: timelineStep
        case .packages: packagesStep
        case .terms: termsStep
        case .proof: proofStep
        case .nextSteps: nextStepsStep
        case .review: reviewStep
        }
    }

    // MARK: Editing helpers

    private func edit(_ change: (inout Deal) -> Void) {
        guard var d = deals.deal(id: dealID) else { return }
        change(&d)
        deals.update(d)
    }

    private func bind<T>(_ path: WritableKeyPath<Deal, T>) -> Binding<T> {
        Binding(get: { deal[keyPath: path] }, set: { value in edit { $0[keyPath: path] = value } })
    }

    private func text(_ path: WritableKeyPath<Deal, String?>) -> Binding<String> {
        Binding(get: { deal[keyPath: path] ?? "" }, set: { value in edit { $0[keyPath: path] = value } })
    }

    private func optionBind<T>(_ id: UUID, _ path: WritableKeyPath<ScopeOption, T>, fallback: T) -> Binding<T> {
        Binding(
            get: { deal.options.first { $0.id == id }?[keyPath: path] ?? fallback },
            set: { value in edit { d in
                if let i = d.options.firstIndex(where: { $0.id == id }) { d.options[i][keyPath: path] = value }
            } })
    }

    private func rate<T>(_ path: WritableKeyPath<RateCard, T>) -> Binding<T> {
        Binding(get: { deals.rates[keyPath: path] }, set: { deals.rates[keyPath: path] = $0 })
    }

    private var lead: ScopeOption? { deal.chosenOption ?? deal.options.first }

    // MARK: 1 · Discovery

    private var discoveryStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("\(deal.disc.answered) of \(Discovery.questionCount) answered")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text3)
                Spacer()
                Button("Fill in from the call recording") {}
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(true)
                    .help("Needs the home server: the local AI listens to the call and answers these for you to check")
            }
            BField("What does the video need to do?", "Make 25 new hires a year want to work here", bind(\.disc.goal))
            HStack(alignment: .top, spacing: 14) {
                BField("Who's the audience?", "Alumni, donors, future fellows", bind(\.disc.audience))
                BField("Where will they watch it?", "Gala screen, website, Instagram", bind(\.disc.whereWatched))
            }
            HStack(alignment: .top, spacing: 14) {
                BField("Who's on camera, and how many?", "Cindy, Meredith and 3–4 fellows", bind(\.disc.onCamera))
                BField("How many locations and shoot days?", "Boulder campus, Denver, one trip", bind(\.disc.locations))
            }
            BField("What formats do they need?", "One hero film, a trailer, vertical clips, stills", bind(\.disc.formats))
            HStack(alignment: .top, spacing: 14) {
                OptionalDate("When does it need to be live?", bind(\.disc.goLive), fallback: Calendar.current.date(byAdding: .month, value: 2, to: Date()) ?? Date())
                OptionalDate("When was the discovery call?", bind(\.disc.callDate), fallback: Date(), withTime: true,
                             caption: deal.proposalDue.map { "Proposal due \($0.formatted(.dateTime.weekday(.wide).hour().minute()))" })
            }
            BField("Call notes", "Anything else they said", bind(\.callNotes), lines: 4...12)
        }
    }

    // MARK: 2 · Summary

    private var summaryStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !deal.disc.goal.isEmpty || !deal.disc.audience.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("What they told you")
                    if !deal.disc.goal.isEmpty { Text("Goal: \(deal.disc.goal)").font(.system(size: 14)).foregroundStyle(Theme.text2) }
                    if !deal.disc.audience.isEmpty { Text("Audience: \(deal.disc.audience)").font(.system(size: 13)).foregroundStyle(Theme.text3) }
                    if !deal.disc.whereWatched.isEmpty { Text("Where: \(deal.disc.whereWatched)").font(.system(size: 13)).foregroundStyle(Theme.text3) }
                }
                .panel(padding: 16)
            }
            BField("Headline", "Thirty years of memories. A world full of stories.", bind(\.story.headline))
            BField("One-line pitch: their goal, their audience, where it plays", "An anniversary film for alumni and donors, premiering at the gala", bind(\.story.logline), lines: 2...4)
            if deal.opensWithSelf {
                Warning("This opens with you. Lead with their goal instead.")
            }
            BField("Callout (optional)", "A film about those who move mountains…", bind(\.story.callout), lines: 2...4)

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 14) {
                    BField("\"Why this matters\" title", "A milestone worth celebrating.", bind(\.story.whyTitle))
                    ParagraphsField("Why this matters", hint: "Paragraphs separated by a blank line",
                                    initial: deal.story.why.joined(separator: "\n\n")) { t in edit { $0.story.why = StoryText.paragraphs(t) } }
                    ParagraphsField("What viewers should feel", hint: "One per line",
                                    initial: deal.story.feelings.joined(separator: "\n")) { t in
                        edit { $0.story.feelings = t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                    }
                    BField("Creative approach title", "Meet the people first.", bind(\.story.approachTitle))
                    ParagraphsField("Story pillars", hint: "Title: text, one per paragraph",
                                    initial: StoryText.join(deal.story.pillars)) { t in edit { $0.story.pillars = StoryText.points(t) } }
                    ParagraphsField("Choices to make together", hint: "Title: text, one per paragraph",
                                    initial: StoryText.join(deal.story.choices)) { t in edit { $0.story.choices = StoryText.points(t) } }
                }
                .padding(.top, 10)
            } label: {
                Text("Story pages (Full proposal only)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text2)
            }
        }
    }

    // MARK: 3 · Scope

    private static let standardExclusions = [
        "Talent and actors", "Location permits and fees", "Licensed music beyond one included track",
        "Travel beyond the Front Range", "Rush turnaround", "Hair and makeup", "Raw footage and project files",
    ]

    private var scopeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            optionsRow(offerThree: true)
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Not included")
                Text("Name what's out of scope now, so it becomes an add-on later instead of a free favor.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                ChipToggles(options: Self.standardExclusions, selected: Binding(get: { deal.exclusions ?? [] }, set: { v in edit { $0.exclusions = v } }))
            }
            .panel()
        }
    }

    @ViewBuilder
    private func optionsRow(offerThree: Bool) -> some View {
        if deal.options.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("No scope yet.").font(.system(size: 14)).foregroundStyle(Theme.text3)
                Button("Start from a one-day shoot") { edit { $0.options = [.starter()] } }.buttonStyle(PrimaryButtonStyle())
            }
            .panel()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(deal.options.count > 1 ? "Options · \(deal.options.count)" : "Scope")
                    Spacer()
                    if offerThree && deal.options.count == 1 {
                        Button("Offer three options") { edit { $0.options = $0.options[0].threeWays() } }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(deal.options) { option in
                            OptionColumn(dealID: dealID, optionID: option.id, isSelected: false,
                                         isChosen: deal.chosenOptionID == option.id, canRemove: deal.options.count > 1) {}
                        }
                    }
                }
            }
        }
    }

    // MARK: 4 · Deliverables

    private static let standardFormats = [
        "4K master", "Web-ready version (1080p)", "Captions file (SRT)", "Vertical 9:16 versions", "Thumbnail stills", "Project files",
    ]

    private var deliverablesStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            if deal.options.isEmpty {
                Text("Set up the scope first.").font(.system(size: 14)).foregroundStyle(Theme.muted).panel()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(deal.options) { option in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(option.name).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                            Text(option.tagline).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            Dial("Main film, minutes", optionBind(option.id, \.filmMinutes, fallback: 1), 1...60)
                            Divider().overlay(Theme.line)
                            ForEach(Extra.allCases) { extra in
                                let on = option.extras.contains(extra)
                                Toggle(isOn: Binding(get: { on }, set: { value in
                                    edit { d in
                                        guard let i = d.options.firstIndex(where: { $0.id == option.id }) else { return }
                                        if value { d.options[i].extras.append(extra) } else { d.options[i].extras.removeAll { $0 == extra } }
                                        d.options[i].extras = Extra.allCases.filter(d.options[i].extras.contains)
                                    }
                                })) {
                                    Text(extra.label).font(.system(size: 12)).foregroundStyle(Theme.text3)
                                }
                                .toggleStyle(.checkbox)
                                if on && extra.hasQuantity {
                                    Dial("How many", Binding(get: { option.quantity(extra) }, set: { n in
                                        edit { d in
                                            if let i = d.options.firstIndex(where: { $0.id == option.id }) { d.options[i].setQuantity(extra, n) }
                                        }
                                    }), 1...50)
                                    .padding(.leading, 20)
                                }
                            }
                        }
                        .padding(16)
                        .frame(width: 250, alignment: .topLeading)
                        .background(Theme.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Formats they'll receive")
                ChipToggles(options: Self.standardFormats, selected: Binding(get: { deal.formats ?? [] }, set: { v in edit { $0.formats = v } }))
            }
            .panel()
        }
    }

    // MARK: 5 · Approach

    private var approachStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let lead {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(ProposalRenderer.approachBlocks(lead, owner: deals.rates.ownerName), id: \.title) { block in
                        HStack(alignment: .top, spacing: 16) {
                            Text(block.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).frame(width: 140, alignment: .leading)
                            Text(block.text).font(.system(size: 13)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .panel()
                Text("This updates on its own as you change the scope.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            } else {
                Text("Set up the scope first.").font(.system(size: 14)).foregroundStyle(Theme.muted).panel()
            }
            BField("Anything to add (optional)", "We'll film the fellows' field trip in March as it happens.", text(\.approachNote), lines: 2...5)
        }
    }

    // MARK: 6 · Timeline

    private var timelineStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                OptionalDate("First shoot day", bind(\.shootStart),
                             fallback: Calendar.current.date(byAdding: .day, value: 21, to: Date()) ?? Date())
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your turnaround (business days)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text3)
                    Dial("Rough cut after filming", rate(\.roughCutBusinessDays), 1...30)
                    Dial("Their feedback window", rate(\.feedbackBusinessDays), 1...20)
                    Dial("Final after feedback", rate(\.finalBusinessDays), 1...20)
                }
                .frame(width: 280)
            }

            if let start = deal.shootStart, let lead {
                let plan = TimelinePlanner.plan(shootStart: start, shootDays: lead.shootDays, rates: deals.rates)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionLabel("Suggested dates")
                        Spacer()
                        Button("Use these dates") { edit { $0.milestones = plan.milestones } }.buttonStyle(PrimaryButtonStyle())
                    }
                    ForEach(plan.milestones) { m in
                        HStack {
                            Text(m.phase).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                            Spacer()
                            Text(m.when).font(.system(size: 13)).monospacedDigit().foregroundStyle(Theme.text2)
                        }
                    }
                    if let live = deal.disc.goLive, plan.finalDelivery > live {
                        Warning("Final delivery lands after their go-live date (\(live.formatted(date: .abbreviated, time: .omitted))). Start sooner or shorten the turnaround.", tone: Theme.coral)
                    }
                    if lead.shootDays > 5 {
                        Text("Long shoots often spread over weeks: edit the filming dates below after using these.")
                            .font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                }
                .panel()
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel("On the proposal")
                    Spacer()
                    Button("Add milestone") { edit { $0.milestones.append(Milestone(phase: "", when: "")) } }
                        .buttonStyle(SecondaryButtonStyle())
                }
                if deal.milestones.isEmpty {
                    Text("No milestones yet.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                ForEach(deal.milestones) { m in
                    HStack(spacing: 10) {
                        TextField("Phase", text: milestoneBind(m.id, \.phase)).textFieldStyle(.roundedBorder)
                        TextField("When", text: milestoneBind(m.id, \.when)).textFieldStyle(.roundedBorder)
                        Button {
                            edit { $0.milestones.removeAll { $0.id == m.id } }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).foregroundStyle(Theme.muted)
                    }
                }
                if !deal.milestones.isEmpty && !deal.hasFeedbackDeadline {
                    Warning("Add a date for their feedback. The project only moves as fast as their review.")
                }
            }
            .panel()
        }
    }

    private func milestoneBind(_ id: UUID, _ path: WritableKeyPath<Milestone, String>) -> Binding<String> {
        Binding(
            get: { deal.milestones.first { $0.id == id }?[keyPath: path] ?? "" },
            set: { v in edit { d in if let i = d.milestones.firstIndex(where: { $0.id == id }) { d.milestones[i][keyPath: path] = v } } })
    }

    // MARK: 7 · Packages

    private var packagesStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            optionsRow(offerThree: true)

            ForEach(deal.options) { option in
                if let suggestion = Estimator.suggestCuts(option, rates: deals.rates) {
                    let est = deals.estimate(option)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(option.name) is quoted \(Int((-est.difference * 100).rounded()))% under your rates.")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.amber)
                        Text("Protect the price, scale the scope. To make \(Money.string(est.quote)) pay your rates: \(suggestion.cuts.joined(separator: ", ")).")
                            .font(.system(size: 13)).foregroundStyle(Theme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Make those cuts") {
                                edit { d in
                                    if let i = d.options.firstIndex(where: { $0.id == option.id }) { d.options[i] = suggestion.option }
                                }
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            Text("Or keep the discount on purpose.").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                    }
                    .panel(padding: 16)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Add-ons, priced separately")
                Text("Extras are where scope creep gets paid for. Tick the ones to offer on this proposal.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                ForEach(deals.rates.addOnMenu) { item in
                    let offered = (deal.addOns ?? []).contains { $0.name == item.name }
                    HStack(spacing: 12) {
                        Toggle(isOn: Binding(get: { offered }, set: { on in
                            edit { d in
                                var list = d.addOns ?? []
                                if on { list.append(AddOn(name: item.name, price: item.price, note: item.note)) }
                                else { list.removeAll { $0.name == item.name } }
                                d.addOns = list
                            }
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                                Text(item.note).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                        }
                        .toggleStyle(.checkbox)
                        Spacer()
                        if offered {
                            TextField("Price", value: Binding(
                                get: { deal.addOns?.first { $0.name == item.name }?.price ?? item.price },
                                set: { p in edit { d in
                                    if let i = d.addOns?.firstIndex(where: { $0.name == item.name }) { d.addOns?[i].price = p }
                                } }), format: .currency(code: "USD").precision(.fractionLength(0)))
                                .textFieldStyle(.roundedBorder).frame(width: 100).multilineTextAlignment(.trailing)
                        } else {
                            Text(Money.string(item.price)).font(.system(size: 13)).foregroundStyle(Theme.muted)
                        }
                    }
                }
            }
            .panel()
        }
    }

    // MARK: 8 · Terms

    private var termsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if deal.terms == nil {
                Text("Filling in your usual terms…").font(.system(size: 13)).foregroundStyle(Theme.muted)
            } else {
                let deposit = (lead.map { deals.estimate($0).total } ?? 0) * deal.termsValue.depositPercent / 100
                HStack(alignment: .center, spacing: 16) {
                    Dial("Deposit %", Binding(get: { Int(deal.termsValue.depositPercent) },
                                              set: { v in edit { $0.termsValue.depositPercent = Double(v) } }), 0...100, step: 5)
                        .frame(width: 240)
                    Text("\(Money.string(deposit)) on \(lead?.name ?? "the lead option") locks the date. No deposit, no booking.")
                        .font(.system(size: 13)).foregroundStyle(Theme.text3)
                }
                .panel(padding: 16)
                BField("Payment schedule", "Deposit up front, balance before final files", bind(\.termsValue.paymentSchedule), lines: 2...4)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Revisions and turnaround").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text3)
                    Text(deal.options.map { "\($0.name): \($0.revisionRounds) round\($0.revisionRounds == 1 ? "" : "s")" }.joined(separator: " · ") + " (set in Scope). Extra rounds are an add-on.")
                        .font(.system(size: 13)).foregroundStyle(Theme.text2)
                    Text("Rough cut \(deals.rates.roughCutBusinessDays) business days after filming · their feedback within \(deals.rates.feedbackBusinessDays) · final \(deals.rates.finalBusinessDays) after that (set in Timeline).")
                        .font(.system(size: 13)).foregroundStyle(Theme.text2)
                }
                .panel(padding: 16)
                BField("Usage rights", "What they can do with it, and who keeps the copyright", bind(\.termsValue.usageRights), lines: 2...4)
                BField("Cancellation", "What happens if the date moves", bind(\.termsValue.cancellation), lines: 2...4)
                BField("Weather", "What happens if the weather turns", bind(\.termsValue.weather), lines: 2...4)
                Button("Make these my usual terms") {
                    let t = deal.termsValue
                    deals.rates.depositPercent = t.depositPercent
                    deals.rates.paymentSchedule = t.paymentSchedule
                    deals.rates.usageRights = t.usageRights
                    deals.rates.cancellationPolicy = t.cancellation
                    deals.rates.weatherPolicy = t.weather
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .onAppear {
            if deal.terms == nil {
                let r = deals.rates
                edit { $0.terms = DealTerms(depositPercent: r.depositPercent, paymentSchedule: r.paymentSchedule,
                                            usageRights: r.usageRights, cancellation: r.cancellationPolicy, weather: r.weatherPolicy) }
            }
        }
    }

    // MARK: 9 · Proof

    private var proofStep: some View {
        let picked = Set(deal.proofProjectIDs ?? [])
        let candidates = projects.projects
            .filter { $0.stage.rawValue >= ProjectStage.edit.rawValue }
            .sorted { matchScore($0) > matchScore($1) }
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("By the numbers")
                HStack(spacing: 14) {
                    BField("Years in business", "6", rate(\.yearsInBusiness))
                    BField("Projects delivered", "120+", rate(\.projectsCompleted))
                    BField("Reviews", "5.0 on Google, 40 reviews", rate(\.reviewSummary))
                }
                Text("Saved for every proposal.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            .panel()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("Pick 2 or 3 projects like this one · \(picked.count) picked")
                    Spacer()
                }
                Text("Best matches first. A manufacturing client wants to see manufacturing.")
                    .font(.system(size: 13)).foregroundStyle(Theme.muted)
                ForEach(candidates) { project in
                    ProofRow(project: project, isPicked: picked.contains(project.id), canPick: picked.count < 3 || picked.contains(project.id)) {
                        edit { d in
                            var ids = d.proofProjectIDs ?? []
                            if ids.contains(project.id) { ids.removeAll { $0 == project.id } } else { ids.append(project.id) }
                            d.proofProjectIDs = ids
                        }
                    } feature: { quote in
                        edit { $0.testimonial = "\u{201C}\(quote)\u{201D} — \(project.client)" }
                    }
                }
            }
            .panel()

            BField("Testimonial to feature", "\u{201C}Emma made our team look like themselves on their best day.\u{201D} — Client name", text(\.testimonial), lines: 2...5)
        }
    }

    private func matchScore(_ p: Project) -> Int {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count > 3 })
        }
        let mine = words(deal.title + " " + deal.disc.goal + " " + deal.client + " " + deal.callNotes)
        let theirs = words(p.name + " " + p.client)
        var score = mine.intersection(theirs).count * 2
        let families = [["wedding", "engagement", "anniversary", "quinceanera", "family", "portraits"],
                        ["documentary", "story", "stories", "fellowship", "journalism", "nonprofit", "restoration", "community"],
                        ["brand", "promo", "catalog", "product", "campaign", "coffee"]]
        for family in families where family.contains(where: mine.contains) && family.contains(where: theirs.contains) { score += 3 }
        if !(p.testimonial ?? "").isEmpty { score += 1 }
        return score
    }

    // MARK: 10 · Next steps

    private var nextStepsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel("Steps to say yes")
                    Spacer()
                    Button("Use the usual three") {
                        let pct = Int(deal.termsValue.depositPercent)
                        edit { $0.nextSteps = [ChecklistItem(text: "Pick the option that fits", done: false),
                                               ChecklistItem(text: "Sign the agreement", done: false),
                                               ChecklistItem(text: "Pay the \(pct)% deposit to lock the date", done: false)] }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button("Add step") { edit { $0.nextSteps.append(ChecklistItem(text: "", done: false)) } }
                        .buttonStyle(SecondaryButtonStyle())
                }
                ForEach(Array(deal.nextSteps.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 10) {
                        Text("\(index + 1)").font(.system(size: 16)).foregroundStyle(Theme.teal).frame(width: 18)
                        TextField("Step", text: Binding(get: { item.text }, set: { v in
                            edit { d in if let i = d.nextSteps.firstIndex(where: { $0.id == item.id }) { d.nextSteps[i].text = v } }
                        })).textFieldStyle(.roundedBorder)
                        Button { edit { $0.nextSteps.removeAll { $0.id == item.id } } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(Theme.muted)
                    }
                }
            }
            .panel()
            BField("How to accept", "Reply to say which option you'd like…", text(\.acceptHow), lines: 2...4)
            OptionalDate("Offer expires", bind(\.expiresOn),
                         fallback: Calendar.current.date(byAdding: .day, value: deals.rates.offerValidDays, to: Date()) ?? Date(),
                         caption: "A date on the offer gives them a reason to decide.")
        }
        .onAppear {
            if deal.acceptHow == nil { edit { $0.acceptHow = deals.rates.acceptHow } }
            if deal.expiresOn == nil {
                let date = Calendar.current.date(byAdding: .day, value: deals.rates.offerValidDays, to: Date())
                edit { $0.expiresOn = date }
            }
        }
    }

    // MARK: 11 · Review & send

    private struct Check: Identifiable {
        let id = UUID()
        let ok: Bool
        let text: String
        let fix: BuilderStep
        var warnOnly = false
    }

    private var checks: [Check] {
        let d = deal
        let discounted = d.options.contains { deals.estimate($0).difference < -0.05 }
        return [
            Check(ok: !d.disc.goal.isEmpty && !d.opensWithSelf, text: "Opens with their goal, not your story", fix: .summary),
            Check(ok: !(d.exclusions ?? []).isEmpty, text: "Says what isn't included", fix: .scope),
            Check(ok: !(d.formats ?? []).isEmpty, text: "Lists every file they'll receive", fix: .deliverables),
            Check(ok: d.shootStart != nil, text: "Uses real dates, not \"4 to 6 weeks\"", fix: .timeline),
            Check(ok: d.hasFeedbackDeadline, text: "Puts a deadline on their feedback", fix: .timeline),
            Check(ok: !d.options.isEmpty, text: "Every package itemized (automatic)", fix: .packages),
            Check(ok: !discounted, text: "Price protected: scope cut instead of discounting", fix: .packages, warnOnly: true),
            Check(ok: d.terms != nil, text: "Deposit, payments, rights and cancellation in writing", fix: .terms),
            Check(ok: BuilderStep.proof.status(d) == .done, text: "Shows relevant work and a testimonial", fix: .proof),
            Check(ok: d.expiresOn != nil, text: "Has an expiry date", fix: .nextSteps),
        ]
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Before you send")
                ForEach(checks) { check in
                    HStack(spacing: 10) {
                        Image(systemName: check.ok ? "checkmark.circle.fill" : (check.warnOnly ? "exclamationmark.circle.fill" : "circle"))
                            .foregroundStyle(check.ok ? Theme.teal : (check.warnOnly ? Theme.amber : Theme.coral))
                        Text(check.text).font(.system(size: 14)).foregroundStyle(check.ok ? Theme.text2 : Theme.text)
                        Spacer()
                        if !check.ok {
                            Button("Fix") { step = check.fix }.buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
                Toggle(isOn: Binding(get: { deal.nameChecked ?? false }, set: { v in edit { $0.nameChecked = v } })) {
                    Text("I checked \"\(deal.client)\" against their website").font(.system(size: 14)).foregroundStyle(Theme.text)
                }
                .toggleStyle(.checkbox)
                .padding(.top, 4)
            }
            .panel()

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Length")
                Picker("", selection: Binding(get: { deal.shortProposal ?? false }, set: { v in edit { $0.shortProposal = v } })) {
                    Text("Short · about 5 pages").tag(true)
                    Text("Full · with story pages and workload").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 460)
                Text("Clients read short proposals and sign them. Use Full for bigger, story-led films.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            .panel()

            HStack(spacing: 12) {
                Button("Preview proposal") { ProposalRenderer.open(deal, store: deals, projects: projects) }
                    .buttonStyle(SecondaryButtonStyle())
                Button(deal.stage == .inquiry ? "Mark as sent" : "Mark revised proposal sent") {
                    if deal.stage == .inquiry {
                        deals.setStage(.proposalOut, for: deal, note: "Proposal sent")
                    } else {
                        deals.logTouch("Revised proposal sent", for: deal)
                    }
                    navigator.builderDealID = nil
                }
                .buttonStyle(PrimaryButtonStyle())
                if let due = deal.proposalDue, deal.stage == .inquiry {
                    Text(due < Date() ? "Was due \(due.formatted(.relative(presentation: .named)))" : "Due \(due.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 13)).foregroundStyle(due < Date() ? Theme.coral : Theme.amber)
                }
            }
            Text("After it's sent, follow-up nudges appear on Today when they go quiet.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
        }
    }
}

// MARK: - Small pieces

struct BField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var lines: ClosedRange<Int> = 1...4

    init(_ label: String, _ placeholder: String, _ text: Binding<String>, lines: ClosedRange<Int> = 1...4) {
        self.label = label
        self.placeholder = placeholder
        self._text = text
        self.lines = lines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text3)
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(lines)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(10)
                .background(Theme.raised)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OptionalDate: View {
    let label: String
    @Binding var date: Date?
    let fallback: Date
    var withTime = false
    var caption: String?

    init(_ label: String, _ date: Binding<Date?>, fallback: Date, withTime: Bool = false, caption: String? = nil) {
        self.label = label
        self._date = date
        self.fallback = fallback
        self.withTime = withTime
        self.caption = caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text3)
            HStack {
                Toggle("", isOn: Binding(get: { date != nil }, set: { date = $0 ? fallback : nil }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                if date != nil {
                    DatePicker("", selection: Binding(get: { date ?? fallback }, set: { date = $0 }),
                               displayedComponents: withTime ? [.date, .hourAndMinute] : [.date])
                        .labelsHidden()
                } else {
                    Text("Not set").font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
            }
            if let caption, date != nil {
                Text(caption).font(.system(size: 12)).foregroundStyle(Theme.amber)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Warning: View {
    let text: String
    var tone: Color = Theme.amber
    init(_ text: String, tone: Color = Theme.amber) {
        self.text = text
        self.tone = tone
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(tone)
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A multi-paragraph field that keeps its own text while typing (so blank lines between
/// paragraphs survive) and hands the parsed result back on every change.
struct ParagraphsField: View {
    let label: String
    let hint: String
    let initial: String
    let commit: (String) -> Void
    @State private var text = ""
    @State private var loaded = false

    init(_ label: String, hint: String, initial: String, commit: @escaping (String) -> Void) {
        self.label = label
        self.hint = hint
        self.initial = initial
        self.commit = commit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text3)
                Text(hint).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 110)
                .padding(8)
                .background(Theme.raised)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
        }
        .onAppear {
            if !loaded { text = initial; loaded = true }
        }
        .onChange(of: text) { _, new in
            if loaded { commit(new) }
        }
    }
}

enum StoryText {
    static func paragraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func points(_ text: String) -> [Point] {
        paragraphs(text).map { para in
            if let colon = para.firstIndex(of: ":") {
                return Point(title: String(para[..<colon]).trimmingCharacters(in: .whitespaces),
                             text: String(para[para.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            }
            return Point(title: para, text: "")
        }
    }

    static func join(_ points: [Point]) -> String {
        points.map { $0.text.isEmpty ? $0.title : "\($0.title): \($0.text)" }.joined(separator: "\n\n")
    }
}

/// Tap-to-toggle chips, with room to add your own.
struct ChipToggles: View {
    let options: [String]
    @Binding var selected: [String]
    @State private var custom = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 8) {
                ForEach(options + selected.filter { !options.contains($0) }, id: \.self) { item in
                    let on = selected.contains(item)
                    Button {
                        if on { selected.removeAll { $0 == item } } else { selected.append(item) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: on ? "checkmark" : "plus").font(.system(size: 9, weight: .bold))
                            Text(item).font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(on ? Theme.teal.opacity(0.22) : Theme.raised)
                        .foregroundStyle(on ? Theme.text : Theme.text3)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(on ? Theme.teal.opacity(0.5) : Theme.line))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                TextField("Add your own", text: $custom).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                    .onSubmit(add)
                Button("Add", action: add).buttonStyle(SecondaryButtonStyle()).disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add() {
        let item = custom.trimmingCharacters(in: .whitespaces)
        guard !item.isEmpty, !selected.contains(item) else { return }
        selected.append(item)
        custom = ""
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// One past project in the Proof step: pick it, and keep its testimonial and link handy.
struct ProofRow: View {
    @EnvironmentObject private var projects: ProjectStore
    let project: Project
    let isPicked: Bool
    let canPick: Bool
    let toggle: () -> Void
    let feature: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(action: toggle) {
                    Image(systemName: isPicked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 16))
                        .foregroundStyle(isPicked ? Theme.teal : (canPick ? Theme.text3 : Theme.track))
                }
                .buttonStyle(.plain)
                .disabled(!canPick)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("\(project.client) · \(project.stage.label)\(project.location.isEmpty ? "" : " · \(project.location)")")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                if let quote = project.testimonial, !quote.isEmpty {
                    Button("Feature its testimonial") { feature(quote) }.buttonStyle(SecondaryButtonStyle())
                }
            }
            if isPicked {
                HStack(spacing: 10) {
                    TextField("Testimonial from this client", text: binding(\.testimonial), axis: .vertical)
                        .lineLimit(1...3).textFieldStyle(.roundedBorder)
                    TextField("Portfolio link", text: binding(\.portfolioURL)).textFieldStyle(.roundedBorder).frame(width: 220)
                }
                .padding(.leading, 26)
            }
        }
        .padding(.vertical, 6)
    }

    private func binding(_ path: WritableKeyPath<Project, String?>) -> Binding<String> {
        Binding(get: { projects.project(id: project.id)?[keyPath: path] ?? "" },
                set: { v in
                    guard var p = projects.project(id: project.id) else { return }
                    p[keyPath: path] = v.isEmpty ? nil : v
                    projects.update(p)
                })
    }
}
