import AVFoundation
import Speech
import SwiftUI

struct Caption: Identifiable {
    let id: UUID
    var english: String
    var translation = ""
    var translatedSource = ""
}

@MainActor
final class LiveSpeech: ObservableObject {
    @Published var captions: [Caption] = []
    @Published private(set) var running = false
    @Published var message = ""
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = UUID()
    private var rollover: Task<Void, Never>?
    private var tapped = false

    func start() async {
        guard !running else { return }
        running = true
        message = "Checking permissions…"
        let token = generation
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        guard token == generation else { return }
        guard mic else { stop("Allow microphone access in System Settings → Privacy & Security."); return }
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard token == generation else { return }
        guard speech == .authorized else {
            stop("Allow Speech Recognition in System Settings → Privacy & Security.")
            return
        }
        beginSegment()
    }

    private func beginSegment() {
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            stop("English on-device speech recognition is unavailable on this Mac.")
            return
        }
        let id = UUID()
        generation = id
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            stop("Connect a microphone and check the selected sound input.")
            return
        }
        let audio = SFSpeechAudioBufferRecognitionRequest()
        audio.requiresOnDeviceRecognition = true
        audio.shouldReportPartialResults = true
        audio.addsPunctuation = true
        request = audio
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            audio.append(buffer)
        }
        tapped = true
        do {
            try engine.start()
        } catch {
            stop(error.localizedDescription)
            return
        }
        message = "Listening"
        task = recognizer.recognitionTask(with: audio) { [weak self] result, error in
            let words = result?.bestTranscription.formattedString ?? ""
            let final = result?.isFinal ?? false
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                if !words.isEmpty {
                    if self.captions.last?.id == id {
                        self.captions[self.captions.count - 1].english = words
                    } else {
                        self.captions.append(Caption(id: id, english: words))
                    }
                }
                if let error {
                    let nsError = error as NSError
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 {
                        self.restart()
                    } else {
                        self.stop(error.localizedDescription)
                    }
                } else if final {
                    self.restart()
                }
            }
        }
        rollover = Task {
            try? await Task.sleep(for: .seconds(48))
            guard !Task.isCancelled, generation == id else { return }
            restart()
        }
    }

    private func restart() {
        releaseSegment()
        beginSegment()
    }

    private func releaseSegment() {
        generation = UUID()
        rollover?.cancel()
        if tapped {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            tapped = false
        }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
    }

    func stop(_ status: String = "Stopped") {
        releaseSegment()
        running = false
        message = status
    }
}
