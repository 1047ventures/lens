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

            // Each file's lookup is released right away; a drive with hundreds of thousands of
            // files would otherwise hold all of them in memory until the listing finishes.
            while let next = autoreleasepool(invoking: { enumerator.nextObject() }) {
                guard let fileURL = next as? URL else { continue }
                let file: MediaFile? = autoreleasepool {
                    let values = try? fileURL.resourceValues(forKeys: [
                        .fileSizeKey, .contentModificationDateKey, .creationDateKey, .isDirectoryKey
                    ])

                    if values?.isDirectory == true {
                        if PremiereCacheFinder.projectAdjacentFolderNames.contains(fileURL.lastPathComponent) {
                            enumerator.skipDescendants()
                        }
                        return nil
                    }

                    let ext = fileURL.pathExtension.lowercased()
                    guard videoExtensions.contains(ext) else { return nil }

                    progress?(fileURL.lastPathComponent)
                    return MediaFile(path: fileURL.path, sizeBytes: Int64(values?.fileSize ?? 0),
                                     modificationDate: values?.contentModificationDate ?? Date(),
                                     creationDate: values?.creationDate)
                }
                if let file { results.append(file) }
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
