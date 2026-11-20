import Foundation
import AppKit

/// Looks at a photo of gear and asks Claude what it is. Small, self-contained service used by
/// "Add from photo" in Gear. Nothing here changes the user's data.
enum GearIdentifier {

    struct Guess {
        var brand = ""
        var model = ""
        var kind: GearItem.Kind = .other
        var serial = ""
        var usedValue: Double?
        var sure = true
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    // MARK: Photo storage

    static var photoFolder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lens/GearPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func photoURL(_ file: String) -> URL { photoFolder.appendingPathComponent(file) }

    /// Saves a small copy of the photo and returns its file name.
    static func keepPhoto(_ jpeg: Data) -> String? {
        let name = UUID().uuidString + ".jpg"
        do { try jpeg.write(to: photoURL(name), options: .atomic); return name } catch { return nil }
    }

    // MARK: Image prep

    /// Reads an image file and returns a JPEG no larger than `maxSide` pixels on its long edge.
    static func jpeg(from url: URL, maxSide: CGFloat = 1600) -> Data? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        return jpeg(from: image, maxSide: maxSide)
    }

    /// The same for a photo that isn't a file yet (one taken with the iPhone camera, for example).
    static func jpeg(from image: NSImage, maxSide: CGFloat = 1600) -> Data? {
        guard let rep = bestRep(image) else { return nil }
        let w = CGFloat(rep.pixelsWide), h = CGFloat(rep.pixelsHigh)
        guard w > 0, h > 0 else { return nil }
        let scale = min(1, maxSide / max(w, h))
        let size = NSSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return out.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    private static func bestRep(_ image: NSImage) -> NSBitmapImageRep? {
        let reps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        return reps.max { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }
            ?? image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }
    }

    // MARK: Asking Claude

    static var hasKey: Bool { !(Keychain.get("anthropic.apiKey") ?? "").isEmpty }

    static func identify(jpeg: Data) async throws -> Guess {
        guard let key = Keychain.get("anthropic.apiKey"), !key.isEmpty else {
            throw Failure("Add your Claude key in Log-ins first, then try again.")
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")

        let kinds = GearItem.Kind.allCases.map(\.rawValue).joined(separator: ", ")
        let prompt = """
        This is a photo of one piece of photo or video gear. Identify it. Reply with ONLY a JSON object, no other text:
        {"brand": string, "model": string (the exact model name as sold, e.g. "A7S III" or "FE 24-70mm f/2.8 GM II"), "kind": one of [\(kinds)], "serial": string (only if clearly readable, else ""), "used_value_usd": number (a rough typical used-market price in US dollars today, or null if you cannot tell), "sure": boolean (false if you are guessing at the brand or exact model)}
        If the photo does not show gear, use "sure": false and leave brand and model empty.
        """
        let model = await MainActor.run { LensAI.model }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 600,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
                    ["type": "text", "text": prompt],
                ],
            ]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw Failure("Couldn't reach Claude. Check your internet and try again.") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            switch status {
            case 401: throw Failure("The Claude key isn't valid. Check it in Log-ins.")
            case 429: throw Failure("Claude is busy right now. Try again in a minute.")
            default: throw Failure("Claude couldn't read this photo (error \(status)).")
            }
        }
        let text = ((json["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
        return try parse(text)
    }

    /// Tolerant: finds the first {...} in the reply and reads whatever fields are there.
    static func parse(_ text: String) throws -> Guess {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let obj = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
        else { throw Failure("Claude's answer wasn't readable. You can type the details yourself.") }
        var g = Guess()
        g.brand = (obj["brand"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        g.model = (obj["model"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        g.serial = (obj["serial"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        if let k = (obj["kind"] as? String)?.lowercased(), let kind = GearItem.Kind(rawValue: k) { g.kind = kind }
        if let v = obj["used_value_usd"] as? Double { g.usedValue = v }
        else if let s = obj["used_value_usd"] as? String, let v = Double(s.filter { "0123456789.".contains($0) }) { g.usedValue = v }
        if let v = g.usedValue, v <= 0 { g.usedValue = nil }
        g.sure = (obj["sure"] as? Bool) ?? false
        if g.brand.isEmpty && g.model.isEmpty { g.sure = false }
        return g
    }
}
