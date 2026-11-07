import Foundation
import SwiftUI
import Combine

@MainActor
final class ScanViewModel: ObservableObject {

    // MARK: - Published state

    @Published var roots: [URL] = []
    @Published var isScanning = false
    @Published var scanStatusText = ""
    @Published var hasScanned = false

    @Published var duplicateGroups: [DuplicateGroup] = []
    @Published var cacheItems: [CacheItem] = []
    @Published var organizeProposals: [OrganizeProposal] = []
    @Published var archiveCandidates: [ArchiveCandidate] = []

    @Published var lastAutoRunSummary: String?
    @Published var pendingCheckpointMessage: String?
    @Published var errorMessage: String?

    @Published var trustSettings = TrustSettings.load()
    @Published var organizeSettings = OrganizeSettings.load()

    private(set) var allFiles: [MediaFile] = []
    private var cancellables = Set<AnyCancellable>()

    init() {
        // TrustSettings/OrganizeSettings are nested ObservableObjects; forward their changes
        // so views observing ScanViewModel (Settings toggles, the rule builder, etc.) redraw too.
        trustSettings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        organizeSettings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Remember the drives between launches, skipping any that aren't plugged in right now.
        let saved = UserDefaults.standard.stringArray(forKey: Self.rootsKey) ?? []
        roots = saved.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    private static let rootsKey = "scanRootPaths"

    private func saveRoots() {
        UserDefaults.standard.set(roots.map(\.path), forKey: Self.rootsKey)
    }

    var recentBatches: [ActionBatch] { ActionLogStore.shared.recentBatches() }

    var overview: ScanOverview {
        ScanOverview(
            totalFiles: allFiles.count,
            totalBytes: allFiles.reduce(0) { $0 + $1.sizeBytes },
            duplicateGroupCount: duplicateGroups.count,
            duplicateWastedBytes: duplicateGroups.reduce(0) { $0 + $1.wastedBytes },
            cacheItemCount: cacheItems.count,
            cacheBytes: cacheItems.reduce(0) { $0 + $1.sizeBytes },
            organizeCount: organizeProposals.count,
            archiveCount: archiveCandidates.count,
            archiveBytes: archiveCandidates.reduce(0) { $0 + $1.file.sizeBytes }
        )
    }

    // MARK: - Roots

    func addRoot(_ url: URL) {
        guard !roots.contains(url) else { return }
        roots.append(url)
        saveRoots()
    }

    func removeRoot(_ url: URL) {
        roots.removeAll { $0 == url }
        saveRoots()
    }

    // MARK: - Scan

    func scan(runAutoApply: Bool = true) {
        guard !roots.isEmpty, !isScanning else { return }
        isScanning = true
        scanStatusText = "Scanning folders…"
        errorMessage = nil
        if runAutoApply {
            lastAutoRunSummary = nil
        }

        let capturedRoots = roots
        let staleAfterDays = trustSettings.staleAfterDays
        let rulesByRoot: [String: OrganizeRule] = Dictionary(
            uniqueKeysWithValues: capturedRoots.map { ($0.path, organizeSettings.rule(for: $0)) }
        )

        Task.detached(priority: .userInitiated) { [weak self] in
            var files = FileScanner.scan(roots: capturedRoots)
            let projectFiles = FileScanner.findProjectFiles(roots: capturedRoots)
            PremiereProjectParser.annotateLinkedFiles(&files, projectFiles: projectFiles)
            files = await VideoMetadataService.enrichAll(files)

            let dupes = HashingService.findDuplicates(among: files)
            let cache = PremiereCacheFinder.find(in: capturedRoots)
            let organize = OrganizerService.proposals(for: files, scanRoots: capturedRoots, rulesByRoot: rulesByRoot)
            let stale = StaleFootageService.candidates(among: files, staleAfterDays: staleAfterDays)

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.allFiles = files
                self.duplicateGroups = dupes
                self.cacheItems = cache
                self.organizeProposals = organize
                self.archiveCandidates = stale
                self.isScanning = false
                self.hasScanned = true
                self.scanStatusText = "Weighed in at \(files.count) video file(s) across \(capturedRoots.count) location(s)."
                // Undo re-scans to refresh the lists, but must never immediately
                // re-trigger auto-apply — that would silently redo what was just undone.
                if runAutoApply {
                    self.runAutoApplyIfEnabled()
                }
            }
        }
    }

    /// Recomputes destination paths from the current rule without a full rescan — powers the
    /// rule-builder's live preview as the user edits factors or switches scope.
    func recomputeOrganizeProposals() {
        let rulesByRoot: [String: OrganizeRule] = Dictionary(
            uniqueKeysWithValues: roots.map { ($0.path, organizeSettings.rule(for: $0)) }
        )
        organizeProposals = OrganizerService.proposals(for: allFiles, scanRoots: roots, rulesByRoot: rulesByRoot)
    }

