import Foundation
import XCTest

@testable import ThalovantSDK

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Device sign-in one step at a time, against the vectors every SDK shares.
///
/// `contracts/conformance/device-login-vectors.json` in the Python SDK,
/// vendored here and pinned by the parity contract. Each case's answers are
/// served through URLSession by `ScriptedApi`, which checks every request the
/// SDK sends; what the SDK produced is recorded, shaped as the reference's
/// `tests/test_home_link_vectors.py` shapes it -- a list, one entry per call.
final class DeviceLoginVectorTests: XCTestCase {

    func testDeviceLoginVectors() async throws {
        let vectors = try loadVectors("device-login-vectors")
        let excludes = (vectors["message_excludes"]?.arrayValue ?? []).compactMap(\.stringValue)
        XCTAssertEqual(excludes.count, 2)
        let cases = try XCTUnwrap(vectors["cases"]?.arrayValue).compactMap(\.objectValue)
        XCTAssertEqual(cases.count, 11)
        for row in cases {
            let name = try XCTUnwrap(row["name"]?.stringValue)
            let call = try XCTUnwrap(row["call"]?.objectValue, name)
            let exchanges = (row["exchanges"]?.arrayValue ?? []).compactMap(\.objectValue)
            ScriptedApi.serve(exchanges)
            let api = ThalovantControlPlane(apiURL: ScriptedApi.apiURL, session: ScriptedApi.session())
            var produced: [JSONValue] = []
            if call["op"]?.stringValue == "begin" {
                do {
                    let grant = try await api.beginDeviceLogin(
                        scopes: call["scopes"]?.arrayValue?.compactMap(\.stringValue),
                        clientName: call["client_name"]?.stringValue
                    )
                    produced.append(.object([
                        "outcome": "started",
                        "user_code": .string(grant.userCode),
                        "verification_uri": .string(grant.verificationUri),
                        "verification_uri_complete": grant.verificationUriComplete.map { .string($0) } ?? .null,
                        "interval": recordedNumber(grant.interval),
                        "expires_in": grant.expiresIn.map { .integer($0) } ?? .null,
                    ]))
                } catch let error as ThalovantApiError {
                    assertExcluded(error, excludes, name)
                    produced.append(.object(["outcome": "error", "status": error.statusCode.map { .integer($0) } ?? .null]))
                }
            } else {
                let authorization = try XCTUnwrap(call["authorization"]?.objectValue, name)
                let grant = DeviceAuthorizationGrant(
                    deviceCode: try XCTUnwrap(authorization["device_code"]?.stringValue, name),
                    interval: try XCTUnwrap(authorization["interval"]?.doubleValue, name)
                )
                for _ in 0..<(call["times"]?.intValue ?? 1) {
                    produced.append(await pollOnce(api, grant, excludes, name))
                }
                if call["op"]?.stringValue == "revoke" {
                    try await api.revokeApiToken()
                    XCTAssertNil(api.accessToken, name)
                    XCTAssertNil(api.tokenId, name)
                    produced = [.object(["outcome": "revoked"])]
                }
            }
            let value = JSONValue.array(produced)
            // Recorded before the asserts: the record is what this SDK produced.
            ConformanceRecord.record("device-login-vectors.json", name, value)
            XCTAssertEqual(ScriptedApi.mismatches, [], name)
            XCTAssertEqual(ScriptedApi.used, exchanges.count, "\(name): not every exchange was used")
            XCTAssertEqual(value, row["expect"], name)
        }
    }

    private func pollOnce(
        _ api: ThalovantControlPlane, _ grant: DeviceAuthorizationGrant, _ excludes: [String], _ name: String
    ) async -> JSONValue {
        do {
            let token = try await api.pollDeviceLogin(grant)
            XCTAssertEqual(api.accessToken, token.accessToken, name)
            XCTAssertEqual(api.tokenId, token.tokenId, name)
            return .object([
                "outcome": "approved",
                "token_type": token.tokenType.map { .string($0) } ?? .null,
                "scopes": .array(token.scopes.map { .string($0) }),
                "expires_at": token.expiresAt.map { .string($0) } ?? .null,
                "token_id": token.tokenId.map { .string($0) } ?? .null,
            ])
        } catch let error as ThalovantApiError {
            let status: JSONValue = error.statusCode.map { .integer($0) } ?? .null
            switch error.kind {
            case .deviceLoginPending(let interval):
                return .object(["outcome": "pending", "interval": recordedNumber(interval)])
            case .deviceLoginExpired:
                assertExcluded(error, excludes, name)
                return .object(["outcome": "expired", "status": status])
            case .deviceLoginDenied:
                assertExcluded(error, excludes, name)
                return .object(["outcome": "denied", "status": status])
            default:
                assertExcluded(error, excludes, name)
                var produced: JSONObject = ["outcome": "error", "status": status]
                if error.statusCode != nil {
                    produced["code"] = apiFields(error)["code"]
                    produced["detail"] = apiFields(error)["detail"]
                }
                return .object(produced)
            }
        } catch {
            XCTFail("\(name): \(error)")
            return .null
        }
    }

