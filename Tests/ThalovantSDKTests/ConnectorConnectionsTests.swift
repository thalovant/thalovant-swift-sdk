import Foundation
import XCTest

@testable import ThalovantSDK

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Answers each request with the next scripted response, headers included, and
/// records what was sent.
final class ConnectorStub: URLProtocol {
    struct Reply {
        var status = 200
        var body: String
        var headers: [String: String] = [:]
    }

    private static let lock = NSLock()
    private static var replies: [Reply] = []
    private static var sentBodies: [Data] = []
    private static var sentCount = 0

    static func serve(_ reply: Reply) {
        lock.lock()
        replies = [reply]
        sentBodies = []
        sentCount = 0
        lock.unlock()
    }

    static var count: Int { lock.lock(); defer { lock.unlock() }; return sentCount }
    static var lastBody: JSONObject? {
        lock.lock(); defer { lock.unlock() }
        return sentBodies.last.flatMap { try? ThalovantJSON.decodeObject($0) }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectorStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            stream.close()
            data = collected
        }
        Self.lock.lock()
        Self.sentCount += 1
        if let data { Self.sentBodies.append(data) }
        let reply = Self.replies.first ?? Reply(body: "{}")
        Self.lock.unlock()
        var headers = reply.headers
        headers["Content-Type"] = "application/json"
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Home bridges (`connection_type: connector`) and the refusals that came with
/// them (thalovant-api #521). No shared vectors: these are this port's own
/// cases, the same as the Python reference's `test_connector_connections.py`.
/// Each also holds for an API that does not have the behaviour yet.
final class ConnectorConnectionsTests: XCTestCase {
    private let hub: JSONObject = [
        "id": .string("hub-1"), "name": .string("Home"), "domain": .string("home.example.com"),
        "data_plane_endpoints": .object(["wss": .string("wss://home.example.com/ws")]),
    ]

    private var api: ThalovantControlPlane!

    override func setUp() {
        super.setUp()
        api = ThalovantControlPlane(
            apiURL: "https://api.example.com", accessToken: "t", session: ConnectorStub.session())
    }

    private func created(_ type: String, extra: String = "", identify: Bool = true) -> String {
        let identity = identify
            ? #","initial_identify":{"password":"platform-password","access_key":"platform-key","site_id":"bridge","default_port":443,"default_master":"wss://home.example.com"}"#
            : ""
        return #"{"id":"client-1","name":"Bridge","hub_id":"hub-1","spec":{"version":"1","connection_type":"\#(type)"},"etag":"e1"\#(identity)\#(extra)}"#
    }

    private func create(
        _ type: String? = nil, spec: JSONObject? = nil, key: String? = nil
    ) async throws -> BootstrapIdentityResult {
        try await api.createClientIdentity(
            hub: hub,
            options: CreateClientIdentityOptions(name: "Bridge", spec: spec, idempotencyKey: key, connectionType: type))
    }

