import Foundation
import CZlibShim

/// Payload types a BINARY frame can carry, by their wire number.
///
/// A hub answers `speak:synth` by rendering the utterance and sending one of
/// these back, so a client with no synthesiser of its own can still speak; a
/// file arrives the same way. The wire numbers the type, this names it.
public let binaryPayloadKinds: [Int: String] = [
    1: "raw_audio",
    2: "numpy_image",
    3: "file",
    4: "stt_transcribe",
    5: "stt_handle",
    6: "tts_audio",
]

/// Names a payload type. One nobody has named still arrives, under its number,
/// rather than being dropped.
public func binaryKindName(_ wireNumber: Int) -> String {
    binaryPayloadKinds[wireNumber] ?? "binary:\(wireNumber)"
}

/// A binary frame: the bytes a hub sent, and what it said about them.
public struct ThalovantBinary: Equatable, Sendable {
    /// `tts_audio`, `file`, ... or `binary:<wire number>` for an unnamed type.
    public let kind: String
    /// The payload itself. Never parsed, never decompressed.
    public let data: Data
    /// What the hub sent beside it.
    public let metadata: JSONObject
    /// What was said, when this is rendered speech.
    public let utterance: String?
    /// The language it was said in.
    public let lang: String?
    /// The name a file arrived under. An empty name is no name.
    public let fileName: String?

    /// Reads a hub's metadata into the shape above.
    ///
    /// A value the hub did not send and one it sent empty both read as `nil`:
    /// rendering `""` as a filename would put a blank name in front of somebody
    /// as though the hub had chosen it.
    public init(kind: String, data: Data, metadata: JSONObject) {
        self.kind = kind
        self.data = data
        self.metadata = metadata
        func text(_ key: String) -> String? {
            guard case .some(.string(let value)) = metadata[key], !value.isEmpty else { return nil }
            return value
        }
        self.utterance = text("utterance")
        self.lang = text("lang")
        self.fileName = text("file_name")
    }
}

/// Reads WIRE-1 frames a bit at a time.
///
/// The layout is leading zero padding, a single `1` bit, one bit saying whether
/// a version follows, the version if so, five bits of message type, one bit of
/// compression, eight bits of metadata length, that many metadata bytes, and
/// then -- for BINARY alone -- four bits naming the payload type before the
/// clip itself. The padding goes on the front, so the clip starts
/// bit-misaligned and cannot be sliced out at a byte boundary.
struct HiveBitReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    mutating func skipLeftPadding() throws {
        while offset < bytes.count * 8 {
            if try readBit() == 1 { return }
        }
        throw ThalovantConnectionError("HiveMind binary frame is all padding.")
    }

    mutating func readBit() throws -> Int {
        guard offset < bytes.count * 8 else {
            throw ThalovantConnectionError("Unexpected end of HiveMind binary frame.")
        }
        let bit = (Int(bytes[offset / 8]) >> (7 - (offset % 8))) & 1
        offset += 1
        return bit
    }

    mutating func readUInt(_ width: Int) throws -> Int {
        var value = 0
        for _ in 0..<width { value = (value << 1) | (try readBit()) }
        return value
    }

    mutating func readBytes(_ count: Int) throws -> Data {
        var out = Data(capacity: count)
        for _ in 0..<count { out.append(UInt8(try readUInt(8))) }
        return out
    }

    mutating func readRemainingBytes() throws -> Data {
        var out = Data()
        while bytes.count * 8 - offset >= 8 { out.append(UInt8(try readUInt(8))) }
        return out
    }
}

/// WIRE-1 message-type codes.
let hiveTypeCodes: [Int: String] = [
    0: "shake", 1: "bus", 2: "shared_bus", 3: "broadcast", 4: "propagate",
    5: "escalate", 6: "hello", 7: "query", 8: "cascade", 9: "ping",
    10: "rendezvous", 11: "3rdparty", 12: "bin",
]

extension HiveWire {
    /// Decodes a WIRE-1 binary frame.
    ///
    /// A BINARY frame does not carry JSON: four bits name the payload type and
    /// everything after them is the clip, raw and never inflated. Every other
    /// type binarized on the wire is still JSON and decodes as it always did.
    public static func decodeBinaryFrame(_ data: Data) throws -> HiveMessage {
        var reader = HiveBitReader(data)
        try reader.skipLeftPadding()
        if try reader.readBit() == 1 {
            let version = try reader.readUInt(8)
            if version > 1 {
                throw ThalovantConnectionError("Unsupported HiveMind binary frame version: \(version).")
            }
        }
        let typeCode = try reader.readUInt(5)
        let compressed = try reader.readBit() == 1
        let metadataLength = try reader.readUInt(8)
        let metadataBytes = try reader.readBytes(metadataLength)
        let msgType = hiveTypeCodes[typeCode] ?? "3rdparty"
        let metadata = decodeWireObject(metadataBytes, compressed: compressed)
        if msgType == "bin" {
            let kind = try reader.readUInt(4)
            var message = HiveMessage(msgType: msgType, payload: [:], metadata: metadata)
            message.binary = ThalovantBinary(
                kind: binaryKindName(kind),
                data: try reader.readRemainingBytes(),
                metadata: metadata
            )
            return message
        }
        let payload = decodeWireObject(try reader.readRemainingBytes(), compressed: compressed)
        return HiveMessage(msgType: msgType, payload: payload, metadata: metadata)
    }

    private static func decodeWireObject(_ bytes: Data, compressed: Bool) -> JSONObject {
        let raw = compressed ? (inflateWireBytes(bytes) ?? bytes) : bytes
        guard !raw.isEmpty, let text = String(data: raw, encoding: .utf8),
              let object = try? ThalovantJSON.decodeObject(text) else { return [:] }
        return object
    }
}


/// Inflates a zlib stream. `nil` when the bytes are not one.
///
/// The encoder chooses per frame whether to compress the metadata -- whichever
/// of the two is shorter -- so a hub really does send both, and a frame whose
/// metadata cannot be read arrives with no language and no filename beside its
/// audio. The clip itself is never compressed, whatever the flag says.
func inflateWireBytes(_ data: Data) -> Data? {
    if data.isEmpty { return data }
    var stream = z_stream()
    guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
        return nil
    }
    defer { inflateEnd(&stream) }
    var input = [UInt8](data)
    var output = Data()
    var buffer = [UInt8](repeating: 0, count: max(1024, data.count * 4))
    var status: Int32 = Z_OK
    input.withUnsafeMutableBufferPointer { source in
        stream.next_in = source.baseAddress
        stream.avail_in = uInt(source.count)
        repeat {
            let produced: Int = buffer.withUnsafeMutableBufferPointer { sink -> Int in
                stream.next_out = sink.baseAddress
                stream.avail_out = uInt(sink.count)
                status = inflate(&stream, Z_NO_FLUSH)
                return sink.count - Int(stream.avail_out)
            }
            if produced > 0 { output.append(contentsOf: buffer[0..<produced]) }
        } while status == Z_OK
    }
    return status == Z_STREAM_END ? output : nil
}
