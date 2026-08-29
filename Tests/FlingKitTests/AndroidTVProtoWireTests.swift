import XCTest
@testable import FlingKit

/// Shared helpers for the AndroidTV test files.
enum ATVTestHex {
    static func bytes(_ hex: String) -> [UInt8] {
        [UInt8](ATVHex.data(hex)!)
    }

    static func data(_ hex: String) -> Data {
        ATVHex.data(hex)!
    }
}

final class AndroidTVProtoWireVarintTests: XCTestCase {

    // Golden values cross-checked against a reference varint implementation.
    let golden: [(UInt64, String)] = [
        (0, "00"),
        (1, "01"),
        (127, "7f"),
        (128, "8001"),
        (300, "ac02"),
        (611, "e304"),
        (16384, "808001"),
        (UInt64(UInt32.max), "ffffffff0f"),
        (UInt64.max, "ffffffffffffffffff01"),
    ]

    func test_varint_encodes_golden_bytes() {
        for (value, hex) in golden {
            XCTAssertEqual(ProtoWire.varint(value), ATVTestHex.bytes(hex), "varint(\(value))")
        }
    }

    func test_varint_decodes_golden_bytes() throws {
        for (value, hex) in golden {
            var index = 0
            XCTAssertEqual(try ProtoWire.readVarint(ATVTestHex.bytes(hex), &index), value)
            XCTAssertEqual(index, hex.count / 2, "index after varint(\(value))")
        }
    }

    func test_varint_roundtrips_boundaries() throws {
        for value: UInt64 in [0, 1, 0x7F, 0x80, 0x3FFF, 0x4000, 1 << 32, UInt64.max - 1] {
            var index = 0
            XCTAssertEqual(try ProtoWire.readVarint(ProtoWire.varint(value), &index), value)
        }
    }

    func test_truncated_varint_throws_and_leaves_index_untouched() {
        var index = 0
        XCTAssertThrowsError(try ProtoWire.readVarint([0x80], &index)) { error in
            XCTAssertEqual(error as? ProtoWireError, .truncatedVarint)
        }
        XCTAssertEqual(index, 0)
    }

    func test_empty_input_throws_truncated() {
        var index = 0
        XCTAssertThrowsError(try ProtoWire.readVarint([], &index)) { error in
            XCTAssertEqual(error as? ProtoWireError, .truncatedVarint)
        }
    }

    func test_eleven_byte_varint_throws_too_long() {
        var index = 0
        let bytes = [UInt8](repeating: 0x80, count: 11)
        XCTAssertThrowsError(try ProtoWire.readVarint(bytes, &index)) { error in
            XCTAssertEqual(error as? ProtoWireError, .varintTooLong)
        }
    }

    func test_varint_decode_starts_at_index() throws {
        var index = 1
        XCTAssertEqual(try ProtoWire.readVarint([0xFF, 0xAC, 0x02], &index), 300)
        XCTAssertEqual(index, 3)
    }
}

final class AndroidTVProtoWriterTests: XCTestCase {

    func test_varint_field() {
        var w = ProtoWriter()
        w.varint(1, 2)
        w.varint(2, 200)
        XCTAssertEqual(w.data, ATVTestHex.data("080210c801"))
    }

    func test_string_field() {
        var w = ProtoWriter()
        w.string(1, "atvremote")
        XCTAssertEqual(w.data, ATVTestHex.data("0a0961747672656d6f7465"))
    }

    func test_bytes_field() {
        var w = ProtoWriter()
        w.bytes(1, Data([0xDE, 0xAD]))
        XCTAssertEqual(w.data, ATVTestHex.data("0a02dead"))
    }

    func test_nested_message_field() {
        var w = ProtoWriter()
        w.message(10) { inner in
            inner.varint(1, 26)
            inner.varint(2, 3)
        }
        XCTAssertEqual(w.data, ATVTestHex.data("5204081a1003"))
    }

    func test_high_field_number_uses_multibyte_tag() {
        var w = ProtoWriter()
        w.message(40) { inner in inner.varint(1, 1) }
        // field 40 wire type 2 → key 322 → varint c2 02
        XCTAssertEqual(w.data, ATVTestHex.data("c202020801"))
    }

    func test_empty_nested_message_still_emitted() {
        var w = ProtoWriter()
        w.message(9) { _ in }
        XCTAssertEqual(w.data, ATVTestHex.data("4a00"))
    }
}

final class AndroidTVProtoReaderTests: XCTestCase {

    func test_reads_varint_and_length_delimited_fields() throws {
        let reader = try ProtoReader(parsing: ATVTestHex.bytes("080210c8015a00"))
        XCTAssertEqual(reader.varint(1), 2)
        XCTAssertEqual(reader.varint(2), 200)
        XCTAssertTrue(reader.has(11))
        XCTAssertEqual(reader.bytes(11), [])
        XCTAssertFalse(reader.has(3))
        XCTAssertNil(reader.varint(3))
    }

    func test_reads_nested_message() throws {
        let reader = try ProtoReader(parsing: ATVTestHex.bytes("5204081a1003"))
        let nested = try XCTUnwrap(reader.message(10))
        XCTAssertEqual(nested.varint(1), 26)
        XCTAssertEqual(nested.varint(2), 3)
    }

    func test_reads_string_field() throws {
        let reader = try ProtoReader(parsing: ATVTestHex.bytes("0a0961747672656d6f7465"))
        XCTAssertEqual(try reader.string(1), "atvremote")
    }

