import Foundation
import AppKit
import UniformTypeIdentifiers

/// Turns files the user attaches in Ask Lens into what Claude can read: photos (shrunk to a sensible
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
            } else if ["pages", "key", "numbers"].contains(url.pathExtension.lowercased()), let preview = iWorkPreview(url) {
                // Pages, Keynote and Numbers files keep a preview of the document inside them.
                if preview.isPDF {
                    blocks.append(["type": "document", "title": url.lastPathComponent,
                                   "source": ["type": "base64", "media_type": "application/pdf", "data": preview.data.base64EncodedString()]])
                } else {
                    blocks.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": preview.data.base64EncodedString()]])
                }
            } else if ["docx", "doc", "rtf", "odt"].contains(url.pathExtension.lowercased()),
                      let doc = try? NSAttributedString(url: url, options: [:], documentAttributes: nil), !doc.string.isEmpty {
                // Word and similar documents: their text.
                blocks.append(["type": "text", "text": "<file name=\"\(url.lastPathComponent)\">\n\(doc.string.prefix(maxTextChars))\n</file>"])
            } else if type?.conforms(to: .text) == true || ["csv", "md", "json", "txt", "eml", "vtt", "srt"].contains(url.pathExtension.lowercased()),
                      let text = try? String(contentsOf: url, encoding: .utf8) {
                blocks.append(["type": "text", "text": "<file name=\"\(url.lastPathComponent)\">\n\(text.prefix(maxTextChars))\n</file>"])
            } else {
                skipped.append(url.lastPathComponent)
            }
        }
        return (blocks, skipped)
    }

    /// The preview Pages, Keynote and Numbers save inside a document: a PDF when there is one, else an image.
    private static func iWorkPreview(_ url: URL) -> (data: Data, isPDF: Bool)? {
        // A document saved as a folder package keeps its preview as a plain file.
        for name in ["QuickLook/Preview.pdf", "preview.pdf"] {
            let file = url.appendingPathComponent(name)
            if let data = try? Data(contentsOf: file), !data.isEmpty { return (data, true) }
        }
        // Otherwise the document is a zip file.
        for (name, isPDF) in [("QuickLook/Preview.pdf", true), ("preview.jpg", false), ("QuickLook/Thumbnail.jpg", false)] {
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-p", url.path, name]
            let pipe = Pipe()
            unzip.standardOutput = pipe
            unzip.standardError = FileHandle.nullDevice
            do { try unzip.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            unzip.waitUntilExit()
            if unzip.terminationStatus == 0, !data.isEmpty { return (data, isPDF) }
        }
        return nil
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