    private func refusal(_ status: Int, _ code: String, _ extra: String = "") -> ConnectorStub.Reply {
        .init(status: status, body: #"{"detail":"refused","code":"\#(code)"\#(extra)}"#)
    }

    private func refused(_ type: String? = nil) async -> ThalovantApiError? {
        do {
            _ = try await create(type)
            return nil
        } catch {
            return error as? ThalovantApiError
        }
    }

    func testTheKindConstantsAreTheWireValues() {
        XCTAssertEqual(connectorConnectionType, "connector")
        XCTAssertEqual(homeAssistantConnectionType, "home_assistant")
    }

    func testABridgeIsCreatedWithItsConnectorListAndThePlatformsCredentials() async throws {
        let serves = #""serves":{"devices":[{"id":"d1","name":"Kitchen","connection_type":"voice_satellite","active":true}],"count":1,"warning":null}"#
        ConnectorStub.serve(.init(status: 201, body: created("connector", extra: "," + serves)))
        let result = try await create(
            connectorConnectionType, spec: ["connectors": .array([.string("music_assistant")])])
        let spec = try XCTUnwrap(ConnectorStub.lastBody?["spec"]?.objectValue)
        XCTAssertEqual(spec["connection_type"]?.stringValue, "connector")
        XCTAssertEqual(spec["connectors"]?.arrayValue?.first?.stringValue, "music_assistant")
        // The answer's credentials are the connection's; the ones minted locally are not.
        XCTAssertEqual(result.identity.accessKey, "platform-key")
        XCTAssertEqual(result.identity.password, "platform-password")
        XCTAssertEqual(result.connectionType, "connector")
        XCTAssertFalse(result.replayed)
        XCTAssertEqual(result.serves?["count"]?.intValue, 1)
        XCTAssertEqual(result.serves?["devices"]?.arrayValue?.count, 1)
        XCTAssertNil(result.servesWarning)
    }

    func testALinkThatServesNobodySaysSo() async throws {
        let serves = #""serves":{"devices":[],"count":0,"warning":"No device of your account is on this hub."}"#
        ConnectorStub.serve(.init(status: 201, body: created("home_assistant", extra: "," + serves)))
        let result = try await create("home_assistant")
        XCTAssertEqual(result.servesWarning, "No device of your account is on this hub.")
    }

    func testAnApiWithoutServesStillWorks() async throws {
        ConnectorStub.serve(.init(status: 201, body: created("connector")))
        let result = try await create("connector")
        XCTAssertNil(result.serves)
        XCTAssertNil(result.servesWarning)
    }

    private func assertReplay(_ reply: ConnectorStub.Reply, file: StaticString = #filePath, line: UInt = #line) async {
        ConnectorStub.serve(reply)
        do {
            _ = try await create("connector", key: "k1")
            XCTFail("a replay must not return an identity", file: file, line: line)
        } catch let error as ThalovantCredentialsNotReplayedError {
            XCTAssertEqual(error.clientId, "client-1", file: file, line: line)
            XCTAssertNil(error.client["initial_identify"], file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    func testAReplayedCreateNeverHandsBackAnIdentityTheSdkMadeUp() async {
        await assertReplay(.init(
            status: 201, body: created("connector", identify: false), headers: ["Idempotent-Replayed": "true"]))
        let marker = #","replay":{"code":"idempotent_replay","credentials_included":false,"detail":"x"}"#
        await assertReplay(.init(status: 201, body: created("connector", extra: marker, identify: false)))
    }

    func testAnAnswerWithoutCredentialsThatIsNotAReplayKeepsTheOldBehaviour() async throws {
        ConnectorStub.serve(.init(status: 201, body: created("connector", identify: false)))
        let result = try await create("connector")
        XCTAssertFalse(result.identity.accessKey.isEmpty)
    }

    func testALinkOnAnotherAccountsHubNamesTheReason() async throws {
        ConnectorStub.serve(refusal(422, "connection_type_unavailable", #","reason":"hub_operated_by_another_account""#))
        let error = await refused("home_assistant")
        XCTAssertEqual(error?.reason, "hub_operated_by_another_account")
        XCTAssertEqual(error?.errorCode, ConnectionProblemCode.connectionTypeUnavailable)
        XCTAssertEqual(error?.kind, .unsupportedConnectionType)
        XCTAssertEqual(error?.statusCode, 422)
        XCTAssertEqual(ConnectorStub.count, 1, "nothing to delete: the API made nothing")
    }

    func testAnUnknownOrAmbiguousKindIsUnsupported() async {
        for code in ["connection_type_unknown", "connection_type_ambiguous"] {
            ConnectorStub.serve(refusal(422, code, #","known":["voice_satellite","connector"]"#))
            let error = await refused("plex")
            XCTAssertEqual(error?.kind, .unsupportedConnectionType)
            XCTAssertEqual(error?.errorCode, code)
            XCTAssertEqual(error?.known, ["voice_satellite", "connector"])
        }
    }

    func testARefusedConnectorListSaysWhyAndWhatIsKnown() async {
        for reason in ["duplicate", "own_kind", "unknown_or_malformed"] {
            ConnectorStub.serve(refusal(422, "connectors_invalid", #","reason":"\#(reason)","known":["music_assistant"]"#))
            let error = await refused("connector")
            XCTAssertEqual(error?.kind, .connectorsInvalid)
            XCTAssertEqual(error?.reason, reason)
            XCTAssertEqual(error?.known, ["music_assistant"])
        }
    }

    func testAnOwnerOnlyRefusalNamesTheLink() async {
        for code in [
            "device_owner_only_beside_home_link", "setup_session_owner_only_beside_home_link",
            "device_identity_owner_only_beside_home_link",
        ] {
            ConnectorStub.serve(refusal(403, code, #","link_client_id":"client-9""#))
            let error = await refused()
            XCTAssertEqual(error?.kind, .ownerOnlyBesideLink(linkClientId: "client-9"))
            XCTAssertEqual(error?.linkClientId, "client-9")
            XCTAssertEqual(error?.statusCode, 403)
        }
    }

    func testTheOtherNewCodesAreTyped() async {
        ConnectorStub.serve(refusal(409, "hub_scale_out_breaks_links", #","links":2"#))
        var error = await refused()
        XCTAssertEqual(error?.kind, .hubScaleOutBreaksLinks)
        XCTAssertEqual(error?.links, 2)
        ConnectorStub.serve(refusal(409, "idempotency_key_spent"))
        error = await refused()
        XCTAssertEqual(error?.kind, .idempotencyKeySpent)
        ConnectorStub.serve(refusal(422, "skill_config_private_hub_only", #","settings":["url","token"]"#))
        error = await refused()
        XCTAssertEqual(error?.kind, .privateHubOnly)
        XCTAssertEqual(error?.settings, ["url", "token"])
        XCTAssertEqual(error?.errorCode, "skill_config_private_hub_only")
    }

    func testAStructuredRefusalInsideDetailIsReadToo() async {
        ConnectorStub.serve(.init(
            status: 422,
            body: #"{"detail":{"code":"connectors_invalid","reason":"duplicate","known":["music_assistant"]}}"#))
        let error = await refused("connector")
        XCTAssertEqual(error?.kind, .connectorsInvalid)
        XCTAssertEqual(error?.reason, "duplicate")
        XCTAssertEqual(error?.known, ["music_assistant"])
    }

    func testAnUnlistedCodeStaysAPlainApiError() async {
        ConnectorStub.serve(refusal(409, "something_new"))
        let error = await refused()
        XCTAssertEqual(error?.kind, .other)
        XCTAssertEqual(error?.errorCode, "something_new")
    }
}
