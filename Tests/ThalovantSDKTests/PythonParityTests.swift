import Foundation
import XCTest
@testable import ThalovantSDK

final class PythonParityTests: XCTestCase {
    func testConfigNumbersRejectLossyCallerValuesBeforeIO() async throws {
        for value in [Double.nan, Double.infinity, -Double.infinity, 1e25] {
            for inPersonas in [false, true] {
                StubURLProtocol.reset()
                let api = ThalovantControlPlane(apiURL: "https://api.example.com", accessToken: "test", session: StubURLProtocol.makeSession())
                let payload: JSONObject = ["nested": .array([.number(value)])]
                do {
                    _ = try await api.updateRuntimeGroupConfig("x", config: inPersonas ? [:] : payload, personas: inPersonas ? payload : nil)
                    XCTFail("Expected numeric validation failure")
                } catch let error as ThalovantApiError { XCTAssertTrue(error.message.contains("floating-point")) }
                XCTAssertTrue(StubURLProtocol.requests.isEmpty)
            }
        }
    }

    func testConfigNumbersRejectStoredIntegerOverflowBeforeWriting() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.init(body: "{\"config\":{\"id\":18446744073709551617},\"revision\":\"\(String(repeating: "a", count: 64))\"}"))
        StubURLProtocol.enqueue(.init(body: "{}"))
        let api = ThalovantControlPlane(apiURL: "https://api.example.com", accessToken: "test", session: StubURLProtocol.makeSession())
        do {
            _ = try await api.updateRuntimeGroupConfig("x", config: ["lang": .string("fr")])
            XCTFail("Expected numeric validation failure")
        } catch let error as ThalovantApiError { XCTAssertTrue(error.message.contains("floating-point")) }
        XCTAssertEqual(StubURLProtocol.requests.map { $0.method }, ["GET"])
    }

    func testConfigNumbersPreserveNativeIntegersExactly() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.init(body: "{\"config\":{\"id\":9223372036854775807},\"revision\":\"\(String(repeating: "a", count: 64))\"}"))
        StubURLProtocol.enqueue(.init(body: "{}"))
        let api = ThalovantControlPlane(apiURL: "https://api.example.com", accessToken: "test", session: StubURLProtocol.makeSession())
        _ = try await api.updateRuntimeGroupConfig("x", config: ["min": .integer(Int.min)])
        let body = try StubURLProtocol.requests[1].bodyObject()!
        XCTAssertEqual(body["config"]?["id"], .integer(Int.max))
        XCTAssertEqual(body["config"]?["min"], .integer(Int.min))
    }

    func testRequestHintsAndLocationPreserveCaller() {
        let base: JSONObject = ["session": .object(["pipeline": .array([.string("old")]),"session_id": .string("kept")])]
        let location = buildLocation(city: " Montréal ",country: " ca ",latitude: 45.5,longitude: -73.5)!
        let result = requestContext(base,sttLang: " fr ",pipeline: [" ","intent"],location: location)!
        XCTAssertEqual(result["stt_lang"],.string("fr"));XCTAssertEqual(location["country_code"],.string("CA"))
        XCTAssertEqual(base["session"]?["pipeline"],.array([.string("old")]))
        XCTAssertNil(requestContext());XCTAssertNil(buildLocation())
        for (lat,lon) in [(0.0,0.0),(91.0,0.0),(0.0,181.0),(Double.nan,1.0)] { XCTAssertNil(buildLocation(city: "Toronto",latitude: lat,longitude: lon)?["coordinate"]) }
    }
    func testSpeakableExamplesPreserveSourcePriority() {
        XCTAssertEqual(speakable("did i (already |)ask (about|for|to|) {thing}"),"did i ask about thing")
        let intent = HubIntent(skillId: "x",name: "x",engine: "padatious",phrases: ["en-us":["{x}","a complete sentence","[please]","(x|y)","x"]])
        XCTAssertEqual(intent.examples(lang: "en-us",limit: 2,speakable: true),["a complete sentence","x"])
    }
    /// What `speakable` did before it was one pass: take the innermost pair
    /// out and start again, a full scan per level of nesting.
    private func speakableByRescanning(_ pattern: String) -> String {
        func innermost(_ text: String, _ open: Character, _ close: Character, _ resolve: (String) -> String) -> String? {
            let chars = Array(text)
            var lastOpen: Int?
            for (index, char) in chars.enumerated() {
                if char == open { lastOpen = index }
                if char == close, let start = lastOpen {
                    return String(chars[..<start]) + resolve(String(chars[(start + 1)..<index])) + String(chars[(index + 1)...])
                }
            }
            return nil
        }
        var text = pattern
        while let next = innermost(text, "[", "]", { _ in "" }) { text = next }
        while let next = innermost(text, "(", ")", { inside in
            let options = inside.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let real = options.filter { !$0.isEmpty }
            return real.count < options.count && real.count <= 1 ? "" : real.first ?? ""
        }) { text = next }
        return speakable(text)
    }

    func testSpeakableIsLinearAndStillTheSameRule() {
        // Patterns come from hubs: nested sixteen thousand deep, around sixteen
        // thousand letters, is one pass -- not one per level, and not the
        // letters copied again at every level.
        let depth = 16_000
        let deep = String(repeating: "(a|", count: depth) + "b" + String(repeating: ")", count: depth)
        let wide = String(repeating: "(", count: depth) + String(repeating: "x", count: depth)
            + String(repeating: ")", count: depth)
        let optional = String(repeating: "[x ", count: depth) + String(repeating: "]", count: depth) + "stay"
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(speakable(deep), "a")
        XCTAssertEqual(speakable(wide), String(repeating: "x", count: depth))
        XCTAssertEqual(speakable(optional), "stay")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
        XCTAssertEqual(speakable("mute it [for a (second|bit)] now"), "mute it now")
        XCTAssertEqual(speakable("a ] b [ c ( d"), "a ] b [ c ( d")
        XCTAssertEqual(speakable("[a [b] c"), "[a c")
        XCTAssertEqual(speakable("( (a|) b) c"), "b c")
        XCTAssertEqual(speakable("x (a|(b|c)|) y ( d | e"), "x a y ( d | e")
        // The same answers as rescanning, on random patterns.
        var generator = SystemRandomNumberGenerator()
        let alphabet: [Character] = ["(", ")", "[", "]", "|", " ", "\t", "a", "b", ",", "{", "}", "x", "_"]
        for _ in 0..<50_000 {
            let pattern = String((0..<Int.random(in: 0...24, using: &generator)).map { _ in
                alphabet.randomElement(using: &generator)!
            })
            XCTAssertEqual(speakable(pattern), speakableByRescanning(pattern), pattern)
        }
    }
    func testEmbeddedAudioIsStrictBoundedAndCollected() throws {
        XCTAssertEqual(try ThalovantEvent(name: ThalovantEvents.audioQueue,data: ["binary_data":.string(" \t")]).audioBytes(),Data())
        XCTAssertThrowsError(try ThalovantEvent(name: ThalovantEvents.audioQueue,data: ["binary_data":.string("00 ")]).audioBytes(maxBytes:1))
        let context: JSONObject = ["request_id":.string("r")]
        let event = ThalovantEvent(name: ThalovantEvents.audioQueue,data: ["binary_data":.string("00 ff\n10"),"lang":.string("fr")],context: context)
        XCTAssertEqual(try event.audioBytes(),Data([0,255,16]));XCTAssertEqual(event.lang,"fr")
        for value in ["","0","0 0","gg","https://example.com","00\u{a0}ff"] { XCTAssertThrowsError(try ThalovantEvent(name: ThalovantEvents.audioQueue,data: ["binary_data":.string(value)]).audioBytes()) }
        let state = AskState();state.process(event,requestId: "r")
        let clip=String(repeating:"00",count:maxAudioClipBytes)
        for _ in 0..<4 { state.process(ThalovantEvent(name:ThalovantEvents.audioQueue,data:["binary_data":.string(clip)],context:context),requestId:"r") }
        state.process(ThalovantEvent(name:ThalovantEvents.audioQueue,data:["binary_data":.string(clip+"00")],context:context),requestId:"r")
        XCTAssertEqual(state.snapshot().droppedMedia,2);XCTAssertEqual(state.snapshot().events.count,4)
        XCTAssertFalse(state.replyGate.isOpen)
    }
    func testConfigConflictsRereadAndPreserveConcurrentKeys() async throws {
        StubURLProtocol.reset()
        let api=ThalovantControlPlane(apiURL:"https://api.example.com",accessToken:"test",session:StubURLProtocol.makeSession())
        let a=String(repeating:"a",count:64),b=String(repeating:"b",count:64)
        StubURLProtocol.enqueue(.init(body:"{\"config\":{\"nested\":{\"original\":true}},\"revision\":\"\(a)\"}"))
        StubURLProtocol.enqueue(.init(status:412,body:"{}"))
        StubURLProtocol.enqueue(.init(body:"{\"config\":{\"nested\":{\"original\":true,\"concurrent\":true}},\"revision\":\"\(b)\"}"))
        StubURLProtocol.enqueue(.init(body:"{}"))
        _ = try await api.updateRuntimeGroupConfig("x/y",config:["nested":.object(["caller":.bool(true)]),"array":.array([.integer(1)])],personas:[:])
        let requests=StubURLProtocol.requests
        XCTAssertEqual(requests.map{$0.method},["GET","PUT","GET","PUT"])
        let body=try requests[3].bodyObject()!
        XCTAssertEqual(body["config"]?["nested"],.object(["original":.bool(true),"concurrent":.bool(true),"caller":.bool(true)]))
        XCTAssertEqual(body["expected_revision"],.string(b));XCTAssertEqual(body["personas"],.object([:]))
    }
    func testConfigFailsClosedAndRetriesOnlyPreconditions() async throws {
        for status in [400,401,403,405,409,412,429,500] {
            StubURLProtocol.reset()
            let api=ThalovantControlPlane(apiURL:"https://api.example.com",accessToken:"test",session:StubURLProtocol.makeSession())
            let attempts=status==412 ? 3 : 1
            for _ in 0..<attempts {
                StubURLProtocol.enqueue(.init(body:"{\"config\":{},\"revision\":\"\(String(repeating:"a",count:64))\"}"))
                StubURLProtocol.enqueue(.init(status:status,body:"{}"))
            }
            do { _ = try await api.updateRuntimeGroupConfig("x",config:[:]);XCTFail("expected failure") }
            catch let error as ThalovantApiError { XCTAssertEqual(error.statusCode,status) }
            XCTAssertEqual(StubURLProtocol.requests.count,attempts*2)
        }
        for body in [#"{"config":{}}"#,#"{"config":{},"revision":"bad"}"#,"{\"config\":[],\"revision\":\"\(String(repeating:"a",count:64))\"}"] {
            StubURLProtocol.reset();StubURLProtocol.enqueue(.init(body:body))
            let api=ThalovantControlPlane(apiURL:"https://api.example.com",accessToken:"test",session:StubURLProtocol.makeSession())
            do { _ = try await api.updateRuntimeGroupConfig("x",config:[:]);XCTFail("expected failure") } catch is ThalovantApiError {}
            XCTAssertEqual(StubURLProtocol.requests.count,1)
        }
    }
}
