import Foundation
import XCTest

@testable import ThalovantSDK

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Proves the security hardening fixes: the bootstrap serializer redacts
/// hub/client credentials by default (F1), the secret-bearing types redact
/// every reflection/printing path (F8), transport errors never leak the
/// access-key-bearing connection URL (F7), and HTTP-failure errors never dump
/// the raw response body into human-facing text (F9). Each test also confirms
/// the intentional secret paths (`asJSON(includeSecrets:)`, the stored values,
/// and `ThalovantApiError.body`) still carry the real data.
final class SecurityHardeningTests: XCTestCase {
    private var api: ThalovantControlPlane!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        api = ThalovantControlPlane(
            apiURL: "https://api.example.com",
            accessToken: "token",
            session: StubURLProtocol.makeSession()
        )
    }

    // A hub resource carrying a stray secret field, to prove the hub branch is
    // redacted too, plus the endpoints/protocols the bootstrap needs.
    private let hubWithSecret: JSONObject = [
        "id": .string("b3b1f5a0-91b8-4a71-a2e5-53422dd0f841"),
        "slug": .string("hub-1"),
        "domain": .string("hub-1.hubs.thalovant.com"),
        "password": .string("HUB-SECRET"),
        "spec": .object(["protocols": .object(["wss": .object(["enabled": .bool(true)])])]),
        "data_plane_endpoints": .object([
            "https": .string("https://hub-1.hubs.thalovant.com"),
            "wss": .string("wss://hub-1.hubs.thalovant.com/ws"),
        ]),
    ]

    // The `POST /v1/clients` response body: `initial_identify` credentials, the
    // `initial_identify_token`, and the echoed `spec` — every secret F1 names.
    private static let clientResponse = """
    {
      "id": "11111111-aaaa-bbbb-cccc-222222222222",
      "name": "swift demo client",
      "active": true,
      "initial_identify": {
        "access_key": "AK-SECRET",
        "password": "PW-SECRET",
        "crypto_key": "CK-SECRET",
        "site_id": "swift-demo-client",
        "default_master": "https://hub-1.hubs.thalovant.com",
        "default_port": 443,
        "mqtt": {
          "endpoint": "mqtts://mqtt.hub-1.hubs.thalovant.com:8883",
          "username": "mqtt-user",
          "password": "MQTT-PW-SECRET",
          "tls": true
        }
      },
      "initial_identify_token": "IIT-SECRET",
      "spec": {
        "version": "1",
        "apiKey": "SPEC-AK-SECRET",
        "password": "SPEC-PW-SECRET",
        "cryptoKey": "SPEC-CK-SECRET",
        "siteId": "swift-demo-client"
      }
    }
    """

    private static let allBootstrapSecrets = [
        "AK-SECRET", "PW-SECRET", "CK-SECRET", "MQTT-PW-SECRET",
        "IIT-SECRET", "SPEC-AK-SECRET", "SPEC-PW-SECRET", "SPEC-CK-SECRET",
        "HUB-SECRET",
    ]

    private func bootstrapResult() async throws -> BootstrapIdentityResult {
        StubURLProtocol.enqueue(.init(body: Self.clientResponse))
        return try await api.createClientIdentity(
            hub: hubWithSecret,
            options: CreateClientIdentityOptions(name: "swift demo client")
        )
    }

    // MARK: F1 — bootstrap serializer redacts hub/client credentials by default

    func testBootstrapAsJSONRedactsHubAndClientSecretsByDefault() async throws {
        let result = try await bootstrapResult()
        let redacted = result.asJSON()

        // identity keeps its existing redaction.
        XCTAssertNil(redacted["identity"]?["access_key"])
        // client.initial_identify secrets are gone; non-secrets remain.
        let identify = redacted["client"]?["initial_identify"]
        XCTAssertNil(identify?["access_key"])
        XCTAssertNil(identify?["password"])
        XCTAssertNil(identify?["crypto_key"])
        XCTAssertNil(identify?["mqtt"]?["password"])
        XCTAssertEqual(identify?["site_id"]?.stringValue, "swift-demo-client")
        XCTAssertEqual(identify?["mqtt"]?["endpoint"]?.stringValue, "mqtts://mqtt.hub-1.hubs.thalovant.com:8883")
        // client.initial_identify_token and echoed spec secrets are gone.
        XCTAssertNil(redacted["client"]?["initial_identify_token"])
        XCTAssertNil(redacted["client"]?["spec"]?["apiKey"])
        XCTAssertNil(redacted["client"]?["spec"]?["password"])
        XCTAssertNil(redacted["client"]?["spec"]?["cryptoKey"])
        XCTAssertEqual(redacted["client"]?["spec"]?["version"]?.stringValue, "1")
        // hub secret is gone; hub identity remains.
        XCTAssertNil(redacted["hub"]?["password"])
        XCTAssertEqual(redacted["hub"]?["id"]?.stringValue, "b3b1f5a0-91b8-4a71-a2e5-53422dd0f841")

        // Belt and suspenders: no secret value survives serialization.
        let encoded = try ThalovantJSON.encodeToString(redacted)
        for secret in Self.allBootstrapSecrets {
            XCTAssertFalse(encoded.contains(secret), "leaked \(secret) in default asJSON()")
        }
    }

    func testBootstrapAsJSONIncludeSecretsStillReturnsRealCredentials() async throws {
        let result = try await bootstrapResult()
        let full = result.asJSON(includeSecrets: true)

        XCTAssertEqual(full["identity"]?["access_key"]?.stringValue, "AK-SECRET")
        XCTAssertEqual(full["client"]?["initial_identify"]?["access_key"]?.stringValue, "AK-SECRET")
        XCTAssertEqual(full["client"]?["initial_identify"]?["mqtt"]?["password"]?.stringValue, "MQTT-PW-SECRET")
        XCTAssertEqual(full["client"]?["initial_identify_token"]?.stringValue, "IIT-SECRET")
        XCTAssertEqual(full["client"]?["spec"]?["apiKey"]?.stringValue, "SPEC-AK-SECRET")
        XCTAssertEqual(full["hub"]?["password"]?.stringValue, "HUB-SECRET")
    }

    // MARK: F8 — secret-bearing types redact every reflection/printing path

    private func assertNoSecretsLeak<T>(_ value: T, secrets: [String], file: StaticString = #filePath, line: UInt = #line) {
        var dumped = ""
        dump(value, to: &dumped)
        let renderings = ["\(value)", String(describing: value), String(reflecting: value), dumped]
        for rendering in renderings {
            for secret in secrets {
                XCTAssertFalse(rendering.contains(secret), "leaked \(secret) via \(rendering)", file: file, line: line)
            }
            XCTAssertTrue(rendering.contains("<redacted>"), "no redaction marker in \(rendering)", file: file, line: line)
        }
    }

    func testIdentityAndMqttRedactAllReflectionPaths() throws {
        let identity = try ThalovantIdentity(json: try ThalovantJSON.decodeObject(Fixtures.clientIdentify))
        let identitySecrets = ["identity-access-key", "identity-password", "0123456789abcdefextra", "mqtt-pass"]
        assertNoSecretsLeak(identity, secrets: identitySecrets)
        XCTAssertTrue("\(identity)".contains("swift-demo-client"), "non-secret siteId should still print")

        let mqtt = try XCTUnwrap(identity.mqtt)
        assertNoSecretsLeak(mqtt, secrets: ["mqtt-pass"])

        // The intentional serializer path still carries the real credentials.
        let full = identity.asJSON(includeSecrets: true)
        XCTAssertEqual(full["access_key"]?.stringValue, "identity-access-key")
        XCTAssertEqual(full["password"]?.stringValue, "identity-password")
        XCTAssertEqual(full["mqtt"]?["password"]?.stringValue, "mqtt-pass")
        // And the stored values are untouched.
        XCTAssertEqual(identity.accessKey, "identity-access-key")
        XCTAssertEqual(mqtt.password, "mqtt-pass")
    }

    func testDeviceGrantAndResultRedactAllReflectionPaths() {
        let grant = DeviceAuthorizationGrant(
            deviceCode: "DC-SECRET",
            userCode: "WDJB-MJHT",
            verificationUri: "https://dash.thalovant.com/activate",
            verificationUriComplete: "https://dash.thalovant.com/activate?user_code=WDJB-MJHT",
            expiresIn: 900,
            interval: 5,
            raw: ["device_code": .string("DC-SECRET")]
        )
        assertNoSecretsLeak(grant, secrets: ["DC-SECRET"])
        XCTAssertTrue("\(grant)".contains("WDJB-MJHT"), "the user code is meant to be shown")
        XCTAssertEqual(grant.deviceCode, "DC-SECRET", "stored value untouched")

        let result = DeviceLoginResult(
            accessToken: "AT-SECRET",
            tokenType: "bearer",
            scopes: ["hubs:read"],
            expiresAt: "2027-01-01T00:00:00Z",
            tokenId: "token-1",
            raw: ["access_token": .string("AT-SECRET"), "token_id": .string("token-1")]
        )
        assertNoSecretsLeak(result, secrets: ["AT-SECRET"])
        XCTAssertTrue("\(result)".contains("token-1"), "non-secret token id should still print")
        XCTAssertEqual(result.accessToken, "AT-SECRET", "stored value untouched")
    }

    // MARK: F7 — transport errors never leak the connection URL / access key

    func testSafeTransportErrorMessageDropsAuthorizationQuery() {
        struct FakeURLError: Error { let failingURL: String }
        let leakURL = "wss://hub-1.hubs.thalovant.com/ws?authorization=BASE64ACCESSKEYSECRET"

        // The vector is real: reflecting a URL-bearing error exposes the query.
        let raw = FakeURLError(failingURL: leakURL)
        XCTAssertTrue("\(raw)".contains("authorization="))
        XCTAssertTrue("\(raw)".contains("BASE64ACCESSKEYSECRET"))
        // The fix keeps only the localized reason.
        XCTAssertFalse(safeTransportErrorMessage(raw).contains("authorization="))
        XCTAssertFalse(safeTransportErrorMessage(raw).contains("BASE64ACCESSKEYSECRET"))

        // The same holds for a genuine URLError-style NSError.
        let nsError = NSError(domain: "NSURLErrorDomain", code: -1004, userInfo: [
            "NSErrorFailingURLKey": leakURL,
            NSLocalizedDescriptionKey: "Could not connect to the server.",
        ])
        XCTAssertTrue(String(describing: nsError).contains("BASE64ACCESSKEYSECRET"), "vector is real")
        let safe = safeTransportErrorMessage(nsError)
        XCTAssertFalse(safe.contains("authorization="))
        XCTAssertFalse(safe.contains("BASE64ACCESSKEYSECRET"))
        XCTAssertFalse(safe.contains("wss://"))
    }

    // MARK: F9 — HTTP failures never dump the raw body into human-facing text

    func testHttpFailureBoundsServerDetailButKeepsRawBody() {
        let hugeMultilineBody = """
        {
          "detail": [
            {"loc": ["body", "spec", "password"], "msg": "invalid", "input": "SUPER-SECRET-PW"},
        \(String(repeating: "    {\"x\": \"padding padding padding padding\"},\n", count: 100))
          ]
        }
        """
        let error = ThalovantApiError.httpFailure(statusCode: 400, body: hugeMultilineBody)

        // Human-facing text: bounded, single line, and not the raw body.
        XCTAssertTrue(error.message.hasPrefix("Thalovant API request failed with HTTP 400"))
        XCTAssertFalse(error.message.contains("\n"), "server detail must be single-line")
        XCTAssertLessThan(error.message.count, 260, "server detail is length-bounded")
        XCTAssertLessThan(error.message.count, hugeMultilineBody.count, "must not be the raw body")
        // description and errorDescription (what a SwiftUI alert renders) match.
        XCTAssertEqual(error.description, error.message)
        XCTAssertEqual(error.errorDescription, error.message)
        // The full raw body is retained for programmatic use.
        XCTAssertEqual(error.body, hugeMultilineBody)
    }

    func testHttpFailureStillDecodesErrorCodeAndCarriesStatus() {
        let coded = ThalovantApiError.httpFailure(
            statusCode: 402,
            body: #"{"detail": {"code": "paid_plan_required", "message": "API access requires a paid plan."}}"#
        )
        XCTAssertEqual(coded.statusCode, 402)
        XCTAssertEqual(coded.errorCode, "paid_plan_required")
        XCTAssertTrue(coded.message.contains("HTTP 402"))

        // An empty body still yields a clean status-only message.
        let empty = ThalovantApiError.httpFailure(statusCode: 500, body: "")
        XCTAssertEqual(empty.message, "Thalovant API request failed with HTTP 500.")
    }

    func testBoundedServerDetailCollapsesWhitespaceAndCaps() {
        XCTAssertEqual(boundedServerDetail("  line1\n\n  line2\t tail  "), "line1 line2 tail")
        XCTAssertEqual(boundedServerDetail(""), "")
        let bounded = boundedServerDetail(String(repeating: "a", count: 500))
        XCTAssertEqual(bounded.count, 201, "200 characters plus the ellipsis")
        XCTAssertTrue(bounded.hasSuffix("…"))
    }
}
