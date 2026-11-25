import Foundation
import AppKit
import AVFoundation
import ImageIO

/// Finds and draws the picture on a project's tile: the one she picked, or else the first still
/// (then the first clip) Lens finds in the project's footage folder. Looks are cheap after the first:
/// the chosen file and its picture are both remembered while Lens is open.
enum ProjectCover {
    private static let stills: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp",
                                              "cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2"]
    private static let clips: Set<String> = ["mov", "mp4", "m4v"]

    @MainActor private static var found: [String: URL?] = [:]
    private static let pictures = NSCache<NSString, NSImage>()

    /// Whether a file she drops or picks can be a cover.
    static func canUse(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return stills.contains(ext) || clips.contains(ext)
    }

    /// The picture for this project's tile, or nil when there's nothing to show yet.
    @MainActor static func image(for project: Project) async -> NSImage? {
        guard let url = await file(for: project) else { return nil }
        let key = url.path as NSString
        if let cached = pictures.object(forKey: key) { return cached }
        let picture = await Task.detached(priority: .utility) { draw(url) }.value
        guard let picture else { return nil }
        pictures.setObject(picture, forKey: key)
        return picture
    }

    /// A small picture of a still (RAW included) or a frame from a clip.
    private static func draw(_ url: URL) -> NSImage? {
        if clips.contains(url.pathExtension.lowercased()) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1280, height: 840)
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            guard let cg = try? generator.copyCGImage(at: CMTime(seconds: 2, preferredTimescale: 600), actualTime: nil) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 1280]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    @MainActor private static func file(for project: Project) async -> URL? {
        if let path = project.coverPath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let folders = [project.folderPath, project.archivedPath].compactMap { $0 }
        guard !folders.isEmpty else { return nil }
        let key = "\(project.id)|" + folders.joined(separator: "|")
        if let known = found[key] { return known }
        let pick = await Task.detached(priority: .utility) { firstPicture(in: folders) }.value
        found[key] = pick
        return pick
    }

    /// The first still in the folder, or the first clip if it has no stills. Looks at a few hundred
    /// files at most, so a huge drive folder never slows the wall down.
    private static func firstPicture(in folders: [String]) -> URL? {
        var firstClip: URL?
        for folder in folders {
            let root = URL(fileURLWithPath: folder)
            guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            var looked = 0
            while let url = walk.nextObject() as? URL, looked < 400 {
                looked += 1
                if walk.level > 4 { walk.skipDescendants(); continue }
                let ext = url.pathExtension.lowercased()
                if stills.contains(ext) { return url }
                if firstClip == nil && clips.contains(ext) { firstClip = url }
            }
        }
        return firstClip
    }
}
