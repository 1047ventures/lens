import Foundation

enum CacheKind: String, Codable {
    case mediaCacheFolder = "Media Cache"
    case previewFilesFolder = "Preview Files"
    case peakFile = "Peak File"
    case conformedAudioFolder = "Conformed Audio"
}

/// Adobe-generated cache/preview data that is always safe to delete because
/// Premiere regenerates it on demand.
struct CacheItem: Identifiable {
    let id = UUID()
    let path: String
    let kind: CacheKind
    let sizeBytes: Int64

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var reason: String { "\(kind.rawValue) — regenerated automatically by Premiere, safe to delete" }
}
