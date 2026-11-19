import Foundation
import AVFoundation
import Speech

/// Talk instead of type. Listens on the Mac's microphone and turns speech into text as you go.
/// Uses Apple's speech recognition, on this Mac when it can, so nothing is sent to Lens's servers.
@MainActor
final class VoiceInput: ObservableObject {
    @Published private(set) var listening = false
    @Published private(set) var text = ""
    @Published var problem: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func toggle() {
        if listening { stop() } else { Task { await start() } }
    }

    func start() async {
        problem = nil
        guard await Self.allowed() else {
            problem = "Lens needs the microphone and speech recognition. Turn them on in System Settings > Privacy & Security, then try again."
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            problem = "Speech recognition isn't available right now. Try again in a moment."
            return
        }
        text = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            problem = "Couldn't use the microphone. Check that one is connected."
            return
        }
        listening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result { self.text = result.bestTranscription.formattedString }
                if error != nil || result?.isFinal == true { self.finish() }
            }
        }
    }

    /// Stop listening. The last few words may still arrive a moment later.
    func stop() {
        guard listening else { return }
        stopAudio()
        request?.endAudio()
    }

    /// Stop and throw away anything still coming (used when the message is sent).
    func cancel() {
        task?.cancel()
        finish()
    }

    private func stopAudio() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        listening = false
    }

    private func finish() {
        stopAudio()
        request = nil
        task = nil
    }

    private static func allowed() async -> Bool {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }
}
