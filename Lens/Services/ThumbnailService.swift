import Foundation
import AVFoundation
import AppKit
import CryptoKit

/// Generates a small frame-grab thumbnail per video file, on demand only — never eagerly
/// for a whole drive during scan. Disk-cached so re-viewing a list (or relaunching the app)
/// doesn't regenerate the same thumbnail twice.
enum ThumbnailService {
    private static let thumbnailSize = CGSize(width: 320, height: 180)

    static func thumbnail(for file: MediaFile) async -> NSImage? {
        let cacheURL = cacheFileURL(for: file)

        if let cached = NSImage(contentsOf: cacheURL) {
            return cached
        }

        guard let generated = await generate(for: file) else { return nil }
        if let tiff = generated.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.75]) {
            try? jpegData.write(to: cacheURL)
        }
        return generated
    }

    private static func generate(for file: MediaFile) async -> NSImage? {
        let asset = AVURLAsset(url: file.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = thumbnailSize
        // Exact-frame matching (the default) silently fails for plenty of real-world footage —
        // HEVC/B-frame-heavy GOPs especially — since it demands a sync sample at that exact
        // timestamp. Accept the nearest available frame instead.
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        let requestedTime = CMTime(seconds: 1, preferredTimescale: 600)
        return await withCheckedContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: requestedTime)]) { _, cgImage, _, _, _ in
                guard let cgImage else {
                    continuation.resume(returning: nil)
                    return
                }
                let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                continuation.resume(returning: image)
            }
        }
    }

    private static func cacheFileURL(for file: MediaFile) -> URL {
        let key = "\(file.path)|\(file.sizeBytes)|\(file.modificationDate.timeIntervalSince1970)"
        let hash = SHA256.hash(data: Data(key.utf8)).compactMap { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("\(hash).jpg")
    }

    private static var cacheDirectory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lens/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}
