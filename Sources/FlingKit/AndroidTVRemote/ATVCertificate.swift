import Foundation
import CryptoKit
import Security

/// An RSA public key as the pairing-secret hash wants it: big-endian magnitude
/// bytes with leading zeros stripped (pairing.py hashes `bytes.fromhex(f"{n:X}")`).
public struct ATVRSAPublicNumbers: Equatable, Sendable {
    public let modulus: Data
    public let exponent: Data

    public init(modulus: Data, exponent: Data) {
        self.modulus = Self.minimalMagnitude(modulus)
        self.exponent = Self.minimalMagnitude(exponent)
    }

    /// DER INTEGERs carry a 0x00 sign pad when the top bit is set; the pairing
    /// hash covers only the magnitude, so the pad must go.
    static func minimalMagnitude(_ data: Data) -> Data {
        var bytes = data
        while bytes.count > 1, bytes.first == 0 { bytes.removeFirst() }
        return bytes
    }
}

/// One client identity for all Android TVs: a self-signed RSA-2048 certificate
/// kept as a PKCS#12 under Application Support. Generation shells out to
/// LibreSSL, whose pkcs12 default ciphers are what SecPKCS12Import accepts.
public final class ATVCertificateStore: @unchecked Sendable {

    public static let defaultDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Fling", isDirectory: true)

    public static let shared = ATVCertificateStore()

    private let directory: URL
    private let clientName: String
    private let opensslPath: String
    private let runner: ProcessRunning
    private let lock = NSLock()
    private var cachedIdentity: SecIdentity?

    /// Local-only transport protection for the .p12 file; the pairing trust
    /// model is the certificate itself, not this passphrase.
    private static let passphrase = "fling-atv-remote"
    private static let keychainLabel = "Fling Android TV Remote"

    public init(directory: URL = ATVCertificateStore.defaultDirectory,
                clientName: String = "Fling",
                opensslPath: String = "/usr/bin/openssl",
                runner: ProcessRunning = SystemProcessRunner()) {
        self.directory = directory
        self.clientName = clientName
        self.opensslPath = opensslPath
        self.runner = runner
    }

    private var identityURL: URL { directory.appendingPathComponent("atv-identity.p12") }
    private var certificateURL: URL { directory.appendingPathComponent("atv-client-cert.der") }
    private var pairedHostsURL: URL { directory.appendingPathComponent("atv-paired-hosts.json") }

    public var identityExists: Bool {
        FileManager.default.fileExists(atPath: identityURL.path)
            && FileManager.default.fileExists(atPath: certificateURL.path)
    }

    // MARK: - identity

    /// Loads the client identity, generating a fresh certificate on first use.
    public func loadIdentity() throws -> SecIdentity {
        lock.lock()
        defer { lock.unlock() }
        if let cachedIdentity { return cachedIdentity }
        if !identityExists { try generateIdentityFiles() }
        let p12 = try Data(contentsOf: identityURL)
        let identity = try importIdentity(from: p12)
        cachedIdentity = identity
        return identity
    }

    /// The client cert's RSA numbers, needed for the pairing-secret hash. Read
    /// from the DER kept next to the .p12, avoiding a keychain round-trip.
    public func clientPublicNumbers() throws -> ATVRSAPublicNumbers {
        let der = try Data(contentsOf: certificateURL)
        return try Self.publicNumbers(fromCertificateDER: der)
    }

