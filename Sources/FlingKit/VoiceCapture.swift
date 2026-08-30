import AVFoundation

public enum VoiceCaptureError: Error {
    case formatUnavailable
}

/// Captures the Mac microphone in the format the Android TV voice channel
/// requires: 16-bit PCM, mono, 8 kHz. Chunks are emitted at exactly 8 KB, so
/// only the tail returned by `stop()` is ever zero-padded by the transport.
public final class VoiceCapture {

    /// The transport's minimum payload size; anything smaller gets zero-padded.
    public static let chunkBytes = ATVRemoteMessage.voiceChunkMinSize

    private let engine = AVAudioEngine()
    /// removeTap does not wait for an in-flight tap callback, so `pending` is
    /// genuinely shared between the render thread and `stop()`.
    private let lock = NSLock()
    private var pending = Data()

    public init() {}

    /// The first call prompts for microphone permission; a denial surfaces as
    /// the engine failing to deliver audio, not as a throw.
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
            self.lock.lock()
            self.pending.append(Data(bytes: channel[0], count: Int(out.frameLength) * 2))
            var full: [Data] = []
            while self.pending.count >= Self.chunkBytes {
                full.append(Data(self.pending.prefix(Self.chunkBytes)))
                self.pending.removeFirst(Self.chunkBytes)
            }
            self.lock.unlock()
            for chunk in full { onChunk(chunk) }
        }

        engine.prepare()
        try engine.start()
    }

    /// Stops capture and returns whatever partial chunk remains, so the caller
    /// can flush it as the utterance's tail.
    public func stop() -> Data {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.lock()
        defer { pending.removeAll(); lock.unlock() }
        return pending
    }
}