    private func assertExcluded(_ error: ThalovantApiError, _ excludes: [String], _ name: String) {
        for secret in excludes {
            for form in printedForms(error) {
                XCTAssertFalse(form.contains(secret), "\(name): an error repeats a secret")
            }
        }
    }

    func testTheContractScopesMatchTheSDK() throws {
        let vectors = try loadVectors("device-login-vectors")
        XCTAssertEqual(.array(homeAssistantScopes.map { .string($0) }), vectors["home_assistant_scopes"])
    }

    func testAPendingPollIsStillAnApiErrorAndSaysHowLongToWait() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.init(status: 400, body: #"{"error": "slow_down"}"#))
        let api = ThalovantControlPlane(apiURL: "https://api.example.com", session: StubURLProtocol.makeSession())
        do {
            _ = try await api.pollDeviceLogin(DeviceAuthorizationGrant(deviceCode: "device-code-1", interval: 2))
            XCTFail("expected a pending poll")
        } catch let error as ThalovantApiError {
            // Old catch sites still match, and every api-errors field is there.
            XCTAssertEqual(error.kind, .deviceLoginPending(interval: 7))
            XCTAssertEqual(error.statusCode, 400)
            XCTAssertEqual(error.problem?["error"], .string("slow_down"))
        }
    }

    func testLoginWithBrowserKeepsTheTokenIdAndRevokeForgetsIt() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.init(body: """
            {"device_code": "device-code-1", "user_code": "WDJB-MJHT",
             "verification_uri": "https://dash.thalovant.com/activate", "expires_in": 900, "interval": 0}
            """))
        StubURLProtocol.enqueue(.init(body: """
            {"access_token": "device-token", "token_type": "bearer", "scopes": ["hubs:read"], "token_id": "token-1"}
            """))
        StubURLProtocol.enqueue(.init(status: 204, body: ""))
        let api = ThalovantControlPlane(apiURL: "https://api.example.com", session: StubURLProtocol.makeSession())
        _ = try await api.loginWithBrowser(options: DeviceLoginOptions(openBrowser: false, prompt: { _ in }))
        XCTAssertEqual(api.accessToken, "device-token")
        XCTAssertEqual(api.tokenId, "token-1")
        try await api.revokeApiToken()
        let revoke = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(revoke.method, "DELETE")
        XCTAssertEqual(revoke.url.absoluteString, "https://api.example.com/v1/auth/api-tokens/token-1")
        XCTAssertEqual(revoke.header("Authorization"), "Bearer device-token")
        XCTAssertNil(api.accessToken)
        XCTAssertNil(api.tokenId)
    }

    func testAPasswordSignInForgetsADeviceTokensId() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.init(body: #"{"access_token": "session-token", "token_type": "bearer"}"#))
        let api = ThalovantControlPlane(apiURL: "https://api.example.com", session: StubURLProtocol.makeSession())
        api.accessToken = "device-token"
        api.tokenId = "token-1"
        try await api.login(email: "dev@example.com", password: "secret")
        XCTAssertEqual(api.accessToken, "session-token")
        XCTAssertNil(api.tokenId, "revokeApiToken() must not revoke the device token by the session's name")
    }

    func testRevokingAnotherTokenKeepsTheOneInUse() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.init(status: 204, body: ""))
        let api = ThalovantControlPlane(
            apiURL: "https://api.example.com", accessToken: "session-token", session: StubURLProtocol.makeSession())
        api.tokenId = "token-1"
        try await api.revokeApiToken(tokenId: "token-2")
        XCTAssertEqual(StubURLProtocol.requests.last?.url.path, "/v1/auth/api-tokens/token-2")
        XCTAssertEqual(api.accessToken, "session-token")
        XCTAssertEqual(api.tokenId, "token-1")

        let bare = ThalovantControlPlane(apiURL: "https://api.example.com", session: StubURLProtocol.makeSession())
        do {
            try await bare.revokeApiToken()
            XCTFail("expected a local refusal")
        } catch let error as ThalovantApiError {
            XCTAssertNil(error.statusCode)
        }
    }
}
