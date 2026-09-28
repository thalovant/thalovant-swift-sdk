import Foundation
import XCTest

@testable import ThalovantSDK

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Creating a connection of a named kind, and deleting one, against the
/// vectors every SDK shares (`connection-kinds-vectors.json`, vendored and
/// pinned by the parity contract). Served through URLSession by `ScriptedApi`;
/// `requests` records what the SDK sent, in order.
final class ConnectionKindsVectorTests: XCTestCase {

    func testConnectionKindsVectors() async throws {
        let vectors = try loadVectors("connection-kinds-vectors")
        let excludes = (vectors["message_excludes"]?.arrayValue ?? []).compactMap(\.stringValue)
        XCTAssertEqual(excludes.count, 2)
        let cases = try XCTUnwrap(vectors["cases"]?.arrayValue).compactMap(\.objectValue)
        XCTAssertEqual(cases.count, 15)
        for row in cases {
            let name = try XCTUnwrap(row["name"]?.stringValue)
            let call = try XCTUnwrap(row["call"]?.objectValue, name)
            ScriptedApi.serve((row["exchanges"]?.arrayValue ?? []).compactMap(\.objectValue))
            let api = ThalovantControlPlane(
                apiURL: ScriptedApi.apiURL, accessToken: "synthetic-token", session: ScriptedApi.session())
            var produced: JSONObject
            if call["op"]?.stringValue == "create" {
                do {
                    let result = try await api.createClientIdentity(
                        hub: try XCTUnwrap(call["hub"]?.objectValue, name),
                        options: CreateClientIdentityOptions(
                            name: try XCTUnwrap(call["name"]?.stringValue, name),
                            connectionType: call["connection_type"]?.stringValue
                        )
                    )
                    produced = [
                        "outcome": "created",
                        "client_id": result.clientId.map { .string($0) } ?? .null,
                        "connection_type": result.connectionType.map { .string($0) } ?? .null,
                        "operation_id": result.operation.map { .string($0.id) } ?? .null,
                    ]
                } catch let error as ThalovantApiError {
                    for secret in excludes {
                        for form in printedForms(error) {
                            XCTAssertFalse(form.contains(secret), "\(name): an error repeats a secret")
                        }
                    }
                    if error.kind == .unsupportedConnectionType {
                        produced = ["outcome": "unsupported"]
                        if error.statusCode != nil {
                            produced.merge(apiFields(error)) { _, new in new }
                        } else {
                            produced["deleted"] = .bool(ScriptedApi.sent.contains { $0.hasPrefix("DELETE ") })
                        }
                    } else {
                        produced = refusal(error)
                    }
                }
            } else {
                do {
                    try await api.deleteClient(
                        try XCTUnwrap(call["client_id"]?.stringValue, name),
                        etag: call["etag"]?.stringValue
                    )
                    produced = ["outcome": "deleted"]
                } catch let error as ThalovantApiError {
                    produced = refusal(error)
                }
            }
            produced["requests"] = .array(ScriptedApi.sent.map { .string($0) })
            let value = JSONValue.object(produced)
            ConformanceRecord.record("connection-kinds-vectors.json", name, value)
            XCTAssertEqual(ScriptedApi.mismatches, [], name)
            XCTAssertEqual(value, row["expect"], name)
        }
    }

    /// The reference's `_kind_outcome`, with the api-errors fields beside it.
    private func refusal(_ error: ThalovantApiError) -> JSONObject {
        var produced = apiFields(error)
        switch error.kind {
        case .plan:
            produced["outcome"] = "plan"
        case .alreadyLinked(let clientId):
            produced["outcome"] = "already_linked"
            produced["client_id"] = clientId.map { .string($0) } ?? .null
        case .auth:
            produced["outcome"] = "auth"
        default:
            produced["outcome"] = "error"
        }
        return produced
    }

