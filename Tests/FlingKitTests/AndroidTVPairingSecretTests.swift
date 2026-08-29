import XCTest
@testable import FlingKit

final class AndroidTVPairingSecretTests: XCTestCase {

    // Fixed vector cross-checked against the reference computation in
    // androidtvremote2 pairing.py: SHA-256(client_mod ‖ client_exp ‖
    // server_mod ‖ server_exp ‖ nonce), nonce = last 4 PIN hex chars,
    // digest[0] must equal the first 2 PIN chars.
    let client = ATVRSAPublicNumbers(modulus: ATVHex.data("B0F1D2C3A4958677CAFEBABE12345601")!,
                                     exponent: ATVHex.data("010001")!)
    let server = ATVRSAPublicNumbers(modulus: ATVHex.data("9A8B7C6D5E4F3A2B0011223344556677")!,
                                     exponent: ATVHex.data("010001")!)
    let expectedDigest = "b389b2584d502929659a2048e141e77c3457c1763e321847b841d85e69512f5d"

    func test_computes_reference_secret() throws {
        let secret = try ATVPairingSecret.compute(client: client, server: server, pin: "B31A2B")
        XCTAssertEqual(ATVHex.string(secret), expectedDigest)
    }

    func test_accepts_lowercase_pin() throws {
        let secret = try ATVPairingSecret.compute(client: client, server: server, pin: "b31a2b")
        XCTAssertEqual(ATVHex.string(secret), expectedDigest)
    }

    func test_zero_padded_exponent_hashes_identically() throws {
        // DER INTEGERs carry a sign pad byte; the hash must cover only the
        // magnitude, so a padded exponent must produce the same digest.
        let padded = ATVRSAPublicNumbers(modulus: client.modulus,
                                         exponent: ATVHex.data("00010001")!)
        let secret = try ATVPairingSecret.compute(client: padded, server: server, pin: "B31A2B")
        XCTAssertEqual(ATVHex.string(secret), expectedDigest)
    }

    func test_wrong_pin_check_byte_throws() {
        XCTAssertThrowsError(try ATVPairingSecret.compute(client: client, server: server,
                                                          pin: "001A2B")) { error in
            XCTAssertEqual(error as? ATVError, .invalidPIN("PIN does not match this TV"))
        }
    }

    func test_wrong_nonce_throws() {
        // Same check byte, different nonce → digest changes → mismatch.
        XCTAssertThrowsError(try ATVPairingSecret.compute(client: client, server: server,
                                                          pin: "B30000"))
    }

    func test_rejects_wrong_length_pin() {
        XCTAssertThrowsError(try ATVPairingSecret.compute(client: client, server: server,
                                                          pin: "B31A2")) { error in
            XCTAssertEqual(error as? ATVError, .invalidPIN("PIN must be exactly 6 characters"))
        }
    }

    func test_rejects_non_hex_pin() {
        XCTAssertThrowsError(try ATVPairingSecret.compute(client: client, server: server,
                                                          pin: "XY1A2B")) { error in
            XCTAssertEqual(error as? ATVError, .invalidPIN("PIN must be hex"))
        }
    }
}

final class AndroidTVRSAPublicNumbersTests: XCTestCase {

    func test_strips_leading_zero_bytes() {
        let numbers = ATVRSAPublicNumbers(modulus: Data([0x00, 0x00, 0xB0, 0xF1]),
                                          exponent: Data([0x00, 0x01, 0x00, 0x01]))
        XCTAssertEqual(numbers.modulus, Data([0xB0, 0xF1]))
        XCTAssertEqual(numbers.exponent, Data([0x01, 0x00, 0x01]))
    }

    func test_keeps_minimal_representation_untouched() {
        let numbers = ATVRSAPublicNumbers(modulus: Data([0xB0, 0x00, 0xF1]),
                                          exponent: Data([0x03]))
        XCTAssertEqual(numbers.modulus, Data([0xB0, 0x00, 0xF1]))
        XCTAssertEqual(numbers.exponent, Data([0x03]))
    }
}

final class AndroidTVCertificateParsingTests: XCTestCase {

    func test_parses_pkcs1_public_key_with_sign_pad() throws {
        // RSAPublicKey ::= SEQUENCE { INTEGER modulus, INTEGER exponent };
        // the modulus's top bit is set so DER pads it with 0x00.
        let der = ATVTestHex.bytes("3010" + "020900b0f1d2c3a4958677" + "0203010001")
        let numbers = try ATVCertificateStore.parsePKCS1RSAPublicKey(der)
        XCTAssertEqual(numbers.modulus, ATVHex.data("b0f1d2c3a4958677"))
        XCTAssertEqual(numbers.exponent, ATVHex.data("010001"))
    }

    func test_parses_pkcs1_with_long_form_lengths() throws {
        // A realistic 2048-bit modulus forces 0x82-prefixed two-byte lengths.
        var modulus: [UInt8] = [0x80]
        modulus.append(contentsOf: [UInt8](repeating: 0xAB, count: 255))
        var der: [UInt8] = [0x30, 0x82, 0x01, 0x0A]      // SEQUENCE, 266 bytes
        der.append(contentsOf: [0x02, 0x82, 0x01, 0x01, 0x00])  // INTEGER, pad + 256
        der.append(contentsOf: modulus)
        der.append(contentsOf: [0x02, 0x03, 0x01, 0x00, 0x01])
        let numbers = try ATVCertificateStore.parsePKCS1RSAPublicKey(der)
        XCTAssertEqual(numbers.modulus, Data(modulus))
        XCTAssertEqual(numbers.exponent, ATVHex.data("010001"))
    }

