import Foundation

/// Android keycodes from remotemessage.proto's RemoteKeyCode enum.
public enum ATVKeyCode {
    public static let power: Int32 = 26
    public static let home: Int32 = 3
    public static let back: Int32 = 4
    public static let dpadUp: Int32 = 19
    public static let dpadDown: Int32 = 20
    public static let dpadLeft: Int32 = 21
    public static let dpadRight: Int32 = 22
    public static let dpadCenter: Int32 = 23
    public static let volumeUp: Int32 = 24
    public static let volumeDown: Int32 = 25
    public static let volumeMute: Int32 = 164
    public static let mediaPlayPause: Int32 = 85
    public static let search: Int32 = 84
    /// KEYCODE_ASSIST (219) opens the Assistant UI; KEYCODE_VOICE_ASSIST (231)
    /// starts a voice interaction. Values from remotemessage.proto.
    public static let assist: Int32 = 219
    public static let voiceAssist: Int32 = 231
}

/// polo.proto `OuterMessage` — the pairing protocol on port 6467.
/// Field numbers and enum values come from tronikos/androidtvremote2.
enum ATVPairingMessage {

    static let statusOK: UInt64 = 200
    static let serviceName = "atvremote"

    // OuterMessage field numbers.
    private enum Field {
        static let protocolVersion = 1
        static let status = 2
        static let pairingRequest = 10
        static let pairingRequestAck = 11
        static let options = 20
        static let configuration = 30
        static let configurationAck = 31
        static let secret = 40
        static let secretAck = 41
    }

    // Options/Configuration enum values (polo.proto).
    private static let encodingHexadecimal: UInt64 = 3
    private static let symbolLength: UInt64 = 6
    private static let roleInput: UInt64 = 1

    /// Every outbound message repeats protocol_version 2 + STATUS_OK, matching
    /// pairing.py's `_create_message`.
    private static func outer(_ build: (inout ProtoWriter) -> Void) -> Data {
        var w = ProtoWriter()
        w.varint(Field.protocolVersion, 2)
        w.varint(Field.status, statusOK)
        build(&w)
        return w.data
    }

    /// Options.Encoding { type: HEXADECIMAL, symbol_length: 6 } — the TV shows
    /// a 6-hex-character PIN.
    private static func encoding(_ w: inout ProtoWriter) {
        w.varint(1, encodingHexadecimal)
        w.varint(2, symbolLength)
    }

    static func pairingRequest(clientName: String) -> Data {
        outer { w in
            w.message(Field.pairingRequest) { r in
                r.string(1, serviceName)
                r.string(2, clientName)
            }
        }
    }

    static func options() -> Data {
        outer { w in
            w.message(Field.options) { o in
                o.message(1, encoding)   // input_encodings
                o.varint(3, roleInput)   // preferred_role
            }
        }
    }

    static func configuration() -> Data {
        outer { w in
            w.message(Field.configuration) { c in
                c.message(1, encoding)   // encoding
                c.varint(2, roleInput)   // client_role
            }
        }
    }

    static func secret(_ secret: Data) -> Data {
        outer { w in
            w.message(Field.secret) { s in
                s.bytes(1, secret)
            }
        }
    }

    struct Inbound {
        var status: UInt64 = 0
        var hasPairingRequestAck = false
        var hasOptions = false
        var hasConfigurationAck = false
        var hasSecretAck = false
    }

    static func parse(_ data: Data) throws -> Inbound {
        let reader = try ProtoReader(parsing: data)
        var msg = Inbound()
        msg.status = reader.varint(Field.status) ?? 0
        msg.hasPairingRequestAck = reader.has(Field.pairingRequestAck)
        msg.hasOptions = reader.has(Field.options)
        msg.hasConfigurationAck = reader.has(Field.configurationAck)
        msg.hasSecretAck = reader.has(Field.secretAck)
        return msg
    }
}

/// remotemessage.proto `RemoteMessage` — the remote protocol on port 6466.
/// Field numbers and enum values come from tronikos/androidtvremote2.
enum ATVRemoteMessage {

