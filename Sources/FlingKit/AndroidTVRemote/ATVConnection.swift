import Foundation
import Network
import Security

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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            startContinuation = continuation
            lock.unlock()

            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.resumeStart(.success(()))
                case .failed(let error):
                    self.resumeStart(.failure(ATVError.connectionFailed(error.localizedDescription)))
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
                            completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: ATVError.connectionFailed(error.localizedDescription))
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
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: ATVError.connectionFailed(error.localizedDescription))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: [UInt8](data))
                } else if isComplete {
                    continuation.resume(throwing: ATVError.connectionClosed)
                } else {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    func cancel() {
        connection.cancel()
    }
}

/// Races `operation` against a wall clock. The operation is not
/// cancellation-responsive, so callers must cancel the underlying connection
/// when this throws `.connectionTimeout` to unblock the losing task.
func withATVDeadline<T: Sendable>(seconds: TimeInterval,
                                  _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ATVError.connectionTimeout
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
