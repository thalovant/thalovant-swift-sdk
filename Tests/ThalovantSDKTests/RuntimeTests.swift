import Foundation
import XCTest
@testable import ThalovantSDK
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private final class RuntimeFake: HiveMindBusTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var online = false
    private var buses: [UUID: (JSONObject) -> Void] = [:]
    private var frames: [UUID: (HiveMessage) -> Void] = [:]
    private var emissions: [ThalovantEvent] = []
    private var sentFrames: [HiveMessage] = []
    var queryAnswer: ((HiveMessage) -> Void)?
    var connected: Bool { lock.locked { online } }
    var handshakeComplete: Bool { connected }
    var supportsHiveMessages: Bool { true }
    var busCount: Int { lock.locked { buses.count } }
    var frameCount: Int { lock.locked { frames.count } }
    var emitted: [ThalovantEvent] { lock.locked { emissions } }
    var sent: [HiveMessage] { lock.locked { sentFrames } }
    func connect(timeout: TimeInterval) async throws { lock.locked { online = true } }
    func disconnect() async { lock.locked { online = false } }
    func addBusHandler(_ handler: @escaping (JSONObject) -> Void) -> UUID {
        let id = UUID(); lock.locked { buses[id] = handler }; return id
    }
    func removeBusHandler(_ id: UUID) { _ = lock.locked { buses.removeValue(forKey: id) } }
    func addMessageHandler(_ handler: @escaping (HiveMessage) -> Void) -> UUID {
        let id = UUID(); lock.locked { frames[id] = handler }; return id
    }
    func removeMessageHandler(_ id: UUID) { _ = lock.locked { frames.removeValue(forKey: id) } }
    func emitBus(type: String, data: JSONObject, context: JSONObject) async throws {
        lock.locked { emissions.append(ThalovantEvent(name: type, data: data, context: context)) }
    }
    func sendHiveFrame(_ message: HiveMessage) async throws {
        lock.locked { sentFrames.append(message) }; queryAnswer?(message)
    }
    func deliver(_ name: String, text: String = "", request: String? = nil, session: String? = nil) {
        let context = contextWithCorrelation([:], sessionId: session, requestId: request)
        let payload: JSONObject = ["type": .string(name), "data": .object(["utterance": .string(text)]), "context": .object(context)]
        for handler in lock.locked({ Array(buses.values) }) { handler(payload) }
    }
    func reply(_ id: String, _ name: String, _ text: String = "", cascade: Bool = false) {
        let bus = HiveMessage(msgType: "bus", payload: ["type": .string(name), "data": .object(["utterance": .string(text)])])
        let message = HiveMessage(msgType: cascade ? "cascade" : "query", payload: encodedJSONObject(bus), metadata: ["query_id": .string(id)])
        for handler in lock.locked({ Array(frames.values) }) { handler(message) }
    }
}

private final class HangingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var didStart = false, didStop = false
    static var started: Bool { lock.locked { didStart } }
    static var stopped: Bool { lock.locked { didStop } }
    static func reset() { lock.locked { didStart = false; didStop = false } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.locked { Self.didStart = true } }
    override func stopLoading() { Self.lock.locked { Self.didStop = true } }
}

