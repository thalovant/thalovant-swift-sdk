import Foundation
import XCTest

@testable import ThalovantSDK

/// A create result, a control plane and a begun browser sign-in are printed by
/// `"\(x)"`, `String(describing:)`, `String(reflecting:)`, `dump()` and `Mirror`
/// without printing a secret. The stored values and
/// `asJSON(includeSecrets: true)` still carry the real data.
final class ReflectionRedactionTests: XCTestCase {
    private func makeResult() throws -> BootstrapIdentityResult {
        let identity = try ThalovantIdentity(json: [
            "access_key": .string("LEAK-ACCESS-KEY"),
            "password": .string("LEAK-PASSWORD"),
            "site_id": .string("bridge"),
            "default_master": .string("wss://home.example.com"),
            "default_port": .number(443),
            "mqtt": .object([
                "endpoint": .string("mqtts://m.example.com:8883"),
                "username": .string("LEAK-MQTT-USER"),
                "password": .string("LEAK-MQTT-PASSWORD"),
            ]),
        ])
        let hub: JSONObject = [
            "id": .string("hub-1"),
            "data_plane_endpoints": .object(["wss": .string("wss://hubuser:LEAK-HUB-URL@home.example.com")]),
        ]
        let client: JSONObject = [
            "id": .string("client-1"),
            "spec": .object(["connection_type": .string("connector"), "apiKey": .string("LEAK-SPEC-KEY"), "password": .string("LEAK-SPEC-PASSWORD")]),
            "initial_identify": .object(["access_key": .string("LEAK-ACCESS-KEY"), "password": .string("LEAK-PASSWORD")]),
            "initial_identify_token": .string("LEAK-TOKEN"),
        ]
        return BootstrapIdentityResult(
            identity: identity, hub: hub, client: client,
            endpoint: SelectedHubEndpoint(hubProtocol: .wss, endpoint: "wss://u:LEAK-ENDPOINT@home.example.com"))
    }

    private func views(_ value: Any) -> [String] {
        var dumped = ""
        dump(value, to: &dumped)
        var described = ""
        print(value, terminator: "", to: &described)
        let mirror = Mirror(reflecting: value).children.map { "\($0.label ?? ""):\($0.value)" }.joined(separator: "|")
        return ["\(value)", String(describing: value), String(reflecting: value), dumped, described, mirror,
                "\([value])", "\(["k": value])"]
    }

    private func assertClean(_ label: String, _ value: Any, file: StaticString = #filePath, line: UInt = #line) {
        for view in views(value) {
            XCTAssertFalse(view.contains("LEAK"), "\(label) printed a secret: \(view)", file: file, line: line)
        }
    }

    func testACreateResultPrintsNoSecretInAnyReflectionPath() throws {
        let result = try makeResult()
        assertClean("result", result)
        let text = "\(result)"
        XCTAssertTrue(text.contains("client-1") && text.contains("home.example.com"))
        // The stored values and the explicit form are unchanged.
        XCTAssertEqual(result.identity.accessKey, "LEAK-ACCESS-KEY")
        XCTAssertEqual(result.client["initial_identify_token"]?.stringValue, "LEAK-TOKEN")
        XCTAssertTrue("\(result.asJSON(includeSecrets: true))".contains("LEAK-ACCESS-KEY"))
        XCTAssertFalse("\(result.asJSON())".contains("LEAK"))
    }

    func testAControlPlanePrintsNoTokenInAnyReflectionPath() {
        let api = ThalovantControlPlane(apiURL: "https://api.example.com", accessToken: "LEAK-BEARER")
        assertClean("control plane", api)
        XCTAssertEqual(api.accessToken, "LEAK-BEARER")
        XCTAssertTrue("\(api)".contains("api.example.com"))
    }

    func testABegunBrowserSignInPrintsNeitherVerifierNorState() throws {
        let begun = try NativeSignIn.begin(clientID: "sdk", redirectURI: "myapp://auth")
        for view in views(begun) {
            XCTAssertFalse(view.contains(begun.verifier), "Begun printed its verifier: \(view)")
            XCTAssertFalse(view.contains(begun.state), "Begun printed its state: \(view)")
        }
        XCTAssertFalse(begun.verifier.isEmpty)
        XCTAssertNotNil(begun.code(from: "myapp://auth?code=abc&state=\(begun.state)"))
    }
}
