import Foundation

/// Everyone the user works with, kept in people.json. Lens fills it in by itself from deal contacts,
/// project clients and people, two-way Gmail conversations, website form emails, Instagram and Facebook
/// message emails and Zoom calls, and merges obvious duplicates (same email, or same name and company).
/// People Lens adds by itself show in "Added recently" for two weeks, where the user can Keep, Edit or Remove
/// them. She can also bring in LinkedIn and Facebook or Instagram downloads, and scan business cards.
/// the user can add, edit, merge, split and remove people by hand; anything she removes stays gone.
@MainActor
final class PeopleStore: ObservableObject {
    @Published private(set) var people: [Person] = []
    /// Left over from older versions, which asked before adding people found in Gmail. Now always empty:
    /// anything in an older file is added on load.
    private var suggestions: [PersonSuggestion] = []

    /// Emails and names the user removed or ignored, so Lens doesn't bring them back.
    private var hidden: Set<String> = []

    private weak var deals: DealStore?
    private weak var projects: ProjectStore?
    private weak var money: MoneyStore?
    private weak var logins: ConnectionStore?
    /// the user's own addresses, seen while reading Gmail, so she never becomes a person.
    private var myEmails: Set<String> = []

    /// Quiet for this many days while on an open deal: worth a check-in.
    static let quietAfterDays = 30

    init() { load() }

    func attach(deals: DealStore, projects: ProjectStore, money: MoneyStore, logins: ConnectionStore? = nil) {
        self.deals = deals
        self.projects = projects
        self.money = money
        self.logins = logins
        sync(deals: deals.deals, projects: projects.projects)
    }

    func person(id: UUID?) -> Person? {
        guard let id else { return nil }
        return people.first { $0.id == id }
    }

