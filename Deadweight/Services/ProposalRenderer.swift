import Foundation
import AppKit

/// Builds the client-facing proposal as one HTML document in Emma's proposal style.
/// Every number comes from the Estimator, so the deck, budgets and comparison table can
/// never disagree. "Short" is the 3–5 page version; "Full" adds her story pages and the
/// workload table.
@MainActor
enum ProposalRenderer {

    static func open(_ deal: Deal, store: DealStore, projects: ProjectStore) {
        let html = render(deal, store: store, projects: projects)
        let dir = DealStore.url("Proposals")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var slug = String(deal.title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        let file = dir.appendingPathComponent(slug + ".html")
        do {
            try html.write(to: file, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(file)
        } catch {
            NSLog("Deadweight: couldn't write proposal: \(error)")
        }
    }

    /// The four "how we do it" blocks, written from the lead option. Shared with the builder.
    static func approachBlocks(_ o: ScopeOption, owner: String) -> [(title: String, text: String)] {
        let first = owner.split(separator: " ").first.map(String.init) ?? owner
        let film = o.travelDays > 0
            ? "\(words(o.localDays).capitalized) local filming day\(o.localDays == 1 ? "" : "s") plus \(words(o.travelDays)) out-of-state day\(o.travelDays == 1 ? "" : "s")\(o.travelPlaces.isEmpty ? "" : " (\(o.travelPlaces))"), with one travel and preparation day per trip."
            : "\(words(o.localDays).capitalized) local filming day\(o.localDays == 1 ? "" : "s") with \(words(o.cameraCount)) camera\(o.cameraCount == 1 ? "" : "s")."
        return [
            ("Research + plan", "Story development, interviewee research and calls, location checks, a shot list and a filming schedule."),
            ("Film + capture", film + " Interviews, B-roll and scenic footage where feasible and permitted."),
            ("Organize + protect", "Organize 4K footage and audio, back everything up to verified drives, and prepare the edit."),
            ("Shape + finish", "Build the story, then refine it with music, titles, captions, sound design and color. Up to \(words(o.revisionRounds)) round\(o.revisionRounds == 1 ? "" : "s") of consolidated feedback."),
            ("Core team", "\(first) directing and producing, with \(words(o.localCrew)) collaborator\(o.localCrew == 1 ? "" : "s") on local days\(o.travelDays > 0 ? " and \(words(o.travelCrew)) on each trip" : "")."),
        ]
    }

    static func render(_ deal: Deal, store: DealStore, projects: ProjectStore) -> String {
        guard let lead = deal.chosenOption ?? deal.options.first else { return "<p>Add an option first.</p>" }
        let b = Builder(deal: deal, lead: lead, store: store, projects: projects)
        let short = deal.shortProposal ?? false
        var html = head(title: "\(deal.client) Proposal")
        html += b.cover()
        if short {
            // About five pages of content: what clients actually read and sign.
            html += b.shortBrief()
            html += b.approach(withTimeline: true)
            html += b.shortPackages()
            html += b.shortTermsAndProof()
            html += b.investment(withTimeline: false)
        } else {
            html += b.brief()
            html += b.why()
            html += b.pillars()
            html += b.approach(withTimeline: false)
            html += b.receive()
            html += b.workload()
            html += b.choices()
            html += b.packages()
            html += b.terms()
            html += b.proof()
            html += b.investment(withTimeline: true)
        }
        html += b.closing()
        return html + "</body></html>"
    }

    // MARK: - Pages

    private final class Counter {
        var page = 0
        var section = 0
    }

    @MainActor
    private struct Builder {
        let deal: Deal
        let lead: ScopeOption
        let store: DealStore
        let projects: ProjectStore
        let counter = Counter()

        var r: RateCard { store.rates }
        var owner: String { r.ownerName.isEmpty ? "Your name" : r.ownerName }
        var est: Estimate { store.estimate(lead) }

        init(deal: Deal, lead: ScopeOption, store: DealStore, projects: ProjectStore) {
            self.deal = deal; self.lead = lead; self.store = store; self.projects = projects
        }

        func footer(_ label: String) -> String {
            counter.page += 1
            let page = counter.page
            return "<div class=ftr><span class=ftr-label>\(e(label))</span><span class=ftr-num>\(String(format: "%02d", page))</span></div>"
        }

        func label(_ text: String) -> String {
            counter.section += 1
            return "<div class=sec-label>\(String(format: "%02d", counter.section)) / \(e(text))</div>"
        }

        var header: String {
            "<div class=hdr><span>\(e(owner))\(r.businessName.isEmpty ? "" : " / " + e(r.businessName))</span><span class=hdr-right>\(e(deal.client)) / Proposal</span></div>"
        }

        func cover() -> String {
            let story = deal.story
            let month = Date().formatted(.dateTime.month(.wide).year())
            return """
            <section class="page dark">\(header)
              <div class=cover>
                <div class=eyebrow>\(e(deal.client))</div>
                <h1 class=cover-h>\(e(story.headline.isEmpty ? deal.title : story.headline))</h1>
                \(story.logline.isEmpty ? "" : "<p class=cover-sub>\(e(story.logline))</p>")
                \(story.callout.isEmpty ? "" : "<div class=callout>\(e(story.callout))</div>")
                <div class=prepared>Prepared for \(e(deal.client)) | \(month)</div>
              </div>\(footer(""))
            </section>
            """
        }

        /// Project summary: their goal first, in their words.
        func brief() -> String {
            let facts = briefFacts()
            guard !facts.isEmpty else { return "" }
            return """
            <section class=page>\(label("The Brief"))<h1>\(e(deal.disc.goal.isEmpty ? deal.title : deal.disc.goal))</h1>
              \(facts)
              \(footer("What You Told Me"))
            </section>
            """
        }

        func briefFacts() -> String {
            let d = deal.disc
            let rows: [(String, String)] = [
                // The goal is the page headline, so it isn't repeated here.
                ("Who's watching", d.audience), ("Where they'll watch it", d.whereWatched),
                ("Who's on camera", d.onCamera), ("Where we film", d.locations),
                ("Live by", d.goLive.map { $0.formatted(date: .long, time: .omitted) } ?? ""),
            ].filter { !$0.1.isEmpty }
            guard !rows.isEmpty else { return "" }
            return "<div class=facts>\(rows.map { "<div><span>\(e($0.0))</span>\(e($0.1))</div>" }.joined())</div>"
        }

        func shortBrief() -> String {
            """
            <section class=page>\(label("The Brief"))<h1>\(e(deal.disc.goal.isEmpty ? deal.title : deal.disc.goal))</h1>
              \(briefFacts())
              \(receiveGrid())
              \(footer("What You Told Me + What You Receive"))
            </section>
            """
        }

        func why() -> String {
            let story = deal.story
            guard !story.why.isEmpty else { return "" }
            return """
            <section class=page>\(label("Why This Matters"))<h1>\(e(story.whyTitle.isEmpty ? "Why this matters." : story.whyTitle))</h1>
              <div class=two><div>\(story.why.map { "<p>\(e($0))</p>" }.joined())</div>
              \(story.feelings.isEmpty ? "" : "<aside class=side><div class=col-label>What I want viewers to feel</div>\(story.feelings.map { "<h3>\(e($0))</h3>" }.joined())</aside>")</div>
              \(footer("The Intention"))
            </section>
            """
        }

        func pillars() -> String {
            let story = deal.story
            guard !story.pillars.isEmpty else { return "" }
            return """
            <section class=page>\(label("The Creative Approach"))<h1>\(e(story.approachTitle.isEmpty ? "The creative approach." : story.approachTitle))</h1>
              <div class=cards>\(story.pillars.enumerated().map { i, p in
                "<div class=card><div class=num>\(String(format: "%02d", i + 1))</div><div class=card-t>\(e(p.title))</div><p>\(e(p.text))</p></div>" }.joined())</div>
              \(footer("A Narrative to Develop Together"))
            </section>
            """
        }

        func approach(withTimeline: Bool) -> String {
            let blocks = ProposalRenderer.approachBlocks(lead, owner: owner)
            let note = (deal.approachNote ?? "").isEmpty ? "" : "<p class=note>\(e(deal.approachNote ?? ""))</p>"
            let timeline = withTimeline && !deal.milestones.isEmpty
                ? "<div class=col-label style='margin-top:26px'>Timeline</div>\(deal.milestones.map { "<div class=tl><b>\(e($0.phase))</b><span>\(e($0.when))</span></div>" }.joined())"
                : ""
            return """
            <section class=page>\(label("How We Bring It to Life"))<h1>A thoughtful plan with a focused team.</h1>
              <div class=rows>\(blocks.map { "<div class='row\($0.title == "Core team" ? " core" : "")'><b>\(e($0.title))</b><span>\(e($0.text))</span></div>" }.joined())</div>
              \(note)\(timeline)
              \(footer("From Research to Final Cut"))
            </section>
            """
        }

        /// Scope and deliverables: every file they receive, and what isn't included.
        func receive() -> String {
            """
            <section class=page>\(label("What You Receive"))<h1>Every file you'll receive.</h1>
              \(receiveGrid())
              \(footer("Scope + Deliverables"))
            </section>
            """
        }

        func receiveGrid() -> String {
            let extras = lead.extras.map { $0.deliverable(lead.quantity($0)) }
            let formats = deal.formats ?? []
            let excluded = deal.exclusions ?? []
            return """
              <div class=grid2>
                <div class=card><div class=col-label>The film</div><h3>Up to \(words(lead.filmMinutes)) minutes</h3>
                  <p>Up to \(lead.interviewees) interview\(lead.interviewees == 1 ? "" : "s"), \(lead.shootDays) filming day\(lead.shootDays == 1 ? "" : "s"), \(lead.cameraCount) camera\(lead.cameraCount == 1 ? "" : "s") on local days.</p>
                  <p>Up to \(words(lead.revisionRounds)) round\(lead.revisionRounds == 1 ? "" : "s") of consolidated revisions.</p></div>
                \(extras.isEmpty ? "" : "<div class=card><div class=col-label>Also included</div><ul>\(extras.map { "<li>\(e($0))</li>" }.joined())</ul></div>")
                \(formats.isEmpty ? "" : "<div class=card><div class=col-label>Formats</div><ul>\(formats.map { "<li>\(e($0))</li>" }.joined())</ul></div>")
                \(excluded.isEmpty ? "" : "<div class=card><div class=col-label>Not included</div><ul class=minus>\(excluded.map { "<li>\(e($0))</li>" }.joined())</ul></div>")
              </div>
            """
        }

        func workload() -> String {
            let est = self.est
            return """
            <section class=page>\(label("Estimated Coverage + Workload"))<h1>The work that brings the story together.</h1>
              <p class=sub>Estimated combined team hours, with equivalent eight-hour workdays as a reference.</p>
              <table class=work><thead><tr><th>Work / estimated coverage</th><th>Team hours</th><th>8-hour days</th></tr></thead><tbody>
              \(est.workload.map { "<tr><td><b>\(e($0.label))</b><small>\(e($0.detail))</small></td><td>\($0.hoursText)</td><td>\($0.daysText)</td></tr>" }.joined())
              <tr class=total><td>Estimated combined team workload</td><td>\(Estimate.range(est.teamHoursLow, est.teamHoursHigh))</td><td>\(Estimate.range(est.teamHoursLow / 8, est.teamHoursHigh / 8, decimals: 1))</td></tr>
              </tbody></table>
              <p class=fine>Days are combined team workday equivalents, not calendar days. Figures are rounded.</p>
              \(footer("Planning Estimates for the Proposed Scope"))
            </section>
            """
        }

        func choices() -> String {
            guard !deal.story.choices.isEmpty else { return "" }
            return """
            <section class=page>\(label("Choices to Make Together"))<h1>The right balance of voices and moments.</h1>
              <div class=grid2>\(deal.story.choices.enumerated().map { i, c in
                "<div class=card><div class=col-label>\(String(format: "%02d", i + 1)) / \(e(c.title))</div><p>\(e(c.text))</p></div>" }.joined())</div>
              \(lead.travelAllowance > 0 ? "<p class=note>Travel expenses carry an estimated \(Money.string(lead.travelAllowance)) allowance. Any additional travel or changes in scope are agreed before booking.</p>" : "")
              \(footer("Coverage to Refine Together"))
            </section>
            """
        }

        /// Packages and pricing: a comparison, then each option itemized, then add-ons.
        func packages() -> String {
            let options = deal.options
            var html = ""
            if options.count > 1 {
                let allExtras = Extra.allCases.filter { x in options.contains { $0.extras.contains(x) } }
                func row(_ label: String, _ cell: (ScopeOption) -> String, cls: String = "") -> String {
                    "<tr class='\(cls)'><th>\(e(label))</th>\(options.map { "<td>\(cell($0))</td>" }.joined())</tr>"
                }
                var rows = [
                    row("Pitch", { e($0.pitch) }, cls: "pitch"),
                    row("Filming days", { o in "\(o.shootDays)" + (o.travelDays > 0 ? " (\(o.travelDays) out of state)" : "") }),
                    row("Interviewees", { "Up to \($0.interviewees)" }),
                    row("Main film", { "Up to \($0.filmMinutes) min" }),
                    row("Crew", { "Emma + \($0.localCrew)" }),
                    row("Revisions", { "\($0.revisionRounds) round\($0.revisionRounds == 1 ? "" : "s")" }),
                ]
                for x in allExtras {
                    rows.append(row(x.shortLabel, { o in o.extras.contains(x) ? e(x.deliverable(o.quantity(x))) : "<span class=no>Not included</span>" }))
                }
                if options.contains(where: { !$0.clientTakesOn.isEmpty }) {
                    rows.append(row("You take on", { $0.clientTakesOn.isEmpty ? "<span class=no>Nothing extra</span>" : "\($0.clientTakesOn.count) planning tasks" }))
                }
                rows.append(row("Investment", { o in
                    let est = store.estimate(o)
                    return Money.string(est.quote) + (est.travelAllowance > 0 ? "<small>+ \(Money.string(est.travelAllowance)) travel</small>" : "")
                }, cls: "fee"))
                html += """
                <section class=page>\(label("Packages"))<h1>\(options.count == 3 ? "Three" : "\(options.count)") ways to tell this story.</h1>
                  <table class=compare><thead><tr><th></th>\(options.map { "<th>\(e($0.name))<span>\(e($0.tagline))</span></th>" }.joined())</tr></thead>
                  <tbody>\(rows.joined())</tbody></table>
                  \(footer("Choose the Level That Fits"))
                </section>
                """
            }
            for option in options {
                html += optionPage(option, allOptions: options)
            }
            if let addOns = deal.addOns, !addOns.isEmpty {
                html += """
                <section class=page><div class=sec-label>Add-ons</div><h1>Priced separately, if you need them.</h1>
                  <table class=budgett><tbody>\(addOns.map { "<tr><th>\(e($0.name))</th><td>\(e($0.note))</td><td class=amt>\(Money.string($0.price))</td></tr>" }.joined())</tbody></table>
                  \(footer("Add-ons"))
                </section>
                """
            }
            return html
        }

        /// One page: every option side by side, itemized line by line, plus add-ons.
        func shortPackages() -> String {
            let options = deal.options
            let estimates = options.map { store.estimate($0) }
            let categories = estimates.first?.clientLines.map(\.category) ?? []
            func row(_ label: String, _ cells: [String], cls: String = "") -> String {
                "<tr class='\(cls)'><th>\(e(label))</th>\(cells.map { "<td>\($0)</td>" }.joined())</tr>"
            }
            var rows = [
                row("What it is", options.map { e($0.pitch.isEmpty ? $0.tagline : $0.pitch) }, cls: "pitch"),
                row("Filming", options.map { o in "\(o.shootDays) day\(o.shootDays == 1 ? "" : "s"), Emma + \(o.localCrew)" }),
                row("Film", options.map { "Up to \($0.filmMinutes) min, \($0.revisionRounds) revision round\($0.revisionRounds == 1 ? "" : "s")" }),
                row("Extras", options.map { o in o.extras.isEmpty ? "<span class=no>Main film only</span>" : e(o.extras.map { $0.deliverable(o.quantity($0)) }.joined(separator: ", ")) }),
            ]
            for category in categories {
                rows.append(row(category, estimates.map { est in Money.string(est.clientLines.first { $0.category == category }?.amount ?? 0) }, cls: "line"))
            }
            if estimates.contains(where: { $0.travelAllowance > 0 }) {
                rows.append(row("Travel allowance", estimates.map { $0.travelAllowance > 0 ? Money.string($0.travelAllowance) : "<span class=no>None</span>" }, cls: "line"))
            }
            rows.append(row("Total", estimates.map { Money.string($0.total) }, cls: "fee"))
            return """
            <section class=page>\(label("Packages"))<h1>\(options.count > 1 ? "Choose the level that fits." : "The investment, line by line.")</h1>
              <table class=compare><thead><tr><th></th>\(options.map { "<th>\(e($0.name))<span>\(e($0.tagline))</span></th>" }.joined())</tr></thead>
              <tbody>\(rows.joined())</tbody></table>
              \(addOnsTable())
              \(footer("Itemized Packages"))
            </section>
            """
        }

        func addOnsTable() -> String {
            guard let addOns = deal.addOns, !addOns.isEmpty else { return "" }
            return "<div class=col-label style='margin-top:24px'>Add-ons, priced separately</div><table class=budgett style='margin-top:6px'><tbody>\(addOns.map { "<tr><th>\(e($0.name))</th><td>\(e($0.note))</td><td class=amt>\(Money.string($0.price))</td></tr>" }.joined())</tbody></table>"
        }

        func shortTermsAndProof() -> String {
            let facts = termsFacts(), work = proofBlock()
            guard !facts.isEmpty || !work.isEmpty else { return "" }
            return """
            <section class=page>\(label("Terms + Recent Work"))<h1>Clear terms, and work like yours.</h1>
              \(facts)\(work)
              \(footer("In Writing, Before the Shoot"))
            </section>
            """
        }

        func optionPage(_ option: ScopeOption, allOptions: [ScopeOption]) -> String {
            let est = store.estimate(option)
            let allExtras = Extra.allCases.filter { x in allOptions.contains { $0.extras.contains(x) } }
            let missing = allExtras.filter { !option.extras.contains($0) }.map(\.label)
            return """
            <section class=page>
              <div class=opt-head><div><div class=sec-label>\(e(option.name)) / \(e(option.tagline))</div><h1>\(e(option.pitch.isEmpty ? deal.title : option.pitch))</h1></div><div class=amount>\(Money.string(est.quote))</div></div>
              <div class=grid2 style="gap:36px">
                <div><div class=col-label>What's included</div><ul>\(ProposalRenderer.included(option, store: store).map { "<li>\(e($0))</li>" }.joined())</ul>
                  \(option.clientTakesOn.isEmpty ? "" : "<div class=col-label style='margin-top:20px'>You take on</div><ul>\(option.clientTakesOn.map { "<li>\(e($0))</li>" }.joined())</ul>")
                  \(missing.isEmpty ? "" : "<div class=col-label style='margin-top:20px'>Not in this option</div><ul class=minus>\(missing.map { "<li>\(e($0))</li>" }.joined())</ul>")
                  \(option.note.isEmpty ? "" : "<p class=fine>\(e(option.note))</p>")</div>
                <div><div class=col-label>Budget</div><table class=budgett><tbody>
                  \(est.clientLines.map { "<tr><th>\(e($0.category))</th><td>\(e($0.covers))\($0.detail.isEmpty ? "" : "<small>\(e($0.detail))</small>")</td><td class=amt>\(Money.string($0.amount))</td></tr>" }.joined())
                  \(est.travelAllowance > 0 ? "<tr><th>Travel allowance</th><td>Flights, hotels and per diems, passed through at cost</td><td class=amt>\(Money.string(est.travelAllowance))</td></tr>" : "")
                  <tr class=total><th>Total</th><td></td><td class=amt>\(Money.string(est.total))</td></tr></tbody></table></div>
              </div>
              \(footer(option.name))
            </section>
            """
        }

        func terms() -> String {
            let facts = termsFacts()
            guard !facts.isEmpty else { return "" }
            return """
            <section class=page>\(label("Terms"))<h1>Clear terms that protect us both.</h1>
              \(facts)
              \(footer("In Writing, Before the Shoot"))
            </section>
            """
        }

        func termsFacts() -> String {
            guard let t = deal.terms else { return "" }
            let deposit = est.total * t.depositPercent / 100
            let revisions = deal.options.count > 1
                ? deal.options.map { "\($0.name): \($0.revisionRounds)" }.joined(separator: " · ") + " consolidated rounds. Extra rounds are priced as an add-on."
                : "\(lead.revisionRounds) consolidated round\(lead.revisionRounds == 1 ? "" : "s"). Extra rounds are priced as an add-on."
            let turnaround = "Rough cut \(r.roughCutBusinessDays) business days after filming wraps. Your consolidated feedback within \(r.feedbackBusinessDays) business days. Final \(r.finalBusinessDays) business days after that."
            let rows = [
                ("Deposit", "\(Int(t.depositPercent))% (\(Money.string(deposit)) on \(deal.chosenOption == nil && deal.options.count > 1 ? lead.name : "this scope")) locks the date. No deposit, no booking."),
                ("Payment schedule", t.paymentSchedule), ("Revisions", revisions), ("Turnaround", turnaround),
                ("Usage rights", t.usageRights), ("Cancellation", t.cancellation), ("Weather", t.weather),
            ].filter { !$0.1.isEmpty }
            return "<div class=facts>\(rows.map { "<div><span>\(e($0.0))</span>\(e($0.1))</div>" }.joined())</div>"
        }

        func proof() -> String {
            let block = proofBlock()
            guard !block.isEmpty else { return "" }
            return """
            <section class=page>\(label("Recent Work"))<h1>Work like yours.</h1>
              \(block)
              \(footer("Proof"))
            </section>
            """
        }

        func proofBlock() -> String {
            let picked = (deal.proofProjectIDs ?? []).compactMap { projects.project(id: $0) }
            let stats = [(r.yearsInBusiness, "years telling stories"), (r.projectsCompleted, "projects delivered"), (r.reviewSummary, "")]
                .filter { !$0.0.isEmpty }
            let testimonial = deal.testimonial ?? ""
            guard !picked.isEmpty || !testimonial.isEmpty || !stats.isEmpty else { return "" }
            return """
              \(stats.isEmpty ? "" : "<div class=stats>\(stats.map { "<div><b>\(e($0.0))</b>\(e($0.1))</div>" }.joined())</div>")
              <div class=cards>\(picked.map { p in
                "<div class=card><div class=card-t>\(e(p.name))</div><p>\(e(p.client))\(p.location.isEmpty ? "" : " · \(e(p.location))")</p>\((p.portfolioURL ?? "").isEmpty ? "" : "<p><a href='\(e(p.portfolioURL ?? ""))'>Watch ↗</a></p>")</div>" }.joined())</div>
              \(testimonial.isEmpty ? "" : "<blockquote>\(e(testimonial))</blockquote>")
            """
        }

        func investment(withTimeline: Bool) -> String {
            let options = deal.options
            let totals = options.map { store.estimate($0).total }
            let priceText = deal.chosenOption != nil || options.count == 1
                ? Money.string(est.total)
                : "\(Money.string(totals.min() ?? 0))–\(Money.string(totals.max() ?? 0))"
            let accept = deal.acceptHow ?? r.acceptHow
            let expires = deal.expiresOn.map { "This proposal is valid until \($0.formatted(date: .long, time: .omitted))." } ?? ""
            return """
            <section class=page>\(label("Investment + Next Steps"))<h1>A shared plan to bring this film to life.</h1>
              <div class=grid2 style="gap:48px">
                <div><div class=col-label>What this includes</div><ul>\(ProposalRenderer.included(lead, store: store).map { "<li>\(e($0))</li>" }.joined())</ul></div>
                \(withTimeline && !deal.milestones.isEmpty ? "<div><div class=col-label>Timeline</div>\(deal.milestones.map { "<div class=tl><b>\(e($0.phase))</b><span>\(e($0.when))</span></div>" }.joined())</div>" : "")
              </div>
              \(deal.nextSteps.isEmpty ? "" : "<div class=col-label style='margin-top:28px'>Next steps</div><div class=steps>\(deal.nextSteps.enumerated().map { "<div><i>\($0.offset + 1)</i>\(e($0.element.text))</div>" }.joined())</div>")
              \(accept.isEmpty && expires.isEmpty ? "" : "<p class=note>\(e(accept)) \(e(expires))</p>")
              <div class=budget><div><div class=col-label>\(options.count > 1 && deal.chosenOption == nil ? "Packages" : "Total investment")</div>
                \(lead.travelAllowance > 0 ? "<div class=bnote>Includes an estimated \(Money.string(lead.travelAllowance)) travel allowance.</div>" : "")</div>
                <div class=amount>\(priceText)</div></div>
              \(footer(""))
            </section>
            """
        }

        func closing() -> String {
            """
            <section class="page dark">\(header)
              <div class=cover><h1 class=cover-h>Thank you for considering this project.</h1>
                <div class=sig>\(e(owner))</div>
                <div class=contact>\(r.email.isEmpty ? "" : "<div><span>Email</span>\(e(r.email))</div>")\(r.website.isEmpty ? "" : "<div><span>Web</span>\(e(r.website))</div>")</div>
              </div>\(footer(owner + (r.businessName.isEmpty ? "" : " " + r.businessName)))
            </section>
            """
        }
    }

    static func included(_ o: ScopeOption, store: DealStore) -> [String] {
        let est = store.estimate(o)
        let planning = est.workload.first?.hoursText ?? ""
        let post = est.workload.first { $0.label.hasPrefix("Main film") }?.hoursText ?? ""
        var items = [
            "Up to \(o.filmMinutes) minute film with up to \(o.interviewees) principal voices",
            "\(o.localDays) local filming day\(o.localDays == 1 ? "" : "s"), Emma plus \(o.localCrew) collaborator\(o.localCrew == 1 ? "" : "s")",
        ]
        if o.travelDays > 0 {
            items.append("\(o.travelDays) out-of-state day\(o.travelDays == 1 ? "" : "s")\(o.travelPlaces.isEmpty ? "" : " (\(o.travelPlaces))") plus travel and preparation")
        }
        items.append("\(planning) hours of planning and \(post) hours of post-production")
        items.append("\(o.revisionRounds) consolidated revision round\(o.revisionRounds == 1 ? "" : "s")")
        items += o.extras.map { $0.deliverable(o.quantity($0)) }
        items.append("Color, sound, titles, licensed music and captions")
        return items
    }

    // MARK: - Helpers

    nonisolated static func e(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    nonisolated static func words(_ n: Int) -> String {
        let names = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return n >= 0 && n < names.count ? names[n] : "\(n)"
    }

    private static func head(title: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name=viewport content="width=device-width,initial-scale=1">
        <title>\(e(title))</title>
        <link rel=stylesheet href="https://fonts.googleapis.com/css2?family=Libre+Baskerville:ital,wght@0,400;0,700;1,400&family=Inter:wght@400;600;700&display=swap">
        <style>
        :root{--bg:#F0EBE1;--fg:#1E3530;--muted:#5A6A61;--accent:#A85B40;--tint:#E8EDE2;--rule:#C5BDB0;--white:#FDFCF9;--d:'Libre Baskerville',Georgia,serif;--b:'Inter','Helvetica Neue',sans-serif}
        *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.6 var(--b);-webkit-font-smoothing:antialiased}
        a{color:var(--accent)}
        .page{max-width:960px;min-height:640px;margin:0 auto;padding:36px 48px 28px;display:flex;flex-direction:column;border-bottom:1px solid var(--rule);break-after:page}
        .dark{background:var(--fg);color:var(--white)}
        .hdr{display:flex;justify-content:space-between;padding-bottom:14px;border-bottom:1.5px solid rgba(255,255,255,.15);font-size:11px;font-weight:700;letter-spacing:.08em;text-transform:uppercase}.hdr-right{opacity:.5}
        .ftr{margin-top:auto;display:flex;justify-content:space-between;padding-top:10px;border-top:1px solid var(--rule);font-size:11px}.dark .ftr{border-color:rgba(255,255,255,.15)}
        .ftr-label{text-transform:uppercase;letter-spacing:.06em;color:var(--muted)}.dark .ftr-label{color:rgba(255,255,255,.4)}.ftr-num{font-weight:700}
        .sec-label,.col-label,.eyebrow{font-size:11px;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:var(--accent)}.sec-label{margin-top:28px}.col-label{margin-bottom:12px}
        h1{font:400 clamp(26px,4vw,38px)/1.2 var(--d);margin:10px 0 0;text-wrap:balance}h3{font:400 18px/1.35 var(--d);margin:10px 0}
        .sub,.fine,.note{color:var(--muted)}.fine{font-size:12px}.note{margin-top:16px}
        .cover{flex:1;display:flex;flex-direction:column;justify-content:center;gap:20px;max-width:720px}.cover-h{font-size:clamp(34px,5vw,50px);color:var(--white)}
        .cover-sub{font-size:16px;color:rgba(255,255,255,.75);margin:0}.callout{background:rgba(255,255,255,.06);padding:22px 26px}.prepared{font-size:10px;letter-spacing:.08em;text-transform:uppercase;opacity:.4}
        .two{display:grid;grid-template-columns:1fr 300px;gap:32px;margin-top:24px}.side{background:var(--tint);padding:26px}
        .cards{display:grid;grid-template-columns:repeat(3,1fr);gap:12px;margin-top:28px}.card{background:var(--tint);padding:24px}.card p{font-size:13px;color:var(--muted);margin:8px 0 0}
        .num{font-weight:700;color:var(--accent)}.card-t{font:400 17px/1.3 var(--d);margin-top:10px}
        .rows{display:flex;flex-direction:column;gap:20px;margin-top:24px}.row{display:grid;grid-template-columns:200px 1fr;gap:20px}.row b{font-size:16px}.core{background:var(--tint);padding:22px 26px}
        .grid2{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-top:24px}
        .facts{display:flex;flex-direction:column;margin-top:24px}.facts div{display:grid;grid-template-columns:220px 1fr;gap:20px;padding:12px 0;border-bottom:1px solid var(--rule)}
        .facts span{font-size:11px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:var(--accent);padding-top:3px}
        .stats{display:flex;gap:40px;margin-top:24px}.stats b{display:block;font:400 32px var(--d)}.stats div{color:var(--muted);font-size:13px}
        blockquote{margin:28px 0 0;padding:22px 26px;background:var(--tint);font:italic 17px/1.5 var(--d)}
        table{width:100%;border-collapse:collapse;margin-top:20px;font-size:13px}th{text-align:left}td,th{padding:11px 14px;vertical-align:top}
        .work thead th,.compare thead th{background:var(--fg);color:var(--white);font:400 16px var(--d)}.work thead th{font:700 11px var(--b);letter-spacing:.06em;text-transform:uppercase}
        .work td:nth-child(n+2){text-align:right;font-weight:600;white-space:nowrap}td small{display:block;color:var(--muted);font-size:12px}
        tbody tr{border-bottom:1px solid var(--rule)}tbody tr:nth-child(even){background:var(--tint)}tr.total{background:var(--fg)!important;color:var(--white);font-weight:700}tr.total small{color:inherit}
        .compare thead th span{display:block;font:600 11px var(--b);letter-spacing:.08em;text-transform:uppercase;opacity:.7}.compare tbody th{color:var(--accent);font-size:12px;width:19%}
        .compare .pitch td{font-size:14px}.compare tr.line td{font-variant-numeric:tabular-nums}.compare .fee td{font:22px var(--d)}.no{color:var(--muted)}
        .opt-head{display:flex;justify-content:space-between;align-items:flex-end;gap:24px;padding-bottom:16px;border-bottom:1.5px solid var(--rule)}
        .amount{font:clamp(32px,4.5vw,46px) var(--d);white-space:nowrap}.budgett th{width:30%}.amt{text-align:right;white-space:nowrap}
        ul{list-style:none;padding:0;margin:0;display:flex;flex-direction:column;gap:8px}li{padding-left:14px;position:relative}li:before{content:'';position:absolute;left:0;top:9px;width:5px;height:5px;border-radius:50%;background:var(--accent)}
        ul.minus li{color:var(--muted)}ul.minus li:before{background:var(--muted)}
        .tl{display:flex;justify-content:space-between;padding:9px 0;border-bottom:1px solid var(--rule)}.tl span{color:var(--muted)}
        .steps{display:flex;gap:24px}.steps div{flex:1}.steps i{font:22px var(--d);color:var(--accent);font-style:normal;margin-right:10px}
        .budget{background:var(--fg);color:var(--white);display:flex;justify-content:space-between;align-items:center;padding:24px 28px;margin-top:24px}.bnote{font-size:12px;opacity:.55}
        .sig{font:italic 24px var(--d)}.contact{display:flex;gap:32px}.contact span{display:block;font-size:10px;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:#C4785E}
        @media(max-width:700px){.page{padding:24px 16px}.two,.cards,.grid2,.row,.facts div{grid-template-columns:1fr}.steps,.opt-head,.stats{flex-direction:column}.compare{font-size:12px}}
        @media print{.page{border:none}}
        </style></head><body>
        """
    }
}
