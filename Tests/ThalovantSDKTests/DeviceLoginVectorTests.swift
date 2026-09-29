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
        XCTAssertEqual(cases.count, 20)
        for row in cases {
            let name = try XCTUnwrap(row["name"]?.stringValue)
            let call = try XCTUnwrap(row["call"]?.objectValue, name)
            let exchanges = (row["exchanges"]?.arrayValue ?? []).compactMap(\.objectValue)
            ScriptedApi.serve(exchanges)
            // Only the approver's read is signed in; a device signing in has no token yet.
            let api = ScriptedApi.controlPlane(
                accessToken: call["op"]?.stringValue == "describe" ? "synthetic-token" : nil)
            var produced: [JSONValue] = []
            if call["op"]?.stringValue == "describe" {
                do {
                    let request = try await api.describeDeviceLogin(
                        userCode: try XCTUnwrap(call["user_code"]?.stringValue, name))
                    produced.append(.object([
                        "outcome": "described",
                        "scopes": .array(request.scopes.map { .string($0) }),
                        "client_name": request.clientName.map { .string($0) } ?? .null,
                        "client_id": request.clientId.map { .string($0) } ?? .null,
                        "client_verified": .bool(request.clientVerified),
                        "device_name": request.deviceName.map { .string($0) } ?? .null,
                    ]))
                } catch let error as ThalovantApiError {
                    produced.append(deviceError(error))
                }
            } else if call["op"]?.stringValue == "begin" {
                do {
                    let grant = try await api.beginDeviceLogin(
                        scopes: call["scopes"]?.arrayValue?.compactMap(\.stringValue),
                        clientName: call["client_name"]?.stringValue,
                        clientId: call["client_id"]?.stringValue
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
                    produced.append(deviceError(error))
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
                    // Idempotent: revoking again sends nothing and succeeds.
                    try await api.revokeApiToken()
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
                return deviceError(error)
            }
        } catch {
            XCTFail("\(name): \(error)")
            return .null
        }
    }

    /// A failure, with the api-errors fields when the API answered one.
    private func deviceError(_ error: ThalovantApiError) -> JSONValue {
        var produced: JSONObject = ["outcome": "error", "status": error.statusCode.map { .integer($0) } ?? .null]
        if error.statusCode != nil {
            produced["code"] = apiFields(error)["code"]
            produced["detail"] = apiFields(error)["detail"]
        }
        return .object(produced)
    }

    private func assertExcluded(_ error: ThalovantApiError, _ excludes: [String], _ name: String) {
        for secret in excludes {
            for form in printedForms(error) {
                XCTAssertFalse(form.contains(secret), "\(name): an error repeats a secret")
            }
        }
    }

    func testA2xxThatIsNotATokenObjectCarriesNoStatus() async throws {
        // Like a 2xx object with no token: the API did not refuse, the SDK
        // could not use its answer.
        for body in ["[]", "not json", "\"token\"", #"{"token_type": "bearer"}"#] {
            StubURLProtocol.reset()
            StubURLProtocol.enqueue(.init(status: 200, body: body))
            let api = ThalovantControlPlane(apiURL: "https://api.example.com", session: StubURLProtocol.makeSession())
            do {
                _ = try await api.pollDeviceLogin(DeviceAuthorizationGrant(deviceCode: "device-code-1"))
                XCTFail("\(body): expected an error")
            } catch let error as ThalovantApiError {
                XCTAssertNil(error.statusCode, body)
                XCTAssertEqual(error.kind, .other, body)
            }
            XCTAssertNil(api.accessToken, body)
        }
    }

    func testTheContractScopesMatchTheSDK() throws {
        let vectors = try loadVectors("device-login-vectors")
        XCTAssertEqual(.array(homeAssistantScopes.map { .string($0) }), vectors["home_assistant_scopes"])
        XCTAssertEqual(.string(homeAssistantClientId), vectors["home_assistant_client_id"])
    }

    func testTheSignaturesBefore0101StillCompile() {
        // clientId came as overloads, not as a defaulted parameter: a
        // reference to the old names still resolves.
        let makeOptions: ([String]?, String?, Bool, @escaping @Sendable (DeviceAuthorizationGrant) -> Void, TimeInterval)
            -> DeviceLoginOptions = DeviceLoginOptions.init(scopes:clientName:openBrowser:prompt:timeout:)
        XCTAssertNil(makeOptions(nil, nil, false, { _ in }, 1).clientId)
        XCTAssertEqual(DeviceLoginOptions(clientId: homeAssistantClientId).clientId, homeAssistantClientId)
        let api = ThalovantControlPlane(apiURL: "https://api.example.com")
        let begin: ([String]?, String?) async throws -> DeviceAuthorizationGrant = api.beginDeviceLogin(scopes:clientName:)
        _ = begin
    }

    func testLoginWithBrowserSignsInAsTheAppItNames() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.init(body: #"{"device_code": "dc-1", "user_code": "WDJB-MJHT", "verification_uri": "https://thalovant.com/activate", "interval": 1}"#))
        StubURLProtocol.enqueue(.init(body: #"{"access_token": "api-token", "token_id": "token-1"}"#))
        let api = ThalovantControlPlane(apiURL: "https://api.example.com", session: StubURLProtocol.makeSession())
        try await api.loginWithBrowser(options: DeviceLoginOptions(
            scopes: homeAssistantScopes, clientName: "Home Assistant (kitchen)", openBrowser: false,
            prompt: { _ in }, clientId: homeAssistantClientId))
        let begin = try XCTUnwrap(StubURLProtocol.requests.first?.bodyObject())
        XCTAssertEqual(begin["client_id"], "thalovant-home-assistant")
        XCTAssertEqual(begin["client_name"], "Home Assistant (kitchen)")
        XCTAssertEqual(api.tokenId, "token-1")
    }

    func testDescribingACodeReadsItAsTheApproverSeesIt() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.init(body: #"{"scopes": ["hubs:read"], "client_name": "Home Assistant", "client_verified": true, "expires_at": "2026-09-28T12:15:00Z"}"#))
        let api = ThalovantControlPlane(
            apiURL: "https://api.example.com", accessToken: "approver", session: StubURLProtocol.makeSession())
        let request = try await api.describeDeviceLogin(userCode: "WDJB/MJHT")
        XCTAssertEqual(StubURLProtocol.requests.first?.url.absoluteString, "https://api.example.com/v1/auth/device/codes/WDJB%2FMJHT")
        XCTAssertEqual(StubURLProtocol.requests.first?.header("Authorization"), "Bearer approver")
        XCTAssertEqual(request.scopes, ["hubs:read"])
        XCTAssertEqual(request.expiresAt, "2026-09-28T12:15:00Z")
        // Verified only with the app named: a bare true says nothing about who asked.
        XCTAssertNil(request.clientId)
        XCTAssertFalse(request.clientVerified)
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

    func testEverySignInSetsTheTokenIdFromItsOwnAnswer() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.init(body: #"{"access_token": "session-token", "token_type": "bearer"}"#))
        StubURLProtocol.enqueue(.init(body: #"{"access_token": "api-token", "token_id": "token-2"}"#))
        let api = ThalovantControlPlane(apiURL: "https://api.example.com", session: StubURLProtocol.makeSession())
        api.accessToken = "device-token"
        api.tokenId = "token-1"
        try await api.login(email: "dev@example.com", password: "secret")
        XCTAssertEqual(api.accessToken, "session-token")
        XCTAssertNil(api.tokenId, "revokeApiToken() must not revoke the device token by the session's name")
        try await api.login(email: "dev@example.com", password: "secret")
        XCTAssertEqual(api.tokenId, "token-2")
    }

    func testARevokeDoesNotForgetASignInThatCompletedDuringIt() async throws {
        HeldAPI.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldAPI.self]
        let api = ThalovantControlPlane(
            apiURL: "https://api.example.com", accessToken: "old-token", session: URLSession(configuration: configuration))
        api.tokenId = "token-1"
        let revoke = Task { try await api.revokeApiToken() }
        // The revoke's DELETE is on its way; a new sign-in lands meanwhile.
        try await eventually { HeldAPI.started }
        XCTAssertEqual(HeldAPI.path, "/v1/auth/api-tokens/token-1")
        api.accessToken = "new-token"
        api.tokenId = "token-2"
        HeldAPI.release()
        try await revoke.value
        XCTAssertEqual(api.accessToken, "new-token")
        XCTAssertEqual(api.tokenId, "token-2")
    }

    /// The same race on two threads: a revoke's check-and-clear against a
    /// sign-in's write. Whichever lands first, the sign-in's token and id are
    /// what is left, together -- never one of them, never neither.
    func testARevokeOnAnotherThreadCannotTearASignIn() throws {
        let api = ThalovantControlPlane(apiURL: "https://api.example.com", session: StubURLProtocol.makeSession())
        let signIn: JSONObject = ["access_token": "new-token", "token_id": "token-2"]
        var torn: [ThalovantControlPlane.Credentials] = []
        for _ in 0..<20_000 {
            api.accessToken = "old-token"
            api.tokenId = "token-1"
            let revoked = api.credentialSnapshot()
            DispatchQueue.concurrentPerform(iterations: 2) { lane in
                if lane == 0 {
                    _ = try? api.keepSignIn(signIn)
                } else {
                    api.forgetRevoked(revoked)
                }
            }
            let left = api.credentialSnapshot()
            if left != .init(accessToken: "new-token", tokenId: "token-2") { torn.append(left) }
        }
        XCTAssertEqual(torn.count, 0, "a revoke tore a sign-in: \(torn.prefix(3))")
    }

    func testRevokingTheTokenInUseIsIdempotentButAnotherTokensRefusalIsNot() async throws {
        StubURLProtocol.reset()
        // The token in use was revoked elsewhere: it cannot authenticate its own revoke.
        StubURLProtocol.enqueue(.init(status: 401, body: #"{"detail": "Could not validate credentials"}"#))
        let api = ThalovantControlPlane(
            apiURL: "https://api.example.com", accessToken: "dead-token", session: StubURLProtocol.makeSession())
        api.tokenId = "token-1"
        try await api.revokeApiToken()
        XCTAssertNil(api.accessToken)
        XCTAssertNil(api.tokenId)
        try await api.revokeApiToken()
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "revoking again sends nothing")

        // Another token's 404 or 401 is the API's answer, and is thrown.
        StubURLProtocol.reset()
        StubURLProtocol.enqueue(.init(status: 404, body: #"{"detail": "API token not found"}"#))
        StubURLProtocol.enqueue(.init(status: 401, body: #"{"detail": "Could not validate credentials"}"#))
        let other = ThalovantControlPlane(
            apiURL: "https://api.example.com", accessToken: "live-token", session: StubURLProtocol.makeSession())
        other.tokenId = "token-1"
        for _ in 0..<2 {
            do {
                try await other.revokeApiToken(tokenId: "token-9")
                XCTFail("expected the API's refusal")
            } catch is ThalovantApiError {}
        }
        XCTAssertEqual(other.accessToken, "live-token")
        XCTAssertEqual(other.tokenId, "token-1")
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

/// Holds each request until released, then answers 204.
private final class HeldAPI: URLProtocol {
    private static let lock = NSLock()
    private static var didStart = false
    private static var seenPath: String?
    private static var gate = DispatchSemaphore(value: 0)
    static var started: Bool { lock.locked { didStart } }
    static var path: String? { lock.locked { seenPath } }
    static func reset() { lock.locked { didStart = false; seenPath = nil; gate = DispatchSemaphore(value: 0) } }
    static func release() { lock.locked { gate }.signal() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let gate = Self.lock.locked { () -> DispatchSemaphore in
            Self.didStart = true
            Self.seenPath = request.url?.path
            return Self.gate
        }
        let answer = HeldAnswer(self)
        DispatchQueue.global().async {
            gate.wait()
            answer.send()
        }
    }
    override func stopLoading() {}
}

/// A held request's 204, sent from another queue once released.
private final class HeldAnswer: @unchecked Sendable {
    private let loading: URLProtocol
    init(_ loading: URLProtocol) { self.loading = loading }
    func send() {
        let response = HTTPURLResponse(
            url: loading.request.url ?? URL(string: "https://api.example.com")!, statusCode: 204,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])!
        loading.client?.urlProtocol(loading, didReceive: response, cacheStoragePolicy: .notAllowed)
        loading.client?.urlProtocolDidFinishLoading(loading)
    }
}
