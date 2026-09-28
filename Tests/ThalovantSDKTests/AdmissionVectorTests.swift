import Foundation
import XCTest

@testable import ThalovantSDK

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Waiting for a hub to admit a new connection, against the vectors every SDK
/// shares (`connection-admission-vectors.json`, vendored and pinned by the
/// parity contract). Served through URLSession by `ScriptedApi`; `polls`
/// counts the GETs the SDK sent.
final class AdmissionVectorTests: XCTestCase {

    /// The case's operation with `{api_host}` and `{api_port}` filled in.
    private func placed(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text):
            return .string(text.replacingOccurrences(of: "{api_host}", with: ScriptedApi.apiHost)
                .replacingOccurrences(of: "{api_port}", with: String(ScriptedApi.apiPort)))
        case .object(let fields):
            return .object(fields.mapValues(placed))
        default:
            return value
        }
    }

    func testConnectionAdmissionVectors() async throws {
        let vectors = try loadVectors("connection-admission-vectors")
        let cases = try XCTUnwrap(vectors["cases"]?.arrayValue).compactMap(\.objectValue)
        XCTAssertEqual(cases.count, 18)
        for row in cases {
            let name = try XCTUnwrap(row["name"]?.stringValue)
            let call = try XCTUnwrap(row["call"]?.objectValue, name)
            ScriptedApi.serve((row["exchanges"]?.arrayValue ?? []).compactMap(\.objectValue))
            // An API out of reach is a loopback listener that resets every
            // connection, dialled for real; every other case is served by the
            // script.
            let resetting = call["api"]?.stringValue == "unreachable" ? try ResettingListener() : nil
            defer { resetting?.stop() }
            let api = resetting.map {
                ThalovantControlPlane(
                    apiURL: "http://127.0.0.1:\($0.port)", accessToken: "synthetic-token",
                    session: URLSession(configuration: .ephemeral))
            } ?? ScriptedApi.controlPlane(accessToken: "synthetic-token")
            var operation: OperationResource?
            if let resource = call["operation"], resource.objectValue != nil {
                operation = try JSONDecoder().decode(OperationResource.self, from: JSONEncoder().encode(placed(resource)))
            }
            let expect = try XCTUnwrap(row["expect"]?.objectValue, name)
            var produced: JSONObject
            let started = ProcessInfo.processInfo.systemUptime
            do {
                try await api.waitForAdmission(
                    operation,
                    timeout: try XCTUnwrap(call["timeout_ms"]?.doubleValue, name) / 1000,
                    pollInterval: try XCTUnwrap(call["poll_interval_ms"]?.doubleValue, name) / 1000
                )
                produced = ["outcome": "admitted", "polls": .integer(ScriptedApi.sent.count)]
            } catch let error as ThalovantAdmissionTimeoutError {
                // Both at once, however a caller matches it.
                let erased: any Error = error
                XCTAssertTrue(erased is any ThalovantConnectionFailure, name)
                XCTAssertTrue(erased is any ThalovantTimeoutFailure, name)
                XCTAssertTrue(error.message.hasSuffix("it may still admit it later."), error.message)
                produced = ["outcome": "timeout"]
                if expect["polls"] != nil { produced["polls"] = .integer(ScriptedApi.sent.count) }
            } catch let error as ThalovantAdmissionFailedError {
                produced = [
                    "outcome": "failed",
                    "error_code": error.errorCode.map { .string($0) } ?? .null,
                    "status": error.statusCode.map { .integer($0) } ?? .null,
                ]
                if let refusal = error.apiError, refusal.statusCode != nil {
                    produced["code"] = refusal.errorCode.map { .string($0) } ?? .null
                    produced["detail"] = refusal.detail.map { .string($0) } ?? .null
                }
                produced["polls"] = .integer(ScriptedApi.sent.count)
            } catch let error as ThalovantApiError where error.kind == .unreachable {
                produced = ["outcome": "unreachable", "polls": .integer(ScriptedApi.sent.count)]
            } catch let error as ThalovantApiError where error.kind == .auth {
                produced = [
                    "outcome": "auth", "status": error.statusCode.map { .integer($0) } ?? .null,
                    "polls": .integer(ScriptedApi.sent.count),
                ]
            } catch is ThalovantApiError {
                produced = ["outcome": "error", "polls": .integer(ScriptedApi.sent.count)]
            }
            if let bound = expect["waited_at_least_ms"]?.intValue {
                // Recorded as the bound it met, so every SDK records the same value.
                let waited = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                produced["waited_at_least_ms"] = .integer(waited >= bound ? bound : waited)
            }
            let value = JSONValue.object(produced)
            ConformanceRecord.record("connection-admission-vectors.json", name, value)
            XCTAssertEqual(ScriptedApi.mismatches, [], name)
            XCTAssertEqual(value, row["expect"], name)
        }
    }

    func testTheResultCarriesTheOperationToWaitOn() async throws {
        let vectors = try loadVectors("connection-admission-vectors")
        let cases = try XCTUnwrap(vectors["cases"]?.arrayValue).compactMap(\.objectValue)
        let ready = try XCTUnwrap(cases.first { $0["name"]?.stringValue == "a 503 is ridden out" })
        let exchanges = (ready["exchanges"]?.arrayValue ?? []).compactMap(\.objectValue)
        // The create answer's own operation, followed from the result.
        let create: JSONObject = [
            "request": .object(["method": "POST", "path": "/v1/clients"]),
            "response": .object([
                "status": .integer(201), "content_type": "application/json",
                "body": .string(try ThalovantJSON.encodeToString([
                    "id": "client-1",
                    "spec": .object(["version": "1"]),
                    "initial_identify": .object([
                        "password": "p", "access_key": "k", "site_id": "s", "default_master": "wss://hub.example",
                    ]),
                    "operation": try XCTUnwrap(ready["call"]?["operation"]),
                ])),
            ]),
        ]
        ScriptedApi.serve([create] + exchanges)
        let api = ScriptedApi.controlPlane(accessToken: "synthetic-token")
        let result = try await api.createClientIdentity(
            hub: ["id": "hub-1", "domain": "hub.example"], options: CreateClientIdentityOptions(name: "Home Assistant"))
        XCTAssertEqual(result.operation?.id, "0b9e7c1a-2f44-4d5e-8a3b-6c1d2e9f7a50")
        try await api.waitForAdmission(result, timeout: 5, pollInterval: 0.01)
        XCTAssertEqual(ScriptedApi.mismatches, [])
        XCTAssertEqual(ScriptedApi.sent.count, 3)
    }

    func testAnOperationInAStatusThisSDKDoesNotKnowIsStillFollowed() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.init(status: 201, body: """
            {"id": "client-1", "spec": {"version": "1"},
             "initial_identify": {"password": "p", "access_key": "k", "site_id": "s", "default_master": "wss://hub.example"},
             "operation": {"id": "op-1", "status": "queued", "links": {"self": "/v1/operations/op-1"}}}
            """))
        StubURLProtocol.enqueue(.init(body: #"{"id": "op-1", "status": "queued"}"#))
        StubURLProtocol.enqueue(.init(body: #"{"id": "op-1", "status": "ready"}"#))
        let api = ThalovantControlPlane(
            apiURL: "https://api.example.com", accessToken: "token", session: StubURLProtocol.makeSession())
        let result = try await api.createClientIdentity(
            hub: ["id": "hub-1", "domain": "hub.example"], options: CreateClientIdentityOptions(name: "Home Assistant"))
        XCTAssertNil(result.operation, "a status the enum does not know does not decode")
        try await api.waitForAdmission(result, timeout: 5, pollInterval: 0.01)
        XCTAssertEqual(StubURLProtocol.requests.map(\.url.path), ["/v1/clients", "/v1/operations/op-1", "/v1/operations/op-1"])
    }

    func testARevokedTokenWhileWaitingIsAnAuthRefusalNotAFailedAdmission() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.init(status: 401, body: #"{"detail": "Could not validate credentials"}"#))
        let api = ThalovantControlPlane(
            apiURL: "https://api.example.com", accessToken: "token", session: StubURLProtocol.makeSession())
        let operation = try JSONDecoder().decode(OperationResource.self, from: Data(Fixtures.operationPending.utf8))
        do {
            try await api.waitForAdmission(operation, timeout: 5, pollInterval: 0.01)
            XCTFail("expected a refusal")
        } catch let error as ThalovantApiError {
            XCTAssertEqual(error.kind, .auth)
        }
    }

    func testAReadTheApiIsSlowToAnswerNeverCarriesTheWaitPastItsDeadline() async throws {
        HangingAPI.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingAPI.self]
        let api = ThalovantControlPlane(
            apiURL: "https://api.example.com", accessToken: "token", session: URLSession(configuration: configuration))
        let operation = try JSONDecoder().decode(OperationResource.self, from: Data(Fixtures.operationPending.utf8))
        let started = ProcessInfo.processInfo.systemUptime
        do {
            try await api.waitForAdmission(operation, timeout: 0.3, pollInterval: 0.01)
            XCTFail("expected the wait to time out")
        } catch is ThalovantAdmissionTimeoutError {}
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
        XCTAssertTrue(HangingAPI.started)
    }

    func testTheWaitIsReadFromTheBodyThenRetryAfterThenRateLimitReset() {
        func wait(_ body: String, _ headers: [String: String]) -> TimeInterval? {
            ThalovantApiError.httpFailure(statusCode: 429, body: body, header: { name in
                headers.first { $0.key.lowercased() == name.lowercased() }?.value
            }).retryAfterSeconds
        }
        XCTAssertEqual(wait(#"{"detail": {"retry_after_seconds": 7}}"#, ["Retry-After": "3"]), 7)
        XCTAssertEqual(wait("Too Many Requests", ["Retry-After": "3", "RateLimit-Reset": "5"]), 3)
        XCTAssertEqual(wait("Too Many Requests", ["ratelimit-reset": " 5 "]), 5)
        XCTAssertNil(wait("Too Many Requests", ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"]))
        XCTAssertNil(wait("Too Many Requests", ["Retry-After": "-1"]))
        XCTAssertNil(wait("Too Many Requests", [:]))
    }

    func testOriginsSpellTheDefaultPortOut() {
        XCTAssertEqual(originOf("https://h"), originOf("https://h:443/v1/operations/x"))
        XCTAssertEqual(originOf("http://H:80"), originOf("http://h/"))
        XCTAssertNotEqual(originOf("http://h"), originOf("https://h"))
        XCTAssertNotEqual(originOf("https://h"), originOf("https://h:8443"))
        XCTAssertNil(originOf("/v1/operations/x"))
    }

    func testA429WithoutARetryAfterIsRiddenOutAtThePollInterval() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.init(status: 429, body: #"{"detail": {"code": "token_rate_limited"}}"#))
        StubURLProtocol.enqueue(.init(body: #"{"id": "op-1", "status": "ready"}"#))
        let api = ThalovantControlPlane(
            apiURL: "https://api.example.com", accessToken: "token", session: StubURLProtocol.makeSession())
        let operation = try JSONDecoder().decode(OperationResource.self, from: Data(Fixtures.operationPending.utf8))
        try await api.waitForAdmission(operation, timeout: 5, pollInterval: 0.01)
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        XCTAssertEqual(
            ThalovantApiError.httpFailure(statusCode: 429, body: #"{"retry_after_seconds": 3}"#).retryAfterSeconds, 3)
        XCTAssertNil(
            ThalovantApiError.httpFailure(statusCode: 429, body: #"{"detail": {"retry_after_seconds": true}}"#)
                .retryAfterSeconds)
    }

    func testAWaitThatCannotEverEndIsRefused() async throws {
        let api = ThalovantControlPlane(apiURL: "https://api.example.com", accessToken: "token")
        for (timeout, poll) in [(TimeInterval.infinity, 1.0), (-1, 1), (5, 0), (5, .nan)] {
            do {
                try await api.waitForAdmission(nil, timeout: timeout, pollInterval: poll)
                XCTFail("expected \(timeout)/\(poll) to be refused")
            } catch is ThalovantApiError {}
        }
    }
}

/// Starts every request and never answers it.
private final class HangingAPI: URLProtocol {
    private static let lock = NSLock()
    private static var didStart = false
    static var started: Bool { lock.locked { didStart } }
    static func reset() { lock.locked { didStart = false } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.locked { Self.didStart = true } }
    override func stopLoading() {}
}
