import Foundation
import AVFoundation
import Speech

/// Turns a recorded call into text with Apple speech recognition, on this Mac only: the audio never
/// leaves it. Long recordings are cut into short pieces, and each piece is listened to in turn.
enum Transcriber {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// How long each piece is. Short pieces keep speech recognition quick and reliable.
    static let pieceSeconds = 50.0

    static var denied: Failure {
        Failure(message: "Lens needs your OK to listen to your recordings. Open System Settings, then Privacy & Security, then Speech Recognition, and turn on Lens.")
    }
    static var notOnThisMac: Failure {
        Failure(message: "This Mac can't turn speech into text by itself yet. Open System Settings, then Keyboard, and turn on Dictation. Lens will try again later.")
    }

    /// Asks once for permission to use speech recognition.
    static func allowed() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { c in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    /// A recognizer that works without the internet, in her language or else English.
    static func recognizer() -> SFSpeechRecognizer? {
        for locale in [Locale.current, Locale(identifier: "en-US")] {
            if let r = SFSpeechRecognizer(locale: locale), r.supportsOnDeviceRecognition { return r }
        }
        return nil
    }

    /// Every word in one recording, with the time each piece starts: "[12:30] so the interview is on Tuesday".
    /// `progress` hears how far along it is, from 0 to 1.
    static func transcribe(_ url: URL, progress: @escaping @Sendable (Double) async -> Void = { _ in }) async throws -> String {
        guard let recognizer = recognizer() else { throw notOnThisMac }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 1 else { return "" }

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lens-listening-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var lines: [String] = []
        var start = 0.0
        var index = 0
        while start < duration {
            try Task.checkCancellation()
            let length = min(pieceSeconds, duration - start)
            let piece = folder.appendingPathComponent("piece-\(index).m4a")
            try await export(asset, from: start, length: length, to: piece)
            let text = try await recognize(piece, with: recognizer)
            if !text.isEmpty { lines.append("[\(clock(start))] \(text)") }
            try? FileManager.default.removeItem(at: piece)
            start += pieceSeconds
            index += 1
            await progress(min(start / duration, 1))
        }
        return lines.joined(separator: "\n")
    }

    /// One short stretch of the recording, as its own audio file.
    private static func export(_ asset: AVAsset, from start: Double, length: Double, to file: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw Failure(message: "Lens couldn't open this recording.")
        }
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                        duration: CMTime(seconds: length, preferredTimescale: 600))
        if #available(macOS 15, *) {
            try await session.export(to: file, as: .m4a)
        } else {
            session.outputURL = file
            session.outputFileType = .m4a
            await session.export()
            if session.status != .completed {
                throw session.error ?? Failure(message: "Lens couldn't open this recording.")
            }
        }
    }

    /// The words in one short piece. Silence comes back as "".
    private static func recognize(_ file: URL, with recognizer: SFSpeechRecognizer) async throws -> String {
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        let once = Once()
        return try await withCheckedThrowingContinuation { c in
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    if once.claim() { c.resume(returning: result.bestTranscription.formattedString) }
                } else if let error {
                    guard once.claim() else { return }
                    // "No speech detected" just means a quiet stretch.
                    let code = (error as NSError).code
                    if code == 1110 || code == 203 || code == 301 { c.resume(returning: "") } else { c.resume(throwing: error) }
                }
            }
        }
    }

    /// 754 seconds → "12:34", 3_754 → "1:02:34".
    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Makes sure an answer is only given once.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}
