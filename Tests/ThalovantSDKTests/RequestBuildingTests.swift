import Foundation
import XCTest

@testable import ThalovantSDK

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// URLProtocol stub that records every request (method, URL, headers, body)
/// and replays queued responses, so no test touches the network.
final class StubURLProtocol: URLProtocol {
    struct RecordedRequest {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data?

        func header(_ name: String) -> String? {
            headers.first { $0.key.lowercased() == name.lowercased() }?.value
        }

        func bodyObject() -> JSONObject? {
            body.flatMap { try? ThalovantJSON.decodeObject($0) }
        }
    }

    struct StubResponse {
        var status: Int = 200
        var body: String = "{}"
    }

    private static let lock = NSLock()
    private static var recorded: [RecordedRequest] = []
    private static var queue: [StubResponse] = []

    static func reset() {
        lock.lock()
        recorded = []
        queue = []
        lock.unlock()
    }

    static func enqueue(_ response: StubResponse) {
        lock.lock()
        queue.append(response)
        lock.unlock()
    }

    static var requests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            headers[name] = value
        }
        let recorded = StubURLProtocol.RecordedRequest(
            method: request.httpMethod ?? "",
            url: request.url ?? URL(string: "about:blank")!,
            headers: headers,
            body: request.httpBody ?? Self.drainBodyStream(request.httpBodyStream)
        )
        StubURLProtocol.lock.lock()
        StubURLProtocol.recorded.append(recorded)
        let stub = StubURLProtocol.queue.isEmpty
            ? StubURLProtocol.StubResponse()
            : StubURLProtocol.queue.removeFirst()
        StubURLProtocol.lock.unlock()

        let response = HTTPURLResponse(
            url: recorded.url,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// Apple platforms hand the body to URLProtocol as a stream.
    private static func drainBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

final class RequestBuildingTests: XCTestCase {
    private var api: ThalovantControlPlane!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        api = ThalovantControlPlane(
            apiURL: "https://api.example.com/v1",
            session: StubURLProtocol.makeSession()
        )
    }

    private func lastRequest(file: StaticString = #filePath, line: UInt = #line) throws -> StubURLProtocol.RecordedRequest {
        try XCTUnwrap(StubURLProtocol.requests.last, file: file, line: line)
    }

    func testLoginSendsOnlyEmailAndPasswordByDefault() async throws {
        StubURLProtocol.enqueue(.init(body: #"{"access_token": "token-1", "token_type": "bearer"}"#))
        let token = try await api.login(email: "dev@example.com", password: "secret")
        XCTAssertEqual(token["access_token"]?.stringValue, "token-1")
        XCTAssertEqual(api.accessToken, "token-1")

        let request = try lastRequest()
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/auth/token")
        XCTAssertEqual(request.header("User-Agent"), "ThalovantSwiftSDK/0.1.1")
        XCTAssertEqual(request.header("Accept"), "application/json")
        XCTAssertEqual(request.header("Content-Type"), "application/json")
        XCTAssertNil(request.header("Authorization"))
        let body = try XCTUnwrap(request.bodyObject())
        XCTAssertEqual(body["email"]?.stringValue, "dev@example.com")
        XCTAssertEqual(body["password"]?.stringValue, "secret")
        XCTAssertNil(body["scope"])
        XCTAssertNil(body["otp_code"])
        XCTAssertNil(body["recovery_code"])
    }

    func testLoginIncludesMfaFieldsOnlyWhenSet() async throws {
        StubURLProtocol.enqueue(.init(body: #"{"access_token": "token-2"}"#))
        _ = try await api.login(email: "dev@example.com", password: "secret", scope: "hubs:read", otpCode: "123456")
        var body = try XCTUnwrap(try lastRequest().bodyObject())
        XCTAssertEqual(body["scope"]?.stringValue, "hubs:read")
        XCTAssertEqual(body["otp_code"]?.stringValue, "123456")
        XCTAssertNil(body["recovery_code"])

        StubURLProtocol.enqueue(.init(body: #"{"access_token": "token-3"}"#))
        _ = try await api.login(email: "dev@example.com", password: "secret", recoveryCode: "abcd-efgh")
        body = try XCTUnwrap(try lastRequest().bodyObject())
        XCTAssertEqual(body["recovery_code"]?.stringValue, "abcd-efgh")
        XCTAssertNil(body["otp_code"])
    }

    func testLoginMfaRequiredSurfacesErrorCode() async {
        StubURLProtocol.enqueue(.init(
            status: 401,
            body: #"{"detail": {"code": "mfa_required", "recovery_available": true}}"#
        ))
        do {
            _ = try await api.login(email: "dev@example.com", password: "secret")
            XCTFail("expected ThalovantApiError")
        } catch let error as ThalovantApiError {
            XCTAssertEqual(error.statusCode, 401)
            XCTAssertEqual(error.errorCode, "mfa_required")
            XCTAssertNotNil(error.body)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testListHubsRequiresAuthAndBuildsQuery() async throws {
        api.accessToken = "token"
        _ = try await api.listHubs(limit: 50, cursor: "abc", ownerId: "owner-1")
        let request = try lastRequest()
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/hubs?limit=50&cursor=abc&owner_id=owner-1")
        XCTAssertEqual(request.header("Authorization"), "Bearer token")
    }

    func testListHubsWithoutTokenThrowsBeforeSendingAnything() async {
        do {
            _ = try await api.listHubs()
            XCTFail("expected ThalovantApiError")
        } catch {
            XCTAssertTrue(error is ThalovantApiError)
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testPublicHubsAreUnauthenticated() async throws {
        _ = try await api.listPublicHubs()
        var request = try lastRequest()
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/public/hubs?limit=24")
        XCTAssertNil(request.header("Authorization"))

        _ = try await api.getPublicHub("hub-1")
        request = try lastRequest()
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/public/hubs/hub-1")
        XCTAssertNil(request.header("Authorization"))
    }

    func testGetOperationPathAndDecoding() async throws {
        api.accessToken = "token"
        StubURLProtocol.enqueue(.init(body: Fixtures.operation))
        let operation = try await api.getOperation(id: "operation-1")
        XCTAssertEqual(operation.status, .timedOut)
        XCTAssertEqual(operation.links["self"], "/v1/operations/operation-1")
        let request = try lastRequest()
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/operations/operation-1")
    }

    func testMemoryListBuildsAllFilters() async throws {
        api.accessToken = "token"
        StubURLProtocol.enqueue(.init(body: Fixtures.memoryList))
        _ = try await api.listMemoryItems(MemoryListOptions(
            scope: .workspace,
            kind: .preference,
            ownerId: "owner-1",
            hubId: "hub-1",
            query: "timezone",
            includeDeleted: true,
            includeExpired: true,
            limit: 25,
            offset: 5
        ))
        let request = try lastRequest()
        XCTAssertEqual(
            request.url.absoluteString,
            "https://api.example.com/v1/memory?scope=workspace&kind=preference&owner_id=owner-1&hub_id=hub-1&q=timezone&include_deleted=true&include_expired=true&limit=25&offset=5"
        )
    }

    func testMemoryListDefaultsHaveNoQuery() async throws {
        api.accessToken = "token"
        StubURLProtocol.enqueue(.init(body: Fixtures.memoryList))
        _ = try await api.listMemoryItems()
        XCTAssertEqual(try lastRequest().url.absoluteString, "https://api.example.com/v1/memory")
    }

    func testMemoryCreateUpdateDelete() async throws {
        api.accessToken = "token"
        StubURLProtocol.enqueue(.init(body: Fixtures.memoryItem))
        _ = try await api.createMemoryItem(MemoryCreatePayload(
            content: "Prefer America/Toronto for scheduling.",
            scope: .workspace,
            kind: .preference,
            tags: ["timezone"]
        ))
        var request = try lastRequest()
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/memory")
        var body = try XCTUnwrap(request.bodyObject())
        XCTAssertEqual(body["scope"]?.stringValue, "workspace")
        XCTAssertEqual(body["kind"]?.stringValue, "preference")
        XCTAssertEqual(body["content"]?.stringValue, "Prefer America/Toronto for scheduling.")
        XCTAssertEqual(body["tags"], .array([.string("timezone")]))
        XCTAssertNil(body["title"])
        XCTAssertNil(body["owner_id"])
        XCTAssertNil(body["clear_expires_at"])

        StubURLProtocol.enqueue(.init(body: Fixtures.memoryItem))
        _ = try await api.updateMemoryItem("mem-1", MemoryUpdatePayload(content: "Updated.", clearExpiresAt: true))
        request = try lastRequest()
        XCTAssertEqual(request.method, "PATCH")
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/memory/mem-1")
        body = try XCTUnwrap(request.bodyObject())
        XCTAssertEqual(body["content"]?.stringValue, "Updated.")
        XCTAssertEqual(body["clear_expires_at"]?.boolValue, true)
        XCTAssertNil(body["kind"])

        StubURLProtocol.enqueue(.init(status: 204, body: ""))
        try await api.deleteMemoryItem("mem-1")
        request = try lastRequest()
        XCTAssertEqual(request.method, "DELETE")
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/memory/mem-1")

        StubURLProtocol.enqueue(.init(body: Fixtures.memorySummary))
        let summary = try await api.getMemorySummary(ownerId: "owner-1")
        XCTAssertEqual(summary.total, 12)
        XCTAssertEqual(
            try lastRequest().url.absoluteString,
            "https://api.example.com/v1/memory/summary?owner_id=owner-1"
        )
    }

    func testAnalyticsOverviewWorkspaceIgnoresOwnerId() async throws {
        api.accessToken = "token"
        _ = try await api.analyticsOverview(AnalyticsOverviewOptions(
            range: "7d",
            bucket: "1h",
            ownerId: "owner-1",
            hubId: "hub-1",
            clientId: "client-1",
            country: "CA",
            message: "msg",
            utterance: "utt",
            intent: "intent-1",
            timeStart: "2026-08-01T00:00:00Z",
            timeEnd: "2026-08-08T00:00:00Z",
            weekday: 2,
            hour: 13
        ))
        let request = try lastRequest()
        XCTAssertTrue(request.url.absoluteString.hasPrefix("https://api.example.com/v1/analytics/overview?"))
        let query = try XCTUnwrap(request.url.query)
        XCTAssertFalse(query.contains("owner_id"), "owner_id is admin-only")
        XCTAssertEqual(
            request.url.absoluteString,
            "https://api.example.com/v1/analytics/overview?range=7d&bucket=1h&hub_id=hub-1&client_id=client-1&country=CA&message=msg&utterance=utt&intent=intent-1&time_start=2026-08-01T00:00:00Z&time_end=2026-08-08T00:00:00Z&weekday=2&hour=13"
        )
    }

    func testAnalyticsOverviewAdminSwitchesEndpointAndSendsOwnerId() async throws {
        api.accessToken = "token"
        _ = try await api.analyticsOverview(AnalyticsOverviewOptions(admin: true, range: "24h", ownerId: "owner-1"))
        XCTAssertEqual(
            try lastRequest().url.absoluteString,
            "https://api.example.com/v1/admin/analytics/overview?range=24h&owner_id=owner-1"
        )
    }

    func testCreateClientSendsIdempotencyKey() async throws {
        api.accessToken = "token"
        _ = try await api.createClient(["hub_id": "hub-1"], idempotencyKey: "fixed-key")
        var request = try lastRequest()
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://api.example.com/v1/clients")
        XCTAssertEqual(request.header("Idempotency-Key"), "fixed-key")

        _ = try await api.createClient(["hub_id": "hub-1"])
        request = try lastRequest()
        let generated = try XCTUnwrap(request.header("Idempotency-Key"))
        XCTAssertFalse(generated.isEmpty)
        XCTAssertNotEqual(generated, "fixed-key")
    }

    func testCreateClientIdentityFlow() async throws {
        api.accessToken = "token"
        StubURLProtocol.enqueue(.init(body: Fixtures.hub))
        StubURLProtocol.enqueue(.init(body: """
        {
          "id": "11111111-aaaa-bbbb-cccc-222222222222",
          "name": "swift demo client",
          "active": false,
          "initial_identify": \(Fixtures.clientIdentify)
        }
        """))
        let result = try await api.createClientIdentity(
            hubId: "hub-1",
            options: CreateClientIdentityOptions(
                name: "swift demo client",
                ownerId: "owner-1",
                active: false,
                idempotencyKey: "bootstrap-key"
            )
        )

        let requests = StubURLProtocol.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].method, "GET")
        XCTAssertEqual(requests[0].url.absoluteString, "https://api.example.com/v1/hubs/hub-1")
        XCTAssertEqual(requests[1].method, "POST")
        XCTAssertEqual(requests[1].url.absoluteString, "https://api.example.com/v1/clients")
        XCTAssertEqual(requests[1].header("Idempotency-Key"), "bootstrap-key")

        let body = try XCTUnwrap(requests[1].bodyObject())
        XCTAssertEqual(body["hub_id"]?.stringValue, "b3b1f5a0-91b8-4a71-a2e5-53422dd0f841")
        XCTAssertEqual(body["name"]?.stringValue, "swift demo client")
        XCTAssertEqual(body["active"]?.boolValue, false)
        XCTAssertEqual(body["owner_id"]?.stringValue, "owner-1")
        let spec = try XCTUnwrap(body["spec"]?.objectValue)
        XCTAssertEqual(spec["version"]?.stringValue, "1")
        XCTAssertEqual(spec["siteId"]?.stringValue, "swift-demo-client")
        XCTAssertFalse(try XCTUnwrap(spec["apiKey"]?.stringValue).isEmpty)
        XCTAssertFalse(try XCTUnwrap(spec["password"]?.stringValue).isEmpty)
        XCTAssertFalse(try XCTUnwrap(spec["cryptoKey"]?.stringValue).isEmpty)

        // Identity is parsed from initial_identify and enriched with the hub's
        // endpoints and protocol settings.
        XCTAssertEqual(result.identity.accessKey, "identity-access-key")
        XCTAssertEqual(result.identity.siteId, "swift-demo-client")
        XCTAssertEqual(result.identity.dataPlaneEndpoints.wss, "wss://hub-1.hubs.thalovant.com/ws")
        XCTAssertEqual(result.selectedProtocol, .wss)
        XCTAssertEqual(result.endpoint?.endpoint, "wss://hub-1.hubs.thalovant.com/ws")

        // Runtime protocol resolution and unsupported-protocol errors.
        let wss = try api.requireRuntimeProtocol(result)
        XCTAssertEqual(wss.hubProtocol, .wss)
        XCTAssertEqual(wss.endpoint, "wss://hub-1.hubs.thalovant.com/ws")

        // Redacted output never leaks secrets.
        let redacted = result.asJSON()
        XCTAssertNil(redacted["identity"]?["access_key"])
        XCTAssertEqual(redacted["selectedProtocol"]?.stringValue, "wss")
    }

    func testCreateClientIdentityActiveDefaultsTrue() async throws {
        api.accessToken = "token"
        StubURLProtocol.enqueue(.init(body: Fixtures.hub))
        StubURLProtocol.enqueue(.init(body: #"{"id": "client-1"}"#))
        let result = try await api.createClientIdentity(
            hubId: "hub-1",
            options: CreateClientIdentityOptions(name: "demo_client")
        )
        let body = try XCTUnwrap(try lastRequest().bodyObject())
        XCTAssertEqual(body["active"]?.boolValue, true)
        XCTAssertNil(body["owner_id"])
        // Without initial_identify, the locally generated secrets are used.
        let spec = try XCTUnwrap(body["spec"]?.objectValue)
        XCTAssertEqual(result.identity.accessKey, spec["apiKey"]?.stringValue)
        XCTAssertEqual(result.identity.siteId, "demo-client")
        XCTAssertEqual(result.identity.defaultPort, 443)
        XCTAssertEqual(result.identity.defaultMaster, "https://hub-1.hubs.thalovant.com")
    }

    func testErrorPropagatesStatusAndBody() async {
        api.accessToken = "token"
        StubURLProtocol.enqueue(.init(status: 404, body: #"{"detail": "Hub not found"}"#))
        do {
            _ = try await api.getHub("missing")
            XCTFail("expected ThalovantApiError")
        } catch let error as ThalovantApiError {
            XCTAssertEqual(error.statusCode, 404)
            XCTAssertNil(error.errorCode)
            XCTAssertEqual(error.body, #"{"detail": "Hub not found"}"#)
            XCTAssertTrue(error.message.contains("404"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
