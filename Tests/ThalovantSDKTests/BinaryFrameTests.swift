import XCTest
@testable import ThalovantSDK

/// Binary frames, against the vectors and frames every SDK shares.
///
/// A hub answers `speak:synth` by rendering the utterance and sending the audio
/// back, so a client with no synthesiser of its own can still speak; a file
/// arrives the same way. The expectations are `binary-vectors.json` and the
/// frames themselves are `binary-frames.json` -- hivemind-bus-client's own
/// encoder output, so this is tested against the wire a hub actually puts out
/// rather than against a reading of the specification.
final class BinaryFrameTests: XCTestCase {
    private func fixture(_ name: String) throws -> JSONObject {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(JSONObject.self, from: Data(contentsOf: url))
    }

    private func cases(_ object: JSONObject, _ key: String = "cases") throws -> [JSONObject] {
        guard case .some(.array(let rows)) = object[key] else {
            XCTFail("no \(key)")
            return []
        }
        // Not compactMap: a row that is not an object would be dropped in
        // silence, and the suite would pass while testing fewer cases than the
        // file declares.
        return try rows.map { value in
            guard case .object(let row) = value else {
                XCTFail("\(key) contains a row that is not an object")
                throw ThalovantRuntimeError("malformed \(key) row")
            }
            return row
        }
    }

    private func string(_ object: JSONObject, _ key: String) -> String? {
        if case .some(.string(let value)) = object[key] { return value }
        return nil
    }

    func testThePayloadKindsAreTheOnesTheVectorsName() throws {
        let spec = try fixture("binary-vectors")
        guard case .some(.object(let named)) = spec["payload_kinds"] else {
            return XCTFail("no payload_kinds")
        }
        XCTAssertEqual(named.count, binaryPayloadKinds.count)
        for (wire, name) in named {
            XCTAssertEqual(binaryKindName(Int(wire) ?? -1), string(named, wire), "payload type \(wire)")
            _ = name
        }
    }

    func testAPayloadTypeNobodyNamedArrivesUnderItsNumber() throws {
        // Only 0-15 can travel: the wire field is four bits. The naming has to
        // hold for every number all the same -- it is the last thing between a
        // payload type nobody has named yet and a frame that disappears.
        let spec = try fixture("binary-vectors")
        guard case .some(.object(let unnamed)) = spec["unnamed_kind_names"] else {
            return XCTFail("no unnamed_kind_names")
        }
        for (wire, _) in unnamed {
            XCTAssertEqual(binaryKindName(Int(wire) ?? -1), string(unnamed, wire), "payload type \(wire)")
        }
    }

    func testTheReferenceEncodersFramesDecodeHere() throws {
        for row in try cases(try fixture("binary-frames")) {
            let name = string(row, "name") ?? "?"
            guard let raw = Data(base64Encoded: string(row, "frame") ?? "") else {
                return XCTFail("\(name): frame is not base64")
            }
            let message = try HiveWire.decodeBinaryFrame(raw)
            XCTAssertEqual(message.msgType, "bin", name)
            guard let binary = message.binary else { return XCTFail("\(name): no binary") }
            XCTAssertEqual(binary.kind, string(row, "expected_kind"), name)
            XCTAssertEqual(binary.data, Data(base64Encoded: string(row, "expected_payload") ?? ""),
                           "\(name): the clip did not survive the decode")
            if case .some(.object(let metadata)) = row["expected_metadata"] {
                for (key, want) in metadata {
                    XCTAssertEqual(binary.metadata[key], want, "\(name): metadata \(key)")
                }
            }
        }
    }

    func testABinarizedBusFrameIsStillText() throws {
        // Only BINARY carries bytes; every other type binarized on the wire is
        // JSON and has to keep decoding as it always did.
        let frames = try fixture("binary-frames")
        guard let raw = Data(base64Encoded: string(frames, "bus_frame") ?? "") else {
            return XCTFail("bus_frame is not base64")
        }
        let message = try HiveWire.decodeBinaryFrame(raw)
        XCTAssertEqual(message.msgType, "bus")
        XCTAssertNil(message.binary)
        XCTAssertEqual(message.payload["type"], .string("speak"))
    }

    func testEveryCaseTheVectorsDescribeDecodesAsItSays() throws {
        let frames = try cases(try fixture("binary-frames"))
        for row in try cases(try fixture("binary-vectors")) {
            let name = string(row, "name") ?? "?"
            guard let frame = frames.first(where: { string($0, "name") == name }),
                  let raw = Data(base64Encoded: string(frame, "frame") ?? "") else {
                return XCTFail("\(name): the vectors describe a case the frames do not carry")
            }
            guard let binary = try HiveWire.decodeBinaryFrame(raw).binary else {
                return XCTFail("\(name): no binary")
            }
            guard case .some(.object(let expected)) = row["expected"] else {
                return XCTFail("\(name): no expectation")
            }
            // Recorded before the assert, for the same reason as the carry.
            // Absent is already nil here, so nothing needs the translation the
            // Go recorder gives its empty strings.
            ConformanceRecord.record("binary-vectors.json", name, JSONValue.object([
                "kind": .string(binary.kind),
                "utterance": binary.utterance.map(JSONValue.string) ?? .null,
                "lang": binary.lang.map(JSONValue.string) ?? .null,
                "file_name": binary.fileName.map(JSONValue.string) ?? .null,
            ]))
            XCTAssertEqual(binary.kind, string(expected, "kind"), name)
            // An empty name is no name: rendering "" would put a blank filename
            // in front of somebody as though the hub had chosen it.
            XCTAssertEqual(binary.utterance, string(expected, "utterance"), "\(name): utterance")
            XCTAssertEqual(binary.lang, string(expected, "lang"), "\(name): lang")
            XCTAssertEqual(binary.fileName, string(expected, "file_name"), "\(name): file_name")
        }
    }

