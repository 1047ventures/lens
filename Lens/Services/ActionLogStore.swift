import Foundation

/// Append-only log of every file action Lens has ever taken, grouped into
/// undoable batches. This is what makes auto-apply mode safe to leave unattended.
final class ActionLogStore {
    static let shared = ActionLogStore()

    private var entries: [ActionLogEntry] = []
    private let queue = DispatchQueue(label: "com.footagepruner.actionlog")

    private init() {
        if let data = try? Data(contentsOf: Self.storeURL),
           let decoded = try? JSONDecoder().decode([ActionLogEntry].self, from: data) {
            entries = decoded
        }
    }

    func append(_ entry: ActionLogEntry) {
        queue.sync {
            entries.append(entry)
            persist()
        }
    }

    func recentBatches(limit: Int = 20) -> [ActionBatch] {
        queue.sync {
            let grouped = Dictionary(grouping: entries, by: { $0.batchId })
            let batches = grouped.map { batchId, batchEntries -> ActionBatch in
                ActionBatch(
                    batchId: batchId,
                    label: batchEntries.first?.batchLabel ?? "Batch",
                    timestamp: batchEntries.first?.timestamp ?? Date(),
                    entries: batchEntries
                )
            }
            return Array(batches.sorted { $0.timestamp > $1.timestamp }.prefix(limit))
        }
    }

    func lastBatch() -> ActionBatch? {
        recentBatches(limit: 1).first
    }

    func removeBatch(_ batchId: UUID) {
        queue.sync {
            entries.removeAll { $0.batchId == batchId }
            persist()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.storeURL)
    }

    static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lens", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("action_log.json")
    }
}
