import XCTest
@testable import FlingKit

/// Golden bytes derived by hand from polo.proto's field numbers and enum values
/// (tronikos/androidtvremote2). Wire order matches python-protobuf's ascending
/// field-number serialization, so these are byte-for-byte what the reference sends.
final class AndroidTVPairingMessageTests: XCTestCase {

    // Every outbound message starts with protocol_version=2, status=STATUS_OK(200).
    let header = "080210c801"

    func test_pairing_request_golden_bytes() {
        XCTAssertEqual(
            ATVPairingMessage.pairingRequest(clientName: "Fling"),
            ATVTestHex.data(header + "52120a0961747672656d6f74651205466c696e67"))
    }

    func test_options_golden_bytes() {
        // options(20){ input_encodings(1){ HEXADECIMAL(3), symbol_length 6 }, preferred_role INPUT(1) }
        XCTAssertEqual(ATVPairingMessage.options(),
                       ATVTestHex.data(header + "a201080a04080310061801"))
    }

    func test_configuration_golden_bytes() {
        // configuration(30){ encoding(1){ 3, 6 }, client_role INPUT(1) }
        XCTAssertEqual(ATVPairingMessage.configuration(),
                       ATVTestHex.data(header + "f201080a04080310061001"))
    }

    func test_secret_golden_bytes() {
        let secret = Data((0 as UInt8)...31)
        XCTAssertEqual(
            ATVPairingMessage.secret(secret),
            ATVTestHex.data(header + "c202220a20000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"))
    }

    func test_parses_pairing_request_ack() throws {
        let msg = try ATVPairingMessage.parse(ATVTestHex.data(header + "5a00"))
        XCTAssertEqual(msg.status, 200)
        XCTAssertTrue(msg.hasPairingRequestAck)
        XCTAssertFalse(msg.hasOptions)
        XCTAssertFalse(msg.hasConfigurationAck)
        XCTAssertFalse(msg.hasSecretAck)
    }

    func test_parses_server_options() throws {
        // options with an output_encodings entry and ROLE_TYPE_OUTPUT, as a TV sends.
        let msg = try ATVPairingMessage.parse(ATVTestHex.data(header + "a201081204080310061802"))
        XCTAssertTrue(msg.hasOptions)
    }

    func test_parses_configuration_ack() throws {
        let msg = try ATVPairingMessage.parse(ATVTestHex.data(header + "fa0100"))
        XCTAssertTrue(msg.hasConfigurationAck)
    }

    func test_parses_secret_ack() throws {
        let secret = ATVHex.string(Data((0 as UInt8)...31))
        let msg = try ATVPairingMessage.parse(ATVTestHex.data(header + "ca02220a20" + secret))
        XCTAssertTrue(msg.hasSecretAck)
    }

    func test_parses_bad_secret_status() throws {
        // STATUS_BAD_SECRET = 402, no payload field.
        let msg = try ATVPairingMessage.parse(ATVTestHex.data("0802109203"))
        XCTAssertEqual(msg.status, 402)
        XCTAssertFalse(msg.hasSecretAck)
    }
}

/// Golden bytes derived by hand from remotemessage.proto's field numbers
/// (tronikos/androidtvremote2).
final class AndroidTVRemoteMessageTests: XCTestCase {

    func test_requested_features_value() {
        // PING(1) | KEY(2) | IME(4) | POWER(32) | VOLUME(64) | APP_LINK(512) = 615.
        // IME is negotiated so the TV reports the foreground app and accepts
        // text; VOICE is off by default.
        XCTAssertEqual(ATVRemoteMessage.Features.requested.rawValue, 615)
    }

    func test_requested_with_voice_features_value() {
        // + VOICE(8) = 623.
        XCTAssertEqual(ATVRemoteMessage.Features.requestedWithVoice.rawValue, 623)
        XCTAssertEqual(ATVRemoteMessage.Features.requested(voice: true).rawValue, 623)
        XCTAssertEqual(ATVRemoteMessage.Features.requested(voice: false).rawValue, 615)
    }

    func test_configure_reply_golden_bytes() {
        // remote_configure(1){ code1=615, device_info{ unknown1=1, unknown2="1",
        // package_name="atvremote", app_version="1.0.0" } }
        XCTAssertEqual(
            ATVRemoteMessage.configureReply(features: .requested),
            ATVTestHex.data("0a1c08e704121718012201312a0961747672656d6f74653205312e302e30"))
    }

    func test_configure_reply_with_voice_golden_bytes() {
        XCTAssertEqual(
            ATVRemoteMessage.configureReply(features: .requestedWithVoice),
            ATVTestHex.data("0a1c08ef04121718012201312a0961747672656d6f74653205312e302e30"))
    }

    func test_configure_reply_zero_features_omits_code1() {
        // proto3 zero omission: python-protobuf drops code1=0, keeping only
        // device_info. Degenerate (an empty intersection), but byte-exact.
        XCTAssertEqual(
            ATVRemoteMessage.configureReply(features: []),
            ATVTestHex.data("0a19121718012201312a0961747672656d6f74653205312e302e30"))
    }

    func test_set_active_zero_features_is_empty_submessage() {
        XCTAssertEqual(ATVRemoteMessage.setActive(features: []), ATVTestHex.data("1200"))
    }

