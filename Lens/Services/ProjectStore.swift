import Foundation

/// Every project, persisted to Application Support as JSON (same pattern as the settings files).
@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [Project] = []

    init() {
        load()
    }

    /// Everything not yet archived, most urgent stage first, then by shoot date.
    var active: [Project] {
        projects
            .filter { $0.stage != .archived }
            .sorted {
                if $0.stage != $1.stage { return $0.stage.rawValue < $1.stage.rawValue }
                return ($0.shootDate ?? .distantFuture) < ($1.shootDate ?? .distantFuture)
            }
    }

    func project(id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    func add(_ project: Project) {
        projects.append(project)
        save()
    }

    func update(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index] = project
        save()
    }

    func delete(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        save()
    }

    func setStage(_ stage: ProjectStage, for project: Project, note: String? = nil) {
        guard var updated = self.project(id: project.id), updated.stage != stage else { return }
        updated.stage = stage
        updated.events.append(ProjectEvent(text: note ?? "Moved to \(stage.label)"))
        update(updated)
    }

    func addEvent(_ text: String, to project: Project) {
        guard var updated = self.project(id: project.id) else { return }
        updated.events.append(ProjectEvent(text: text))
        update(updated)
    }

    /// Adds a Zoom meeting summary, or refreshes it if it's already there.
    func attachNote(_ note: MeetingNote, to projectID: UUID) {
        guard var p = project(id: projectID) else { return }
        var list = p.meetingNotes ?? []
        if let i = list.firstIndex(where: { $0.id == note.id }) {
            guard list[i] != note else { return }
            list[i] = note
        } else {
            list.append(note)
        }
        p.meetingNotes = list.sorted { $0.date > $1.date }
        update(p)
    }

    /// Takes a meeting summary off, for when it landed on the wrong one.
    func removeNote(_ noteID: String, from projectID: UUID) {
        guard var p = project(id: projectID), let list = p.meetingNotes, list.contains(where: { $0.id == noteID }) else { return }
        p.meetingNotes = list.filter { $0.id != noteID }
        update(p)
    }

    /// Links a Gmail conversation to a project, or refreshes it if it's already linked.
    func attachEmail(_ thread: EmailThread, to projectID: UUID) {
        guard var p = project(id: projectID) else { return }
        var list = p.emails ?? []
        if let i = list.firstIndex(where: { $0.id == thread.id }) {
            guard list[i] != thread else { return }
            list[i] = thread
        } else {
            list.append(thread)
        }
        p.emails = list.sorted { $0.lastDate > $1.lastDate }
        update(p)
    }

    /// Takes a Gmail conversation off, for when it landed on the wrong project.
    func removeEmail(_ threadID: String, from projectID: UUID) {
        guard var p = project(id: projectID), let list = p.emails, list.contains(where: { $0.id == threadID }) else { return }
        p.emails = list.filter { $0.id != threadID }
        update(p)
    }

    // MARK: - Filed automatically

    /// Notes that Lens put something on a project by itself, so it shows in "Filed automatically".
    func logAutoFiled(_ item: AutoFiled, on projectID: UUID) {
        guard var p = project(id: projectID) else { return }
        var list = (p.autoFiled ?? []).filter { !($0.kind == item.kind && $0.itemID == item.itemID) }
        list.insert(item, at: 0)
        p.autoFiled = Array(list.prefix(40))
        update(p)
    }

    /// the user moved it or took it off: it's no longer something Lens filed here.
    func dropAutoFiled(_ kind: AutoFiled.Kind, itemID: String, from projectID: UUID? = nil) {
        for p in projects where projectID == nil || p.id == projectID {
            guard let list = p.autoFiled, list.contains(where: { $0.kind == kind && $0.itemID == itemID }) else { continue }
            edit(p.id) { $0.autoFiled = list.filter { !($0.kind == kind && $0.itemID == itemID) } }
        }
    }

    /// What Lens filed by itself across all projects in the last few days, newest first (for Today).
    func recentlyAutoFiled(days: Double = 7) -> [(project: Project, item: AutoFiled)] {
        let since = Date().addingTimeInterval(-days * 86400)
        return projects.flatMap { p in (p.autoFiled ?? []).filter { $0.date > since }.map { (project: p, item: $0) } }
            .sorted { $0.item.date > $1.item.date }
    }

    /// Adds people who clearly belong to a project: someone in at least three of its emails and calls,
    /// who doesn't show up like that on any other open project. Lens files them by itself (no role yet)
    /// and lists them under "Filed automatically". People the user took off aren't added again.
    func addRegulars() {
        func seen(in p: Project) -> [String: (name: String, count: Int)] {
            var found: [String: (name: String, count: Int)] = [:]
            func note(_ name: String, _ email: String, _ counted: inout Set<String>) {
                let e = email.lowercased()
                guard e.contains("@"), !PeopleStore.isAutomated(e), counted.insert(e).inserted else { return }
                let current = found[e]
                let better = (current?.name ?? e) == e ? name : current!.name
                found[e] = (better, (current?.count ?? 0) + 1)
            }
            for thread in p.emails ?? [] {
                var counted = Set<String>()
                for raw in thread.people ?? [] {
                    let a = GmailAPI.parseAddress(raw)
                    note(a.name, a.email, &counted)
                }
            }
            for call in p.meetingNotes ?? [] {
                var counted = Set<String>()
                for person in call.people ?? [] { note(person.name, person.email, &counted) }
                for e in call.attendees ?? [] { note(e, e, &counted) }
            }
            return found
        }
        let open = active
        let counts = Dictionary(uniqueKeysWithValues: open.map { ($0.id, seen(in: $0)) })
        for p in open {
            let known = Set((p.people ?? []).map { $0.email.lowercased() } + (p.notPeople ?? []).map { $0.lowercased() })
            let regulars = (counts[p.id] ?? [:]).filter { email, v in
                v.count >= 3 && !known.contains(email)
                    && !open.contains { $0.id != p.id && (counts[$0.id]?[email]?.count ?? 0) >= 2 }
            }
            guard !regulars.isEmpty else { continue }
            let added = regulars.sorted { $0.key < $1.key }.map { ProjectPerson(name: $0.value.name, email: $0.key, role: "") }
            edit(p.id) { $0.people = ($0.people ?? []) + added }
            for person in added {
                logAutoFiled(AutoFiled(kind: .person, itemID: person.email, title: person.name, source: "Emails and calls"), on: p.id)
            }
        }
    }

    /// Takes someone off a project: Lens won't add or suggest them there again, and emails that
    /// were only there because of them come off too.
    func removePerson(_ person: ProjectPerson, from projectID: UUID) {
        let e = person.email.lowercased()
        edit(projectID) { p in
            p.people = (p.people ?? []).filter { $0.id != person.id }
            if p.people?.isEmpty == true { p.people = nil }
            if e.contains("@"), !(p.notPeople ?? []).contains(e) { p.notPeople = (p.notPeople ?? []) + [e] }
        }
        if e.contains("@") { dropAutoFiled(.person, itemID: person.email, from: projectID) }
        ProjectRelevance.tidy(self, projectID: projectID)
    }

    /// Takes a person Lens added off the project, and remembers not to add them again.
    func removeAutoPerson(_ email: String, from projectID: UUID) {
        let e = email.lowercased()
        edit(projectID) { p in
            p.people = (p.people ?? []).filter { $0.email.lowercased() != e }
            if !(p.notPeople ?? []).contains(e) { p.notPeople = (p.notPeople ?? []) + [e] }
        }
        dropAutoFiled(.person, itemID: email, from: projectID)
    }

    /// Moves a person Lens added from one project to another.
    func moveAutoPerson(_ email: String, from: UUID, to: UUID) {
        let person = project(id: from)?.people?.first { $0.email.lowercased() == email.lowercased() }
        removeAutoPerson(email, from: from)
        edit(to) { p in
            guard !(p.people ?? []).contains(where: { $0.email.lowercased() == email.lowercased() }) else { return }
            p.people = (p.people ?? []) + [person ?? ProjectPerson(name: email, email: email.lowercased(), role: "")]
            p.notPeople = p.notPeople?.filter { $0 != email.lowercased() }
        }
    }

    // MARK: - Time

    /// The project whose timer is running, if any. Only one runs at a time.
    var timing: Project? { projects.first { $0.timerStartedAt != nil } }

    /// Starts the timer on a project, stopping (and logging) any other one first.
    func startTimer(_ projectID: UUID, kind: TimeKind) {
        if let running = timing, running.id != projectID { stopTimer(running.id) }
        guard var p = project(id: projectID), p.timerStartedAt == nil else { return }
        p.timerStartedAt = Date()
        p.timerKind = kind
        update(p)
    }

    /// Stops the timer and logs the time. Anything under a minute is dropped.
    func stopTimer(_ projectID: UUID) {
        guard var p = project(id: projectID), let started = p.timerStartedAt else { return }
        let hours = Date().timeIntervalSince(started) / 3600
        p.timerStartedAt = nil
        if hours >= 1.0 / 60 {
            var list = p.timeEntries ?? []
            list.append(TimeEntry(date: started, hours: (hours * 100).rounded() / 100,
                                  kind: p.timerKind ?? TimeKind.guess(for: p.stage), note: "Timer"))
            p.timeEntries = list.sorted { $0.date > $1.date }
        }
        update(p)
    }

    /// Adds time, or saves changes to time already logged.
    func saveTime(_ entry: TimeEntry, to projectID: UUID) {
        guard var p = project(id: projectID) else { return }
        var list = p.timeEntries ?? []
        if let i = list.firstIndex(where: { $0.id == entry.id }) { list[i] = entry } else { list.append(entry) }
        p.timeEntries = list.sorted { $0.date > $1.date }
        update(p)
    }

    func deleteTime(_ entryID: UUID, from projectID: UUID) {
        guard var p = project(id: projectID) else { return }
        p.timeEntries = (p.timeEntries ?? []).filter { $0.id != entryID }
        update(p)
    }

    /// Stops suggesting a Zoom call or calendar event as time.
    func skipTimeSource(_ source: String, on projectID: UUID) {
        guard var p = project(id: projectID) else { return }
        p.skippedTimeSources = (p.skippedTimeSources ?? []) + [source]
        update(p)
    }

    /// Creates a project for each top-level folder on a drive (and each folder inside an
    /// "Organized" folder, the structure the organizer builds). Skips Premiere cache folders,
    /// hidden folders, and folders that already belong to a project. Returns how many were added.
    @discardableResult
    func importProjects(fromFoldersIn root: URL) -> Int {
        let fm = FileManager.default
        let known = Set(projects.compactMap(\.folderPath))
        var candidates: [URL] = []

        func subfolders(of url: URL) -> [URL] {
            let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles])) ?? []
            return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        }

        for folder in subfolders(of: root) {
            if PremiereCacheFinder.projectAdjacentFolderNames.contains(folder.lastPathComponent) { continue }
            if folder.lastPathComponent == "Organized" {
                candidates.append(contentsOf: subfolders(of: folder))
            } else {
                candidates.append(folder)
            }
        }

        var added = 0
        for folder in candidates where !known.contains(folder.path) {
            var project = Project(name: folder.lastPathComponent, folderPath: folder.path, stage: .edit)
            project.events = [ProjectEvent(text: "Imported from the \(folder.lastPathComponent) folder")]
            projects.append(project)
            added += 1
        }
        if added > 0 { save() }
        return added
    }

    /// Moves a project's whole footage folder to the server folder, then marks it archived.
    /// Logged like every other move, so it shows up in Settings › Undo.
    func moveToServer(_ project: Project, serverFolder: URL) async throws {
        guard let source = project.folderURL else { return }
        let label = "Moved \(project.name) to the server"
        let destination = try await Task.detached(priority: .userInitiated) {
            try FileActionExecutor.moveFolder(source, intoDirectory: serverFolder, label: label)
        }.value
        guard var updated = self.project(id: project.id) else { return }
        updated.archivedPath = destination.path
        updated.stage = .archived
        updated.events.append(ProjectEvent(text: "Footage moved to the server"))
        update(updated)
    }

    /// If footage that was moved to the server has since been moved back (an undo),
    /// point the project back at its working folder.
    func reconcileArchives() {
        let fm = FileManager.default
        var changed = false
        for index in projects.indices {
            guard let archived = projects[index].archivedPath,
                  let folder = projects[index].folderPath,
                  !fm.fileExists(atPath: archived), fm.fileExists(atPath: folder) else { continue }
            projects[index].archivedPath = nil
            if projects[index].stage == .archived { projects[index].stage = .paid }
            projects[index].events.append(ProjectEvent(text: "Footage moved back from the server"))
            changed = true
        }
        if changed { save() }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            projects = try decoder.decode([Project].self, from: data)
        } catch {
            // Keep a copy before anything is saved over it, so nothing is lost for good.
            NSLog("Lens: couldn't read projects.json: \(error)")
            let backup = Self.storeURL.deletingLastPathComponent()
                .appendingPathComponent("projects-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? data.write(to: backup)
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(projects) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }

    static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lens", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("projects.json")
    }
}

