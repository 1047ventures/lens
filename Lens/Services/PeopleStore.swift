import Foundation

/// Everyone Emma works with, kept in people.json. Lens fills it in by itself from deal contacts,
/// project clients and two-way Gmail conversations, and merges obvious duplicates. Emma can add,
/// edit, merge, split and remove people by hand; anything she removes or ignores stays gone.
@MainActor
final class PeopleStore: ObservableObject {
    @Published private(set) var people: [Person] = []
    /// People found in Gmail who aren't in People yet.
    @Published private(set) var suggestions: [PersonSuggestion] = []

    /// Emails and names Emma removed or ignored, so Lens doesn't bring them back.
    private var hidden: Set<String> = []

    private weak var deals: DealStore?
    private weak var projects: ProjectStore?
    private weak var money: MoneyStore?

    /// Quiet for this many days while on an open deal: worth a check-in.
    static let quietAfterDays = 30

    init() { load() }

    func attach(deals: DealStore, projects: ProjectStore, money: MoneyStore) {
        self.deals = deals
        self.projects = projects
        self.money = money
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

    // MARK: - Suggestions from Gmail

    func accept(_ s: PersonSuggestion) {
        suggestions.removeAll { $0.id == s.id }
        var p = Person(name: s.name.isEmpty ? s.email : s.name, emails: [s.email])
        p.met = "Email"
        if let t = s.thread { p.threads = [t] }
        if let i = people.firstIndex(where: { Person.nameKey($0.name) == Person.nameKey(p.name) && $0.emails.isEmpty }) {
            people[i] = Self.combined(people[i], p)
        } else {
            people.append(p)
        }
        save()
    }

    func ignore(_ s: PersonSuggestion) {
        suggestions.removeAll { $0.id == s.id }
        hidden.insert(s.email)
        save()
    }

    /// Called for each Gmail conversation Lens reads. People already in Lens get the conversation on their page.
    /// Real people who wrote to Emma in a two-way conversation (or one on a deal or project) are suggested.
    func noteThread(_ thread: GmailAPI.Thread, link: EmailThread, me: String, onFile: Bool) {
        var everyone: [String: String] = [:]   // email → name
        var senders = Set<String>()
        for m in thread.messages {
            for (raw, isSender) in [(m.from, true), (m.replyTo, true), (m.to, false)] {
                for part in raw.split(separator: ",") {
                    let a = GmailAPI.parseAddress(String(part))
                    guard a.email.contains("@"), a.email != me, !Self.isAutomated(a.email) else { continue }
                    if everyone[a.email] == nil || everyone[a.email] == a.email { everyone[a.email] = a.name }
                    if isSender { senders.insert(a.email) }
                }
            }
        }
        let emmaWrote = thread.messages.contains { GmailAPI.parseAddress($0.from).email == me }
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
            } else if senders.contains(email), emmaWrote || onFile, !hidden.contains(email) {
                let clean = name == email ? "" : name
                if let k = suggestions.firstIndex(where: { $0.email == email }) {
                    if (suggestions[k].thread?.lastDate ?? .distantPast) < link.lastDate { suggestions[k].thread = link; changed = true }
                } else {
                    suggestions.append(PersonSuggestion(name: clean, email: email, thread: link))
                    changed = true
                }
            }
        }
        if changed {
            suggestions.sort { ($0.thread?.lastDate ?? $0.found) > ($1.thread?.lastDate ?? $1.found) }
            if suggestions.count > 60 { suggestions = Array(suggestions.prefix(60)) }
            save()
        }
    }

    /// No-reply senders, newsletters, notifications and services: never people.
    static func isAutomated(_ email: String) -> Bool {
        let e = email.lowercased()
        let parts = e.split(separator: "@")
        guard parts.count == 2 else { return true }
        let local = String(parts[0]), domain = String(parts[1])
        let words = ["noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "do_not_reply", "notification",
                     "newsletter", "mailer-daemon", "postmaster", "bounce", "unsubscribe", "digest", "automated",
                     "alerts", "updates", "marketing", "receipts", "billing", "invoice", "calendar-server"]
        if words.contains(where: local.contains) { return true }
        if ["news", "info-news", "notify", "support", "help", "team", "hello-news"].contains(local) { return true }
        let services = ["zoom.us", "calendar.google.com", "mailchimp.com", "mcsv.net", "substack.com", "facebookmail.com",
                        "sendgrid.net", "mailgun.org", "constantcontact.com", "hubspotemail.net", "klaviyomail.com",
                        "amazonses.com", "intuit.com", "paypal.com", "venmo.com", "stripe.com"]
            + GmailSync.leadSenders.map(\.domain)
        return services.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }

    // MARK: - Building people from deals and projects

    /// Makes sure everyone on a deal or project is in People and linked to it. Runs whenever deals or
    /// projects change. Only adds and links; never removes anything Emma set.
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
                guard !name.isEmpty, !hide(email: email, name: name), email.isEmpty || !Self.isAutomated(email) else { continue }
                let i: Int
                if let found = find(email: email, name: name) {
                    i = found
                } else {
                    var p = Person(name: name, emails: email.isEmpty ? [] : [email], automatic: true)
                    p.met = deal.source
                    p.createdAt = deal.createdAt
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
            // Skip anyone Emma took off this project on purpose.
            if list.contains(where: { $0.unlinked.contains(project.id) }) { continue }
            var p = Person(name: client, automatic: true)
            p.projectIDs = [project.id]
            p.createdAt = project.createdAt
            if project.stage.rawValue >= ProjectStage.booked.rawValue { p.addTag(PersonTag.client.rawValue) }
            list.append(p)
        }

        list = Self.mergeDuplicates(list)
        if list != people {
            people = list
            save()
        }
    }

    private static func tagFromRole(_ p: inout Person) {
        let role = p.role.lowercased()
        for tag in [PersonTag.director, .interviewee, .crew, .vendor] where role.contains(tag.rawValue.lowercased()) {
            p.addTag(tag.rawValue)
        }
    }

    /// Same email, or the same name where at most one of them has an email: one person.
    private static func mergeDuplicates(_ input: [Person]) -> [Person] {
        var list = input
        var i = 0
        while i < list.count {
            var j = i + 1
            while j < list.count {
                let a = list[i], b = list[j]
                let sharesEmail = !Set(a.emails).isDisjoint(with: b.emails)
                let sameName = !Person.nameKey(a.name).isEmpty && Person.nameKey(a.name) == Person.nameKey(b.name)
                    && (a.emails.isEmpty || b.emails.isEmpty)
                if (sharesEmail || sameName) && !keptApart(a, b) {
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

    /// The last time Emma was in touch: an email, a call note, or a chat she logged.
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

    /// People on open deals Emma hasn't been in touch with for a while (and has no follow-up set for).
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
            ([p.name, p.company, p.role, p.phone, p.link, p.met, p.notes] + p.emails + p.tags)
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
