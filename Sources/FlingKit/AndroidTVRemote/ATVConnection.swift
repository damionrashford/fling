import Foundation
import Network
import Security

/// Message-transport seam so session logic (handshake, reconnect, voice) is
/// testable against a scripted fake; `ATVFramedConnection` is the production
/// conformer. `AnyObject` because supersession checks use identity.
protocol ATVTransporting: AnyObject, Sendable {
    func start() async throws
    func send(_ message: Data) async throws
    func receiveMessage() async throws -> Data
    func cancel()
}

/// TLS transport carrying varint-length-framed protobuf messages — the wire
/// format both TV ports share (androidtvremote2 base.py).
///
/// `@unchecked Sendable`: all mutable state is guarded by `lock`; Network
/// callbacks arrive on a private queue while callers await on continuations.
final class ATVFramedConnection: @unchecked Sendable {

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "fling.atv.connection")
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var timedOut = false
    /// "host:port", for log lines.
    private let endpoint: String

    /// The TV's self-signed certificate, captured during the TLS handshake.
    /// The pairing secret is computed over its RSA public numbers.
    var serverCertificateDER: Data? { capture.der }

    init(host: String, port: UInt16, identity: SecIdentity) {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        if let secIdentity = sec_identity_create(identity) {
            sec_protocol_options_set_local_identity(security, secIdentity)
        }

        let capture = CertificateCapture()
        // The TV's certificate is self-signed, so system trust evaluation would
        // always fail; the protocol's trust model is the pairing secret. Accept
        // the cert and keep its DER for that computation.
        sec_protocol_options_set_verify_block(security, { _, secTrust, complete in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
               let leaf = chain.first {
                capture.der = SecCertificateCopyData(leaf) as Data
            }
            complete(true)
        }, queue)

        connection = NWConnection(host: NWEndpoint.Host(host),
                                  port: NWEndpoint.Port(rawValue: port)!,
                                  using: NWParameters(tls: tls))
        self.capture = capture
        self.endpoint = "\(host):\(port)"
    }

    /// Bridges the verify block (set up before `self` is fully initialized) to
    /// the instance.
    private final class CertificateCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var _der: Data?
        var der: Data? {
            get { lock.lock(); defer { lock.unlock() }; return _der }
            set { lock.lock(); defer { lock.unlock() }; _der = newValue }
        }
    }
    private let capture: CertificateCapture

    func start(timeout: TimeInterval = 15) async throws {
        ATVLog.shared.log("conn", "\(endpoint) connect start")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            startContinuation = continuation
            lock.unlock()

            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    ATVLog.shared.log("conn", "\(self.endpoint) tls established")
                    self.resumeStart(.success(()))
                case .failed(let error):
                    // Before `.ready` the failure happened inside the TLS
                    // handshake, which the reference treats as "the TV no
                    // longer trusts this certificate" (androidtv_remote.py
                    // maps ssl.SSLError to InvalidAuth). Keep that distinct
                    // from a mid-session drop so the app can suggest
                    // re-pairing.
                    let stage = self.startPending ? "handshake" : "session"
                    ATVLog.shared.log("conn", "\(self.endpoint) \(stage) failed: \(error)")
                    self.resumeStart(.failure(Self.startFailure(error)))
                    self.connection.cancel()
                case .cancelled:
                    self.lock.lock()
                    let timedOut = self.timedOut
                    self.lock.unlock()
                    self.resumeStart(.failure(timedOut ? ATVError.connectionTimeout
                                                       : ATVError.connectionClosed))
                default:
                    break
                }
            }
            // NWConnection's own TCP timeout runs over a minute; a menu-bar
            // button must give up sooner.
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let stillWaiting = self.startContinuation != nil
                if stillWaiting { self.timedOut = true }
                self.lock.unlock()
                if stillWaiting { self.connection.cancel() }
            }
            connection.start(queue: queue)
        }
    }

    private var startPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return startContinuation != nil
    }

    /// Failures while `start()` is still pending happened during the TLS
    /// handshake. A TLS alert or a reset after TCP came up means the server
    /// aborted the handshake — the paired-certificate rejection signature —
    /// mapped distinctly; anything else (routing, refusal) stays
    /// `connectionFailed`. `String(describing:)` keeps the NWError domain and
    /// code verbatim for the log and the UI.
    static func startFailure(_ error: NWError) -> ATVError {
        let text = String(describing: error)
        switch error {
        case .tls:
            return .tlsHandshakeFailed(text)
        case .posix(let code) where code == .ECONNRESET || code == .EPIPE:
            return .tlsHandshakeFailed(text)
        default:
            return .connectionFailed(text)
        }
    }

    private func resumeStart(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = startContinuation
        startContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func send(_ message: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: ProtoFrame.encode(message),
                            completion: .contentProcessed { [endpoint] error in
                if let error {
                    ATVLog.shared.log("conn", "\(endpoint) send failed: \(error)")
                    continuation.resume(throwing: ATVError.connectionFailed(String(describing: error)))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Returns the next complete protobuf message. Single reader only: both
    /// protocols are strictly message-at-a-time on one loop.
    func receiveMessage() async throws -> Data {
        while true {
            if let frame = try nextBufferedFrame() { return frame }
            let chunk = try await receiveChunk()
            appendToBuffer(chunk)
        }
    }

    private func nextBufferedFrame() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return try ProtoFrame.next(in: &buffer)
    }

    private func appendToBuffer(_ chunk: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(contentsOf: chunk)
    }

    private func receiveChunk() async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [endpoint] data, _, isComplete, error in
                if let error {
                    ATVLog.shared.log("conn", "\(endpoint) receive failed: \(error)")
                    continuation.resume(throwing: ATVError.connectionFailed(String(describing: error)))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: [UInt8](data))
                } else if isComplete {
                    ATVLog.shared.log("conn", "\(endpoint) closed by peer")
                    continuation.resume(throwing: ATVError.connectionClosed)
                } else {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    func cancel() {
        ATVLog.shared.log("conn", "\(endpoint) cancel")
        connection.cancel()
    }
}

extension ATVFramedConnection: ATVTransporting {
    /// Default-argument methods don't witness protocol requirements.
    func start() async throws {
        try await start(timeout: 15)
    }
}

/// Races `operation` against a wall clock. The operation is not
/// cancellation-responsive, so the task group cannot drain — and therefore
/// cannot propagate the timeout — until `onDeadline` unblocks it by cancelling
/// the underlying connection. Without that hook the deadline never actually
/// fired: the group sat on the stuck receive until the OS TCP timeout.
/// Set-once flag shared between the timer child and the awaiting parent.
private final class ATVDeadlineFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

func withATVDeadline<T: Sendable>(seconds: TimeInterval,
                                  onDeadline: (@Sendable () -> Void)? = nil,
                                  _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let expired = ATVDeadlineFlag()
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            expired.set()
            onDeadline?()
            throw ATVError.connectionTimeout
        }
        defer { group.cancelAll() }
        do {
            return try await group.next()!
        } catch {
            // After the deadline fires, the unblocked operation's own error
            // races the timer's; report the timeout either way.
            throw expired.isSet ? ATVError.connectionTimeout : error
        }
    }
}