    // MARK: - Auto-apply (Level 2 trust)

    private func runAutoApplyIfEnabled() {
        var summaries: [String] = []

        if trustSettings.isAutoApply(.cacheCleanup), !cacheItems.isEmpty {
            // Count before applying: a successful apply empties the list.
            let count = cacheItems.count
            do {
                try applyCacheCleanup(cacheItems, enforceCheckpoint: true)
                summaries.append("Cleared out \(count) cache item(s) Premiere won't miss.")
            } catch {
                pendingCheckpointMessage = error.localizedDescription
            }
        }

        if trustSettings.isAutoApply(.duplicateRemoval), !duplicateGroups.isEmpty {
            let toRemove = duplicateGroups.filter { !$0.anyLinked }
            do {
                try applyDuplicateRemoval(toRemove, enforceCheckpoint: true)
                summaries.append("Cut \(toRemove.count) group(s) of duplicate weight.")
            } catch {
                pendingCheckpointMessage = error.localizedDescription
            }
        }

        if trustSettings.isAutoApply(.organize), !organizeProposals.isEmpty {
            let count = organizeProposals.count
            do {
                try applyOrganize(organizeProposals, enforceCheckpoint: true)
                summaries.append("Filed \(count) stray file(s) into place.")
            } catch {
                pendingCheckpointMessage = error.localizedDescription
            }
        }

        if trustSettings.isAutoApply(.archive), !archiveCandidates.isEmpty, trustSettings.archiveDestinationPath != nil {
            let count = archiveCandidates.count
            do {
                try applyArchive(archiveCandidates, enforceCheckpoint: true)
                summaries.append("Shipped \(count) stale file(s) off to archive.")
            } catch {
                pendingCheckpointMessage = error.localizedDescription
            }
        }

        if !summaries.isEmpty {
            lastAutoRunSummary = summaries.joined(separator: " ")
        }
    }

    // MARK: - Apply actions (also used by manual "Apply" buttons, enforceCheckpoint: false)

    func applyDuplicateRemoval(_ groups: [DuplicateGroup], enforceCheckpoint: Bool) throws {
        let toTrash = groups.flatMap { $0.filesToRemove }.map { (path: $0.path, sizeBytes: $0.sizeBytes) }
        guard !toTrash.isEmpty else { return }
        try FileActionExecutor.trash(toTrash, label: "Duplicate Removal", settings: trustSettings, enforceCheckpoint: enforceCheckpoint)
        duplicateGroups.removeAll { group in groups.contains { $0.id == group.id } }
    }

    func applyCacheCleanup(_ items: [CacheItem], enforceCheckpoint: Bool) throws {
        let toTrash = items.map { (path: $0.path, sizeBytes: $0.sizeBytes) }
        guard !toTrash.isEmpty else { return }
        try FileActionExecutor.trash(toTrash, label: "Cache Cleanup", settings: trustSettings, enforceCheckpoint: enforceCheckpoint)
        cacheItems.removeAll { item in items.contains { $0.id == item.id } }
    }

    func applyOrganize(_ proposals: [OrganizeProposal], enforceCheckpoint: Bool) throws {
        let moves = proposals.map { (source: $0.file, destination: $0.proposedURL) }
        guard !moves.isEmpty else { return }
        try FileActionExecutor.move(moves, label: "Organize", settings: trustSettings, enforceCheckpoint: enforceCheckpoint)
        organizeProposals.removeAll { proposal in proposals.contains { $0.id == proposal.id } }
    }

    func applyArchive(_ candidates: [ArchiveCandidate], enforceCheckpoint: Bool) throws {
        guard let destRoot = trustSettings.archiveDestinationPath else {
            errorMessage = "Set an Archive destination in Settings first."
            return
        }
        let destURL = URL(fileURLWithPath: destRoot)
        let moves = candidates.map { candidate -> (source: MediaFile, destination: URL) in
            (source: candidate.file, destination: destURL.appendingPathComponent(candidate.file.filename))
        }
        guard !moves.isEmpty else { return }
        try FileActionExecutor.move(moves, label: "Archive", settings: trustSettings, enforceCheckpoint: enforceCheckpoint)
        archiveCandidates.removeAll { candidate in candidates.contains { $0.id == candidate.id } }
    }

    // MARK: - Undo

    func undoLastBatch() {
        guard let batch = ActionLogStore.shared.lastBatch() else { return }
        FileActionExecutor.undo(batch: batch)
        lastAutoRunSummary = nil
        scan(runAutoApply: false)
    }

    func undo(_ batch: ActionBatch) {
        FileActionExecutor.undo(batch: batch)
        scan(runAutoApply: false)
    }
}