final class RuntimeTests: XCTestCase {
    private func client(_ fake: RuntimeFake) throws -> ThalovantClient {
        var identity = try ThalovantJSON.decodeObject(Fixtures.clientIdentify)
        identity["default_master"] = .string("wss://hub.example")
        return ThalovantClient(identity: try ThalovantIdentity(json: identity),
            transport: fake, replySettle: 0, emptyReplyWait: 0)
    }
    private func until(_ predicate: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 2
        while !predicate() {
            if ProcessInfo.processInfo.systemUptime >= end { throw ThalovantTimeoutError("Test barrier did not settle.") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    func testQueryScopesNestedCascadeAndDeduplicatesSpeech() async throws {
        let fake = RuntimeFake(), sdk = try client(fake)
        fake.queryAnswer = { _ in
            fake.reply("other", "speak", "wrong")
            fake.reply("q", "speak", " first   part ")
            fake.reply("q", "speak", "first part")
            fake.reply("q", "ovos.utterance.speak", "second", cascade: true)
            fake.reply("q", "hive.query.complete", cascade: true)
        }
        let reply = try await sdk.query("hello", sessionId: "s", requestId: "r", queryId: "q")
        XCTAssertEqual(reply.text, "first part second"); XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.sessionId, "s"); XCTAssertEqual(reply.requestId, "r")
        let frame = try XCTUnwrap(fake.sent.first)
        XCTAssertEqual(frame.msgType, "query")
        XCTAssertEqual(frame.payload["payload"]?.objectValue?["context"]?.objectValue?["request_id"], .string("r"))
        XCTAssertEqual(fake.frameCount, 0)
    }
    func testQueryFailureTimeoutCancellationAndDisconnectCleanHandlers() async throws {
        let fake = RuntimeFake(), sdk = try client(fake)
        fake.queryAnswer = { _ in fake.reply("q", ThalovantEvents.policyDenied) }
        do { _ = try await sdk.query("test", queryId: "q"); XCTFail("Expected failure") }
        catch is ThalovantRuntimeError {}
        XCTAssertEqual(fake.frameCount, 0)
        fake.queryAnswer = nil
        do { _ = try await sdk.query("test", timeout: 0.02); XCTFail("Expected timeout") }
        catch is ThalovantTimeoutError {}
        let cancelled = Task { try await sdk.query("test") }
        try await until { fake.frameCount == 1 && fake.connected }; cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(fake.frameCount, 0)
        let priorSent = fake.sent.count
        let lost = Task { try await sdk.query("test") }
        try await until { fake.sent.count > priorSent }
        await fake.disconnect()
        do { _ = try await lost.value; XCTFail("Expected disconnect") } catch is ThalovantConnectionError {}
        XCTAssertEqual(fake.frameCount, 0)
    }
    func testWaitFiltersRequestBeforeRewrittenSessionAndCleansHandlers() async throws {
        let fake = RuntimeFake(), sdk = try client(fake)
        let wait = Task { try await sdk.waitForEvent("speak", sessionId: "mine", requestId: "r") { $0.text == "yes" } }
        try await until { fake.busCount == 1 && fake.connected }
        fake.deliver("speak", text: "yes", request: "wrong", session: "mine")
        fake.deliver("speak", text: "no", request: "r", session: "rewritten")
        fake.deliver("speak", text: "yes", request: "r", session: "rewritten")
        let answer = try await wait.value; XCTAssertEqual(answer.text, "yes"); XCTAssertEqual(fake.busCount, 0)
        do { _ = try await sdk.waitForEvent("never", timeout: 0.02); XCTFail("Expected timeout") }
        catch is ThalovantTimeoutError {}
        let cancelled = Task { try await sdk.waitForEvent("never") }
        try await until { fake.busCount == 1 }; cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        XCTAssertEqual(fake.busCount, 0)
    }
    func testStreamStopsAtCountTimeoutAndTransportLoss() async throws {
        let fake = RuntimeFake(), sdk = try client(fake)
        let stream = sdk.listen("speak", maxEvents: 2)
        let reader = Task { () throws -> [ThalovantEvent] in
            var events: [ThalovantEvent] = []; for try await event in stream { events.append(event) }; return events
        }
        try await until { fake.connected }
        fake.deliver("other"); fake.deliver("speak"); fake.deliver("speak")
        let events = try await reader.value; XCTAssertEqual(events.count, 2); XCTAssertEqual(fake.busCount, 0)
        for try await _ in sdk.listen("never", timeout: 0.02) { XCTFail("Unexpected event") }
        XCTAssertEqual(fake.busCount, 0)
        let lostStream = sdk.listen("never")
        try await Task.sleep(nanoseconds: 10_000_000)
        await fake.disconnect()
        do { for try await _ in lostStream { XCTFail("Unexpected event") }; XCTFail("Expected loss") }
        catch is ThalovantConnectionError {}
        XCTAssertEqual(fake.busCount, 0)
    }
    func testConversationSharesSessionAndPreservesExactCodeMetadata() async throws {
        let fake = RuntimeFake(), sdk = try client(fake)
        let original: JSONObject = ["input": .object(["custom": .string("keep")])]
        let scope = sdk.conversation(sessionId: "stable", lang: "fr-fr", context: original)
        try await scope.sendAction(" launch ", title: "Go")
        try await scope.sendCode(" 001-09 ", label: "Ticket")
        let action = fake.emitted[0], code = fake.emitted[1]
        XCTAssertEqual(action.sessionId, "stable"); XCTAssertEqual(code.sessionId, action.sessionId)
        XCTAssertNotEqual(action.requestId, code.requestId)
        XCTAssertEqual(action.utterances, ["launch"])
        XCTAssertEqual(action.context["input"]?.objectValue?["custom"], .string("keep"))
        XCTAssertEqual(code.utterances, ["001-09"])
        XCTAssertEqual(code.data["input"]?.objectValue?["exact"], .bool(true))
        XCTAssertEqual(code.data["lang"], .string("fr-fr"))
        XCTAssertNil(original["input"]?.objectValue?["kind"])
        let health = try await sdk.healthcheck(), doctor = try await sdk.doctor()
        XCTAssertTrue(health.ok); XCTAssertTrue(doctor.ok)
        let info = try await sdk.connectWithInfo(); XCTAssertEqual(info.phase, "ready")
    }
    func testHTTPCancellationCancelsUnderlyingURLSessionTask() async throws {
        HangingURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [HangingURLProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let sdk = ThalovantControlPlane(session: session)
        let request = Task { try await sdk.listPublicHubs() }
        try await until { HangingURLProtocol.started }; request.cancel()
        do { _ = try await request.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        try await until { HangingURLProtocol.stopped }
        let cancelled = Task { () throws -> JSONObject in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await sdk.listPublicHubs()
        }
        do { _ = try await cancelled.value; XCTFail("Expected pre-cancellation") } catch is CancellationError {}
    }
}
