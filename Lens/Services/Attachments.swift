import Foundation
import AppKit
import UniformTypeIdentifiers

/// Turns files Emma attaches in Ask Lens into what Claude can read: photos (shrunk to a sensible
/// size), PDFs, and plain text such as CSV or notes.
enum Attachments {
    static let maxPDFBytes = 30 * 1024 * 1024
    static let maxTextChars = 400_000

    /// Content blocks for Claude, plus the names of files that couldn't be read.
    static func blocks(for urls: [URL]) -> ([[String: Any]], [String]) {
        var blocks: [[String: Any]] = [], skipped: [String] = []
        for url in urls {
            let type = UTType(filenameExtension: url.pathExtension.lowercased())
            if type?.conforms(to: .image) == true, let data = jpeg(url) {
                blocks.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": data.base64EncodedString()]])
            } else if type?.conforms(to: .pdf) == true, let data = try? Data(contentsOf: url), data.count <= maxPDFBytes {
                blocks.append(["type": "document", "title": url.lastPathComponent,
                               "source": ["type": "base64", "media_type": "application/pdf", "data": data.base64EncodedString()]])
            } else if type?.conforms(to: .text) == true || ["csv", "md", "json", "txt", "eml", "vtt", "srt"].contains(url.pathExtension.lowercased()),
                      let text = try? String(contentsOf: url, encoding: .utf8) {
                blocks.append(["type": "text", "text": "<file name=\"\(url.lastPathComponent)\">\n\(text.prefix(maxTextChars))\n</file>"])
            } else {
                skipped.append(url.lastPathComponent)
            }
        }
        return (blocks, skipped)
    }

    /// A JPEG no bigger than 2000 px on the long side (works for HEIC, RAW previews, PNG…).
    private static func jpeg(_ url: URL) -> Data? {
        guard let image = NSImage(contentsOf: url), let rep = image.representations.first else { return nil }
        let w = CGFloat(max(rep.pixelsWide, 1)), h = CGFloat(max(rep.pixelsHigh, 1))
        let scale = min(1, 2000 / max(w, h))
        let size = NSSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }
}
