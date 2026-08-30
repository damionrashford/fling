import XCTest
import Network
@testable import FlingKit

/// Session bring-up diagnostics and lifecycle: TLS-stage error mapping, the
/// voice-bitmask retry decision, the deadline unblock, the file logger, and
/// scripted-transport tests for reconnect/voice reentrancy.

final class AndroidTVStartFailureTests: XCTestCase {

    func test_tls_error_during_handshake_maps_to_tlsHandshakeFailed() {
        // errSSLClosedAbort (-9806): the server killed the handshake.
        let error = NWError.tls(-9806)
        guard case .tlsHandshakeFailed(let detail) = ATVFramedConnection.startFailure(error) else {
            return XCTFail("expected tlsHandshakeFailed")
        }
        // Verbatim NWError text so the OSStatus survives to the UI and log.
        XCTAssertTrue(detail.contains("9806"), detail)
    }

    func test_reset_after_tcp_maps_to_tlsHandshakeFailed() {
        // The TV accepted TCP then RST during TLS — the paired-certificate
        // rejection signature (reference maps ssl.SSLError to InvalidAuth).
        let error = NWError.posix(.ECONNRESET)
        guard case .tlsHandshakeFailed = ATVFramedConnection.startFailure(error) else {
            return XCTFail("expected tlsHandshakeFailed")
        }
    }

    func test_refused_connection_stays_connectionFailed() {
        let error = NWError.posix(.ECONNREFUSED)
        guard case .connectionFailed(let detail) = ATVFramedConnection.startFailure(error) else {
            return XCTFail("expected connectionFailed")
        }
        XCTAssertEqual(detail, String(describing: error))
    }
}

final class AndroidTVVoiceRetryTests: XCTestCase {

    func test_post_tls_close_with_voice_retries() {
        XCTAssertTrue(ATVRemoteClient.shouldRetryWithoutVoice(
            after: ATVError.connectionClosed, voiceRequested: true, tlsEstablished: true))
        XCTAssertTrue(ATVRemoteClient.shouldRetryWithoutVoice(
            after: ATVError.connectionFailed("POSIXErrorCode(rawValue: 54): Connection reset by peer"),
            voiceRequested: true, tlsEstablished: true))
    }

    func test_pre_tls_failures_never_retry_or_latch() {
        // ECONNREFUSED / host down / unreachable are not feature rejection.
        XCTAssertFalse(ATVRemoteClient.shouldRetryWithoutVoice(
            after: ATVError.connectionFailed("POSIXErrorCode(rawValue: 61): Connection refused"),
            voiceRequested: true, tlsEstablished: false))
        XCTAssertFalse(ATVRemoteClient.shouldRetryWithoutVoice(
            after: ATVError.connectionClosed, voiceRequested: true, tlsEstablished: false))
    }

    func test_without_voice_requested_never_retries() {
        XCTAssertFalse(ATVRemoteClient.shouldRetryWithoutVoice(
            after: ATVError.connectionClosed, voiceRequested: false, tlsEstablished: true))
    }

    func test_tls_stage_and_silence_are_not_the_voice_bits_doing() {
        XCTAssertFalse(ATVRemoteClient.shouldRetryWithoutVoice(
            after: ATVError.tlsHandshakeFailed("-9806"), voiceRequested: true, tlsEstablished: true))
        XCTAssertFalse(ATVRemoteClient.shouldRetryWithoutVoice(
            after: ATVError.connectionTimeout, voiceRequested: true, tlsEstablished: true))
        XCTAssertFalse(ATVRemoteClient.shouldRetryWithoutVoice(
            after: ATVError.notPaired, voiceRequested: true, tlsEstablished: true))
    }
}

final class AndroidTVDeadlineTests: XCTestCase {

