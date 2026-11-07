import Foundation

/// Walks user-chosen folders/drives and catalogs every video file found.
enum FileScanner {
    static let videoExtensions: Set<String> = [
        "mp4", "mov", "mxf", "avi", "m4v", "braw", "r3d", "mts", "m2ts", "wmv", "mkv"
    ]

    static func scan(roots: [URL], progress: ((String) -> Void)? = nil) -> [MediaFile] {
        var results: [MediaFile] = []
        let fm = FileManager.default

        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let fileURL as URL in enumerator {
                let values = try? fileURL.resourceValues(forKeys: [
                    .fileSizeKey, .contentModificationDateKey, .creationDateKey, .isDirectoryKey
                ])

                if values?.isDirectory == true {
                    if PremiereCacheFinder.projectAdjacentFolderNames.contains(fileURL.lastPathComponent) {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                let ext = fileURL.pathExtension.lowercased()
                guard videoExtensions.contains(ext) else { continue }

                let size = Int64(values?.fileSize ?? 0)
                let mtime = values?.contentModificationDate ?? Date()
                let ctime = values?.creationDate

                progress?(fileURL.lastPathComponent)
                results.append(MediaFile(path: fileURL.path, sizeBytes: size, modificationDate: mtime, creationDate: ctime))
            }
        }
        return results
    }

    /// Finds every .prproj file under the given roots.
    static func findProjectFiles(roots: [URL]) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles], errorHandler: { _, _ in true }
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "prproj" {
                result.append(url)
            }
        }
        return result
    }
}
