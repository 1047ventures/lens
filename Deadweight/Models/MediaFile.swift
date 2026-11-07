import Foundation

/// A single video file discovered on disk during a scan.
struct MediaFile: Identifiable, Codable, Hashable {
    let id: UUID
    let path: String
    let sizeBytes: Int64
    let modificationDate: Date
    let creationDate: Date?
    var quickFingerprint: String?
    var fullHash: String?
    var linkedProjects: [String] = []

    // Best-effort video metadata, filled in by VideoMetadataService after the initial scan.
    // Any of these can be nil if the file's container doesn't carry that info.
    var duration: TimeInterval?
    var width: Int?
    var height: Int?
    var codec: String?
    var frameRate: Double?
    var cameraModel: String?
    var gpsLatitude: Double?
    var gpsLongitude: Double?
    var locationLabel: String?

    init(path: String, sizeBytes: Int64, modificationDate: Date, creationDate: Date? = nil) {
        self.id = UUID()
        self.path = path
        self.sizeBytes = sizeBytes
        self.modificationDate = modificationDate
        self.creationDate = creationDate
    }

    var url: URL { URL(fileURLWithPath: path) }
    var filename: String { url.lastPathComponent }
    var parentFolderName: String { url.deletingLastPathComponent().lastPathComponent }
    var isLinked: Bool { !linkedProjects.isEmpty }

    var resolutionLabel: String? {
        guard let width, let height else { return nil }
        return "\(width)×\(height)"
    }

    var durationLabel: String? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        let totalSeconds = Int(duration.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// A short "resolution · duration · codec" caption for list rows, omitting any part that's unknown.
    var metadataCaption: String? {
        let parts = [resolutionLabel, durationLabel, codec].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func == (lhs: MediaFile, rhs: MediaFile) -> Bool { lhs.path == rhs.path }
    func hash(into hasher: inout Hasher) { hasher.combine(path) }
}

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