    /// Feature bits negotiated in RemoteConfigure.code1 (remote.py `Feature`).
    struct Features: OptionSet, Equatable {
        let rawValue: UInt64
        static let ping = Features(rawValue: 1 << 0)
        static let key = Features(rawValue: 1 << 1)
        static let ime = Features(rawValue: 1 << 2)
        static let voice = Features(rawValue: 1 << 3)
        static let power = Features(rawValue: 1 << 5)
        static let volume = Features(rawValue: 1 << 6)
        static let appLink = Features(rawValue: 1 << 9)

        /// IME is negotiated so the TV pushes the foreground app package
        /// (RemoteImeKeyInject) and accepts text entry (RemoteImeBatchEdit).
        static let requested: Features = [.ping, .key, .ime, .power, .volume, .appLink]

        /// Voice is opt-in: once negotiated, KEYCODE_SEARCH puts the TV into
        /// mic-listening mode, which breaks typed search.
        static let requestedWithVoice: Features = requested.union(.voice)

        static func requested(voice: Bool) -> Features {
            voice ? requestedWithVoice : requested
        }
    }

    enum Direction: UInt64 {
        case startLong = 1
        case endLong = 2
        case short = 3
    }

    // RemoteMessage field numbers.
    private enum Field {
        static let remoteConfigure = 1
        static let remoteSetActive = 2
        static let remoteError = 3
        static let remotePingRequest = 8
        static let remotePingResponse = 9
        static let remoteKeyInject = 10
        static let remoteImeKeyInject = 20
        static let remoteImeBatchEdit = 21
        static let remoteVoiceBegin = 30
        static let remoteVoicePayload = 31
        static let remoteVoiceEnd = 32
        static let remoteStart = 40
        static let remoteAppLinkLaunch = 90
    }

    /// Voice audio format the TV expects (RemoteVoicePayload comment + voice_stream.py):
    /// 16-bit PCM, mono, 8000 Hz. Chunks below `voiceChunkMinSize` are zero-padded;
    /// anything above `voiceChunkSize` is split, or the TV drops the connection.
    static let voiceSampleRate = 8000
    static let voiceChunkMinSize = 8 * 1024
    static let voiceChunkSize = 20 * 1024

    /// The reply half of the RemoteConfigure exchange. Identity strings match
    /// remote.py; the TV displays none of them but rejects an empty configure.
    static func configureReply(features: Features) -> Data {
        var w = ProtoWriter()
        w.message(Field.remoteConfigure) { c in
            // proto3 zero omission, matching python-protobuf byte-for-byte
            // even for a degenerate all-zero intersection.
            if features.rawValue != 0 { c.varint(1, features.rawValue) }  // code1
            c.message(2) { d in                 // device_info
                d.varint(3, 1)                  // unknown1
                d.string(4, "1")                // unknown2
                d.string(5, "atvremote")        // package_name
                d.string(6, "1.0.0")            // app_version
            }
        }
        return w.data
    }

    static func setActive(features: Features) -> Data {
        var w = ProtoWriter()
        w.message(Field.remoteSetActive) { s in
            // proto3 zero omission; the empty submessage still marks presence.
            if features.rawValue != 0 { s.varint(1, features.rawValue) }
        }
        return w.data
    }

    static func pingResponse(val1: UInt64) -> Data {
        var w = ProtoWriter()
        w.message(Field.remotePingResponse) { p in
            // proto3: zero scalars are omitted, only the submessage marks presence.
            if val1 != 0 { p.varint(1, val1) }
        }
        return w.data
    }

    static func keyInject(keyCode: Int32, direction: Direction = .short) -> Data {
        var w = ProtoWriter()
        w.message(Field.remoteKeyInject) { k in
            // Enum varints are int32 sign-extended to 10 bytes, so a negative
            // keycode must encode as two's complement, not trap.
            k.varint(1, UInt64(bitPattern: Int64(keyCode)))
            k.varint(2, direction.rawValue)
        }
        return w.data
    }

    static func appLinkLaunch(link: String) -> Data {
        var w = ProtoWriter()
        w.message(Field.remoteAppLinkLaunch) { a in
            a.string(1, link)
        }
        return w.data
    }

