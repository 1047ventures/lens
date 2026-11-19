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
