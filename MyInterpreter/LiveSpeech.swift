import AVFoundation
import CoreMedia
import Speech
import SwiftUI

struct Caption: Identifiable {
    let id = UUID()
    let session: UUID
    var range: CMTimeRange
    let sourceLocale: String
    var original: String
    var speaker: Int?
    var translation = ""
    var translatedSource = ""

    func overlaps(_ other: CMTimeRange) -> Bool {
        CMTimeCompare(range.start, other.start) == 0 || CMTimeRangeGetIntersection(range, otherRange: other).duration > .zero
    }
}

struct Transcript {
    var history: [Caption] = []
    var live: Caption?

    mutating func record(_ text: String, range: CMTimeRange, final: Bool, session: UUID, sourceLocale: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        if history.contains(where: { $0.session == session && $0.range.containsTimeRange(range) }) { return }

        let matchingDraft = live.flatMap { $0.session == session && $0.overlaps(range) ? $0 : nil }
        var line = matchingDraft ?? Caption(session: session, range: range, sourceLocale: sourceLocale, original: words)
        line.range = range
        line.original = words
        if final {
            let index = history.firstIndex { $0.session == session && $0.range.start > range.start }
            history.insert(line, at: index ?? history.endIndex)
            if matchingDraft != nil { live = nil }
        } else {
            live = line
        }
    }

    func exportText(language: String) -> String {
        var blocks: [String] = []
        var previousSession: UUID?
        var sessionNumber = 0

        func append(_ line: Caption, draft: Bool) {
            if previousSession != line.session {
                previousSession = line.session
                sessionNumber += 1
                blocks.append("Session \(sessionNumber)")
            }
            var lines: [String] = []
            if draft { lines.append("[Current speech · draft]") }
            if let speaker = line.speaker { lines.append("Speaker \(speaker)") }
            let sourceName = Locale.current.localizedString(forIdentifier: line.sourceLocale) ?? line.sourceLocale
            lines.append("\(sourceName): \(line.original)")
            let translated = line.translatedSource == line.original && !line.translation.isEmpty
            lines.append("\(language): \(translated ? line.translation : "[Translation pending]")")
            blocks.append(lines.joined(separator: "\n"))
        }

        for line in history { append(line, draft: false) }
        if let live { append(live, draft: true) }
        return blocks.joined(separator: "\n\n") + (blocks.isEmpty ? "" : "\n")
    }

    var pendingTranslation: Caption? {
        if let line = history.first(where: { $0.translatedSource != $0.original }) { return line }
        guard let live, live.original != live.translatedSource else { return nil }
        return live
    }

    mutating func applyTranslation(_ text: String, for source: Caption) {
        if let i = history.lastIndex(where: { $0.id == source.id && $0.original == source.original }) {
            history[i].translation = text
            history[i].translatedSource = source.original
        } else if live?.id == source.id && live?.original == source.original {
            live?.translation = text
            live?.translatedSource = source.original
        }
    }

    mutating func clearTranslations() {
        for i in history.indices {
            history[i].translation = ""
            history[i].translatedSource = ""
        }
        live?.translation = ""
        live?.translatedSource = ""
    }
}

@MainActor
final class LiveSpeech: ObservableObject {
    @Published var transcript = Transcript()
    @Published private(set) var running = false
    @Published private(set) var finishing = false
    @Published var message = ""

    @Published var speakerStatus = ""
    private var frames = SpeakerFrames()
    private var speakerTask: Task<Void, Never>?
    private var speakerSession = UUID()
    private var session = UUID()
    private var capture: MicrophoneCapture?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?