    func testEveryKindTheMeshVectorsDeclareHasACase() throws {
        // A declared kind with no case is a rule written down and never checked.
        let spec = try fixture("mesh-vectors")
        let covered = Set(try cases(spec).compactMap { string($0, "kind") })
        for key in ["kinds", "refused_kinds"] {
            guard case .some(.array(let declared)) = spec[key] else { continue }
            for value in declared {
                if case .string(let kind) = value {
                    XCTAssertTrue(covered.contains(kind), "\(kind) is declared with no case")
                }
            }
        }
    }

    func testOnlyTheMeshKindsAreSubscribable() throws {
        for row in try cases(try fixture("mesh-vectors")) {
            guard let kind = string(row, "kind"),
                  case .some(.object(let expected)) = row["expected"],
                  case .some(.bool(let accepted)) = expected["accepted"] else { continue }
            XCTAssertEqual(hiveKinds.contains(kind), accepted, kind)
        }
    }

    /// A zlib stream holding `data` in stored blocks: a real stream, without a
    /// compressor in the test target.
    private func zlibStored(_ data: Data) -> Data {
        var out = Data([0x78, 0x01])
        let bytes = [UInt8](data)
        var offset = 0
        repeat {
            let count = min(65_535, bytes.count - offset)
            let final: UInt8 = offset + count == bytes.count ? 1 : 0
            out.append(final)
            out.append(contentsOf: [UInt8(count & 0xff), UInt8(count >> 8)])
            out.append(contentsOf: [UInt8(~count & 0xff), UInt8((~count >> 8) & 0xff)])
            out.append(contentsOf: bytes[offset..<offset + count])
            offset += count
        } while offset < bytes.count
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        let adler = (b << 16) | a
        out.append(contentsOf: [UInt8(adler >> 24), UInt8((adler >> 16) & 0xff), UInt8((adler >> 8) & 0xff), UInt8(adler & 0xff)])
        return out
    }

    /// A binarized bus frame whose metadata and payload are compressed.
    private func compressedBusFrame(_ payload: Data) -> Data {
        let metadata = zlibStored(Data("{}".utf8))
        return Data([0x83, UInt8(metadata.count)]) + metadata + payload
    }

    func testACompressedPartIsCappedWhenItInflates() throws {
        let body = Data(#"{"type": "speak", "data": {"u": "xxxxxxxxxxxxxxxxxxxx"}, "context": {}}"#.utf8)
        XCTAssertEqual(body.count, 71)
        let stream = zlibStored(body)
        XCTAssertEqual(try inflateWireBytesOrThrow(stream, limit: 71), body, "exactly at the cap still inflates")
        XCTAssertThrowsError(try inflateWireBytesOrThrow(stream, limit: 70)) { error in
            XCTAssertTrue("\(error)".contains("size limit"), "\(error)")
        }
        XCTAssertEqual(wireInflationLimit, 32 * 1024 * 1024)
        let message = try HiveWire.decodeBinaryFrame(compressedBusFrame(stream))
        XCTAssertEqual(message.payload["type"], "speak")
    }

    func testAPartLargerThanOneInflationStepIsCappedExactly() throws {
        // Several steps of the fixed scratch buffer, and several stored blocks.
        let size = 3 * wireInflationChunk + 17
        let body = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let stream = zlibStored(body)
        XCTAssertEqual(try inflateWireBytesOrThrow(stream, limit: size), body)
        XCTAssertThrowsError(try inflateWireBytesOrThrow(stream, limit: size - 1)) {
            XCTAssertTrue("\($0)".contains("size limit"), "\($0)")
        }
        XCTAssertThrowsError(try inflateWireBytesOrThrow(stream, limit: wireInflationChunk)) {
            XCTAssertTrue("\($0)".contains("size limit"), "\($0)")
        }
        XCTAssertThrowsError(try inflateWireBytesOrThrow(Data(stream.dropLast(4)), limit: size)) {
            XCTAssertTrue("\($0)".contains("truncated"), "\($0)")
        }
    }

    func testATruncatedCompressedPartRefusesTheFrame() throws {
        let body = Data(#"{"type": "speak", "data": {}, "context": {}}"#.utf8)
        let truncated = zlibStored(body).dropLast(4)
        // Read as empty, it would pass for a message with nothing in it.
        XCTAssertThrowsError(try HiveWire.decodeBinaryFrame(compressedBusFrame(Data(truncated)))) { error in
            XCTAssertTrue("\(error)".contains("truncated"), "\(error)")
        }
        // The metadata too: a clip must not arrive stripped of it.
        let metadata = Data(zlibStored(Data(#"{"lang": "en-us"}"#.utf8)).dropLast(2))
        let frame = Data([0x83, UInt8(metadata.count)]) + metadata + zlibStored(body)
        XCTAssertThrowsError(try HiveWire.decodeBinaryFrame(frame))
    }

    func testAPartThatInflatesToSomethingOtherThanAnObjectRefusesTheFrame() throws {
        for text in ["not json", "[1, 2]", "\"speak\""] {
            XCTAssertThrowsError(try HiveWire.decodeBinaryFrame(compressedBusFrame(zlibStored(Data(text.utf8)))), text) {
                XCTAssertTrue("\($0)".contains("not a JSON object"), "\($0)")
            }
        }
    }
}
