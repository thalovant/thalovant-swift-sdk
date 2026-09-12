import Foundation
import XCTest
@testable import ThalovantSDK

final class PythonParityTests: XCTestCase {
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
        XCTAssertEqual(intent.examples(lang: "en-us",limit: 2,speakable: true),["x","a complete sentence"])
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
