import AVFoundation

public enum VoiceCaptureError: Error {
    case formatUnavailable
}

/// Captures the Mac microphone in the format the Android TV voice channel
/// requires: 16-bit PCM, mono, 8 kHz. Chunks are emitted at exactly 8 KB so
/// the transport never has to zero-pad mid-utterance — padding is only ever
/// applied to the final partial chunk returned by `stop()`.
public final class VoiceCapture {

    /// The transport's minimum payload size; anything smaller gets zero-padded.
    public static let chunkBytes = 8 * 1024

    private let engine = AVAudioEngine()
    /// Only touched from the tap's audio queue while running, and from `stop()`
    /// after the tap is removed.
    private var pending = Data()

    public init() {}

    /// The first call prompts for microphone permission (the bundle carries
    /// NSMicrophoneUsageDescription); a denial surfaces as the engine failing
    /// to deliver audio, not as a throw.
    public func start(onChunk: @escaping @Sendable (Data) -> Void) throws {
        let input = engine.inputNode
        let native = input.outputFormat(forBus: 0)
        guard native.sampleRate > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000,
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: native, to: target) else {
            throw VoiceCaptureError.formatUnavailable
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: native) { [weak self] buffer, _ in
            guard let self else { return }
            let ratio = target.sampleRate / native.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                return
            }
            var served = false
            _ = converter.convert(to: out, error: nil) { _, status in
                if served { status.pointee = .noDataNow; return nil }
                served = true
                status.pointee = .haveData
                return buffer
            }
            guard let channel = out.int16ChannelData, out.frameLength > 0 else { return }
            self.pending.append(Data(bytes: channel[0], count: Int(out.frameLength) * 2))
            while self.pending.count >= Self.chunkBytes {
                onChunk(Data(self.pending.prefix(Self.chunkBytes)))
                self.pending.removeFirst(Self.chunkBytes)
            }
        }

        engine.prepare()
        try engine.start()
    }

    /// Stops capture and returns whatever partial chunk remains, so the caller
    /// can flush it as the utterance's tail.
    public func stop() -> Data {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        defer { pending.removeAll() }
        return pending
    }
}
