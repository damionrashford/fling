import Foundation

/// Errors surfaced by the Android TV remote subsystem. String payloads keep the
/// enum Equatable so UI code can match on cases.
public enum ATVError: Error, Equatable {
    case connectionFailed(String)
    /// The server aborted the TLS handshake itself (alert, or reset right
    /// after TCP came up). On port 6466 this is the signature of the TV no
    /// longer trusting the client certificate — the fix is re-pairing, not
    /// retrying. Payload is the verbatim NWError text.
    case tlsHandshakeFailed(String)
    case connectionClosed
    case connectionTimeout
    case notConnected
    case pairingNotStarted
    /// Pairing status other than STATUS_OK — 402 is a rejected secret.
    case serverStatus(UInt64)
    case unexpectedMessage
    case invalidPIN(String)
    case certificateFailure(String)
    case noHostConfigured
    case notPaired
    case invalidText
    /// Voice was not negotiated — construct the facade with `enableVoice: true`.
    case voiceNotEnabled
    case voiceSessionActive
    case voiceSessionInactive
    /// The TV never answered KEYCODE_SEARCH with RemoteVoiceBegin.
    case voiceTimeout
}

/// App-facing facade over the Android TV Remote protocol v2 client: one-time
/// pairing on port 6467, then the power/key session on port 6466. Call order
/// is `hasPairing`, `startPairing`, `finishPairing`, then any session method.
public actor AndroidTVRemote {

    public let store: ATVCertificateStore
    private let clientName: String
    private let remote: ATVRemoteClient
    private var pairing: ATVPairingClient?
    private var pairingHost: String?
    private var lastHost: String?
    /// Single in-flight connect, joined by overlapping callers so a second
    /// connect can't tear down the first one's fresh session.
    private var inflightConnect: (id: UUID, host: String, task: Task<Void, Error>)?

    /// `enableVoice` negotiates the VOICE feature so `beginVoice`/`sendVoice`
    /// work. Off by default: once negotiated, KEYCODE_SEARCH puts the TV into
    /// mic-listening mode instead of opening typed search.
    public init(clientName: String = "Fling",
                store: ATVCertificateStore = .shared,
                enableVoice: Bool = false) {
        self.init(clientName: clientName, store: store,
                  remote: ATVRemoteClient(store: store, enableVoice: enableVoice))
    }

    /// Test seam: a remote with an injected transport.
    init(clientName: String = "Fling",
         store: ATVCertificateStore = .shared,
         remote: ATVRemoteClient) {
        self.clientName = clientName
        self.store = store
        self.remote = remote
    }

    // MARK: - pairing

    /// Client-side record only: the identity exists and this host acked the
    /// secret once. The TV clearing its side surfaces as a TLS failure on
    /// `connect`, which is the signal to re-pair.
    public nonisolated func hasPairing(host: String) -> Bool {
        store.identityExists && store.pairedHosts().contains(host)
    }

    /// When this returns, the TV is displaying a 6-hex-character PIN.
    public func startPairing(host: String) async throws {
        await pairing?.cancel()
        let client = ATVPairingClient(clientName: clientName, store: store)
        pairing = client
        pairingHost = host
        try await client.start(host: host)
    }

    public func finishPairing(pin: String) async throws {
        guard let pairing, let pairingHost else { throw ATVError.pairingNotStarted }
        try await pairing.finish(pin: pin)
        store.recordPairedHost(pairingHost)
        self.pairing = nil
        self.pairingHost = nil
    }

    public func cancelPairing() async {
        await pairing?.cancel()
        pairing = nil
        pairingHost = nil
    }

    // MARK: - remote session

    public func connect(host: String) async throws {
        guard hasPairing(host: host) else { throw ATVError.notPaired }
        lastHost = host
        if let inflight = inflightConnect, inflight.host == host {
            return try await inflight.task.value
        }
        if let inflight = inflightConnect {
            // A connect to a different host is settling; let it finish so two
            // teardowns can't interleave. Its outcome is that caller's to
            // handle, not ours.
            _ = try? await inflight.task.value
        }
        let id = UUID()
        let task = Task { [remote] in try await remote.connect(host: host) }
        inflightConnect = (id, host, task)
        // Identity-checked: while this call awaited, a joiner may have
        // resumed first and a later call registered its own attempt.
        defer { if inflightConnect?.id == id { inflightConnect = nil } }
        try await task.value
    }

    /// Power state from the TV's last RemoteStart; meaningful once connected.
    public var isOn: Bool {
        get async { await remote.isOn }
    }

    /// Toggles power, connecting first if needed. Pass `host` on the first call;
    /// later calls fall back to the last host used.
    public func togglePower(host: String? = nil) async throws {
        try await ensureConnected(host: host)
        try await remote.powerToggle()
    }

    /// Sends any keycode (see `ATVKeyCode`), connecting on demand.
    public func pressKey(_ code: Int32, host: String? = nil) async throws {
        try await ensureConnected(host: host)
        try await remote.sendKey(code)
    }

    /// Launches an app, connecting on demand. A bare app id (no URL scheme)
    /// becomes a `market://launch?id=…` link.
    public func launchApp(link: String, host: String? = nil) async throws {
        try await ensureConnected(host: host)
        try await remote.launchApp(link: Self.normalizeAppLink(link))
    }

    /// Commits text via the IME, connecting on demand. Only lands when a text
    /// field is focused on the TV.
    public func sendText(_ text: String, host: String? = nil) async throws {
        try await ensureConnected(host: host)
        try await remote.sendText(text)
    }

    // MARK: - voice

    /// Opens a voice session (KEYCODE_SEARCH → RemoteVoiceBegin handshake).
    /// Requires the facade to have been constructed with `enableVoice: true`.
    public func beginVoice(host: String? = nil) async throws {
        try await ensureConnected(host: host)
        try await remote.beginVoice()
    }

    /// Streams one PCM chunk: 16-bit little-endian, mono, 8000 Hz. Chunks under
    /// 8 KB are zero-padded; over 20 KB are split.
    public func sendVoice(pcm: Data) async throws {
        try await remote.sendVoice(pcm: pcm)
    }

    public func endVoice() async throws {
        try await remote.endVoice()
    }

    /// Connection, power, and foreground-app events from the remote session.
    public func events() async -> AsyncStream<ATVRemoteClient.Event> {
        await remote.events()
    }

    // MARK: - plumbing

    /// Connects when disconnected — and also when connected to a *different*
    /// TV than requested, since sending there would steer the wrong device.
    private func ensureConnected(host: String?) async throws {
        if let host { lastHost = host }
        guard let target = lastHost else { throw ATVError.noHostConfigured }
        if await remote.isConnected, await remote.connectedHost == target { return }
        try await connect(host: target)
    }

    /// androidtv_remote.py send_launch_app_command: a value without a URL scheme
    /// is a Play Store package id.
    static func normalizeAppLink(_ link: String) -> String {
        hasURLScheme(link) ? link : "market://launch?id=\(link)"
    }

    private static func hasURLScheme(_ link: String) -> Bool {
        guard let range = link.range(of: "://") else { return false }
        let scheme = link[link.startIndex ..< range.lowerBound]
        return !scheme.isEmpty && scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
    }
}
