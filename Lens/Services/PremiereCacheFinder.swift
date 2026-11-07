import Foundation

/// Finds Adobe-generated cache/preview data, which Premiere regenerates on demand and which
/// often accounts for tens-to-hundreds of GB — the single biggest zero-risk space win.
enum PremiereCacheFinder {
    static let globalCacheDirs: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Application Support/Adobe/Common/Media Cache Files"),
            home.appendingPathComponent("Library/Application Support/Adobe/Common/Media Cache")
        ]
    }()

    static let projectAdjacentFolderNames: Set<String> = [
        "Adobe Premiere Pro Preview Files", "Media Cache Files", "Media Cache", "Conformed Audio"
    ]

    static let peakFileExtensions: Set<String> = ["pek", "cfa"]

    static func find(in roots: [URL]) -> [CacheItem] {
        var items: [CacheItem] = []
        let fm = FileManager.default

        for dir in globalCacheDirs where fm.fileExists(atPath: dir.path) {
            let size = folderSize(dir)
            if size > 0 {
                items.append(CacheItem(path: dir.path, kind: .mediaCacheFolder, sizeBytes: size))
            }
        }

        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

                if isDir, projectAdjacentFolderNames.contains(url.lastPathComponent) {
                    let kind: CacheKind = url.lastPathComponent.contains("Preview") ? .previewFilesFolder
                        : url.lastPathComponent.contains("Conformed") ? .conformedAudioFolder
                        : .mediaCacheFolder
                    let size = folderSize(url)
                    if size > 0 {
                        items.append(CacheItem(path: url.path, kind: kind, sizeBytes: size))
                    }
                    enumerator.skipDescendants()
                    continue
                }

                if !isDir, peakFileExtensions.contains(url.pathExtension.lowercased()) {
                    let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    items.append(CacheItem(path: url.path, kind: .peakFile, sizeBytes: size))
                }
            }
        }

        return items
    }

    static func folderSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [], errorHandler: nil
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard !isDir else { continue }
            total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}
