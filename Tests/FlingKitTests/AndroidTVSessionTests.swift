import XCTest
import Network
@testable import FlingKit

/// Session bring-up diagnostics: TLS-stage error mapping, the voice-bitmask
/// retry decision, the deadline unblock, and the file logger.

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

    func test_close_during_configure_with_voice_retries() {
        XCTAssertTrue(ATVRemoteClient.shouldRetryWithoutVoice(
            after: ATVError.connectionClosed, voiceRequested: true))
        XCTAssertTrue(ATVRemoteClient.shouldRetryWithoutVoice(
            after: ATVError.connectionFailed("POSIXErrorCode(rawValue: 54): Connection reset by peer"),
            voiceRequested: true))
    }

    func test_without_voice_requested_never_retries() {
        XCTAssertFalse(ATVRemoteClient.shouldRetryWithoutVoice(
            after: ATVError.connectionClosed, voiceRequested: false))
    }

    func test_tls_stage_and_silence_are_not_the_voice_bits_doing() {
        XCTAssertFalse(ATVRemoteClient.shouldRetryWithoutVoice(
            after: ATVError.tlsHandshakeFailed("-9806"), voiceRequested: true))
        XCTAssertFalse(ATVRemoteClient.shouldRetryWithoutVoice(
            after: ATVError.connectionTimeout, voiceRequested: true))
        XCTAssertFalse(ATVRemoteClient.shouldRetryWithoutVoice(
            after: ATVError.notPaired, voiceRequested: true))
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
