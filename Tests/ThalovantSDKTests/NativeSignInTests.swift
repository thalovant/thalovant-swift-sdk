import XCTest
@testable import ThalovantSDK

/// The authorization-code grant, which every app that needed it wrote for
/// itself until this existed.
///
/// What is tested here is what is a security bug when wrong and looks fine
/// when wrong: that the challenge really is S256 of the verifier, that the
/// verifier never reaches the browser, that a redirect answering a different
/// attempt is refused, and that `plain` cannot be asked for.
final class NativeSignInTests: XCTestCase {

    private func query(_ url: String) -> [String: String] {
        var found: [String: String] = [:]
        for item in URLComponents(string: url)?.queryItems ?? [] {
            found[item.name] = item.value ?? ""
        }
        return found
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// FIPS 180-4 / NIST vectors. This SDK carries its own SHA-256 because
    /// CryptoKit is not on Linux, where CI builds it; a transcription slip in
    /// the constant table would produce challenges the API silently rejects.
    func testSHA256MatchesThePublishedVectors() {
        XCTAssertEqual(
            hex(SHA256.hash([])),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(
            hex(SHA256.hash(Array("abc".utf8))),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            hex(SHA256.hash(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        // Two blocks plus a length that lands exactly on the padding boundary.
        XCTAssertEqual(
            hex(SHA256.hash(Array(repeating: UInt8(ascii: "a"), count: 55))),
            "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
        XCTAssertEqual(
            hex(SHA256.hash(Array(repeating: UInt8(ascii: "a"), count: 56))),
            "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
    }

    func testTheChallengeIsTheS256OfTheVerifier() throws {
        let begun = try NativeSignIn.begin(clientID: "thalovant-ios", redirectURI: "thalovant://auth")
        let expected = NativeSignIn.base64URL(SHA256.hash(Array(begun.verifier.utf8)))
        XCTAssertEqual(query(begun.authorizationURL)["code_challenge"], expected)
    }

    func testTheVerifierNeverReachesTheBrowser() throws {
        let begun = try NativeSignIn.begin(clientID: "app", redirectURI: "app://auth")
        XCTAssertFalse(begun.authorizationURL.contains(begun.verifier))
    }

    func testOnlyS256IsOffered() throws {
        let begun = try NativeSignIn.begin(clientID: "app", redirectURI: "app://auth")
        XCTAssertEqual(query(begun.authorizationURL)["code_challenge_method"], "S256")
    }

    func testEveryAttemptGetsItsOwnVerifierAndState() throws {
        let first = try NativeSignIn.begin(clientID: "app", redirectURI: "app://auth")
        let second = try NativeSignIn.begin(clientID: "app", redirectURI: "app://auth")
        XCTAssertNotEqual(first.verifier, second.verifier)
        XCTAssertNotEqual(first.state, second.state)
    }

    func testTheRequestCarriesWhatTheAuthorizeEndpointMatchesOn() throws {
        let begun = try NativeSignIn.begin(
            clientID: "thalovant-ios",
            redirectURI: "thalovant://auth",
            scopes: ["hubs:read", "clients:write"])
        let parameters = query(begun.authorizationURL)
        XCTAssertEqual(parameters["client_id"], "thalovant-ios")
        XCTAssertEqual(parameters["redirect_uri"], "thalovant://auth")
        XCTAssertEqual(parameters["response_type"], "code")
        XCTAssertEqual(parameters["scope"], "hubs:read clients:write")
        XCTAssertEqual(parameters["state"], begun.state)
        XCTAssertTrue(begun.authorizationURL.hasPrefix("https://dash.thalovant.com/authorize?"))
    }

    func testARedirectAnsweringADifferentAttemptIsRefused() throws {
        let begun = try NativeSignIn.begin(clientID: "app", redirectURI: "app://auth")
        XCTAssertNil(begun.code(from: "app://auth?code=abc&state=somebody-elses"))
        XCTAssertEqual(begun.code(from: "app://auth?code=abc&state=\(begun.state)"), "abc")
    }

    func testNoCodeOrAnErrorIsNotSuccess() throws {
        let begun = try NativeSignIn.begin(clientID: "app", redirectURI: "app://auth")
        XCTAssertNil(begun.code(from: "app://auth?state=\(begun.state)"))
        XCTAssertNil(begun.code(from: "app://auth?code=&state=\(begun.state)"))
        XCTAssertNil(begun.code(from: "app://auth?error=access_denied&state=\(begun.state)"))
        XCTAssertNil(begun.code(from: "app://auth"))
    }

    func testAnEmptyClientOrRedirectIsRefusedHereRatherThanAtTheAPI() {
        XCTAssertThrowsError(try NativeSignIn.begin(clientID: "", redirectURI: "app://auth"))
        XCTAssertThrowsError(try NativeSignIn.begin(clientID: "app", redirectURI: "  "))
    }

    func testAThalovantURLIsRecognisedBySchemeAndHost() {
        XCTAssertTrue(NativeSignIn.isThalovantURL("https://dash.thalovant.com/authorize?x=1"))
        XCTAssertTrue(NativeSignIn.isThalovantURL("https://thalovant.com"))
        XCTAssertFalse(NativeSignIn.isThalovantURL("http://dash.thalovant.com"))
        // The one that matters: a lookalike host ending in the same letters.
        XCTAssertFalse(NativeSignIn.isThalovantURL("https://dash.thalovant.com.evil.test"))
        // A host that passes, reached through credentials reading as another.
        XCTAssertFalse(NativeSignIn.isThalovantURL("https://evil.test@dash.thalovant.com"))
        XCTAssertFalse(NativeSignIn.isThalovantURL("https://notthalovant.com"))
        XCTAssertFalse(NativeSignIn.isThalovantURL("nonsense"))
    }

    func testARefusalThatAlsoCarriesACodeIsStillARefusal() throws {
        // CodeRabbit caught this: checking only for a missing code accepted
        // error=access_denied&code=... and would have started an exchange on a
        // code the authorization server had just declined to issue.
        let begun = try NativeSignIn.begin(clientID: "app", redirectURI: "app://auth")
        XCTAssertNil(begun.code(from: "app://auth?error=access_denied&code=abc&state=\(begun.state)"))
        XCTAssertNil(begun.code(from: "app://auth?code=abc&error=server_error&state=\(begun.state)"))
    }

    func testTheTokenExchangeRefusesCleartextAndAllowsLoopback() {
        XCTAssertThrowsError(try NativeSignIn.requireSecureTokenExchange("http://control.example.test"))
        // Loopback has no cleartext to observe, and is how the API is run locally.
        for allowed in ["http://localhost:8080", "http://127.0.0.1:8080", "https://api.thalovant.com"] {
            XCTAssertNoThrow(try NativeSignIn.requireSecureTokenExchange(allowed), allowed)
        }
    }

    func testACallbackArrivingSomewhereElseIsRefused() throws {
        // CodeRabbit: state proves the answer belongs to this request; it does
        // not prove it came back to the app that made it.
        let begun = try NativeSignIn.begin(clientID: "app", redirectURI: "app://auth")
        XCTAssertEqual(begun.code(from: "app://auth?code=abc&state=\(begun.state)"), "abc")
        XCTAssertNil(begun.code(from: "app://elsewhere?code=abc&state=\(begun.state)"))
        XCTAssertNil(begun.code(from: "https://evil.test/auth?code=abc&state=\(begun.state)"))
    }

    func testADashboardThatIsNotSafeIsRefused() {
        for bad in [
            "http://dash.example.test",
            "https://evil.test@dash.thalovant.com",
            "ftp://dash.thalovant.com",
            // A fragment puts every parameter somewhere a browser never sends.
            "https://dash.example.test#section",
            "https://dash.example.test?next=/x",
        ] {
            XCTAssertThrowsError(
                try NativeSignIn.begin(clientID: "app", redirectURI: "app://auth", dashboardURL: bad), bad)
        }
        // Self-hosted https is real, and loopback never leaves the machine.
        for good in ["https://dash.example.test", "http://localhost:9000", "http://[::1]:9000"] {
            XCTAssertNoThrow(
                try NativeSignIn.begin(clientID: "app", redirectURI: "app://auth", dashboardURL: good), good)
        }
    }
}
