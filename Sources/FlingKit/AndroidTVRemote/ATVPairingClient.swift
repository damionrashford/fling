import Foundation

/// Drives the one-time pairing handshake on port 6467 (polo.proto), ported
/// from androidtvremote2 pairing.py.
///
/// Call order: `start(host:)` — when it returns, the TV is showing a 6-hex-char
/// PIN — then `finish(pin:)` with what the user read off the screen. The same
/// instance must handle both calls: the secret is computed over the server
/// certificate captured during `start`'s TLS handshake.
public actor ATVPairingClient {

    private let store: ATVCertificateStore
    private let clientName: String
    private var connection: ATVFramedConnection?

    public init(clientName: String = "Fling", store: ATVCertificateStore = .shared) {
        self.clientName = clientName
        self.store = store
    }

    /// Connects and walks the handshake up to ConfigurationAck, at which point
    /// the TV displays the PIN.
    public func start(host: String, port: UInt16 = 6467) async throws {
        cancel()
        let identity = try store.loadIdentity()
        let connection = ATVFramedConnection(host: host, port: port, identity: identity)
        self.connection = connection
        do {
            try await connection.start()

            try await connection.send(ATVPairingMessage.pairingRequest(clientName: clientName))
            let ack = try await receive(on: connection)
            guard ack.hasPairingRequestAck else { throw ATVError.unexpectedMessage }

            try await connection.send(ATVPairingMessage.options())
            let options = try await receive(on: connection)
            guard options.hasOptions else { throw ATVError.unexpectedMessage }

            try await connection.send(ATVPairingMessage.configuration())
            let configurationAck = try await receive(on: connection)
            guard configurationAck.hasConfigurationAck else { throw ATVError.unexpectedMessage }
        } catch {
            cancel()
            throw error
        }
    }

    /// Sends the secret derived from the on-screen PIN. On SecretAck the TV has
    /// stored our certificate and port 6466 will accept it from now on.
    public func finish(pin: String) async throws {
        guard let connection else { throw ATVError.pairingNotStarted }
        do {
            let client = try store.clientPublicNumbers()
            guard let serverDER = connection.serverCertificateDER else {
                throw ATVError.certificateFailure("no server certificate captured")
            }
            let server = try ATVCertificateStore.publicNumbers(fromCertificateDER: serverDER)
            let secret = try ATVPairingSecret.compute(client: client, server: server, pin: pin)

            try await connection.send(ATVPairingMessage.secret(secret))
            let ack = try await receive(on: connection)
            guard ack.hasSecretAck else { throw ATVError.unexpectedMessage }
        } catch {
            cancel()
            throw error
        }
        cancel()
    }

    public func cancel() {
        connection?.cancel()
        connection = nil
    }

    /// Any non-OK status is terminal — the reference closes the connection on
    /// it (e.g. STATUS_BAD_SECRET 402 for a wrong PIN).
    private func receive(on connection: ATVFramedConnection) async throws -> ATVPairingMessage.Inbound {
        let message = try await withATVDeadline(seconds: 30) {
            try await connection.receiveMessage()
        }
        let inbound = try ATVPairingMessage.parse(message)
        guard inbound.status == ATVPairingMessage.statusOK else {
            throw ATVError.serverStatus(inbound.status)
        }
        return inbound
    }
}
