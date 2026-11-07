import Foundation

/// The rule used for every added folder by default, plus optional per-folder overrides.
/// Persisted to Application Support as JSON, same pattern as TrustSettings.
final class OrganizeSettings: ObservableObject, Codable {
    @Published var defaultRule: OrganizeRule
    /// Keyed by root folder path (the same paths that appear in ScanViewModel.roots).
    @Published var folderRules: [String: OrganizeRule]

    enum CodingKeys: String, CodingKey {
        case defaultRule, folderRules
    }

    init() {
        self.defaultRule = .defaultRule
        self.folderRules = [:]
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.defaultRule = try c.decodeIfPresent(OrganizeRule.self, forKey: .defaultRule) ?? .defaultRule
        self.folderRules = try c.decodeIfPresent([String: OrganizeRule].self, forKey: .folderRules) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(defaultRule, forKey: .defaultRule)
        try c.encode(folderRules, forKey: .folderRules)
    }

    /// Resolves the rule that applies to a given root folder — its own override if it has
    /// one, otherwise the default rule shared by every folder without a custom rule.
    func rule(for root: URL) -> OrganizeRule {
        folderRules[root.path] ?? defaultRule
    }

    func hasOverride(for root: URL) -> Bool {
        folderRules[root.path] != nil
    }

    func setRule(_ rule: OrganizeRule, for root: URL?) {
        if let root {
            folderRules[root.path] = rule
        } else {
            defaultRule = rule
        }
        save()
    }

    func clearOverride(for root: URL) {
        folderRules.removeValue(forKey: root.path)
        save()
    }

    static func load() -> OrganizeSettings {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode(OrganizeSettings.self, from: data) else {
            return OrganizeSettings()
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.storeURL)
    }

    static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lens", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("organize_settings.json")
    }
}
