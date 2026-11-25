import AVFoundation
import CoreMedia
import FluidAudio
import Speech

// One byte per 80 ms frame. Zero denotes silence, overlap or uncertain speech.
struct SpeakerFrames {
    var origin = 0.0
    var duration = 0.08
    var slots: [UInt8] = []
    private var numbers: [Int: UInt8] = [:]

    mutating func append(_ chunk: DiarizerChunkResult) {
        for i in 0..<chunk.finalizedFrameCount {
            let frame = chunk.startFrame + i
            guard frame >= slots.count else { continue }
            if frame > slots.count { slots.append(contentsOf: repeatElement(0, count: frame - slots.count)) }
            let active = (0..<4).filter { chunk.probability(speaker: $0, frame: i, numSpeakers: 4) >= 0.55 }
            if active.count == 1, let slot = active.first {
                let number = numbers[slot] ?? UInt8(numbers.count + 1)
                numbers[slot] = number
                slots.append(number)
            } else {
                slots.append(0)
            }
        }
    }

    func label(for range: CMTimeRange) -> Int? {
        guard range.isValid, range.start.seconds.isFinite, range.end.seconds.isFinite else { return nil }
        let first = max(0, Int(floor((range.start.seconds - origin) / duration)))
        let end = min(slots.count, Int(ceil((range.end.seconds - origin) / duration)))
        guard first < end else { return nil }
        var counts = Array(repeating: 0, count: 5)
        for slot in slots[first..<end] { counts[Int(slot)] += 1 }
        guard let best = (1...4).max(by: { counts[$0] < counts[$1] }),
              counts[best] >= 4, counts[best] * 3 >= (end - first) * 2 else { return nil }
        return best
    }
}

enum SpeakerTracking {
    static func follow(_ packets: AsyncStream<VoicePacket>,
                       ready: @Sendable () async -> Void,
                       publish: @Sendable (DiarizerChunkResult, Double, Double) async -> Void) async throws {
        let diarizer = SortformerDiarizer(config: .default)
        let models = try await SortformerModels.loadFromHuggingFace(config: .default)
        try Task.checkCancellation()
        diarizer.initialize(models: models)
        await ready()
        let converter = AudioConverter()
        var origin: Double?
        var expected: Double?
        let duration = Double(diarizer.config.frameDurationSeconds)
        for await packet in packets {
            try Task.checkCancellation()
            let start = packet.start.seconds
            if let expected, abs(expected - start) > 0.01 {
                throw NSError(domain: "SpeakerTracking", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Speaker analysis fell behind. Restart listening to resume labels."
                ])
            }
            if origin == nil { origin = start }
            expected = start + Double(packet.buffer.frameLength) / packet.buffer.format.sampleRate
            let samples = try converter.resampleBuffer(packet.buffer)
            if let update = try diarizer.process(samples: samples, sourceSampleRate: 16_000) {
                await publish(update.chunkResult, origin ?? start, duration)
            }
        }
        try Task.checkCancellation()
        if let origin, let update = try diarizer.finalizeSession() {
            await publish(update.chunkResult, origin, duration)
        }
    }
}

struct VoicePacket: @unchecked Sendable {
    // The capture delegate publishes a new buffer per callback and never mutates it afterwards.
    let buffer: AVAudioPCMBuffer
    let start: CMTime
}

final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "MyInterpreter.microphone")
    private let format: AVAudioFormat
    private let speech: AsyncThrowingStream<AnalyzerInput, Error>.Continuation
    private let voice: AsyncStream<VoicePacket>.Continuation
    private let reader = AudioConverter()
    private var converter: AVAudioConverter?
    private var frame: Int64 = 0

    init(device: AVCaptureDevice, format: AVAudioFormat,
         speech: AsyncThrowingStream<AnalyzerInput, Error>.Continuation,
         voice: AsyncStream<VoicePacket>.Continuation) throws {
        self.format = format
        self.speech = speech
        self.voice = voice
        super.init()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        guard session.canAddInput(input) else { throw CaptureFailure("Cannot open the selected microphone.") }
        session.addInput(input)
        guard session.canAddOutput(output) else { throw CaptureFailure("Cannot receive microphone audio.") }
        output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM]
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
    }

    func start() { session.startRunning() }

    func stop() {
        session.stopRunning()
        queue.sync {
            speech.finish()
            voice.finish()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        do {
            let raw = try reader.extractAVAudioPCMBuffer(from: sampleBuffer)
            guard raw.frameLength > 0 else { return }
            let pcm = try convert(raw)
            guard pcm.frameLength > 0 else { return }
            let time = CMTime(value: frame, timescale: CMTimeScale(format.sampleRate))
            frame += Int64(pcm.frameLength)
            speech.yield(AnalyzerInput(buffer: pcm, bufferStartTime: time))
            voice.yield(VoicePacket(buffer: pcm, start: time))
        } catch {
            speech.finish(throwing: error)
            voice.finish()
        }
    }

    private func convert(_ raw: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if raw.format == format { return raw }
        if converter?.inputFormat != raw.format {
            converter = AVAudioConverter(from: raw.format, to: format)
        }
        let capacity = ceil(Double(raw.frameLength) * format.sampleRate / raw.format.sampleRate) + 32
        guard let converter, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(capacity))
        else { throw CaptureFailure("Unsupported microphone audio format.") }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return raw
        }
        if status == .error { throw error ?? CaptureFailure("Microphone audio conversion failed.") }
        return pcm
    }
}

private struct CaptureFailure: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}
