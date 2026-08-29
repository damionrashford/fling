import Foundation

enum ProtoWireError: Error, Equatable {
    case truncatedVarint
    case varintTooLong
    case truncatedField
    /// Groups (wire types 3/4) are pre-proto3 relics no Android TV message uses.
    case unsupportedWireType(UInt8)
    case oversizedFrame(UInt64)
    case malformedUTF8
}

/// Minimal protobuf wire codec. The protocol needs only two small schemas
/// (polo.proto, remotemessage.proto), so hand-rolling keeps SwiftProtobuf out
/// of the dependency graph.
enum ProtoWire {

    static func varint(_ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var v = value
        repeat {
            let byte = UInt8(v & 0x7F)
            v >>= 7
            bytes.append(v == 0 ? byte : byte | 0x80)
        } while v != 0
        return bytes
    }

    /// Reads a varint starting at `index`, advancing it past the varint.
    /// `index` is untouched on failure so framing code can retry with more data.
    static func readVarint(_ bytes: [UInt8], _ index: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var i = index
        while true {
            guard shift < 64 else { throw ProtoWireError.varintTooLong }
            guard i < bytes.count else { throw ProtoWireError.truncatedVarint }
            let byte = bytes[i]
            i += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                index = i
                return result
            }
            shift += 7
        }
    }
}

/// Appends fields in call order. Callers write in ascending field number to
/// match python-protobuf's output, keeping golden byte tests comparable.
struct ProtoWriter {
    private(set) var bytes: [UInt8] = []

    var data: Data { Data(bytes) }

    mutating func varint(_ field: Int, _ value: UInt64) {
        tag(field, wireType: 0)
        bytes.append(contentsOf: ProtoWire.varint(value))
    }

    mutating func string(_ field: Int, _ value: String) {
        lengthDelimited(field, Array(value.utf8))
    }

    mutating func bytes(_ field: Int, _ value: Data) {
        lengthDelimited(field, [UInt8](value))
    }

    mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var sub = ProtoWriter()
        build(&sub)
        lengthDelimited(field, sub.bytes)
    }

    private mutating func lengthDelimited(_ field: Int, _ payload: [UInt8]) {
        tag(field, wireType: 2)
        bytes.append(contentsOf: ProtoWire.varint(UInt64(payload.count)))
        bytes.append(contentsOf: payload)
    }

    private mutating func tag(_ field: Int, wireType: UInt64) {
        bytes.append(contentsOf: ProtoWire.varint(UInt64(field) << 3 | wireType))
    }
}

enum ProtoFieldValue: Equatable {
    case varint(UInt64)
    case lengthDelimited([UInt8])
    case fixed32(UInt32)
    case fixed64(UInt64)
}

/// Eagerly parses a message into (field, value) pairs; the schemas are a
/// handful of fields each, so lazy scanning is not warranted.
struct ProtoReader {
    let fields: [(number: Int, value: ProtoFieldValue)]

    init(parsing data: Data) throws {
        try self.init(parsing: [UInt8](data))
    }

    init(parsing bytes: [UInt8]) throws {
        var parsed: [(Int, ProtoFieldValue)] = []
        var index = 0
        while index < bytes.count {
            let key = try ProtoWire.readVarint(bytes, &index)
            let field = Int(key >> 3)
            let wireType = UInt8(key & 0x7)
            switch wireType {
            case 0:
                parsed.append((field, .varint(try ProtoWire.readVarint(bytes, &index))))
            case 1:
                guard index + 8 <= bytes.count else { throw ProtoWireError.truncatedField }
                var v: UInt64 = 0
                for i in 0..<8 { v |= UInt64(bytes[index + i]) << (8 * UInt64(i)) }
                index += 8
                parsed.append((field, .fixed64(v)))
            case 2:
                let length = try ProtoWire.readVarint(bytes, &index)
                guard length <= UInt64(bytes.count - index) else { throw ProtoWireError.truncatedField }
                let payload = Array(bytes[index ..< index + Int(length)])
                index += Int(length)
                parsed.append((field, .lengthDelimited(payload)))
            case 5:
                guard index + 4 <= bytes.count else { throw ProtoWireError.truncatedField }
                var v: UInt32 = 0
                for i in 0..<4 { v |= UInt32(bytes[index + i]) << (8 * UInt32(i)) }
                index += 4
                parsed.append((field, .fixed32(v)))
            default:
                throw ProtoWireError.unsupportedWireType(wireType)
            }
        }
        fields = parsed
    }

    func has(_ field: Int) -> Bool {
        fields.contains { $0.number == field }
    }

    func varint(_ field: Int) -> UInt64? {
        for (number, value) in fields where number == field {
            if case .varint(let v) = value { return v }
        }
        return nil
    }

    func bytes(_ field: Int) -> [UInt8]? {
        for (number, value) in fields where number == field {
            if case .lengthDelimited(let payload) = value { return payload }
        }
        return nil
    }

    func string(_ field: Int) throws -> String? {
        guard let payload = bytes(field) else { return nil }
        guard let s = String(bytes: payload, encoding: .utf8) else { throw ProtoWireError.malformedUTF8 }
        return s
    }

    func message(_ field: Int) throws -> ProtoReader? {
        guard let payload = bytes(field) else { return nil }
        return try ProtoReader(parsing: payload)
    }
}

/// Both TV ports frame every protobuf message with a plain varint byte-length
/// prefix (androidtvremote2 base.py).
enum ProtoFrame {
    /// Remote messages are tens of bytes; anything past this is a corrupt
    /// stream, and buffering it would only defer the failure.
    static let maxLength: UInt64 = 1 << 20

    static func encode(_ message: Data) -> Data {
        var out = Data(ProtoWire.varint(UInt64(message.count)))
        out.append(message)
        return out
    }

    /// Consumes and returns one complete frame, or nil if more bytes are needed
    /// (the length prefix itself may arrive split across TCP reads).
    static func next(in buffer: inout [UInt8]) throws -> Data? {
        var index = 0
        let length: UInt64
        do {
            length = try ProtoWire.readVarint(buffer, &index)
        } catch ProtoWireError.truncatedVarint {
            return nil
        }
        guard length <= maxLength else { throw ProtoWireError.oversizedFrame(length) }
        guard UInt64(buffer.count - index) >= length else { return nil }
        let frame = Data(buffer[index ..< index + Int(length)])
        buffer.removeFirst(index + Int(length))
        return frame
    }
}

/// Shared hex plumbing: PINs arrive as hex text and tests express golden bytes
/// as hex strings.
enum ATVHex {
    static func data(_ string: String) -> Data? {
        let chars = Array(string)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else { return nil }
            out.append(UInt8(hi << 4 | lo))
            i += 2
        }
        return out
    }

    static func string(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
