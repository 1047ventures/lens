import Foundation
import Photos
import AVFoundation
import AppKit

/// Reads the Mac's Photos app (with her permission) into Lens's drive memory, so the thousands
/// of photos in there show up in Library search next to everything on her drives. Read only:
/// Lens never changes or deletes anything in Photos.
enum PhotosLibrary {
    static let driveID = "photos-app"

    static var allowed: Bool { PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized }
    static var refused: Bool {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return s == .denied || s == .restricted
    }

    /// Asks for permission the first time, then lists every photo and video by year and month.
    /// Returns nil if she said no.
    static func read() async -> CatalogDrive? {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        return await Task.detached(priority: .utility) { write() }.value
    }

    private static func write() -> CatalogDrive {
        let folder = DriveCatalog.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent("\(driveID).tsv.tmp")
        let final = folder.appendingPathComponent("\(driveID).tsv")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let handle = try? FileHandle(forWritingTo: temp)

        var buffer = Data()
        var photos = 0, videos = 0
        var photoBytes: Int64 = 0, videoBytes: Int64 = 0
        let month = DateFormatter(); month.dateFormat = "yyyy/MMMM yyyy"

        let assets = PHAsset.fetchAssets(with: nil)
        assets.enumerateObjects { asset, _, _ in
            autoreleasepool {
                let resources = PHAssetResource.assetResources(for: asset)
                let main = resources.first { [.photo, .video, .fullSizePhoto, .fullSizeVideo].contains($0.type) } ?? resources.first
                let name = (main?.originalFilename ?? "Untitled")
                    .replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
                let size = (main?.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
                let date = asset.creationDate ?? Date(timeIntervalSince1970: 0)
                let isVideo = asset.mediaType == .video
                if isVideo { videos += 1; videoBytes += size } else { photos += 1; photoBytes += size }
                let path = "Photos/\(month.string(from: date))/\(name)"
                let kind = isVideo ? CatalogKind.video : CatalogKind.photo
                buffer.append(Data("\(path)\t\(size)\t\(Int(date.timeIntervalSince1970))\t\(kind.rawValue)\t\(asset.localIdentifier)\n".utf8))
                if buffer.count > 256 * 1024 { try? handle?.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
            }
        }
        try? handle?.write(contentsOf: buffer)
        try? handle?.close()
        _ = try? FileManager.default.replaceItemAt(final, withItemAt: temp)
        if !FileManager.default.fileExists(atPath: final.path) { try? FileManager.default.moveItem(at: temp, to: final) }

        return CatalogDrive(id: driveID, name: "Photos app", isMac: false, total: 0, free: 0,
                            lastSeen: Date(), lastScanned: Date(),
                            videoCount: videos, videoBytes: videoBytes, photoCount: photos, photoBytes: photoBytes,
                            projectCount: 0, source: "photos")
    }

    // MARK: Pictures for the folder view

    static func asset(_ id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    /// `quick` gets the small version Photos already has on hand (for thumbnails); otherwise full quality.
    static func image(_ id: String, size: CGSize, quick: Bool = false) async -> NSImage? {
        guard let asset = asset(id) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = quick ? .fastFormat : .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { cont in
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { image, _ in
                cont.resume(returning: image)
            }
        }
    }

    static func playerItem(_ id: String) async -> AVPlayerItem? {
        guard let asset = asset(id) else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        return await withCheckedContinuation { cont in
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, _ in
                cont.resume(returning: item)
            }
        }
    }
}
