import Foundation

/// A set of files whose content is byte-for-byte identical (confirmed by full hash).
struct DuplicateGroup: Identifiable {
    let id = UUID()
    var files: [MediaFile]
    /// Path of the copy to keep by default. Prefers a file that's linked in a Premiere
    /// project, then the one living deepest in an already-organized folder structure.
    var keepPath: String

    init(files: [MediaFile]) {
        self.files = files
        self.keepPath = DuplicateGroup.defaultKeep(among: files)
    }

    static func defaultKeep(among files: [MediaFile]) -> String {
        if let linked = files.first(where: { $0.isLinked }) {
            return linked.path
        }
        // Prefer the file already inside an "Organized" tree, else the oldest (likely original).
        if let organized = files.first(where: { $0.path.contains("/Organized/") }) {
            return organized.path
        }
        return files.min(by: { $0.modificationDate < $1.modificationDate })?.path ?? files[0].path
    }

    var filesToRemove: [MediaFile] {
        files.filter { $0.path != keepPath }
    }

    var wastedBytes: Int64 {
        filesToRemove.reduce(0) { $0 + $1.sizeBytes }
    }

    var anyLinked: Bool {
        filesToRemove.contains { $0.isLinked }
    }
}