    func start(deviceID: String, sourceLocale: String, roomMode: Bool, vocabulary: String) async {
        guard !running, !finishing else { return }
        let id = UUID()
        session = id
        speakerTask?.cancel()
        speakerSession = id
        frames = SpeakerFrames()
        speakerStatus = ""
        running = true
        message = "Checking microphone…"
        do {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard id == session else { return }
            guard allowed else { throw CaptureError("Allow microphone access in System Settings → Privacy & Security.") }
            let selected = deviceID.isEmpty ? AVCaptureDevice.default(for: .audio) : AVCaptureDevice(uniqueID: deviceID)
            guard let device = selected else { throw CaptureError("Select an available microphone in Input settings.") }
            let requested = Locale(identifier: sourceLocale)
            let terms = vocabulary.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let transcriber: any SpeechModule
            let receive: @MainActor () async throws -> Void
            let context = AnalysisContext()
            if !roomMode && terms.isEmpty && SpeechTranscriber.isAvailable,
               let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
                let module = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                               reportingOptions: [.volatileResults], attributeOptions: [])
                transcriber = module
                receive = {
                    for try await result in module.results {
                        self.record(result.text, result.range, result.isFinal, id, sourceLocale)
                    }
                }
            } else {
                guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) else {
                    throw CaptureError("Speech recognition is unavailable for the selected language and mode. Choose another spoken language or turn off Room microphone and clear Names and terms.")
                }
                var preset = DictationTranscriber.Preset.progressiveLongDictation
                if roomMode { preset.contentHints.insert(.farField) }
                let module = DictationTranscriber(locale: locale, preset: preset)
                context.contextualStrings[.general] = terms
                transcriber = module
                receive = {
                    for try await result in module.results {
                        self.record(result.text, result.range, result.isFinal, id, sourceLocale)
                    }
                }
            }
            guard id == session else { return }
            message = "Preparing " + (Locale.current.localizedString(forIdentifier: sourceLocale) ?? sourceLocale) + " speech model…"
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await install.downloadAndInstall()
            }
            guard id == session else { return }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw CaptureError("The selected speech model has no available audio format.")
            }
            guard id == session else { return }
            let analysis = SpeechAnalyzer(modules: [transcriber])
            if !terms.isEmpty {
                try await analysis.setContext(context)
            }
            let (stream, continuation) = AsyncThrowingStream<AnalyzerInput, Error>.makeStream()
            try await analysis.start(inputSequence: stream)
            guard id == session else {
                continuation.finish()
                await analysis.cancelAndFinishNow()
                return
            }
            let voiceInput = startSpeakerTracking(id)
            let microphone: MicrophoneCapture
            do {
                microphone = try MicrophoneCapture(device: device, format: format,
                                                   speech: continuation, voice: voiceInput)
            } catch {
                voiceInput.finish()
                continuation.finish()
                await analysis.cancelAndFinishNow()
                throw error
            }
            capture = microphone
            analyzer = analysis
            input = continuation
            microphone.start()
            message = "Listening · " + device.localizedName
            try await receive()
            if id == session { reset("Stopped") }
        } catch {
            if id == session { reset(error.localizedDescription) }
        }
    }

    private func record(_ text: AttributedString, _ range: CMTimeRange, _ final: Bool, _ id: UUID, _ sourceLocale: String) {
        guard session == id else { return }
        transcript.record(String(text.characters), range: range, final: final, session: id, sourceLocale: sourceLocale)
        updateLabels(from: range.start.seconds, to: range.end.seconds, id: id)
    }

    private func updateLabels(from start: Double, to end: Double, id: UUID) {
        for i in transcript.history.indices.reversed() {
            let line = transcript.history[i]
            if line.session != id || line.range.end.seconds < start { break }
            guard line.range.start.seconds <= end else { continue }
            let label = frames.label(for: line.range)
            if label != line.speaker { transcript.history[i].speaker = label }
        }
        if let live = transcript.live, live.session == id {
            let label = frames.label(for: live.range)
            if label != live.speaker { transcript.live?.speaker = label }
        }
    }

    private func startSpeakerTracking(_ id: UUID) -> AsyncStream<VoicePacket>.Continuation {
        let (stream, continuation) = AsyncStream<VoicePacket>.makeStream(bufferingPolicy: .bufferingNewest(120))
        speakerStatus = "Preparing speaker model…"
        speakerTask = Task {
            do {
                try await SpeakerTracking.follow(stream, ready: { @MainActor in
                    if self.speakerSession == id { self.speakerStatus = "" }
                }, publish: { @MainActor chunk, origin, duration in
                    guard self.speakerSession == id else { return }
                    self.frames.origin = origin
                    self.frames.duration = duration
                    self.frames.append(chunk)
                    let start = origin + Double(chunk.startFrame) * duration
                    self.updateLabels(from: start, to: start + Double(chunk.finalizedFrameCount) * duration, id: id)
                })
            } catch {
                if !Task.isCancelled && speakerSession == id {
                    speakerStatus = "Speaker labels unavailable · " + error.localizedDescription
                }
            }
            continuation.finish()
        }
        return continuation
    }

    private func endInput() {
        capture?.stop()
        capture = nil
        input?.finish()
        input = nil
    }

    func stop() {
        guard running, !finishing else { return }
        guard let analyzer else { reset("Stopped"); return }
        finishing = true
        message = "Finishing last phrase…"
        endInput()
        let id = session
        Task {
            do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
            catch { if id == session { reset(error.localizedDescription) } }
        }
    }

    private func reset(_ status: String) {
        endInput()
        transcript.live = nil
        session = UUID()
        analyzer = nil
        running = false
        finishing = false
        message = status
    }
}

private struct CaptureError: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}