    var sorted: [Person] {
        people.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Changes

    func add(_ person: Person) {
        people.append(person)
        save()
    }

    func update(_ person: Person) {
        guard let i = people.firstIndex(where: { $0.id == person.id }) else { return }
        var p = person
        p.emails = Self.cleanEmails(p.emails)
        people[i] = p
        // Gave them an email someone else already has: that's the same person.
        if let j = people.firstIndex(where: { $0.id != p.id && !Set($0.emails).isDisjoint(with: p.emails) && !Self.keptApart($0, p) }) {
            let other = people[j]
            people[i] = Self.combined(p, other)
            people.remove(at: j)
        }
        save()
    }

    /// Clears out people Lens added by itself who aren't real contacts: machine senders, and people from
    /// one-way email (never a back-and-forth) who aren't on a deal or project and Emma never touched.
    /// Returns how many were removed. Removed people aren't added again.
    @discardableResult
    func tidy() -> Int {
        let before = people.count
        people.removeAll { p in
            guard p.automatic, p.dealIDs.isEmpty, p.projectIDs.isEmpty, p.notes.isEmpty, p.followUp == nil,
                  p.phone.isEmpty, p.tags.isEmpty, p.touches.isEmpty else { return false }
            if p.emails.contains(where: Self.isAutomated) { hidden.formUnion(p.emails); return true }
            guard (p.addedFrom ?? "Gmail") == "Gmail" else { return false }
            // No conversation with more than one message: nobody wrote back and forth.
            let realTalk = p.threads.contains { $0.messageCount >= 2 && !Self.isAutoReply($0.subject) }
            if !realTalk { hidden.formUnion(p.emails); return true }
            return false
        }
        let removed = before - people.count
        if removed > 0 { save() }
        return removed
    }

    func delete(_ person: Person) {
        people.removeAll { $0.id == person.id }
        hidden.formUnion(person.emails)
        let key = Person.nameKey(person.name)
        if !key.isEmpty { hidden.insert("name:" + key) }
        save()
    }

    func logTouch(_ text: String, for person: Person) {
        guard var p = self.person(id: person.id) else { return }
        p.touches.append(ProjectEvent(text: text.isEmpty ? "Talked" : text))
        update(p)
    }

    func setFollowUp(_ date: Date?, note: String = "", for person: Person) {
        guard var p = self.person(id: person.id) else { return }
        p.followUp = date
        p.followUpNote = date == nil ? "" : note
        update(p)
    }

    /// Puts someone on a project (or deal). Undoes an earlier "take off".
    func link(_ person: Person, project id: UUID) {
        guard var p = self.person(id: person.id) else { return }
        if !p.projectIDs.contains(id) { p.projectIDs.append(id) }
        p.unlinked.removeAll { $0 == id }
        update(p)
    }

    func unlink(_ person: Person, from id: UUID) {
        guard var p = self.person(id: person.id) else { return }
        p.projectIDs.removeAll { $0 == id }
        p.dealIDs.removeAll { $0 == id }
        if !p.unlinked.contains(id) { p.unlinked.append(id) }
        update(p)
    }

    /// Folds `other` into `keep`: emails, tags, links, notes and history all end up on one person.
    func merge(_ other: Person, into keep: Person) {
        guard other.id != keep.id, let i = people.firstIndex(where: { $0.id == keep.id }),
              let j = people.firstIndex(where: { $0.id == other.id }) else { return }
        people[i] = Self.combined(people[i], people[j])
        people.remove(at: j)
        for k in people.indices where people[k].notSame.contains(other.id) {
            people[k].notSame = people[k].notSame.map { $0 == other.id ? keep.id : $0 }
        }
        save()
    }

    /// Two people got merged who aren't the same: one email (and the deals it's on) becomes its own person.
    @discardableResult
    func split(_ person: Person, email: String) -> UUID? {
        guard var original = self.person(id: person.id), original.emails.count > 1, original.emails.contains(email) else { return nil }
        original.emails.removeAll { $0 == email }
        var fresh = Person(name: original.name, emails: [email])
        fresh.company = original.company
        fresh.met = original.met
        fresh.tags = original.tags
        let theirDeals = (deals?.deals ?? []).filter { d in d.contacts.contains { $0.email.lowercased() == email } }
        for d in theirDeals where original.dealIDs.contains(d.id) {
            fresh.dealIDs.append(d.id)
            if let pid = d.projectID { fresh.projectIDs.append(pid) }
            // Only take it off the original if none of their other emails are on that deal.
            if !d.contacts.contains(where: { original.emails.contains($0.email.lowercased()) }) {
                original.dealIDs.removeAll { $0 == d.id }
                if let pid = d.projectID { original.projectIDs.removeAll { $0 == pid } }
            }
        }
        fresh.notSame = [original.id]
        original.notSame.append(fresh.id)
        if let i = people.firstIndex(where: { $0.id == original.id }) { people[i] = original }
        people.append(fresh)
        save()
        return fresh.id
    }

    // MARK: - Added recently

    /// People Lens added by itself in the last two weeks that the user hasn't kept yet, newest first.
    var recentlyAdded: [Person] {
        let now = Date()
        return people.filter { $0.isRecentlyAdded(now: now) }.sorted { ($0.addedOn ?? .distantPast) > ($1.addedOn ?? .distantPast) }
    }

    func keep(_ person: Person) {
        guard let i = people.firstIndex(where: { $0.id == person.id }) else { return }
        people[i].reviewed = true
        save()
    }

    func keepAll() {
        let now = Date()
        for i in people.indices where people[i].isRecentlyAdded(now: now) { people[i].reviewed = true }
        save()
    }

    /// the user's own email addresses: never a person.
    func isMine(_ email: String) -> Bool {
        let e = email.lowercased()
        return myEmails.contains(e) || e == ConnectionStore.defaultOwnerEmail || e == logins?.ownerEmail
    }

    private func isHidden(_ p: Person) -> Bool {
        if !p.emails.isEmpty { return p.emails.contains(where: hidden.contains) }
        let key = Person.nameKey(p.name)
        return !key.isEmpty && hidden.contains("name:" + key)
    }

    /// Adds someone Lens found, or fills in the blanks on the person already here. Returns true if anything changed.
    @discardableResult
    private func absorb(_ incoming: Person) -> Bool {
        if let i = people.firstIndex(where: { Self.isSame($0, incoming) }) {
            let merged = Self.combined(people[i], incoming)
            guard merged != people[i] else { return false }
            people[i] = merged
            return true
        }
        people.append(incoming)
        return true
    }

    struct BringInResult {
        var added = 0
        /// Already in People (any missing details were filled in).
        var alreadyHere = 0
        /// People the user removed before, left out.
        var leftOut = 0
    }

    /// People from a LinkedIn or Meta download, or from business cards. New people are added, people
    /// already here get any missing details filled in. With `respectRemoved`, people the user removed stay out.
    @discardableResult
    func bringIn(_ incoming: [Person], respectRemoved: Bool = true) -> BringInResult {
        var result = BringInResult()
        for var p in incoming {
            p.name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
            p.emails = Self.cleanEmails(p.emails).filter { !isMine($0) }
            guard !p.name.isEmpty || !p.emails.isEmpty else { continue }
            if p.name.isEmpty { p.name = p.emails[0] }
            if respectRemoved {
                guard !isHidden(p) else { result.leftOut += 1; continue }
            } else {
                hidden.subtract(p.emails)
                hidden.remove("name:" + Person.nameKey(p.name))
            }
            let before = people.count
            absorb(p)
            if people.count > before { result.added += 1 } else { result.alreadyHere += 1 }
        }
        people = Self.mergeDuplicates(people)
        save()
        return result
    }

    /// Adds someone from a business card (or fills in the person already here) and returns who they ended up as.
    @discardableResult
    func addFromCard(_ p: Person) -> UUID? {
        bringIn([p], respectRemoved: false)
        return people.first { $0.id == p.id }?.id ?? people.first { Self.isSame($0, p) }?.id
    }

    // MARK: - People from Gmail, Instagram, Facebook and Zoom

    /// Called for each Gmail conversation Lens reads. People already in Lens get the conversation on their page.
    /// Real people who wrote to the user about work (a two-way conversation, one on a deal or project, or a website
    /// form) are added by themselves.
    func noteThread(_ thread: GmailAPI.Thread, link: EmailThread, me: String, onFile: Bool) {
        if !me.isEmpty { myEmails.insert(me.lowercased()) }
        var everyone: [String: String] = [:]   // email → name
        var senders = Set<String>()
        for m in thread.messages {
            for (raw, isSender) in [(m.from, true), (m.replyTo, true), (m.to, false)] {
                for part in raw.split(separator: ",") {
                    let a = GmailAPI.parseAddress(String(part))
                    guard a.email.contains("@"), a.email != me, !isMine(a.email), !Self.isAutomated(a.email) else { continue }
                    if everyone[a.email] == nil || everyone[a.email] == a.email { everyone[a.email] = a.name }
                    if isSender { senders.insert(a.email) }
                }
            }
        }
        let emmaWrote = thread.messages.contains { GmailAPI.parseAddress($0.from).email == me }
        // Auto-replies, bounces and out-of-office notes never add anyone.
        let autoReply = thread.messages.contains { Self.isAutoReply($0.subject) }
        // Who actually wrote a message here (not just copied on it).
        let wrote = Set(thread.messages.map { GmailAPI.parseAddress($0.from).email.lowercased() })
        // A website form or a wedding directory sent it: the person is in Reply-To.
        let formSource: String? = thread.messages.lazy.compactMap { m -> String? in
            let domain = GmailAPI.parseAddress(m.from).email.split(separator: "@").last.map(String.init) ?? ""
            return GmailSync.leadSenders.first { domain == $0.domain || domain.hasSuffix("." + $0.domain) }?.source
        }.first
        // Booking forms like Acuity send from a no-reply address: the client's email is in the message itself.
        if formSource != nil, senders.isEmpty, let first = thread.messages.first,
           let email = GmailSync.clientEmail(in: first.text, me: me, sender: GmailAPI.parseAddress(first.from).email),
           !isMine(email) {
            everyone[email] = GmailSync.clientName(in: first.text) ?? email
            senders.insert(email)
        }
        var changed = false
        for (email, name) in everyone {
            if let i = people.firstIndex(where: { $0.emails.contains(email) }) {
                var list = people[i].threads
                if let k = list.firstIndex(where: { $0.id == link.id }) {
                    guard list[k] != link else { continue }
                    list[k] = link
                } else {
                    list.append(link)
                }
                people[i].threads = Array(list.sorted { $0.lastDate > $1.lastDate }.prefix(40))
                changed = true
            } else if !autoReply, senders.contains(email), !hidden.contains(email),
                      // A real conversation: Emma wrote and they wrote back. Or a website or booking form.
                      (emmaWrote && wrote.contains(email.lowercased())) || formSource != nil {
                let clean = name == email ? "" : name
                var p = Person(name: clean.isEmpty ? email : clean, emails: [email], automatic: true)
                p.threads = [link]
                let website = formSource == "Website form"
                p.met = website ? "Website" : (formSource ?? "Email")
                p.addedFrom = website ? "your website" : (formSource ?? "Gmail")
                p.addedOn = Date()
                if absorb(p) { changed = true }
            }
        }
        if changed { save() }
    }

    /// Instagram and Facebook email the user when someone messages her ("Jordan Reyes sent you a message").
    /// Those people are added with where they wrote from. Names only: these emails don't share addresses.
    func noteSocial(_ thread: GmailAPI.Thread) {
        var changed = false
        for m in thread.messages {
            let from = GmailAPI.parseAddress(m.from)
            let domain = from.email.split(separator: "@").last.map { String($0).lowercased() } ?? ""
            let site: String
            if domain.contains("instagram") { site = "Instagram" }
            else if domain == "facebookmail.com" || domain.hasSuffix(".facebookmail.com") || domain.contains("facebook") { site = "Facebook" }
            else { continue }
            guard let found = Self.socialSender(subject: m.subject, fromName: from.name == from.email ? "" : from.name) else { continue }
            var p = Person(name: found.name, automatic: true)
            if let handle = found.handle, site == "Instagram" { p.link = "@" + handle }
            p.met = site
            p.addedFrom = site
            p.addedOn = Date()
            guard !isHidden(p) else { continue }
            // Already here with this handle: nothing to add.
            if !p.link.isEmpty, people.contains(where: { $0.link.lowercased() == p.link.lowercased() }) { continue }
            if absorb(p) { changed = true }
        }
        if changed { save() }
    }

    /// Someone who messaged Emma on Instagram or Facebook (read straight from Meta).
    func noteDM(name: String, handle: String, site: String) {
        guard !name.isEmpty || !handle.isEmpty else { return }
        var p = Person(name: name.isEmpty ? handle : name, automatic: true)
        if !handle.isEmpty, site == "Instagram" { p.link = "@" + handle }
        p.met = site
        p.addedFrom = site
        p.addedOn = Date()
        guard !isHidden(p) else { return }
        if !p.link.isEmpty, people.contains(where: { $0.link.lowercased() == p.link.lowercased() }) { return }
        if absorb(p) { save() }
    }

    /// Who wrote, from an Instagram or Facebook message email. Nil when it isn't about a message.
    static func socialSender(subject: String, fromName: String) -> (name: String, handle: String?)? {
        let s = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = ["^(.+?) (?:sent you a message|sent you messages|wants to send you a message|messaged you|replied to your story|sent you a photo|sent you a video)",
                        "^(?:new message from|message from|you have a new message from) (.+?)$",
                        "^(.+?) \\(@[A-Za-z0-9._]+\\) (?:sent|wants|messaged)"]
        var raw: String?
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let r = Range(m.range(at: 1), in: s) else { continue }
            raw = String(s[r])
            break
        }
        let generic = ["facebook", "instagram", "messenger", "meta", "someone", "a friend", "you"]
        if raw == nil, !fromName.isEmpty, !generic.contains(fromName.lowercased()), s.lowercased().contains("message") {
            raw = fromName
        }
        guard var name = raw?.trimmingCharacters(in: .whitespaces), !name.isEmpty, !generic.contains(name.lowercased()) else { return nil }
        // "Jordan Reyes (@jordanreyes)" or "@jordanreyes" or "jordanreyes".
        var handle: String?
        let handlePattern = try? NSRegularExpression(pattern: "@([A-Za-z0-9._]+)")
        if let m = handlePattern?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) {
            handle = String(s[r])
        }
        if let open = name.firstIndex(of: "(") { name = String(name[..<open]).trimmingCharacters(in: .whitespaces) }
        if name.hasPrefix("@") { name.removeFirst() }
        if !name.contains(" "), name.range(of: "^[a-z0-9._]+$", options: .regularExpression) != nil { handle = handle ?? name }
        guard name.count <= 60, !name.isEmpty else { return nil }
        return (name, handle)
    }

    /// Everyone on a Zoom call (with an email) becomes a person, unless they're already here.
    func noteMeetings(_ notes: [MeetingNote]) {
        var changed = false
        for n in notes {
            var found: [(name: String, email: String)] = (n.people ?? []).map { ($0.name, $0.email.lowercased()) }
            found += (n.attendees ?? []).map { ("", $0.lowercased()) }
            for (name, email) in found where email.contains("@") && !isMine(email) && !Self.isAutomated(email) && !hidden.contains(email) {
                if people.contains(where: { $0.emails.contains(email) }) { continue }
                let clean = name.trimmingCharacters(in: .whitespaces)
                var p = Person(name: clean.isEmpty ? email : clean, emails: [email], automatic: true)
                p.met = "Zoom"
                p.addedFrom = "a Zoom call"
                p.addedOn = Date()
                if absorb(p) { changed = true }
            }
        }
        if changed { save() }
    }

    /// No-reply senders, newsletters, notifications and services: never people.
    /// "Automatic reply", "Out of office", "Undeliverable"… subjects that come from machines, not people.
    static func isAutoReply(_ subject: String) -> Bool {
        let s = subject.lowercased()
        return ["automatic reply", "auto reply", "autoreply", "auto-reply", "out of office", "out of the office",
                "away from", "undeliverable", "delivery status", "delivery failure", "mail delivery", "returned mail",
                "auto:", "vacation", "thank you for contacting", "thanks for contacting", "we received your",
                "your order", "order confirmation", "receipt", "verify your", "confirm your", "password", "security alert",
                "unsubscribe", "newsletter", "webinar", "% off", "sale ends"].contains(where: s.contains)
    }

    static func isAutomated(_ email: String) -> Bool {
        let e = email.lowercased()
        let parts = e.split(separator: "@")
        guard parts.count == 2 else { return true }
        let local = String(parts[0]), domain = String(parts[1])
        let words = ["noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "do_not_reply", "notification",
                     "newsletter", "mailer-daemon", "postmaster", "bounce", "unsubscribe", "digest", "automated",
                     "alerts", "updates", "marketing", "receipts", "billing", "invoice", "calendar-server",
                     "reply", "orders", "order-", "shop", "store", "promo", "deals", "offers", "rewards", "account",
                     "security", "verify", "confirm", "feedback", "survey", "community", "events@", "press@"]
        if words.contains(where: local.contains) { return true }
        if ["news", "info-news", "notify", "support", "help", "team", "hello-news", "service", "customerservice",
            "care", "sales", "admin", "accounts", "membership", "members", "jobs", "careers"].contains(local) { return true }
        let services = ["zoom.us", "calendar.google.com", "mailchimp.com", "mcsv.net", "substack.com", "facebookmail.com",
                        "sendgrid.net", "mailgun.org", "constantcontact.com", "hubspotemail.net", "klaviyomail.com",
                        "amazonses.com", "intuit.com", "paypal.com", "venmo.com", "stripe.com",
                        "google.com", "apple.com", "amazon.com", "linkedin.com", "instagram.com", "facebook.com",
                        "x.com", "twitter.com", "uber.com", "lyft.com", "airbnb.com", "etsy.com", "shopify.com",
                        "adobe.com", "dropbox.com", "notion.so", "slack.com", "canva.com", "github.com", "microsoft.com",
                        "youtube.com", "spotify.com", "netflix.com", "freshbooks.com", "acuityscheduling.com",
                        "calendly.com", "docusign.net", "eventbrite.com", "squarespace.com", "wix.com", "vimeo.com",
                        "frame.io", "bhphotovideo.com", "adorama.com", "usps.com", "ups.com", "fedex.com"]
            + GmailSync.leadSenders.map(\.domain)
        return services.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }

    // MARK: - Building people from deals and projects

    /// Makes sure everyone on a deal or project is in People and linked to it. Runs whenever deals or
    /// projects change. Only adds and links; never removes anything the user set.
    func sync(deals: [Deal], projects: [Project]) {
        var list = people

        func find(email: String, name: String) -> Int? {
            if !email.isEmpty, let i = list.firstIndex(where: { $0.emails.contains(email) }) { return i }
            let key = Person.nameKey(name)
            guard !key.isEmpty else { return nil }
            return list.firstIndex { Person.nameKey($0.name) == key && (email.isEmpty || $0.emails.isEmpty) }
        }

        func hide(email: String, name: String) -> Bool {
            if !email.isEmpty { return hidden.contains(email) }
            return hidden.contains("name:" + Person.nameKey(name))
        }

        for deal in deals {
            for contact in deal.contacts {
                let rawEmail = contact.email.trimmingCharacters(in: .whitespaces).lowercased()
                let email = rawEmail.contains("@") ? rawEmail : ""
                let name = contact.name.trimmingCharacters(in: .whitespaces).isEmpty ? email : contact.name.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !hide(email: email, name: name), email.isEmpty || (!Self.isAutomated(email) && !isMine(email)) else { continue }
                let i: Int
                if let found = find(email: email, name: name) {
                    i = found
                } else {
                    var p = Person(name: name, emails: email.isEmpty ? [] : [email], automatic: true)
                    p.met = deal.source
                    p.createdAt = deal.createdAt
                    p.addedFrom = "a deal"
                    p.addedOn = Date()
                    list.append(p)
                    i = list.count - 1
                }
                var p = list[i]
                if !email.isEmpty, !p.emails.contains(email) { p.emails.append(email) }
                if p.role.isEmpty { p.role = contact.role }
                if p.company.isEmpty, Person.nameKey(deal.client) != Person.nameKey(name) { p.company = deal.client }
                if p.met.isEmpty { p.met = deal.source }
                if !p.unlinked.contains(deal.id), !p.dealIDs.contains(deal.id) { p.dealIDs.append(deal.id) }
                if let pid = deal.projectID, !p.unlinked.contains(pid), !p.projectIDs.contains(pid) { p.projectIDs.append(pid) }
                Self.tagFromRole(&p)
                if deal.stage == .won {
                    if !p.has(.client) { p.addTag(PersonTag.client.rawValue); p.tags.removeAll { $0 == PersonTag.lead.rawValue } }
                } else if deal.stage.isOpen, !p.has(.client), !p.has(.lead), p.tags.isEmpty {
                    p.addTag(PersonTag.lead.rawValue)
                }
                list[i] = p
            }
        }

        // The people the user (or Lens) put on each project.
        for project in projects {
            for person in project.people ?? [] {
                let rawEmail = person.email.trimmingCharacters(in: .whitespaces).lowercased()
                let email = rawEmail.contains("@") ? rawEmail : ""
                let trimmed = person.name.trimmingCharacters(in: .whitespaces)
                let name = trimmed.isEmpty ? email : trimmed
                guard !name.isEmpty, !hide(email: email, name: name), email.isEmpty || (!Self.isAutomated(email) && !isMine(email)) else { continue }
                let i: Int
                if let found = find(email: email, name: name) {
                    i = found
                } else {
                    var p = Person(name: name, emails: email.isEmpty ? [] : [email], automatic: true)
                    p.createdAt = project.createdAt
                    p.addedFrom = "a project"
                    p.addedOn = Date()
                    list.append(p)
                    i = list.count - 1
                }
                var p = list[i]
                if !email.isEmpty, !p.emails.contains(email) { p.emails.append(email) }
                if p.name.contains("@"), !trimmed.isEmpty, !trimmed.contains("@") { p.name = trimmed }
                if p.role.isEmpty, person.role != "Client" { p.role = person.role }
                if person.role == "Client" { p.addTag(PersonTag.client.rawValue); p.tags.removeAll { $0 == PersonTag.lead.rawValue } }
                if !p.unlinked.contains(project.id), !p.projectIDs.contains(project.id) { p.projectIDs.append(project.id) }
                Self.tagFromRole(&p)
                list[i] = p
            }
        }

        for project in projects {
            if list.contains(where: { $0.projectIDs.contains(project.id) }) { continue }
            let client = project.client.trimmingCharacters(in: .whitespaces)
            let key = Person.nameKey(client)
            guard !key.isEmpty else { continue }
            if let i = list.firstIndex(where: { Person.nameKey($0.name) == key && !$0.unlinked.contains(project.id) }) {
                list[i].projectIDs.append(project.id)
                continue
            }
            let sameCompany = list.indices.filter { Person.nameKey(list[$0].company) == key && !list[$0].unlinked.contains(project.id) }
            if sameCompany.count == 1 {
                list[sameCompany[0]].projectIDs.append(project.id)
                continue
            }
            if !sameCompany.isEmpty || hidden.contains("name:" + key) { continue }
            // Skip anyone the user took off this project on purpose.
            if list.contains(where: { $0.unlinked.contains(project.id) }) { continue }
            var p = Person(name: client, automatic: true)
            p.projectIDs = [project.id]
            p.createdAt = project.createdAt
            p.addedFrom = "a project"
            p.addedOn = Date()
            if project.stage.rawValue >= ProjectStage.booked.rawValue { p.addTag(PersonTag.client.rawValue) }
            list.append(p)
        }

        list = Self.mergeDuplicates(list)
        if list != people {
            people = list
            save()
        }
        // Everyone on the Zoom calls filed on these deals and projects.
        noteMeetings(deals.flatMap { $0.meetingNotes ?? [] } + projects.flatMap { $0.meetingNotes ?? [] })
    }

    private static func tagFromRole(_ p: inout Person) {
        let role = p.role.lowercased()
        for tag in [PersonTag.director, .interviewee, .crew, .vendor] where role.contains(tag.rawValue.lowercased()) {
            p.addTag(tag.rawValue)
        }
    }

    /// Same email, the same name and company, or the same name where at most one of them has an email: one person.
    static func isSame(_ a: Person, _ b: Person) -> Bool {
        guard !keptApart(a, b) else { return false }
        if !Set(a.emails).isDisjoint(with: b.emails) { return true }
        let name = Person.nameKey(a.name)
        guard !name.isEmpty, name == Person.nameKey(b.name) else { return false }
        if a.emails.isEmpty || b.emails.isEmpty { return true }
        let company = Person.nameKey(a.company)
        return !company.isEmpty && company == Person.nameKey(b.company)
    }

    private static func mergeDuplicates(_ input: [Person]) -> [Person] {
        var list = input
        var i = 0
        while i < list.count {
            var j = i + 1
            while j < list.count {
                let a = list[i], b = list[j]
                if isSame(a, b) {
                    list[i] = combined(a, b)
                    list.remove(at: j)
                } else {
                    j += 1
                }
            }
            i += 1
        }
        return list
    }

    private static func keptApart(_ a: Person, _ b: Person) -> Bool {
        a.notSame.contains(b.id) || b.notSame.contains(a.id)
    }

    private static func combined(_ a: Person, _ b: Person) -> Person {
        var p = a
        func fill(_ path: WritableKeyPath<Person, String>) { if p[keyPath: path].isEmpty { p[keyPath: path] = b[keyPath: path] } }
        fill(\.phone); fill(\.company); fill(\.role); fill(\.link); fill(\.met)
        if p.name.isEmpty || p.name.contains("@") { p.name = b.name }
        for e in b.emails where !p.emails.contains(e) { p.emails.append(e) }
        for t in b.tags { p.addTag(t) }
        if !b.notes.isEmpty { p.notes = p.notes.isEmpty ? b.notes : p.notes + "\n\n" + b.notes }
        if let f = b.followUp, p.followUp.map({ f < $0 }) ?? true { p.followUp = f; p.followUpNote = b.followUpNote }
        p.touches = (p.touches + b.touches).sorted { $0.date < $1.date }
        p.dealIDs += b.dealIDs.filter { !p.dealIDs.contains($0) }
        p.projectIDs += b.projectIDs.filter { !p.projectIDs.contains($0) }
        p.unlinked += b.unlinked.filter { !p.unlinked.contains($0) }
        p.threads += b.threads.filter { t in !p.threads.contains { $0.id == t.id } }
        p.threads.sort { $0.lastDate > $1.lastDate }
        p.notSame = (p.notSame + b.notSame.filter { !p.notSame.contains($0) }).filter { $0 != a.id && $0 != b.id }
        p.automatic = a.automatic && b.automatic
        p.createdAt = min(a.createdAt, b.createdAt)
        if p.addedFrom == nil { p.addedFrom = b.addedFrom }
        // Only "added recently" if both were: someone already in People stays out of that list.
        if let x = a.addedOn, let y = b.addedOn { p.addedOn = min(x, y) } else { p.addedOn = nil }
        if a.reviewed == true || b.reviewed == true { p.reviewed = true }
        let photos = (a.cardPhotos ?? []) + (b.cardPhotos ?? []).filter { !(a.cardPhotos ?? []).contains($0) }
        p.cardPhotos = photos.isEmpty ? nil : photos
        if p.metOn == nil { p.metOn = b.metOn }
        if p.connectedOn == nil { p.connectedOn = b.connectedOn }
        return p
    }

    private static func cleanEmails(_ emails: [String]) -> [String] {
        var out: [String] = []
        for e in emails.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) where !e.isEmpty && !out.contains(e) { out.append(e) }
        return out
    }

    // MARK: - Everything about one person

    func deals(for p: Person) -> [Deal] {
        p.dealIDs.compactMap { deals?.deal(id: $0) }.sorted { $0.lastTouch > $1.lastTouch }
    }

    func projects(for p: Person) -> [Project] {
        p.projectIDs.compactMap { projects?.project(id: $0) }.sorted { ($0.shootDate ?? $0.createdAt) > ($1.shootDate ?? $1.createdAt) }
    }

    func people(onProject id: UUID) -> [Person] { sorted.filter { $0.projectIDs.contains(id) } }
    func people(onDeal id: UUID) -> [Person] { sorted.filter { $0.dealIDs.contains(id) } }

    /// Their own conversations plus those on their deals and projects, newest first.
    func emails(for p: Person) -> [EmailThread] {
        var all = p.threads
        for t in deals(for: p).flatMap({ $0.emails ?? [] }) + projects(for: p).flatMap({ $0.emails ?? [] })
        where !all.contains(where: { $0.id == t.id }) { all.append(t) }
        return all.sorted { $0.lastDate > $1.lastDate }
    }

    /// Zoom notes on their deals and projects, plus (with `mentions`) any summary that mentions their full name.
    func meetingNotes(for p: Person, mentions: Bool = true) -> [MeetingNote] {
        var all = deals(for: p).flatMap { $0.meetingNotes ?? [] } + projects(for: p).flatMap { $0.meetingNotes ?? [] }
        if mentions, p.name.split(separator: " ").count >= 2 {
            let everywhere = (deals?.deals ?? []).flatMap { $0.meetingNotes ?? [] } + (projects?.projects ?? []).flatMap { $0.meetingNotes ?? [] }
            for n in everywhere where n.summary.localizedCaseInsensitiveContains(p.name) || n.title.localizedCaseInsensitiveContains(p.name) {
                all.append(n)
            }
        }
        var seen = Set<String>()
        return all.filter { seen.insert($0.id).inserted }.sorted { $0.date > $1.date }
    }

    struct Payment: Identifiable {
        let id = UUID()
        let date: Date
        let amount: Double
        let label: String
    }

    /// What they've paid: income booked to their projects, or paid invoices when the bank lines aren't sorted yet.
    func payments(for p: Person) -> [Payment] {
        guard let money else { return [] }
        var out: [Payment] = []
        let projectIDs = Set(p.projectIDs)
        let names = projects(for: p)
        for id in projectIDs {
            let label = names.first { $0.id == id }?.name ?? "A project"
            let txns = money.txns.filter { $0.projectID == id && $0.amount > 0 && $0.category.group == .income }
            if !txns.isEmpty {
                out += txns.map { Payment(date: $0.date, amount: $0.amount, label: label) }
            } else {
                out += money.receivables.filter { $0.projectID == id && $0.paidOn != nil }
                    .map { Payment(date: $0.paidOn!, amount: $0.amount, label: "\(label) · \($0.label)") }
            }
        }
        let keys = Set([Person.nameKey(p.name), Person.nameKey(p.company)].filter { !$0.isEmpty })
        out += money.receivables.filter { r in
            r.paidOn != nil && (r.projectID.map { !projectIDs.contains($0) } ?? true) && keys.contains(Person.nameKey(r.client))
        }.map { Payment(date: $0.paidOn!, amount: $0.amount, label: $0.label) }
        return out.sorted { $0.date > $1.date }
    }

    func totalPaid(by p: Person) -> Double { payments(for: p).reduce(0) { $0 + $1.amount } }

    /// The last time the user was in touch: an email, a call note, or a chat she logged.
    func lastInTouch(_ p: Person) -> Date? {
        // Only notes on their own deals and projects here: reading every summary for every row would be slow.
        let dates = p.touches.map(\.date) + emails(for: p).map(\.lastDate) + meetingNotes(for: p, mentions: false).map(\.date)
        return dates.max()
    }

    func daysQuiet(_ p: Person, now: Date = Date()) -> Int? {
        guard let last = lastInTouch(p) else { return nil }
        return Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: last),
                                               to: Calendar.current.startOfDay(for: now)).day
    }

    var followUpsDue: [Person] {
        people.filter { $0.isFollowUpDue() }.sorted { ($0.followUp ?? .distantPast) < ($1.followUp ?? .distantPast) }
    }

    /// People on open deals the user hasn't been in touch with for a while (and has no follow-up set for).
    var goneQuiet: [(person: Person, deal: Deal, days: Int)] {
        people.compactMap { p -> (Person, Deal, Int)? in
            guard p.followUp == nil, let deal = deals(for: p).first(where: { $0.stage.isOpen }) else { return nil }
            let days = daysQuiet(p) ?? deal.daysSinceTouch()
            return days >= Self.quietAfterDays ? (p, deal, days) : nil
        }
        .sorted { $0.2 > $1.2 }
    }

    func search(_ query: String) -> [Person] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return sorted }
        return sorted.filter { p in
            ([p.name, p.company, p.role, p.phone, p.link, p.met, p.notes, p.addedFrom ?? ""] + p.emails + p.tags)
                .contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    // MARK: - Timeline

    struct Moment: Identifiable {
        enum Kind { case deal, project, email, meeting, money, touch }
        let id: String
        let date: Date
        let kind: Kind
        let title: String
        let detail: String
        var dealID: UUID?
        var projectID: UUID?
        var link: String?
    }

    /// Everything with this person in one list, newest first.
    func timeline(for p: Person) -> [Moment] {
        var out: [Moment] = []
        for d in deals(for: p) {
            out.append(Moment(id: "deal-\(d.id)", date: d.createdAt, kind: .deal, title: d.title,
                              detail: "Inquiry came in · \(d.source)", dealID: d.id))
            for e in d.events {
                out.append(Moment(id: "de-\(e.id)", date: e.date, kind: .deal, title: d.title, detail: e.text, dealID: d.id))
            }
        }
        for pr in projects(for: p) {
            for e in pr.events {
                out.append(Moment(id: "pe-\(e.id)", date: e.date, kind: .project, title: pr.name, detail: e.text, projectID: pr.id))
            }
            if let shoot = pr.shootDate {
                out.append(Moment(id: "shoot-\(pr.id)", date: shoot, kind: .project, title: pr.name,
                                  detail: pr.location.isEmpty ? "Shoot day" : "Shoot day at \(pr.location)", projectID: pr.id))
            }
        }
        for t in emails(for: p) {
            out.append(Moment(id: "mail-\(t.id)", date: t.lastDate, kind: .email, title: t.subject.isEmpty ? "(no subject)" : t.subject,
                              detail: "Latest from \(t.from): \(t.snippet)", link: t.link))
        }
        for n in meetingNotes(for: p) {
            out.append(Moment(id: "zoom-\(n.id)", date: n.date, kind: .meeting, title: n.title,
                              detail: String(n.summary.prefix(220)), link: n.link))
        }
        for pay in payments(for: p) {
            out.append(Moment(id: "pay-\(pay.id)", date: pay.date, kind: .money, title: "Paid \(Money.string(pay.amount))", detail: pay.label))
        }
        for t in p.touches {
            out.append(Moment(id: "touch-\(t.id)", date: t.date, kind: .touch, title: t.text, detail: "You logged this"))
        }
        return out.sorted { $0.date > $1.date }
    }

    // MARK: - Saving (people.json)

    private struct Saved: Codable {
        var people: [Lossy<Person>]?
        var suggestions: [Lossy<PersonSuggestion>]?
        var hidden: [String]?
    }

    /// One unreadable entry is skipped instead of losing the whole list.
    private struct Lossy<T: Codable>: Codable {
        let value: T?
        init(_ value: T) { self.value = value }
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
        func encode(to encoder: Encoder) throws { try value?.encode(to: encoder) }
    }

    private static var fileURL: URL { DealStore.url("people.json") }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        do {
            let saved = try decoder.decode(Saved.self, from: data)
            people = (saved.people ?? []).compactMap(\.value)
            suggestions = (saved.suggestions ?? []).compactMap(\.value)
            hidden = Set(saved.hidden ?? [])
            // Older versions asked before adding people found in Gmail. Add any still waiting.
            if !suggestions.isEmpty {
                for s in suggestions where !hidden.contains(s.email) {
                    var p = Person(name: s.name.isEmpty ? s.email : s.name, emails: [s.email], automatic: true)
                    p.met = "Email"
                    p.addedFrom = "Gmail"
                    p.addedOn = Date()
                    if let t = s.thread { p.threads = [t] }
                    absorb(p)
                }
                suggestions = []
                save()
            }
        } catch {
            NSLog("Lens: couldn't read people.json: \(error)")
            // Keep a copy so nothing is lost if a later save overwrites it.
            try? data.write(to: DealStore.url("people-unreadable.json"), options: .atomic)
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let saved = Saved(people: people.map { Lossy($0) }, suggestions: suggestions.map { Lossy($0) }, hidden: Array(hidden))
        if let data = try? encoder.encode(saved) { try? data.write(to: Self.fileURL, options: .atomic) }
    }
}
