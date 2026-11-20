import Foundation
import AppKit

/// Reads business cards from a photo with Claude. A photo can hold one card or several. Small,
/// self-contained service used by "Scan a card" in People and Today. Nothing here changes the user's data.
enum CardReader {

    struct Card {
        var name = ""
        var company = ""
        var title = ""
        var email = ""
        var phone = ""
        var website = ""
        var instagram = ""
        /// Fields Claude couldn't read for sure: "name", "email"…
        var unsure: Set<String> = []
    }

    // MARK: Photo storage (Application Support/Lens/CardPhotos)

    static var photoFolder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lens/CardPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func photoURL(_ file: String) -> URL { photoFolder.appendingPathComponent(file) }

    /// Saves the card photo and returns its file name.
    static func keepPhoto(_ jpeg: Data) -> String? {
        let name = UUID().uuidString + ".jpg"
        do { try jpeg.write(to: photoURL(name), options: .atomic); return name } catch { return nil }
    }

    // MARK: Asking Claude

    static var hasKey: Bool { GearIdentifier.hasKey }

    static func read(jpeg: Data) async throws -> [Card] {
        guard let key = Keychain.get("anthropic.apiKey"), !key.isEmpty else {
            throw GearIdentifier.Failure("Add your Claude key in Log-ins first, then try again.")
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")

        let prompt = """
        This is a photo of one or more business cards. Read every card in the photo. Reply with ONLY a JSON object, no other text:
        {"cards": [{"name": string, "company": string, "title": string, "email": string, "phone": string, "website": string, "instagram": string (the handle with @, if shown), "unsure": [the names of any fields above you could not read clearly or are guessing at]}]}
        Use "" for anything not on the card. Copy what is printed; never invent details. If there is no business card in the photo, reply {"cards": []}.
        """
        let model = await MainActor.run { LensAI.model }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1500,
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
        catch { throw GearIdentifier.Failure("Couldn't reach Claude. Check your internet and try again.") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            switch status {
            case 401: throw GearIdentifier.Failure("The Claude key isn't valid. Check it in Log-ins.")
            case 429: throw GearIdentifier.Failure("Claude is busy right now. Try again in a minute.")
            default: throw GearIdentifier.Failure("Claude couldn't read this photo (error \(status)).")
            }
        }
        let text = ((json["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
        return try parse(text)
    }

    /// Tolerant: finds the first {...} in the reply and reads whatever cards are there.
    static func parse(_ text: String) throws -> [Card] {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let obj = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
        else { throw GearIdentifier.Failure("Claude's answer wasn't readable. You can type the details yourself.") }
        let list = (obj["cards"] as? [[String: Any]]) ?? [obj]
        return list.compactMap { c in
            func field(_ k: String) -> String { ((c[k] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            var card = Card(name: field("name"), company: field("company"), title: field("title"), email: field("email").lowercased(),
                            phone: field("phone"), website: field("website"), instagram: field("instagram"))
            card.unsure = Set(((c["unsure"] as? [String]) ?? []).map { $0.lowercased() })
            if !card.email.isEmpty, !card.email.contains("@") { card.unsure.insert("email") }
            if card.name.isEmpty { card.unsure.insert("name") }
            let empty = [card.name, card.company, card.email, card.phone, card.website, card.instagram].allSatisfy(\.isEmpty)
            return empty ? nil : card
        }
    }
}