// MARK: - Is this email about this project?

/// Decides whether an email conversation is really about a project, so a project doesn't fill up with
/// every email that happens to include one of its people.
@MainActor
enum ProjectRelevance {
    /// Emma's own address, so she never counts as "someone on the project".
    static var me = ""

    /// The email addresses of the people on the project's People list (not Emma's).
    static func personEmails(_ p: Project) -> Set<String> {
        let mine = me.lowercased()
        return Set((p.people ?? []).map { $0.email.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("@") && $0 != mine })
    }

    /// The email addresses in a conversation.
    static func addresses(_ t: EmailThread) -> [String] {
        (t.people ?? []).map { GmailAPI.parseAddress($0).email.lowercased() }.filter { $0.contains("@") }
    }

    /// A conversation belongs on a project only when someone on its People list is in it.
    static func belongs(_ t: EmailThread, to p: Project) -> Bool {
        let people = personEmails(p)
        guard !people.isEmpty else { return false }
        return addresses(t).contains { people.contains($0) }
    }

    /// Takes off a project every email that has none of its people in it. Projects with no one on
    /// People yet are left alone, so nothing disappears before Emma has added anyone.
    static func tidy(_ projects: ProjectStore, projectID: UUID) {
        guard let p = projects.project(id: projectID), !personEmails(p).isEmpty else { return }
        for t in p.emails ?? [] where !addresses(t).isEmpty && !belongs(t, to: p) {
            projects.removeEmail(t.id, from: p.id)
        }
    }

    /// Once: the new rule for every project, and people Lens added by itself come off again.
    static func tidy(_ projects: ProjectStore) {
        for p in projects.projects {
            let key = "projectTidy.v2.\(p.id.uuidString)"
            guard !UserDefaults.standard.bool(forKey: key) else { continue }
            UserDefaults.standard.set(true, forKey: key)
            let added = (p.autoFiled ?? []).filter { $0.kind == .person }.map { $0.itemID.lowercased() }
            for person in p.people ?? [] where added.contains(person.email.lowercased()) || PeopleStore.isAutomated(person.email) {
                projects.removePerson(person, from: p.id)
            }
            tidy(projects, projectID: p.id)
        }
    }
}