    /// Text entry via the IME (remote.py `send_text`): a single-insert batch
    /// edit carrying the caller's counters. `start`/`end` are `len - 1`, where
    /// the reference puts the cursor.
    static func imeBatchEdit(text: String, imeCounter: UInt64, fieldCounter: UInt64) -> Data {
        // Python `len(str)` counts Unicode scalars, not grapheme clusters.
        let cursor = UInt64(max(0, text.unicodeScalars.count - 1))
        var w = ProtoWriter()
        w.message(Field.remoteImeBatchEdit) { b in
            if imeCounter != 0 { b.varint(1, imeCounter) }
            if fieldCounter != 0 { b.varint(2, fieldCounter) }
            b.message(3) { edit in              // edit_info (repeated, one entry)
                edit.varint(1, 1)               // insert = 1
                edit.message(2) { obj in        // text_field_status: RemoteImeObject
                    if cursor != 0 { obj.varint(1, cursor) }  // start
                    if cursor != 0 { obj.varint(2, cursor) }  // end
                    obj.string(3, text)         // value
                }
            }
        }
        return w.data
    }

    static func voiceBegin(sessionId: UInt64) -> Data {
        var w = ProtoWriter()
        w.message(Field.remoteVoiceBegin) { v in v.varint(1, sessionId) }
        return w.data
    }

    static func voicePayload(sessionId: UInt64, samples: Data) -> Data {
        var w = ProtoWriter()
        w.message(Field.remoteVoicePayload) { v in
            v.varint(1, sessionId)
            v.bytes(2, samples)
        }
        return w.data
    }

    static func voiceEnd(sessionId: UInt64) -> Data {
        var w = ProtoWriter()
        w.message(Field.remoteVoiceEnd) { v in v.varint(1, sessionId) }
        return w.data
    }

    struct Inbound {
        /// RemoteConfigure.code1 — the features the TV supports.
        var configureFeatures: Features?
        var hasSetActive = false
        /// RemotePingRequest.val1, echoed back in the response.
        var pingVal1: UInt64?
        /// RemoteStart.started — the TV's power state. False arrives as an
        /// empty submessage because proto3 omits zero scalars.
        var started: Bool?
        var hasError = false
        /// RemoteImeKeyInject.app_info.app_package — the foreground app.
        /// nil when the message is absent; "" when present but empty (the app
        /// went away), which callers map to "no app".
        var currentApp: String?
        /// RemoteImeBatchEdit.{ime_counter, field_counter} — the TV pushes these
        /// when a text field is focused; text entry must echo them back.
        var imeCounter: UInt64?
        var imeFieldCounter: UInt64?
        /// RemoteVoiceBegin.session_id — the TV's answer to KEYCODE_SEARCH,
        /// authorizing an audio stream.
        var voiceBeginSessionId: UInt64?
    }

    static func parse(_ data: Data) throws -> Inbound {
        let reader = try ProtoReader(parsing: data)
        var msg = Inbound()
        if let configure = try reader.message(Field.remoteConfigure) {
            msg.configureFeatures = Features(rawValue: configure.varint(1) ?? 0)
        }
        msg.hasSetActive = reader.has(Field.remoteSetActive)
        if let ping = try reader.message(Field.remotePingRequest) {
            msg.pingVal1 = ping.varint(1) ?? 0
        }
        if let start = try reader.message(Field.remoteStart) {
            msg.started = (start.varint(1) ?? 0) != 0
        }
        if let imeKey = try reader.message(Field.remoteImeKeyInject),
           let appInfo = try imeKey.message(1) {
            // Raw package, "" included, so callers can tell "app closed"
            // (empty) from "no report" (field absent).
            msg.currentApp = try appInfo.string(12) ?? ""
        }
        if let batch = try reader.message(Field.remoteImeBatchEdit) {
            msg.imeCounter = batch.varint(1) ?? 0
            msg.imeFieldCounter = batch.varint(2) ?? 0
        }
        if let voice = try reader.message(Field.remoteVoiceBegin) {
            msg.voiceBeginSessionId = voice.varint(1) ?? 0
        }
        msg.hasError = reader.has(Field.remoteError)
        return msg
    }
}
