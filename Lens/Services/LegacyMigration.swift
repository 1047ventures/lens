import Foundation

/// Lens used to be called Deadweight. On first launch after the rename, move its data folder
/// and remembered drives over so nothing is lost. Safe to run every launch: it does nothing
/// once the new folder exists.
enum LegacyMigration {
    static func run() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appendingPathComponent("Deadweight", isDirectory: true)
        let new = support.appendingPathComponent("Lens", isDirectory: true)
        if FileManager.default.fileExists(atPath: old.path) && !FileManager.default.fileExists(atPath: new.path) {
            try? FileManager.default.moveItem(at: old, to: new)
        }
        // Remembered drives lived under the old bundle id.
        let key = "scanRootPaths"
        if UserDefaults.standard.stringArray(forKey: key) == nil,
           let saved = UserDefaults(suiteName: "com.example.Deadweight")?.stringArray(forKey: key) {
            UserDefaults.standard.set(saved, forKey: key)
        }
    }
}