    func test_invalid_utf8_string_throws() throws {
        let reader = try ProtoReader(parsing: [0x0A, 0x01, 0xFF])
        XCTAssertThrowsError(try reader.string(1)) { error in
            XCTAssertEqual(error as? ProtoWireError, .malformedUTF8)
        }
    }

    func test_skips_unknown_fixed_width_fields() throws {
        // field 3 fixed64, field 4 fixed32, then field 1 varint — the codec
        // must parse past wire types it never emits itself.
        let bytes = ATVTestHex.bytes("190102030405060708" + "250a0b0c0d" + "0805")
        let reader = try ProtoReader(parsing: bytes)
        XCTAssertEqual(reader.varint(1), 5)
        XCTAssertEqual(reader.fields.count, 3)
        if case .fixed64(let v) = reader.fields[0].value {
            XCTAssertEqual(v, 0x0807060504030201)
        } else {
            XCTFail("expected fixed64")
        }
        if case .fixed32(let v) = reader.fields[1].value {
            XCTAssertEqual(v, 0x0d0c0b0a)
        } else {
            XCTFail("expected fixed32")
        }
    }

    func test_group_wire_type_throws() {
        XCTAssertThrowsError(try ProtoReader(parsing: [0x0B])) { error in
            XCTAssertEqual(error as? ProtoWireError, .unsupportedWireType(3))
        }
    }

    func test_truncated_length_delimited_throws() {
        XCTAssertThrowsError(try ProtoReader(parsing: [0x0A, 0x05, 0x01])) { error in
            XCTAssertEqual(error as? ProtoWireError, .truncatedField)
        }
    }

    func test_truncated_fixed64_throws() {
        XCTAssertThrowsError(try ProtoReader(parsing: [0x19, 0x01])) { error in
            XCTAssertEqual(error as? ProtoWireError, .truncatedField)
        }
    }

    func test_empty_message_parses_to_no_fields() throws {
        XCTAssertTrue(try ProtoReader(parsing: []).fields.isEmpty)
    }
}

final class AndroidTVProtoFrameTests: XCTestCase {

    func test_encode_prefixes_length_varint() {
        let message = ATVTestHex.data("5204081a1003")
        XCTAssertEqual(ProtoFrame.encode(message), ATVTestHex.data("065204081a1003"))
    }

    func test_encode_uses_multibyte_length_for_large_payloads() {
        let message = Data(repeating: 0xAA, count: 300)
        let framed = ProtoFrame.encode(message)
        XCTAssertEqual(framed.prefix(2), ATVTestHex.data("ac02"))
        XCTAssertEqual(framed.count, 302)
    }

    func test_next_returns_nil_until_frame_complete() throws {
        var buffer: [UInt8] = []
        let framed = ATVTestHex.bytes("065204081a1003")
        for byte in framed.dropLast() {
            buffer.append(byte)
            XCTAssertNil(try ProtoFrame.next(in: &buffer))
        }
        buffer.append(framed.last!)
        XCTAssertEqual(try ProtoFrame.next(in: &buffer), ATVTestHex.data("5204081a1003"))
        XCTAssertTrue(buffer.isEmpty)
    }

    func test_next_handles_length_prefix_split_across_reads() throws {
        // 300-byte frame: the two-byte length prefix arrives one byte at a time.
        var buffer: [UInt8] = [0xAC]
        XCTAssertNil(try ProtoFrame.next(in: &buffer))
        buffer.append(0x02)
        XCTAssertNil(try ProtoFrame.next(in: &buffer))
        buffer.append(contentsOf: [UInt8](repeating: 0x55, count: 300))
        XCTAssertEqual(try ProtoFrame.next(in: &buffer), Data(repeating: 0x55, count: 300))
    }

    func test_next_extracts_multiple_frames_from_one_buffer() throws {
        var buffer = ATVTestHex.bytes("024a00" + "065204081a1003")
        XCTAssertEqual(try ProtoFrame.next(in: &buffer), ATVTestHex.data("4a00"))
        XCTAssertEqual(try ProtoFrame.next(in: &buffer), ATVTestHex.data("5204081a1003"))
        XCTAssertNil(try ProtoFrame.next(in: &buffer))
    }

    func test_zero_length_frame() throws {
        var buffer: [UInt8] = [0x00]
        XCTAssertEqual(try ProtoFrame.next(in: &buffer), Data())
    }

    func test_oversized_frame_throws() {
        var buffer = ProtoWire.varint(ProtoFrame.maxLength + 1)
        XCTAssertThrowsError(try ProtoFrame.next(in: &buffer)) { error in
            XCTAssertEqual(error as? ProtoWireError, .oversizedFrame(ProtoFrame.maxLength + 1))
        }
    }
}

final class AndroidTVHexTests: XCTestCase {

    func test_roundtrip() {
        XCTAssertEqual(ATVHex.data("b31a2b"), Data([0xB3, 0x1A, 0x2B]))
        XCTAssertEqual(ATVHex.data("B31A2B"), Data([0xB3, 0x1A, 0x2B]))
        XCTAssertEqual(ATVHex.string(Data([0xB3, 0x1A, 0x2B])), "b31a2b")
    }

    func test_rejects_odd_length_and_non_hex() {
        XCTAssertNil(ATVHex.data("abc"))
        XCTAssertNil(ATVHex.data("zz"))
    }
}
