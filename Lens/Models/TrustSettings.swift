import Foundation

enum ActionType: String, Codable, CaseIterable, Identifiable {
    case duplicateRemoval = "Duplicate Removal"
    case cacheCleanup = "Cache Cleanup"
    case organize = "Organize"
    case archive = "Archive"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .duplicateRemoval: return "Send extra copies of duplicate footage to the Trash"
        case .cacheCleanup: return "Delete Premiere media cache & preview files"
        case .organize: return "Move loose files into folders based on your Organize rule"
        case .archive: return "Move stale, unlinked footage to your Archive destination"
        }
    }
}

/// Per-action-type "I trust you" toggles plus the checkpoint thresholds that keep
/// auto-apply from running away. Persisted to Application Support as JSON.
final class TrustSettings: ObservableObject, Codable {
    @Published var autoApply: [String: Bool]
    @Published var checkpointFileCount: Int
    @Published var checkpointGigabytes: Double
    @Published var staleAfterDays: Int
    @Published var archiveDestinationPath: String?

    enum CodingKeys: String, CodingKey {
        case autoApply, checkpointFileCount, checkpointGigabytes, staleAfterDays, archiveDestinationPath
    }

    init() {
        self.autoApply = Dictionary(uniqueKeysWithValues: ActionType.allCases.map { ($0.rawValue, false) })
        self.checkpointFileCount = 200
        self.checkpointGigabytes = 100
        self.staleAfterDays = 180
        self.archiveDestinationPath = nil
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.autoApply = try c.decodeIfPresent([String: Bool].self, forKey: .autoApply) ?? [:]
        self.checkpointFileCount = try c.decodeIfPresent(Int.self, forKey: .checkpointFileCount) ?? 200
        self.checkpointGigabytes = try c.decodeIfPresent(Double.self, forKey: .checkpointGigabytes) ?? 100
        self.staleAfterDays = try c.decodeIfPresent(Int.self, forKey: .staleAfterDays) ?? 180
        self.archiveDestinationPath = try c.decodeIfPresent(String.self, forKey: .archiveDestinationPath)
        for type in ActionType.allCases where autoApply[type.rawValue] == nil {
            autoApply[type.rawValue] = false
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(autoApply, forKey: .autoApply)
        try c.encode(checkpointFileCount, forKey: .checkpointFileCount)
        try c.encode(checkpointGigabytes, forKey: .checkpointGigabytes)
        try c.encode(staleAfterDays, forKey: .staleAfterDays)
        try c.encodeIfPresent(archiveDestinationPath, forKey: .archiveDestinationPath)
    }

    func isAutoApply(_ type: ActionType) -> Bool { autoApply[type.rawValue] ?? false }

    func setAutoApply(_ type: ActionType, _ value: Bool) {
        autoApply[type.rawValue] = value
        save()
    }

    /// A batch this large pauses for confirmation even in auto-apply mode.
    func exceedsCheckpoint(fileCount: Int, bytes: Int64) -> Bool {
        let gb = Double(bytes) / 1_000_000_000
        return fileCount > checkpointFileCount || gb > checkpointGigabytes
    }

    static func load() -> TrustSettings {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode(TrustSettings.self, from: data) else {
            return TrustSettings()
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: TrustSettings.storeURL)
    }

    static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lens", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("trust_settings.json")
    }
}