    /// Hands `onDeadline` the power to resume the stuck operation, standing in
    /// for `connection.cancel()` failing a pending receive.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false

        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if opened { lock.unlock(); c.resume(); return }
                continuation = c
                lock.unlock()
            }
        }

        func open() {
            lock.lock()
            opened = true
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume()
        }
    }

    /// Regression: the group cannot drain — so the timeout could never
    /// propagate — unless onDeadline unblocks the non-cancellation-responsive
    /// operation.
    func test_deadline_fires_by_unblocking_the_stuck_operation() async {
        let gate = Gate()
        let started = Date()
        do {
            _ = try await withATVDeadline(seconds: 0.2, onDeadline: { gate.open() }) { () async throws -> Int in
                await gate.wait()
                throw ATVError.connectionClosed   // what a cancelled receive throws
            }
            XCTFail("expected connectionTimeout")
        } catch {
            XCTAssertEqual(error as? ATVError, .connectionTimeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func test_fast_operation_wins_without_onDeadline_firing() async throws {
        let gate = Gate()
        let value = try await withATVDeadline(seconds: 5, onDeadline: { gate.open() }) { 42 }
        XCTAssertEqual(value, 42)
    }
}

final class AndroidTVLogTests: XCTestCase {

    private func tempLogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fling-atvlog-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Fling.log")
    }

    func test_appends_timestamped_tagged_lines_creating_directory() throws {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let log = ATVLog(fileURL: url)
        log.log("conn", "192.168.1.64:6466 connect start")
        log.log("remote", "handshake complete active=0x267 isOn=true")

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasSuffix("[conn] 192.168.1.64:6466 connect start"), lines[0])
        XCTAssertTrue(lines[1].hasSuffix("[remote] handshake complete active=0x267 isOn=true"), lines[1])
        // ISO8601 with fractional seconds, UTC: 2026-08-29T12:34:56.789Z
        let stamp = lines[0].prefix(while: { $0 != " " })
        XCTAssertNotNil(ISO8601DateFormatter().date(from: stamp.replacingOccurrences(
            of: #"\.\d{3}"#, with: "", options: .regularExpression)), String(stamp))
        XCTAssertTrue(stamp.hasSuffix("Z"), String(stamp))
    }

    func test_logging_to_unwritable_path_is_a_noop_not_a_crash() {
        let log = ATVLog(fileURL: URL(fileURLWithPath: "/dev/null/impossible/Fling.log"))
        log.log("conn", "dropped")
        log.log("conn", "dropped again")
    }
}

// MARK: - scripted transport

/// In-memory transport: tests push server frames and inspect what the client
/// sent. Single reader, like the real connection.
final class FakeTransport: ATVTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Data] = []
    private var waiter: CheckedContinuation<Data, Error>?
    private var closed = false
    private var sent: [Data] = []

    var startError: Error?
    var startDelay: TimeInterval = 0
    /// Runs on every client send, with the sent bytes and this transport.
    var onSend: (@Sendable (Data, FakeTransport) -> Void)?

    func start() async throws {
        if startDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(startDelay * 1_000_000_000)) }
        if let startError { throw startError }
    }

    func send(_ message: Data) async throws {
        lock.lock()
        sent.append(message)
        let callback = onSend
        lock.unlock()
        callback?(message, self)
    }

    func receiveMessage() async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if !pending.isEmpty {
                let next = pending.removeFirst()
                lock.unlock()
                cont.resume(returning: next)
                return
            }
            if closed {
                lock.unlock()
                cont.resume(throwing: ATVError.connectionClosed)
                return
            }
            waiter = cont
            lock.unlock()
        }
    }

    func push(_ message: Data) {
        lock.lock()
        if let cont = waiter {
            waiter = nil
            lock.unlock()
            cont.resume(returning: message)
            return
        }
        pending.append(message)
        lock.unlock()
    }

    /// Buffered frames still drain before the close is seen, like TCP.
    func close() {
        lock.lock()
        closed = true
        let cont = waiter
        waiter = nil
        lock.unlock()
        cont?.resume(throwing: ATVError.connectionClosed)
    }

    func cancel() { close() }

    var sentMessages: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }
}

/// Server-side frames, built with the same writer the goldens verify.
private enum ServerFrames {
    static func configure(code1: UInt64) -> Data {
        var w = ProtoWriter()
        w.message(1) { c in c.varint(1, code1) }
        return w.data
    }
    static let setActive = ATVTestHex.data("1200")
    static let startOn = ATVTestHex.data("c202020801")
    static func voiceBegin(sessionId: UInt64) -> Data {
        var w = ProtoWriter()
        w.message(30) { v in v.varint(1, sessionId) }
        return w.data
    }
    static func fullHandshake(into transport: FakeTransport, code1: UInt64 = 0x26F) {
        transport.push(configure(code1: code1))
        transport.push(setActive)
        transport.push(startOn)
    }
}