    /// Extracts RSA modulus + exponent from any DER certificate — used on the
    /// server cert captured during the pairing TLS handshake.
    public static func publicNumbers(fromCertificateDER der: Data) throws -> ATVRSAPublicNumbers {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw ATVError.certificateFailure("not a DER certificate")
        }
        guard let key = SecCertificateCopyKey(certificate) else {
            throw ATVError.certificateFailure("certificate has no readable public key")
        }
        if let attributes = SecKeyCopyAttributes(key) as? [String: Any],
           let type = attributes[kSecAttrKeyType as String] as? String,
           type != (kSecAttrKeyTypeRSA as String) {
            // The pairing secret is defined over RSA numbers, so a non-RSA
            // server cert cannot be paired with.
            throw ATVError.certificateFailure("certificate key is not RSA")
        }
        var error: Unmanaged<CFError>?
        guard let external = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw ATVError.certificateFailure("could not export public key")
        }
        // RSA public SecKeys export as PKCS#1 RSAPublicKey.
        return try parsePKCS1RSAPublicKey([UInt8](external))
    }

    /// PKCS#1 RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }
    static func parsePKCS1RSAPublicKey(_ der: [UInt8]) throws -> ATVRSAPublicNumbers {
        var index = 0

        func readLength() throws -> Int {
            guard index < der.count else { throw ATVError.certificateFailure("truncated DER") }
            let first = der[index]
            index += 1
            if first < 0x80 { return Int(first) }
            let byteCount = Int(first & 0x7F)
            guard byteCount > 0, byteCount <= 4, index + byteCount <= der.count else {
                throw ATVError.certificateFailure("bad DER length")
            }
            var length = 0
            for _ in 0..<byteCount {
                length = length << 8 | Int(der[index])
                index += 1
            }
            return length
        }

        func expect(tag: UInt8) throws {
            guard index < der.count, der[index] == tag else {
                throw ATVError.certificateFailure("unexpected DER tag")
            }
            index += 1
        }

        func readInteger() throws -> Data {
            try expect(tag: 0x02)
            let length = try readLength()
            guard length > 0, index + length <= der.count else {
                throw ATVError.certificateFailure("truncated DER integer")
            }
            let value = Data(der[index ..< index + length])
            index += length
            return value
        }

        try expect(tag: 0x30)
        _ = try readLength()
        let modulus = try readInteger()
        let exponent = try readInteger()
        return ATVRSAPublicNumbers(modulus: modulus, exponent: exponent)
    }

    // MARK: - paired hosts

    /// Client-side mirror of the TV remembering the client certificate, so the
    /// UI can offer "pair" or "power" without probing the network.
    public func pairedHosts() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: pairedHostsURL),
              let hosts = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return hosts
    }

    public func recordPairedHost(_ host: String) {
        mutatePairedHosts { hosts in
            if !hosts.contains(host) { hosts.append(host) }
        }
    }

    public func removePairedHost(_ host: String) {
        mutatePairedHosts { hosts in
            hosts.removeAll { $0 == host }
        }
    }

    private func mutatePairedHosts(_ mutate: (inout [String]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var hosts: [String] = []
        if let data = try? Data(contentsOf: pairedHostsURL),
           let existing = try? JSONDecoder().decode([String].self, from: data) {
            hosts = existing
        }
        mutate(&hosts)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(hosts) {
            try? data.write(to: pairedHostsURL, options: .atomic)
        }
    }

    // MARK: - generation

    private func generateIdentityFiles() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let workDir = fm.temporaryDirectory.appendingPathComponent("fling-atv-\(UUID().uuidString)",
                                                                   isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        // The PEM key exists only inside this temp dir; the .p12 is the sole
        // durable copy of the private key.
        defer { try? fm.removeItem(at: workDir) }

        let keyPath = workDir.appendingPathComponent("client-key.tmp").path
        let certPath = workDir.appendingPathComponent("client-cert.tmp").path
        let derPath = workDir.appendingPathComponent("client-cert.der").path
        let p12Path = workDir.appendingPathComponent("atv-identity.p12").path

        // Mirrors certificate_generator.py: RSA-2048, SHA-256, self-signed,
        // 10-year validity, CN = client name shown on the TV.
        try runOpenSSL(["req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes",
                        "-days", "3650", "-subj", "/CN=\(clientName)",
                        "-keyout", keyPath, "-out", certPath],
                       produces: certPath)
        try runOpenSSL(["x509", "-in", certPath, "-outform", "der", "-out", derPath],
                       produces: derPath)
        try runOpenSSL(["pkcs12", "-export", "-inkey", keyPath, "-in", certPath,
                        "-name", Self.keychainLabel,
                        "-passout", "pass:\(Self.passphrase)", "-out", p12Path],
                       produces: p12Path)

        if FileManager.default.fileExists(atPath: identityURL.path) {
            try fm.removeItem(at: identityURL)
        }
        if FileManager.default.fileExists(atPath: certificateURL.path) {
            try fm.removeItem(at: certificateURL)
        }
        try fm.moveItem(atPath: p12Path, toPath: identityURL.path)
        try fm.moveItem(atPath: derPath, toPath: certificateURL.path)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identityURL.path)
    }

    /// openssl reports usage errors on stderr while still exiting 0 in some
    /// modes, so success is judged by the output file existing.
    private func runOpenSSL(_ args: [String], produces path: String) throws {
        let output = try runner.run(opensslPath, args)
        guard FileManager.default.fileExists(atPath: path) else {
            throw ATVError.certificateFailure("openssl \(args.first ?? "") failed: \(output)")
        }
    }

    // MARK: - keychain import

    private func importIdentity(from p12: Data) throws -> SecIdentity {
        let options = [kSecImportExportPassphrase as String: Self.passphrase] as CFDictionary
        var items: CFArray?
        let status = SecPKCS12Import(p12 as CFData, options, &items)
        switch status {
        case errSecSuccess:
            guard let array = items as? [[String: Any]],
                  let first = array.first,
                  let ref = first[kSecImportItemIdentity as String],
                  CFGetTypeID(ref as CFTypeRef) == SecIdentityGetTypeID() else {
                throw ATVError.certificateFailure("PKCS#12 import returned no identity")
            }
            return (ref as! SecIdentity)
        case errSecDuplicateItem:
            // A previous run already put this identity in the default keychain;
            // find it by matching the certificate bytes on disk.
            return try findImportedIdentity()
        default:
            throw ATVError.certificateFailure("SecPKCS12Import failed: \(status)")
        }
    }

    private func findImportedIdentity() throws -> SecIdentity {
        let expectedDER = try Data(contentsOf: certificateURL)
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let identities = result as? [SecIdentity] else {
            throw ATVError.certificateFailure("identity lookup failed: \(status)")
        }
        for identity in identities {
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
                  let certificate else { continue }
            if SecCertificateCopyData(certificate) as Data == expectedDER {
                return identity
            }
        }
        throw ATVError.certificateFailure("identity not found in keychain")
    }
}

/// The pairing-secret computation, ported byte-for-byte from pairing.py's
/// `async_finish_pairing`.
enum ATVPairingSecret {

    /// SHA-256 over (client modulus ‖ client exponent ‖ server modulus ‖
    /// server exponent ‖ nonce), nonce being the PIN's last 4 hex chars. The
    /// digest's first byte must equal the PIN's first 2, catching a typo here.
    static func compute(client: ATVRSAPublicNumbers,
                        server: ATVRSAPublicNumbers,
                        pin: String) throws -> Data {
        guard pin.count == 6 else { throw ATVError.invalidPIN("PIN must be exactly 6 characters") }
        guard let pinBytes = ATVHex.data(pin) else { throw ATVError.invalidPIN("PIN must be hex") }

        var hash = SHA256()
        hash.update(data: client.modulus)
        hash.update(data: client.exponent)
        hash.update(data: server.modulus)
        hash.update(data: server.exponent)
        hash.update(data: pinBytes.dropFirst())   // nonce: last 2 bytes
        let digest = Data(hash.finalize())

        guard digest.first == pinBytes.first else {
            throw ATVError.invalidPIN("PIN does not match this TV")
        }
        return digest
    }
}