    func test_set_active_golden_bytes() {
        XCTAssertEqual(ATVRemoteMessage.setActive(features: .requested),
                       ATVTestHex.data("120308e704"))
    }

    func test_set_active_with_voice_golden_bytes() {
        XCTAssertEqual(ATVRemoteMessage.setActive(features: .requestedWithVoice),
                       ATVTestHex.data("120308ef04"))
    }

    func test_ping_response_golden_bytes() {
        XCTAssertEqual(ATVRemoteMessage.pingResponse(val1: 1), ATVTestHex.data("4a020801"))
    }

    func test_ping_response_omits_zero_val1() {
        // proto3 zero scalars are absent from the wire; only the submessage
        // marks presence.
        XCTAssertEqual(ATVRemoteMessage.pingResponse(val1: 0), ATVTestHex.data("4a00"))
    }

    func test_key_inject_power_golden_bytes() {
        // remote_key_inject(10){ key_code=KEYCODE_POWER(26), direction=SHORT(3) }
        XCTAssertEqual(ATVRemoteMessage.keyInject(keyCode: ATVKeyCode.power),
                       ATVTestHex.data("5204081a1003"))
    }

    func test_key_inject_negative_keycode_encodes_twos_complement() {
        // Enum varints sign-extend to 10 bytes (python-protobuf does the
        // same); a negative Int32 must not trap the public API.
        XCTAssertEqual(ATVRemoteMessage.keyInject(keyCode: -1),
                       ATVTestHex.data("520d08ffffffffffffffffff011003"))
    }

    func test_key_inject_long_press_direction() {
        XCTAssertEqual(ATVRemoteMessage.keyInject(keyCode: ATVKeyCode.power, direction: .startLong),
                       ATVTestHex.data("5204081a1001"))
    }

    func test_parses_remote_configure() throws {
        // remote_configure{ code1=0x2FF, device_info{ model="SmartTV", vendor="TCL" } }
        let msg = try ATVRemoteMessage.parse(ATVTestHex.data("0a1308ff05120e0a07536d6172745456120354434c"))
        let supported = try XCTUnwrap(msg.configureFeatures)
        XCTAssertEqual(supported.rawValue, 0x2FF)
        // Negotiation keeps only what both sides support (0x2FF includes IME).
        XCTAssertEqual(ATVRemoteMessage.Features.requested.intersection(supported).rawValue, 615)
    }

    func test_configure_negotiation_drops_unsupported_features() {
        let supported = ATVRemoteMessage.Features(rawValue: 0b11)  // PING | KEY only
        XCTAssertEqual(ATVRemoteMessage.Features.requested.intersection(supported).rawValue, 3)
    }

    func test_parses_set_active() throws {
        let msg = try ATVRemoteMessage.parse(ATVTestHex.data("1200"))
        XCTAssertTrue(msg.hasSetActive)
        XCTAssertNil(msg.configureFeatures)
    }

    func test_parses_ping_request() throws {
        let msg = try ATVRemoteMessage.parse(ATVTestHex.data("42020805"))
        XCTAssertEqual(msg.pingVal1, 5)
    }

    func test_parses_empty_ping_request_as_zero() throws {
        let msg = try ATVRemoteMessage.parse(ATVTestHex.data("4200"))
        XCTAssertEqual(msg.pingVal1, 0)
    }

    func test_parses_remote_start_on() throws {
        let msg = try ATVRemoteMessage.parse(ATVTestHex.data("c202020801"))
        XCTAssertEqual(msg.started, true)
    }

    func test_parses_remote_start_off_as_empty_submessage() throws {
        // started=false arrives as a zero-length submessage (proto3 zero omission);
        // presence of field 40 alone must set started, not leave it nil.
        let msg = try ATVRemoteMessage.parse(ATVTestHex.data("c20200"))
        XCTAssertEqual(msg.started, false)
    }

    func test_started_nil_when_remote_start_absent() throws {
        let msg = try ATVRemoteMessage.parse(ATVTestHex.data("4200"))
        XCTAssertNil(msg.started)
    }

    func test_parses_remote_error() throws {
        // remote_error(3){ value=true }
        let msg = try ATVRemoteMessage.parse(ATVTestHex.data("1a020801"))
        XCTAssertTrue(msg.hasError)
    }

    func test_keycode_constants_match_proto() {
        XCTAssertEqual(ATVKeyCode.power, 26)
        XCTAssertEqual(ATVKeyCode.home, 3)
        XCTAssertEqual(ATVKeyCode.back, 4)
        XCTAssertEqual(ATVKeyCode.dpadUp, 19)
        XCTAssertEqual(ATVKeyCode.dpadDown, 20)
        XCTAssertEqual(ATVKeyCode.dpadLeft, 21)
        XCTAssertEqual(ATVKeyCode.dpadRight, 22)
        XCTAssertEqual(ATVKeyCode.dpadCenter, 23)
        XCTAssertEqual(ATVKeyCode.volumeUp, 24)
        XCTAssertEqual(ATVKeyCode.volumeDown, 25)
        XCTAssertEqual(ATVKeyCode.volumeMute, 164)
        XCTAssertEqual(ATVKeyCode.mediaPlayPause, 85)
        XCTAssertEqual(ATVKeyCode.search, 84)
        XCTAssertEqual(ATVKeyCode.assist, 219)
        XCTAssertEqual(ATVKeyCode.voiceAssist, 231)
    }
}
