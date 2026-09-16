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
        return rows.compactMap { if case .object(let row) = $0 { return row } else { return nil } }
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
}
