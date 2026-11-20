import AppKit

/// A picture of the Lens window as Emma sees it right now, so Ask Lens can see her screen without a
/// screenshot. Only Lens's own window is captured (nothing else on her Mac), and it isn't saved anywhere.
@MainActor
enum LensScreen {
    /// The Lens window as a JPEG, base64, at most `maxWidth` pixels wide. Nil if there's no window to see.
    static func snapshot(maxWidth: CGFloat = 1600) -> String? {
        let candidates = NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) && $0.contentView != nil && $0.frame.width > 500 }
        guard let window = NSApp.mainWindow.flatMap({ candidates.contains($0) ? $0 : nil }) ?? candidates.max(by: { $0.frame.width < $1.frame.width }),
              let view = window.contentView else { return nil }
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0, let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        guard let full = rep.cgImage else { return nil }
        let scale = min(1, maxWidth / CGFloat(full.width))
        let width = max(1, Int(CGFloat(full.width) * scale)), height = max(1, Int(CGFloat(full.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(full, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        else { return nil }
        return data.base64EncodedString()
    }
}