    func test_rejects_non_sequence() {
        XCTAssertThrowsError(try ATVCertificateStore.parsePKCS1RSAPublicKey([0x02, 0x01, 0x05]))
    }

    func test_rejects_truncated_integer() {
        XCTAssertThrowsError(try ATVCertificateStore.parsePKCS1RSAPublicKey([0x30, 0x04, 0x02, 0x05, 0x01]))
    }

    /// A fixed self-signed RSA-2048 certificate (public half only, generated as
    /// a test fixture) exercises the same Security-framework path used on the
    /// server certificate captured during the pairing TLS handshake.
    func test_extracts_public_numbers_from_der_certificate() throws {
        let der = try XCTUnwrap(Data(base64Encoded: Self.fixtureCertificateBase64))
        let numbers = try ATVCertificateStore.publicNumbers(fromCertificateDER: der)
        XCTAssertEqual(ATVHex.string(numbers.modulus), Self.fixtureModulusHex)
        XCTAssertEqual(numbers.exponent, ATVHex.data("010001"))
        XCTAssertEqual(numbers.modulus.count, 256)
    }

    func test_rejects_garbage_certificate_data() {
        XCTAssertThrowsError(try ATVCertificateStore.publicNumbers(fromCertificateDER: Data([0x01, 0x02])))
    }

    static let fixtureModulusHex =
        "b79d070c0beef3ce439c298ac34b1d35579cd8e00333ce678ddf28540bd89dbfaecd0543" +
        "87b16c7673d4bc76c769cdd82225957d8f0184890f198fc2279f101630de4b3ae38c026e" +
        "27df62cbbfb2072cc63eed45a6e9606f59b49846d2a942f5ca8251befda0e31e36b77d64" +
        "c5d3858e5528aaec7a19345e2a4c4004df82e65f7f35f5c0508c8036d69c29a132044706" +
        "ce0d972bf4ee22e7f096fc63b1ff69ed4230992bed88f9461fbfb4fd96a8f60b1936654d" +
        "0738ae56a4f93295d0739fb391f99f8db79ad58e4eddb690566785363d6b9e9c3d7501aa" +
        "0d3762eb7be548e744a88670ab588e9d23b421066b6c0e547b2366d7b8785a2d0a7fc792" +
        "ca90ef47"

    static let fixtureCertificateBase64 = """
        MIICsjCCAZoCCQCGvJDaXHZspTANBgkqhkiG9w0BAQsFADAbMRkwFwYDVQQDDBBGbGluZ1Rlc3RG\
        aXh0dXJlMB4XDTI2MDgyOTAwMjIzMFoXDTM2MDgyNjAwMjIzMFowGzEZMBcGA1UEAwwQRmxpbmdU\
        ZXN0Rml4dHVyZTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALedBwwL7vPOQ5wpisNL\
        HTVXnNjgAzPOZ43fKFQL2J2/rs0FQ4exbHZz1Lx2x2nN2CIllX2PAYSJDxmPwiefEBYw3ks644wC\
        biffYsu/sgcsxj7tRabpYG9ZtJhG0qlC9cqCUb79oOMeNrd9ZMXThY5VKKrsehk0XipMQATfguZf\
        fzX1wFCMgDbWnCmhMgRHBs4Nlyv07iLn8Jb8Y7H/ae1CMJkr7Yj5Rh+/tP2WqPYLGTZlTQc4rlak\
        +TKV0HOfs5H5n423mtWOTt22kFZnhTY9a56cPXUBqg03Yut75UjnRKiGcKtYjp0jtCEGa2wOVHsj\
        Zte4eFotCn/HksqQ70cCAwEAATANBgkqhkiG9w0BAQsFAAOCAQEAYzh+jX9Xltz5Kut6DP6KCE/A\
        FSpCh4Fk6yfhJJwR+i9IP2Sky4KK6pAnaX4zU2ZkfrZMBKmzjl3OT+yrr8xBeDfF/A6w+KaliCY7\
        n1UHDeUSUsAIdlPhELpzthFetCLpn8o2avMsdOrTpvhfHEqdRgXZwwJnM+hPUh3wbw9rK18VbR1s\
        rfuh9A6k3UAUJGXKeJKvTevzuDPE9tdih5tpUUxL6f/J+q9+qKhqS4qu47uiiajUzkALrnUQwzvV\
        Poo3MlblqpwNVIbOTLVTO5QlbmVbVwLxRTx11oOnAMsrIvLO1jU4aZ7s5BCaBVprCKblyWN0hxry\
        hVLhoAtghj4KuQ==
        """
}

final class AndroidTVPairedHostsTests: XCTestCase {

    private var store: ATVCertificateStore!
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fling-atv-tests-\(UUID().uuidString)", isDirectory: true)
        store = ATVCertificateStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func test_starts_empty() {
        XCTAssertEqual(store.pairedHosts(), [])
        XCTAssertFalse(store.identityExists)
    }

    func test_records_and_removes_hosts() {
        store.recordPairedHost("192.168.1.42")
        store.recordPairedHost("192.168.1.42")   // idempotent
        store.recordPairedHost("192.168.1.77")
        XCTAssertEqual(store.pairedHosts(), ["192.168.1.42", "192.168.1.77"])

        store.removePairedHost("192.168.1.42")
        XCTAssertEqual(store.pairedHosts(), ["192.168.1.77"])
    }

    func test_hosts_persist_across_store_instances() {
        store.recordPairedHost("192.168.1.42")
        let reopened = ATVCertificateStore(directory: directory)
        XCTAssertEqual(reopened.pairedHosts(), ["192.168.1.42"])
    }
}
