import Foundation

/// The remote-control session on port 6466 (remotemessage.proto), ported from
/// androidtvremote2 remote.py: configure/set-active handshake, ping keepalive,
/// key injection, power state, app reporting, IME text, and voice streaming.
public actor ATVRemoteClient {

    public enum Event: Sendable, Equatable {
        case connected
        case powerChanged(Bool)
        /// Foreground app package, or nil when it goes away. Requires the IME
        /// feature (negotiated by default).
        case appChanged(String?)
        case disconnected
    }

    /// From the latest RemoteStart — the TV pushes one on connect and again
    /// whenever power flips.
    public private(set) var isOn = false
    public private(set) var isConnected = false
    /// Foreground app package (e.g. "com.google.android.youtube.tv"), nil if
    /// unknown or the launcher is showing.
    public private(set) var currentApp: String?

    private let store: ATVCertificateStore
    private let enableVoice: Bool
    /// Latched when a TV closed the configure exchange with VOICE requested;
    /// later connects mirror the reference's voice-off negotiation.
    private var voiceRejectedByTV = false
    private var connection: ATVFramedConnection?
    private var readTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]
    private var activeFeatures: ATVRemoteMessage.Features

    // IME counters the TV pushes when a text field is focused; text entry is a
    // no-op on the TV until these are non-zero.
    private var imeCounter: UInt64 = 0
    private var imeFieldCounter: UInt64 = 0

    // Voice session state.
    private var voiceSession: UInt64?
    private var voiceBeginContinuation: CheckedContinuation<UInt64, Error>?
    private var voiceTimeoutTask: Task<Void, Never>?

    /// The server pings every 5s when idle and drops clients after 3 unanswered
    /// pings; mirroring remote.py, a 16s silence means the link is dead.
    private static let idleTimeout: TimeInterval = 16
    /// Matches remote.py VOICE_SESSION_TIMEOUT.
    private static let voiceBeginTimeout: TimeInterval = 2

    public init(store: ATVCertificateStore = .shared, enableVoice: Bool = false) {
        self.store = store
        self.enableVoice = enableVoice
        self.activeFeatures = ATVRemoteMessage.Features.requested(voice: enableVoice)
    }

    /// Connects and completes the handshake, returning once RemoteStart makes
    /// `isOn` valid. A `tlsHandshakeFailed` here usually means the TV no
    /// longer holds the client certificate and pairing is needed.
    ///
    /// When VOICE was requested and the TV closes during the configure
    /// exchange (after TLS succeeded), the connect is retried once without
    /// VOICE and voice stays off for this client. The field-tested reference
    /// never sends the VOICE bit — androidtv_remote.py defaults
    /// `enable_voice=False` — so firmware that objects to it gets exactly the
    /// reference's bytes on the retry.
    public func connect(host: String, port: UInt16 = 6466) async throws {
        let voiceRequested = enableVoice && !voiceRejectedByTV
        do {
            try await connectOnce(host: host, port: port, voice: voiceRequested)
        } catch let error where Self.shouldRetryWithoutVoice(after: error, voiceRequested: voiceRequested) {
            ATVLog.shared.log("remote", "handshake failed with VOICE requested (\(error)); retrying without voice")
            voiceRejectedByTV = true
            try await connectOnce(host: host, port: port, voice: false)
        }
    }

    /// A close after TLS came up but before RemoteStart is the only failure
    /// shape a rejected feature bit can produce; TLS-stage failures
    /// (`tlsHandshakeFailed`) and silence (`connectionTimeout`) cannot be the
    /// voice bit's doing, so they are not retried.
    static func shouldRetryWithoutVoice(after error: Error, voiceRequested: Bool) -> Bool {
        guard voiceRequested else { return false }
        switch error {
        case ATVError.connectionClosed, ATVError.connectionFailed:
            return true
        default:
            return false
        }
    }

    private func connectOnce(host: String, port: UInt16, voice: Bool) async throws {
        teardown(emitDisconnected: false)
        activeFeatures = ATVRemoteMessage.Features.requested(voice: voice)
        ATVLog.shared.log("remote", "connect \(host):\(port) requesting features=0x\(String(activeFeatures.rawValue, radix: 16))")
        let identity = try store.loadIdentity()
        let connection = ATVFramedConnection(host: host, port: port, identity: identity)
        self.connection = connection
        do {
            try await connection.start()
            // The TV opens with RemoteConfigure → RemoteSetActive → RemoteStart;
            // handle() answers the first two and returns power state on the third.
            var started: Bool?
            while started == nil {
                let message = try await withATVDeadline(seconds: Self.idleTimeout,
                                                        onDeadline: { connection.cancel() }) {
                    try await connection.receiveMessage()
                }
                started = try await handle(message, on: connection)
            }
            isConnected = true
            isOn = started ?? false
            ATVLog.shared.log("remote", "handshake complete active=0x\(String(activeFeatures.rawValue, radix: 16)) isOn=\(isOn)")
            emit(.connected)
            emit(.powerChanged(isOn))
        } catch {
            ATVLog.shared.log("remote", "connect failed: \(error)")
            teardown(emitDisconnected: false)
            throw error
        }
        readTask = Task { [weak self] in
            await self?.runReadLoop(on: connection)
        }
    }

    /// Injects a SHORT key press (remote.py send_key_command).
    public func sendKey(_ keyCode: Int32) async throws {
        guard isConnected, let connection else { throw ATVError.notConnected }
        try await connection.send(ATVRemoteMessage.keyInject(keyCode: keyCode))
    }

    /// KEYCODE_POWER toggles: the same key wakes a sleeping TV and sleeps an
    /// awake one. `isOn` follows via the RemoteStart the TV pushes after.
    public func powerToggle() async throws {
        try await sendKey(ATVKeyCode.power)
    }

    /// Launches an app by deep link (remote.py send_launch_app_command).
    public func launchApp(link: String) async throws {
        guard isConnected, let connection else { throw ATVError.notConnected }
        try await connection.send(ATVRemoteMessage.appLinkLaunch(link: link))
    }

    /// Commits text through the IME (remote.py send_text). Only takes effect
    /// when a text field is focused on the TV: otherwise the counters this
    /// echoes were never sent and the TV drops the edit.
    public func sendText(_ text: String) async throws {
        guard isConnected, let connection else { throw ATVError.notConnected }
        guard !text.isEmpty else { throw ATVError.invalidText }
        try await connection.send(ATVRemoteMessage.imeBatchEdit(text: text,
                                                                imeCounter: imeCounter,
                                                                fieldCounter: imeFieldCounter))
    }

    // MARK: - voice

    /// Opens a voice session: sends KEYCODE_SEARCH, waits for the TV's
    /// RemoteVoiceBegin, then echoes it back (remote.py start_voice). Requires
    /// the VOICE feature to have been negotiated.
    public func beginVoice() async throws {
        guard isConnected, let connection else { throw ATVError.notConnected }
        guard activeFeatures.contains(.voice) else { throw ATVError.voiceNotEnabled }
        guard voiceSession == nil else { throw ATVError.voiceSessionActive }

        try await connection.send(ATVRemoteMessage.keyInject(keyCode: ATVKeyCode.search))
        let sessionId = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt64, Error>) in
            voiceBeginContinuation = cont
            // The TV may never answer (older devices, no mic); don't hang.
            voiceTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.voiceBeginTimeout * 1_000_000_000))
                await self?.timeOutVoiceBegin()
            }
        }
        voiceSession = sessionId
        try await connection.send(ATVRemoteMessage.voiceBegin(sessionId: sessionId))
    }

    /// Streams one PCM chunk (16-bit, mono, 8000 Hz). Under-sized chunks are
    /// zero-padded and over-sized ones split, matching send_voice_chunk — the
    /// TV drops the connection on a chunk larger than 20 KB.
    public func sendVoice(pcm: Data) async throws {
        guard isConnected, let connection else { throw ATVError.notConnected }
        guard let session = voiceSession else { throw ATVError.voiceSessionInactive }

        var chunk = pcm
        if chunk.count < ATVRemoteMessage.voiceChunkMinSize {
            chunk.append(Data(count: ATVRemoteMessage.voiceChunkMinSize - chunk.count))
        }
        var offset = 0
        while offset < chunk.count {
            let end = min(offset + ATVRemoteMessage.voiceChunkSize, chunk.count)
            let slice = chunk.subdata(in: offset ..< end)
            try await connection.send(ATVRemoteMessage.voicePayload(sessionId: session, samples: slice))
            offset = end
        }
    }

    /// Ends the voice session (remote.py end_voice). Idempotent.
    public func endVoice() async throws {
        guard let session = voiceSession else { return }
        voiceSession = nil
        guard isConnected, let connection else { return }
        try await connection.send(ATVRemoteMessage.voiceEnd(sessionId: session))
    }

    /// Connection, power, and foreground-app changes. Each call returns an
    /// independent stream, and events are not replayed, so read `isOn` /
    /// `currentApp` for the current state.
    public func events() -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    // MARK: - internals

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private func emit(_ event: Event) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func timeOutVoiceBegin() {
        guard let cont = voiceBeginContinuation else { return }
        voiceBeginContinuation = nil
        cont.resume(throwing: ATVError.voiceTimeout)
    }

    /// Answers whatever the server sent (remote.py `_handle_message`); returns
    /// RemoteStart.started when present so connect() can detect readiness.
    private func handle(_ data: Data, on connection: ATVFramedConnection) async throws -> Bool? {
        let message = try ATVRemoteMessage.parse(data)
        if let supported = message.configureFeatures {
            // Only advertise features both sides support (remote.py
            // `_active_features &= supported_features`). `activeFeatures`
            // starts as this connect's request, so a voice-less retry stays
            // voice-less here.
            activeFeatures = activeFeatures.intersection(supported)
            ATVLog.shared.log("remote", "recv RemoteConfigure code1=0x\(String(supported.rawValue, radix: 16)); send reply active=0x\(String(activeFeatures.rawValue, radix: 16))")
            try await connection.send(ATVRemoteMessage.configureReply(features: activeFeatures))
        }
        if message.hasSetActive {
            ATVLog.shared.log("remote", "recv RemoteSetActive; send active=0x\(String(activeFeatures.rawValue, radix: 16))")
            try await connection.send(ATVRemoteMessage.setActive(features: activeFeatures))
        }
        if let val1 = message.pingVal1 {
            try await connection.send(ATVRemoteMessage.pingResponse(val1: val1))
        }
        if let reported = message.currentApp {
            // "" means the foreground app went away.
            let app = reported.isEmpty ? nil : reported
            if app != currentApp {
                currentApp = app
                emit(.appChanged(app))
            }
        }
        if let counter = message.imeCounter { imeCounter = counter }
        if let fieldCounter = message.imeFieldCounter { imeFieldCounter = fieldCounter }
        if let sessionId = message.voiceBeginSessionId, let cont = voiceBeginContinuation {
            voiceBeginContinuation = nil
            voiceTimeoutTask?.cancel()
            voiceTimeoutTask = nil
            cont.resume(returning: sessionId)
        }
        if let started = message.started {
            ATVLog.shared.log("remote", "recv RemoteStart started=\(started)")
        }
        return message.started
    }

    private func runReadLoop(on connection: ATVFramedConnection) async {
        while self.connection === connection {
            do {
                let message = try await withATVDeadline(seconds: Self.idleTimeout,
                                                        onDeadline: { connection.cancel() }) {
                    try await connection.receiveMessage()
                }
                if let started = try await handle(message, on: connection), started != isOn {
                    isOn = started
                    emit(.powerChanged(started))
                }
            } catch {
                // Stale loop from a superseded connection: someone already
                // reconnected or tore down; nothing to report.
                if self.connection === connection {
                    ATVLog.shared.log("remote", "session ended: \(error)")
                    teardown(emitDisconnected: true)
                }
                return
            }
        }
    }

    private func teardown(emitDisconnected: Bool) {
        readTask?.cancel()
        readTask = nil
        connection?.cancel()
        connection = nil
        isConnected = false
        currentApp = nil
        imeCounter = 0
        imeFieldCounter = 0
        voiceSession = nil
        voiceTimeoutTask?.cancel()
        voiceTimeoutTask = nil
        if let cont = voiceBeginContinuation {
            voiceBeginContinuation = nil
            cont.resume(throwing: ATVError.connectionClosed)
        }
        if emitDisconnected { emit(.disconnected) }
    }
}
