import Foundation

/// The "big picture" summary shown on the Weigh-In page once a scan completes —
/// computed fresh from the scan results, never persisted on its own.
struct ScanOverview {
    let totalFiles: Int
    let totalBytes: Int64

    let duplicateGroupCount: Int
    let duplicateWastedBytes: Int64

    let cacheItemCount: Int
    let cacheBytes: Int64

    let organizeCount: Int

    let archiveCount: Int
    let archiveBytes: Int64

    var reclaimableBytes: Int64 { duplicateWastedBytes + cacheBytes + archiveBytes }

    static let empty = ScanOverview(
        totalFiles: 0, totalBytes: 0,
        duplicateGroupCount: 0, duplicateWastedBytes: 0,
        cacheItemCount: 0, cacheBytes: 0,
        organizeCount: 0,
        archiveCount: 0, archiveBytes: 0
    )
}
