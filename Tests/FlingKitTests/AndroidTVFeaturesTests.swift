import XCTest
@testable import FlingKit

/// Golden bytes for the app-launch, current-app, IME-text, and voice messages,
/// derived by hand from remotemessage.proto field numbers (tronikos/androidtvremote2).

final class AndroidTVAppLaunchTests: XCTestCase {

    func test_app_link_launch_golden_bytes() {
        // remote_app_link_launch_request(90){ app_link(1) = "..." }
        XCTAssertEqual(
            ATVRemoteMessage.appLinkLaunch(link: "https://www.youtube.com/watch?v=x"),
            ATVTestHex.data("d205230a2168747470733a2f2f7777772e796f75747562652e636f6d2f77617463683f763d78"))
    }

    func test_app_link_launch_market_link_golden_bytes() {
        XCTAssertEqual(
            ATVRemoteMessage.appLinkLaunch(link: "market://launch?id=com.netflix.ninja"),
            ATVTestHex.data("d205260a246d61726b65743a2f2f6c61756e63683f69643d636f6d2e6e6574666c69782e6e696e6a61"))
    }

    // The facade turns a bare package id into a Play Store link
    // (androidtv_remote.py send_launch_app_command).
    func test_normalize_bare_package_id() {
        XCTAssertEqual(AndroidTVRemote.normalizeAppLink("com.netflix.ninja"),
                       "market://launch?id=com.netflix.ninja")
    }

    func test_normalize_keeps_schemed_links_untouched() {
        XCTAssertEqual(AndroidTVRemote.normalizeAppLink("https://www.youtube.com/watch?v=x"),
                       "https://www.youtube.com/watch?v=x")
        XCTAssertEqual(AndroidTVRemote.normalizeAppLink("market://launch?id=com.netflix.ninja"),
                       "market://launch?id=com.netflix.ninja")
    }
}

final class AndroidTVKeyInjectTests: XCTestCase {

    func test_search_key_golden_bytes() {
        // remote_key_inject(10){ key_code=KEYCODE_SEARCH(84), direction=SHORT(3) }
        XCTAssertEqual(ATVRemoteMessage.keyInject(keyCode: ATVKeyCode.search),
                       ATVTestHex.data("520408541003"))
    }

    func test_assist_key_golden_bytes() {
        // key_code=219 needs a two-byte varint.
        XCTAssertEqual(ATVRemoteMessage.keyInject(keyCode: ATVKeyCode.assist),
                       ATVTestHex.data("520508db011003"))
    }

    func test_voice_assist_key_golden_bytes() {
        XCTAssertEqual(ATVRemoteMessage.keyInject(keyCode: ATVKeyCode.voiceAssist),
                       ATVTestHex.data("520508e7011003"))
    }

    func test_dpad_keys_golden_bytes() {
        XCTAssertEqual(ATVRemoteMessage.keyInject(keyCode: ATVKeyCode.dpadCenter),
                       ATVTestHex.data("520408171003"))
        XCTAssertEqual(ATVRemoteMessage.keyInject(keyCode: ATVKeyCode.dpadUp),
                       ATVTestHex.data("520408131003"))
    }
}

final class AndroidTVCurrentAppTests: XCTestCase {

    func test_parses_foreground_app_package() throws {
        // remote_ime_key_inject(20){ app_info(1){ app_package(12) = "com.netflix.ninja" } }
        let msg = try ATVRemoteMessage.parse(
            ATVTestHex.data("a201150a136211636f6d2e6e6574666c69782e6e696e6a61"))
        XCTAssertEqual(msg.currentApp, "com.netflix.ninja")
    }

    func test_empty_package_parses_to_empty_string() throws {
        // Present-but-empty package: the app went away. Distinct from absent.
        let msg = try ATVRemoteMessage.parse(ATVTestHex.data("a201040a026200"))
        XCTAssertEqual(msg.currentApp, "")
    }

    func test_current_app_nil_when_message_absent() throws {
        let msg = try ATVRemoteMessage.parse(ATVTestHex.data("4200"))  // a ping request
        XCTAssertNil(msg.currentApp)
    }
}

final class AndroidTVImeTextTests: XCTestCase {

    func test_send_text_golden_bytes() {
        // remote_ime_batch_edit(21){ ime_counter=5, field_counter=3,
        //   edit_info{ insert=1, text_field_status{ start=1, end=1, value="Hi" } } }
        XCTAssertEqual(
            ATVRemoteMessage.imeBatchEdit(text: "Hi", imeCounter: 5, fieldCounter: 3),
            ATVTestHex.data("aa0112080510031a0c08011208080110011a024869"))
    }

    func test_single_char_omits_zero_cursor() {
        // "A": cursor = len-1 = 0, so start/end are absent (proto3 zero omission);
        // only value survives.
        XCTAssertEqual(
            ATVRemoteMessage.imeBatchEdit(text: "A", imeCounter: 0, fieldCounter: 0),
            ATVTestHex.data("aa01091a07080112031a0141"))
    }

    func test_send_text_with_counters() {
        XCTAssertEqual(
            ATVRemoteMessage.imeBatchEdit(text: "Hello", imeCounter: 1, fieldCounter: 1),
            ATVTestHex.data("aa0115080110011a0f0801120b080410041a0548656c6c6f"))
    }

    func test_parses_incoming_ime_counters() throws {
        // The TV pushes remote_ime_batch_edit(21){ ime_counter=7, field_counter=2 }
        // when a text field is focused.
        let msg = try ATVRemoteMessage.parse(ATVTestHex.data("aa010408071002"))
        XCTAssertEqual(msg.imeCounter, 7)
        XCTAssertEqual(msg.imeFieldCounter, 2)
    }
}

final class AndroidTVVoiceTests: XCTestCase {

    func test_voice_begin_golden_bytes() {
        // remote_voice_begin(30){ session_id(1) = 7 }
        XCTAssertEqual(ATVRemoteMessage.voiceBegin(sessionId: 7),
                       ATVTestHex.data("f201020807"))
    }

    func test_voice_payload_golden_bytes() {
        // remote_voice_payload(31){ session_id(1)=7, samples(2)=DEAD }
        XCTAssertEqual(ATVRemoteMessage.voicePayload(sessionId: 7, samples: Data([0xDE, 0xAD])),
                       ATVTestHex.data("fa010608071202dead"))
    }

    func test_voice_end_golden_bytes() {
        // remote_voice_end(32){ session_id(1) = 7 }
        XCTAssertEqual(ATVRemoteMessage.voiceEnd(sessionId: 7),
                       ATVTestHex.data("8202020807"))
    }

    func test_parses_incoming_voice_begin_session() throws {
        // remote_voice_begin(30){ session_id=42, package_name="com.google.android.katniss" }
        let msg = try ATVRemoteMessage.parse(
            ATVTestHex.data("f2011e082a121a636f6d2e676f6f676c652e616e64726f69642e6b61746e697373"))
        XCTAssertEqual(msg.voiceBeginSessionId, 42)
    }

    func test_voice_audio_format_constants() {
        // From the RemoteVoicePayload proto comment and voice_stream.py.
        XCTAssertEqual(ATVRemoteMessage.voiceSampleRate, 8000)
        XCTAssertEqual(ATVRemoteMessage.voiceChunkMinSize, 8 * 1024)
        XCTAssertEqual(ATVRemoteMessage.voiceChunkSize, 20 * 1024)
    }
}
