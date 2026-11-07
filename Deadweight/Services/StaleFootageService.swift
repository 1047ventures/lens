import Foundation

/// Flags footage that hasn't been touched in a long time and isn't referenced by any
/// known Premiere project as a candidate to move off the SSD.
enum StaleFootageService {
    static func candidates(among files: [MediaFile], staleAfterDays: Int) -> [ArchiveCandidate] {
        let now = Date()
        return files.compactMap { file in
            guard !file.isLinked else { return nil }
            let days = Calendar.current.dateComponents([.day], from: file.modificationDate, to: now).day ?? 0
            guard days >= staleAfterDays else { return nil }
            return ArchiveCandidate(file: file, daysSinceModified: days)
        }
    }
}
