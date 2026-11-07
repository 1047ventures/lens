import Foundation

enum FileActionError: Error, LocalizedError {
    case checkpointExceeded(fileCount: Int, gigabytes: Double)

    var errorDescription: String? {
        switch self {
        case .checkpointExceeded(let count, let gb):
            return "This batch would touch \(count) files (\(String(format: "%.1f", gb)) GB) — " +
                "above your auto-apply checkpoint. Review and confirm it manually."
        }
    }
}

/// Performs every actual file move/delete. Deletion always routes through the macOS Trash,
/// never a hard unlink, and every action is logged so a whole batch can be undone.
enum FileActionExecutor {

    @discardableResult
    static func trash(_ paths: [(path: String, sizeBytes: Int64)], label: String,
                       settings: TrustSettings, enforceCheckpoint: Bool) throws -> UUID {
        let totalBytes = paths.reduce(0) { $0 + $1.sizeBytes }
        if enforceCheckpoint, settings.exceedsCheckpoint(fileCount: paths.count, bytes: totalBytes) {
            throw FileActionError.checkpointExceeded(fileCount: paths.count, gigabytes: Double(totalBytes) / 1_000_000_000)
        }

        let batchId = UUID()
        let fm = FileManager.default
        for item in paths {
            var trashedURL: NSURL?
            do {
                try fm.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: &trashedURL)
            } catch {
                continue
            }
            let entry = ActionLogEntry(kind: .trash, sourcePath: item.path, trashedPath: trashedURL?.path,
                                        sizeBytes: item.sizeBytes, batchId: batchId, batchLabel: label)
            ActionLogStore.shared.append(entry)
        }
        return batchId
    }

    @discardableResult
    static func move(_ moves: [(source: MediaFile, destination: URL)], label: String,
                      settings: TrustSettings, enforceCheckpoint: Bool) throws -> UUID {
        let totalBytes = moves.reduce(0) { $0 + $1.source.sizeBytes }
        if enforceCheckpoint, settings.exceedsCheckpoint(fileCount: moves.count, bytes: totalBytes) {
            throw FileActionError.checkpointExceeded(fileCount: moves.count, gigabytes: Double(totalBytes) / 1_000_000_000)
        }

        let batchId = UUID()
        let fm = FileManager.default
        for (file, destination) in moves {
            do {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

                var finalDestination = destination
                var counter = 1
                while fm.fileExists(atPath: finalDestination.path) {
                    let base = destination.deletingPathExtension().lastPathComponent
                    let ext = destination.pathExtension
                    finalDestination = destination.deletingLastPathComponent()
                        .appendingPathComponent("\(base)-\(counter).\(ext)")
                    counter += 1
                }

                try fm.moveItem(at: file.url, to: finalDestination)
                let entry = ActionLogEntry(kind: .move, sourcePath: file.path, destinationPath: finalDestination.path,
                                            sizeBytes: file.sizeBytes, batchId: batchId, batchLabel: label)
                ActionLogStore.shared.append(entry)
            } catch {
                continue
            }
        }
        return batchId
    }

    /// Reverses every entry in a batch: moved files go back to their source path,
    /// trashed items are restored from the Trash to their original location.
    /// Moves a whole project folder into `destinationDir` (e.g. the home server) as one
    /// logged, undoable action. Returns where it landed.
    @discardableResult
    static func moveFolder(_ source: URL, intoDirectory destinationDir: URL, label: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        var destination = destinationDir.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        var counter = 1
        while fm.fileExists(atPath: destination.path) {
            destination = destinationDir.appendingPathComponent("\(source.lastPathComponent)-\(counter)", isDirectory: true)
            counter += 1
        }

        let size = PremiereCacheFinder.folderSize(source)
        try fm.moveItem(at: source, to: destination)
        ActionLogStore.shared.append(ActionLogEntry(kind: .move, sourcePath: source.path,
                                                    destinationPath: destination.path, sizeBytes: size,
                                                    batchId: UUID(), batchLabel: label))
        return destination
    }

    static func undo(batch: ActionBatch) {
        let fm = FileManager.default
        for entry in batch.entries.reversed() {
            switch entry.kind {
            case .move:
                guard let dest = entry.destinationPath else { continue }
                let sourceURL = URL(fileURLWithPath: entry.sourcePath)
                do {
                    try fm.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: URL(fileURLWithPath: dest), to: sourceURL)
                } catch { continue }
            case .trash:
                guard let trashedPath = entry.trashedPath else { continue }
                let originalURL = URL(fileURLWithPath: entry.sourcePath)
                do {
                    try fm.createDirectory(at: originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: URL(fileURLWithPath: trashedPath), to: originalURL)
                } catch { continue }
            case .restore:
                continue
            }
        }
        ActionLogStore.shared.removeBatch(batch.batchId)
    }
}
