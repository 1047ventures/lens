import Foundation

enum ActionKind: String, Codable {
    case move
    case trash
    case restore
}

/// One executed file action, permanently recorded so a batch can be undone later.
struct ActionLogEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let kind: ActionKind
    let sourcePath: String
    /// Destination path for a move; nil for a trash action.
    let destinationPath: String?
    /// Where FileManager.trashItem actually placed the file, needed to restore it.
    let trashedPath: String?
    let sizeBytes: Int64
    let batchId: UUID
    let batchLabel: String

    init(kind: ActionKind, sourcePath: String, destinationPath: String? = nil,
         trashedPath: String? = nil, sizeBytes: Int64, batchId: UUID, batchLabel: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.kind = kind
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.trashedPath = trashedPath
        self.sizeBytes = sizeBytes
        self.batchId = batchId
        self.batchLabel = batchLabel
    }
}

/// A group of actions executed together, undoable as a unit.
struct ActionBatch: Identifiable {
    let batchId: UUID
    let label: String
    let timestamp: Date
    let entries: [ActionLogEntry]

    var id: UUID { batchId }
    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.sizeBytes } }
}