    func testWithoutAKindTheCreateIsWhatItWas() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.init(status: 201, body: """
            {"id": "client-1", "spec": {"version": "1"},
             "initial_identify": {"password": "p", "access_key": "k", "site_id": "s", "default_master": "wss://hub.example"}}
            """))
        let api = ThalovantControlPlane(
            apiURL: "https://api.example.com", accessToken: "token", session: StubURLProtocol.makeSession())
        let result = try await api.createClientIdentity(
            hub: ["id": "hub-1", "domain": "hub.example"], options: CreateClientIdentityOptions(name: "satellite"))
        let body = try XCTUnwrap(StubURLProtocol.requests.first?.bodyObject())
        XCTAssertNil(body["spec"]?["connection_type"], "no kind asked, none sent")
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "no echo check, no delete")
        XCTAssertEqual(result.clientId, "client-1")
        XCTAssertNil(result.connectionType)
        XCTAssertNil(result.operation)
    }

    func testEveryRefusalKindKeepsWhatTheApiSaid() {
        let linked = ThalovantApiError.httpFailure(
            statusCode: 409,
            body: #"{"status": 409, "detail": "This hub is already linked to a Home Assistant.", "code": "home_assistant_already_linked", "client_id": "client-9"}"#
        )
        XCTAssertEqual(linked.kind, .alreadyLinked(clientId: "client-9"))
        XCTAssertEqual(linked.statusCode, 409)
        XCTAssertEqual(linked.errorCode, "home_assistant_already_linked")
        XCTAssertEqual(linked.detail, "This hub is already linked to a Home Assistant.")
        XCTAssertEqual(linked.problem?["client_id"], .string("client-9"))

        // FastAPI's own envelope names the client inside `detail`.
        let nested = ThalovantApiError.httpFailure(
            statusCode: 409,
            body: #"{"detail": {"code": "home_assistant_already_linked", "existing_client_id": "client-8"}}"#
        )
        XCTAssertEqual(nested.kind, .alreadyLinked(clientId: "client-8"))

        XCTAssertEqual(ThalovantApiError.httpFailure(statusCode: 423, body: "{}").kind, .auth)
        XCTAssertEqual(ThalovantApiError.httpFailure(statusCode: 402, body: "").kind, .plan)
        XCTAssertEqual(
            ThalovantApiError.httpFailure(statusCode: 403, body: #"{"detail": "Forbidden"}"#).kind, .other)
        XCTAssertEqual(ThalovantApiError(message: "local").kind, .other)
        XCTAssertEqual(ThalovantApiError(message: "stale", statusCode: 401).kind, .auth)
        XCTAssertEqual(
            ThalovantApiError(message: "explicit", statusCode: 401, kind: .other).kind, .other,
            "an explicit kind wins")
    }

    func testADeleteThatCannotReadAnEtagSaysSo() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.init(body: #"{"id": "client-1"}"#))
        let api = ThalovantControlPlane(
            apiURL: "https://api.example.com", accessToken: "token", session: StubURLProtocol.makeSession())
        do {
            try await api.deleteClient("client-1")
            XCTFail("expected a refusal")
        } catch let error as ThalovantApiError {
            XCTAssertNil(error.statusCode)
            XCTAssertTrue(error.message.contains("etag"))
        }
        XCTAssertEqual(StubURLProtocol.requests.map(\.method), ["GET"])
    }

    func testASecondChangedEtagIsNotRetriedAgain() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.init(status: 412, body: #"{"detail": "ETag mismatch"}"#))
        StubURLProtocol.enqueue(.init(body: #"{"id": "client-1", "etag": "etag-2"}"#))
        StubURLProtocol.enqueue(.init(status: 412, body: #"{"detail": "ETag mismatch"}"#))
        let api = ThalovantControlPlane(
            apiURL: "https://api.example.com", accessToken: "token", session: StubURLProtocol.makeSession())
        do {
            try await api.deleteClient("client-1", etag: "etag-1")
            XCTFail("expected the second 412")
        } catch let error as ThalovantApiError {
            XCTAssertEqual(error.statusCode, 412)
        }
        XCTAssertEqual(StubURLProtocol.requests.map(\.method), ["DELETE", "GET", "DELETE"])
    }
}