private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [ATVRemoteClient.Event] = []
    func append(_ event: ATVRemoteClient.Event) {
        lock.lock()
        collected.append(event)
        lock.unlock()
    }
    var events: [ATVRemoteClient.Event] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}

private func collectEvents(of client: ATVRemoteClient) async -> EventCollector {
    let collector = EventCollector()
    let stream = await client.events()
    Task { for await event in stream { collector.append(event) } }
    return collector
}

private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async -> Bool {
    let started = Date()
    while Date().timeIntervalSince(started) < timeout {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

/// Counts transports handed out and remembers them per call.
private final class TransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var built: [(host: String, transport: FakeTransport)] = []
    private let configure: @Sendable (FakeTransport, String) -> Void

    init(configure: @escaping @Sendable (FakeTransport, String) -> Void) {
        self.configure = configure
    }

    func make(host: String, port: UInt16) -> FakeTransport {
        let transport = FakeTransport()
        configure(transport, host)
        lock.lock()
        built.append((host, transport))
        lock.unlock()
        return transport
    }

    var transports: [(host: String, transport: FakeTransport)] {
        lock.lock()
        defer { lock.unlock() }
        return built
    }
}

// MARK: - session lifecycle tests

final class AndroidTVSessionLifecycleTests: XCTestCase {

    func test_handshake_completes_and_records_connected_host() async throws {
        let factory = TransportFactory { transport, _ in
            ServerFrames.fullHandshake(into: transport)
        }
        let client = ATVRemoteClient(transportFactory: { factory.make(host: $0, port: $1) })
        try await client.connect(host: "hostA")

        let isConnected = await client.isConnected
        let connectedHost = await client.connectedHost
        let isOn = await client.isOn
        XCTAssertTrue(isConnected)
        XCTAssertEqual(connectedHost, "hostA")
        XCTAssertTrue(isOn)
        // Negotiation without voice: 0x26F ∩ 615 = 615.
        let sent = factory.transports[0].transport.sentMessages
        XCTAssertEqual(sent.first, ATVRemoteMessage.configureReply(features: .init(rawValue: 615)))
        XCTAssertEqual(sent.dropFirst().first, ATVRemoteMessage.setActive(features: .init(rawValue: 615)))
    }

    /// Fix 1: a post-TLS close with VOICE requested retries once without the
    /// bit and latches — precisely, not for reachability failures.
    func test_post_tls_close_latches_voice_off_and_retries() async throws {
        let counter = TransportFactory { transport, _ in
            transport.push(ServerFrames.configure(code1: 0x26F))
        }
        var attempt = 0
        let lock = NSLock()
        let client = ATVRemoteClient(enableVoice: true, transportFactory: { host, port in
            lock.lock()
            attempt += 1
            let current = attempt
            lock.unlock()
            let transport = counter.make(host: host, port: port)
            if current == 1 {
                transport.close()   // configure delivered, then TV drops us
            } else {
                transport.push(ServerFrames.setActive)
                transport.push(ServerFrames.startOn)
            }
            return transport
        })
        try await client.connect(host: "hostA")

        let transports = counter.transports
        XCTAssertEqual(transports.count, 2)
        // Attempt 1 echoed voice (TV advertised it: 0x26F ∩ 623 = 623)…
        XCTAssertEqual(transports[0].transport.sentMessages.first,
                       ATVRemoteMessage.configureReply(features: .init(rawValue: 623)))
        // …attempt 2 is the reference's field-tested voice-off bytes.
        XCTAssertEqual(transports[1].transport.sentMessages.first,
                       ATVRemoteMessage.configureReply(features: .init(rawValue: 615)))
        let isConnected = await client.isConnected
        XCTAssertTrue(isConnected)
    }

    /// Fix 1: pre-TLS failure (TV off, refused) must not retry or latch.
    func test_pre_tls_failure_does_not_latch_voice() async throws {
        var attempt = 0
        let lock = NSLock()
        let factory = TransportFactory { transport, _ in
            ServerFrames.fullHandshake(into: transport)
        }
        let client = ATVRemoteClient(enableVoice: true, transportFactory: { host, port in
            lock.lock()
            attempt += 1
            let current = attempt
            lock.unlock()
            let transport = factory.make(host: host, port: port)
            if current == 1 { transport.startError = ATVError.connectionFailed("refused") }
            return transport
        })

        do {
            try await client.connect(host: "hostA")
            XCTFail("expected connectionFailed")
        } catch {
            XCTAssertEqual(error as? ATVError, .connectionFailed("refused"))
        }
        XCTAssertEqual(factory.transports.count, 1, "pre-TLS failure must not trigger the voice retry")

        // Next connect still asks for voice: nothing was latched.
        try await client.connect(host: "hostA")
        XCTAssertEqual(factory.transports[1].transport.sentMessages.first,
                       ATVRemoteMessage.configureReply(features: .init(rawValue: 623)))
    }

    /// Fix 4: replacing a live session with a failing connect must surface
    /// exactly one .disconnected.
    func test_reconnect_failure_emits_exactly_one_disconnected() async throws {
        var attempt = 0
        let lock = NSLock()
        let factory = TransportFactory { transport, _ in transport }
        let client = ATVRemoteClient(transportFactory: { host, port in
            lock.lock()
            attempt += 1
            let current = attempt
            lock.unlock()
            let transport = factory.make(host: host, port: port)
            if current == 1 {
                ServerFrames.fullHandshake(into: transport)
            } else {
                transport.startError = ATVError.connectionFailed("refused")
            }
            return transport
        })

        let events = await collectEvents(of: client)
        try await client.connect(host: "hostA")
        let sawConnected = await waitUntil { events.events.contains(.connected) }
        XCTAssertTrue(sawConnected)

        do {
            try await client.connect(host: "hostA")
            XCTFail("expected failure")
        } catch {}

        let sawDisconnected = await waitUntil { events.events.contains(.disconnected) }
        XCTAssertTrue(sawDisconnected, "subscribers never learned the old session died")
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(events.events.filter { $0 == .disconnected }.count, 1)
        let isConnected = await client.isConnected
        XCTAssertFalse(isConnected)
    }
}

// MARK: - voice reentrancy and ordering

final class AndroidTVVoiceSessionTests: XCTestCase {

    private func connectedVoiceClient(_ factory: TransportFactory) async throws -> ATVRemoteClient {
        let client = ATVRemoteClient(enableVoice: true,
                                     transportFactory: { factory.make(host: $0, port: $1) })
        try await client.connect(host: "hostA")
        return client
    }

    /// Fix 5b: the TV answering KEYCODE_SEARCH instantly must find the
    /// continuation already registered.
    func test_instant_voice_begin_answer_is_not_dropped() async throws {
        let searchKey = ATVRemoteMessage.keyInject(keyCode: ATVKeyCode.search)
        let factory = TransportFactory { transport, _ in
            ServerFrames.fullHandshake(into: transport)
            transport.onSend = { message, transport in
                if message == searchKey { transport.push(ServerFrames.voiceBegin(sessionId: 7)) }
            }
        }
        let client = try await connectedVoiceClient(factory)

        let started = Date()
        try await client.beginVoice()
        // Well under the 2s voiceTimeout: the answer was caught, not dropped.
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        // The client echoes RemoteVoiceBegin back (remote.py start_voice).
        let sent = factory.transports[0].transport.sentMessages
        XCTAssertTrue(sent.contains(ATVRemoteMessage.voiceBegin(sessionId: 7)))
    }

    /// Fix 5a: a second beginVoice while the first awaits the TV must throw,
    /// not overwrite (and leak) the first continuation.
    func test_concurrent_beginVoice_throws_instead_of_leaking_the_first() async throws {
        let factory = TransportFactory { transport, _ in
            ServerFrames.fullHandshake(into: transport)
            // No auto-answer: the first beginVoice parks awaiting the TV.
        }
        let client = try await connectedVoiceClient(factory)

        let first = Task { try await client.beginVoice() }
        try? await Task.sleep(nanoseconds: 100_000_000)   // let it park

        do {
            try await client.beginVoice()
            XCTFail("expected voiceSessionActive")
        } catch {
            XCTAssertEqual(error as? ATVError, .voiceSessionActive)
        }

        // The parked first call still completes when the TV answers.
        factory.transports[0].transport.push(ServerFrames.voiceBegin(sessionId: 9))
        try await first.value
        let sent = factory.transports[0].transport.sentMessages
        XCTAssertTrue(sent.contains(ATVRemoteMessage.voiceBegin(sessionId: 9)))
    }
}

// MARK: - facade single-flight and host switching

final class AndroidTVFacadeTests: XCTestCase {

    /// A store whose pairing records are real files but whose identity is
    /// never loaded (the transport factory bypasses TLS).
    private func pairedStore(hosts: [String]) throws -> (ATVCertificateStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fling-atv-facade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("atv-identity.p12"))
        try Data().write(to: dir.appendingPathComponent("atv-client-cert.der"))
        let store = ATVCertificateStore(directory: dir)
        for host in hosts { store.recordPairedHost(host) }
        return (store, dir)
    }

    /// Fix 2: overlapping facade connects share one attempt instead of the
    /// second teardown killing the first's fresh session.
    func test_overlapping_connects_share_a_single_attempt() async throws {
        let (store, dir) = try pairedStore(hosts: ["hostA"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let factory = TransportFactory { transport, _ in
            transport.startDelay = 0.15   // keep the first connect in flight
            ServerFrames.fullHandshake(into: transport)
        }
        let remote = ATVRemoteClient(store: store,
                                     transportFactory: { factory.make(host: $0, port: $1) })
        let facade = AndroidTVRemote(store: store, remote: remote)

        async let first: Void = facade.connect(host: "hostA")
        async let second: Void = facade.connect(host: "hostA")
        _ = try await (first, second)

        XCTAssertEqual(factory.transports.count, 1,
                       "the second caller must join the in-flight connect")
        let isConnected = await remote.isConnected
        XCTAssertTrue(isConnected)
    }

    /// Fix 3: a command aimed at a different paired TV must reconnect there,
    /// not steer the currently connected one.
    func test_host_switch_reconnects_to_the_requested_tv() async throws {
        let (store, dir) = try pairedStore(hosts: ["hostA", "hostB"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let factory = TransportFactory { transport, _ in
            ServerFrames.fullHandshake(into: transport)
        }
        let remote = ATVRemoteClient(store: store,
                                     transportFactory: { factory.make(host: $0, port: $1) })
        let facade = AndroidTVRemote(store: store, remote: remote)

        try await facade.connect(host: "hostA")
        try await facade.pressKey(ATVKeyCode.dpadUp, host: "hostB")

        let transports = factory.transports
        XCTAssertEqual(transports.map(\.host), ["hostA", "hostB"])
        let key = ATVRemoteMessage.keyInject(keyCode: ATVKeyCode.dpadUp)
        XCTAssertTrue(transports[1].transport.sentMessages.contains(key),
                      "the key must land on the hostB session")
        XCTAssertFalse(transports[0].transport.sentMessages.contains(key),
                       "the key must not go to the old hostA session")
        let connectedHost = await remote.connectedHost
        XCTAssertEqual(connectedHost, "hostB")
    }

    /// Same-host repeat commands reuse the live session (no reconnect storm).
    func test_same_host_command_reuses_the_session() async throws {
        let (store, dir) = try pairedStore(hosts: ["hostA"])
        defer { try? FileManager.default.removeItem(at: dir) }

        let factory = TransportFactory { transport, _ in
            ServerFrames.fullHandshake(into: transport)
        }
        let remote = ATVRemoteClient(store: store,
                                     transportFactory: { factory.make(host: $0, port: $1) })
        let facade = AndroidTVRemote(store: store, remote: remote)

        try await facade.pressKey(ATVKeyCode.dpadUp, host: "hostA")
        try await facade.pressKey(ATVKeyCode.dpadDown, host: "hostA")
        XCTAssertEqual(factory.transports.count, 1)
    }
}
