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

    func testConnectionAdmissionVectors() async throws {
        let vectors = try loadVectors("connection-admission-vectors")
        let cases = try XCTUnwrap(vectors["cases"]?.arrayValue).compactMap(\.objectValue)
        XCTAssertEqual(cases.count, 8)
        for row in cases {
            let name = try XCTUnwrap(row["name"]?.stringValue)
            let call = try XCTUnwrap(row["call"]?.objectValue, name)
            ScriptedApi.serve((row["exchanges"]?.arrayValue ?? []).compactMap(\.objectValue))
            let api = ThalovantControlPlane(
                apiURL: ScriptedApi.apiURL, accessToken: "synthetic-token", session: ScriptedApi.session())
            var operation: OperationResource?
            if let resource = call["operation"], resource.objectValue != nil {
                operation = try JSONDecoder().decode(OperationResource.self, from: JSONEncoder().encode(resource))
            }
            let produced: JSONObject
            do {
                try await api.waitForAdmission(
                    operation,
                    timeout: try XCTUnwrap(call["timeout_seconds"]?.doubleValue, name),
                    pollInterval: try XCTUnwrap(call["poll_interval_seconds"]?.doubleValue, name)
                )
                produced = ["outcome": "admitted", "polls": .integer(ScriptedApi.sent.count)]
            } catch let error as ThalovantAdmissionTimeoutError {
                // Both at once, however a caller matches it.
                let erased: any Error = error
                XCTAssertTrue(erased is any ThalovantConnectionFailure, name)
                XCTAssertTrue(erased is any ThalovantTimeoutFailure, name)
                produced = ["outcome": "timeout"]
            } catch let error as ThalovantAdmissionFailedError {
                produced = [
                    "outcome": "failed",
                    "error_code": error.errorCode.map { .string($0) } ?? .null,
                    "polls": .integer(ScriptedApi.sent.count),
                ]
            } catch is ThalovantApiError {
                produced = ["outcome": "error", "polls": .integer(ScriptedApi.sent.count)]
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
        let api = ThalovantControlPlane(
            apiURL: ScriptedApi.apiURL, accessToken: "synthetic-token", session: ScriptedApi.session())
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
