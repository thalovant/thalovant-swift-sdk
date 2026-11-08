import Foundation
import XCTest

@testable import ThalovantSDK

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Browser sign-in beyond the shared vectors: what is shown and opened, the
/// generated secrets, the configuration's own edges, the chooser's device
/// path, and what never reaches an error. `BrowserLoginVectorTests` runs the
/// contract every SDK shares; these are the parts that are this SDK's own, or
/// that are about what must not happen. They run on every platform;
/// `BrowserLoginListenerTests` below needs the loopback listener (macOS, Linux).
final class BrowserLoginTests: XCTestCase {
    static let config = """
        {"authorization_endpoint": "https://dash.thalovant.com/authorize", "token_endpoint": "/v1/auth/native/token",
         "device_authorization_endpoint": "/v1/auth/device/authorize", "sdk_client_id": "thalovant-sdk",
         "loopback_redirect_uri": "http://127.0.0.1:{port}/callback", "code_challenge_methods_supported": ["S256"]}
        """
    static let token = """
        {"access_token": "tvpat_unit_token", "token_type": "bearer", "scopes": ["hubs:read"],
         "expires_at": "2027-11-08T12:00:00Z", "token_id": "tok-unit", "ai_disclosure": "AI"}
        """
    static let deviceGrant = """
        {"device_code": "dc-unit", "user_code": "WDJB-MJHT", "verification_uri": "https://thalovant.com/activate",
         "verification_uri_complete": "https://thalovant.com/activate?code=WDJB-MJHT", "interval": 0}
        """

    /// The device-login routes.
    static func serveDeviceLogin() {
        UnitApi.serve { _, path, _ in
            switch path {
            case "/v1/auth/device/authorize": return .init(200, Self.deviceGrant)
            case "/v1/auth/device/token": return .init(200, Self.token)
            default: return .init(599, "{}")
            }
        }
    }

    // MARK: What the person sees

    func testTheNoticeShowsTheURLOnTheLineAfter() {
        XCTAssertEqual(
            BrowserLogin.notice(for: "https://x.test/a", openBrowser: true),
            "Opening your browser to sign in to Thalovant. If it does not open, visit:\nhttps://x.test/a")
        XCTAssertEqual(BrowserLogin.notice(for: "https://x.test/a", openBrowser: false), "To sign in to Thalovant, visit:\nhttps://x.test/a")
    }

    func testTheDeviceNameDefaultsToThisSDKOnThisHost() {
        XCTAssertEqual(BrowserLogin.deviceName(host: "workstation"), "thalovant-swift-sdk on workstation")
        XCTAssertEqual(BrowserLogin.deviceName(host: String(repeating: "h", count: 300)).unicodeScalars.count, 120)
        XCTAssertEqual(BrowserLogin.deviceName(host: ""), "thalovant-swift-sdk")
        XCTAssertTrue(BrowserLogin.defaultDeviceName().hasPrefix("thalovant-swift-sdk"))
        XCTAssertLessThanOrEqual(BrowserLogin.defaultDeviceName().unicodeScalars.count, 120)
        // Code points, not grapheme clusters: a flag is two of them.
        XCTAssertEqual(BrowserLogin.truncatedToCodePoints("🇨🇦🇫🇷", 3).unicodeScalars.count, 3)
    }

    // MARK: The secrets

    func testEveryVerifierAndStateIsFreshAndWellFormed() {
        let verifiers = Set((0..<50).map { _ in BrowserLogin.newVerifier() })
        let states = Set((0..<50).map { _ in BrowserLogin.newState() })
        XCTAssertEqual(verifiers.count, 50)
        XCTAssertEqual(states.count, 50)
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let base64URL = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        for verifier in verifiers {
            XCTAssertEqual(verifier.count, 86)
            XCTAssertTrue(verifier.unicodeScalars.allSatisfy(unreserved.contains))
        }
        for state in states {
            // 24 random bytes: 192 bits, well over the 128 the contract asks for.
            XCTAssertEqual(state.count, 32)
            XCTAssertTrue(state.unicodeScalars.allSatisfy(base64URL.contains))
        }
        XCTAssertEqual(BrowserLogin.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testScrubbingIsOnePassAndLeavesItsMarkerAlone() {
        let hidden = ["abc", "abcdef", "c"]
        XCTAssertEqual(redacting("xx-abc-abcdef-[redacted]", hidden), "xx-[redacted]-[redacted]-[redacted]")
        let once = redacting(.object(["seen:abcdef": ["c", ["deep": "abc"]]]), hidden)
        XCTAssertEqual(once, .object(["seen:[redacted]": ["[redacted]", ["deep": "[redacted]"]]]))
        XCTAssertEqual(redacting(once, hidden), once)
        XCTAssertEqual(redacting("nothing hidden", []), "nothing hidden")
        // A short value inside a longer one cannot break the longer one up, in
        // either order, and overlapping values leave nothing of either.
        XCTAssertEqual(redacting("zabq", ["ab", "zabq"]), "[redacted]")
        XCTAssertEqual(redacting("zabq", ["zabq", "ab"]), "[redacted]")
        XCTAssertEqual(redacting("<abcde>", ["abc", "cde"]), "<[redacted]>")
        // A secret that contains the marker is still taken out; one that lies
        // wholly inside an existing marker is not, and a marker a match runs
        // into is replaced whole.
        XCTAssertEqual(redacting("echo a[redacted]b end", ["a[redacted]b"]), "echo [redacted] end")
        XCTAssertEqual(redacting("echo [redacted] end", ["dact"]), "echo [redacted] end")
        XCTAssertEqual(redacting("xab[redacted]y", ["b[re"]), "xa[redacted]y")
        for (text, hidden) in [("echo a[redacted]b end", ["a[redacted]b"]), ("xab[redacted]y", ["b[re"]), ("c-[redacted]-c", ["c"])] {
            let once = redacting(text, hidden)
            XCTAssertEqual(redacting(once, hidden), once, text)
        }
    }

    func testScrubbingMakesANewErrorFromTheScrubbedFieldsAlone() {
        let original = ThalovantApiError(
            message: "failed for code-123", statusCode: 422,
            body: #"{"detail": [{"input": "code-123"}], "seen:code-123": "x"}"#)
        let clean = original.withoutSecrets(["code-123"])
        XCTAssertEqual(clean.statusCode, 422)
        let shown = printedForms(clean) + [clean.body ?? "", String(describing: clean.problem)]
        XCTAssertFalse(shown.contains { $0.contains("code-123") })
        XCTAssertEqual(clean.problem?["seen:[redacted]"], "x")
        XCTAssertEqual(clean.message, "failed for [redacted]")
    }

    func testOnlyRFC6749ErrorsAreKeptFromACallback() {
        let state = "Xx0-_yLq7m3Vw9ZtR2cKp4HdN8sFjB6a"
        for error in ["invalid_request", "unauthorized_client", "unsupported_response_type", "invalid_scope",
                      "server_error", "temporarily_unavailable"] {
            XCTAssertEqual(classifyLoopbackRequest(method: "GET", target: "/callback?error=\(error)&state=\(state)", state: state).callback,
                           .failed(error: error))
        }
        for error in ["not-an-oauth-code", state, "denied-\(state)", "Server_Error", "access_denied%20"] {
            let (status, callback) = classifyLoopbackRequest(
                method: "GET", target: "/callback?error=\(error)&state=\(state)", state: state)
            XCTAssertEqual(status, 200)
            XCTAssertEqual(callback, .failed(error: nil), error)
        }
    }

    func testACallbackIsNeverPrintedWithItsCode() {
        XCTAssertFalse(String(describing: LoopbackCallback.code("nc_secret")).contains("nc_secret"))
        XCTAssertFalse(String(reflecting: LoopbackCallback.code("nc_secret")).contains("nc_secret"))
    }

    // MARK: No request leaves the API

    func testNoRequestLeavesTheAPIOrigin() throws {
        let plane = UnitApi.controlPlane()
        let api = try XCTUnwrap(URL(string: plane.apiURL))
        // Joined by concatenation onto the API's own address: whatever the
        // path says, the host is the API's, and so is the token.
        for path in ["/https://elsewhere.example/v1/x", "/elsewhere.example:443/v1/x", "https://elsewhere.example/v1/x",
                     "//elsewhere.example/v1/x", "/v1/x@elsewhere.example", "/%2F%2Felsewhere.example/x"] {
            let request = try plane.buildRequest("GET", path, auth: false)
            XCTAssertEqual(ThalovantControlPlane.origin(of: try XCTUnwrap(request.url)), ThalovantControlPlane.origin(of: api), path)
        }
        let origin = ThalovantControlPlane.origin
        XCTAssertEqual(origin(URL(string: "https://API.example.com/x")!), origin(URL(string: "https://api.example.com:443/y")!))
        XCTAssertNotEqual(origin(URL(string: "https://api.example.com/x")!), origin(URL(string: "https://api.example.com:8443/x")!))
        XCTAssertNotEqual(origin(URL(string: "https://api.example.com/x")!), origin(URL(string: "http://api.example.com/x")!))
        XCTAssertNotEqual(origin(URL(string: "https://api.example.com/x")!), origin(URL(string: "https://elsewhere.example/x")!))
    }

    // MARK: The token

    func testTheTokenIdComesFromTheExchangeAnswer() throws {
        let plane = UnitApi.controlPlane()
        plane.tokenId = "an-earlier-token"
        let kept = try plane.browserTokenResult(["access_token": "tvpat_a", "token_id": "tok-a", "token_type": "bearer"])
        XCTAssertEqual(kept.tokenId, "tok-a")
        XCTAssertEqual(plane.accessToken, "tvpat_a")
        XCTAssertEqual(plane.tokenId, "tok-a")
        XCTAssertNil(try plane.browserTokenResult(["access_token": "tvpat_b", "token_id": ""]).tokenId)
        XCTAssertNil(try plane.browserTokenResult(["access_token": "tvpat_c"]).tokenId)
        XCTAssertNil(plane.tokenId)
        XCTAssertThrowsError(try plane.browserTokenResult(["token_type": "bearer"])) { error in
            XCTAssertNil((error as? ThalovantApiError)?.statusCode)
        }
    }

    // MARK: The chooser's device path

    func testADeviceLoginChosenByTheChooserOpensItsPageWithTheOpener() async throws {
        Self.serveDeviceLogin()
        let opened = LockedBox<String>()
        let plane = UnitApi.controlPlane()
        let token = try await plane.interactiveLogin(options: InteractiveLoginOptions(
            method: .device, deviceName: "unit", opener: { opened.setOnce($0.absoluteString) }))
        XCTAssertEqual(token.tokenId, "tok-unit")
        try await eventually { opened.value != nil }
        XCTAssertEqual(opened.value, "https://thalovant.com/activate?code=WDJB-MJHT")
        XCTAssertEqual(UnitApi.requests, ["POST /v1/auth/device/authorize", "POST /v1/auth/device/token"])
    }

    /// An opener that waits for a console browser to exit holds neither the
    /// polls nor their timeout.
    func testTheChoosersDeviceOpenerDoesNotHoldThePolls() async throws {
        Self.serveDeviceLogin()
        let release = DispatchSemaphore(value: 0)
        let opened = LockedBox<Bool>()
        let plane = UnitApi.controlPlane()
        let started = ProcessInfo.processInfo.systemUptime
        let token = try await plane.interactiveLogin(options: InteractiveLoginOptions(
            method: .device, deviceName: "unit", opener: { _ in
                opened.setOnce(true)
                _ = release.wait(timeout: .now() + 10)
            }))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 5)
        release.signal()
        XCTAssertEqual(token.accessToken, "tvpat_unit_token")
        try await eventually { opened.value == true }
    }

    func testAnEmptyDeviceNameIsNotSentToADeviceLogin() async throws {
        UnitApi.serve { _, path, _ in
            path == "/v1/auth/device/authorize" ? .init(200, Self.deviceGrant) : .init(200, Self.token)
        }
        let plane = UnitApi.controlPlane()
        try await plane.interactiveLogin(options: InteractiveLoginOptions(method: .device, deviceName: "", openBrowser: false))
        XCTAssertEqual(UnitApi.bodies.first, .object([:]))
        try await plane.interactiveLogin(options: InteractiveLoginOptions(method: .device, openBrowser: false))
        XCTAssertEqual(UnitApi.bodies.dropFirst(2).first??["client_name"], .string(BrowserLogin.defaultDeviceName()))
    }

    #if !(os(macOS) || os(Linux))
    /// No loopback listener here: the chooser signs in with a device login,
    /// and a forced browser sign-in says why it cannot.
    func testWithoutAListenerTheChooserUsesDeviceLogin() async throws {
        XCTAssertFalse(BrowserLogin.isAvailable)
        Self.serveDeviceLogin()
        let plane = UnitApi.controlPlane()
        var auto = InteractiveLoginOptions(openBrowser: false)
        auto.environment = ["DISPLAY": ":0"]
        auto.platform = "macos"
        let token = try await plane.interactiveLogin(options: auto)
        XCTAssertEqual(token.tokenId, "tok-unit")
        XCTAssertFalse(UnitApi.requests.contains("GET /v1/auth/native/config"))
        do {
            try await plane.interactiveLogin(options: InteractiveLoginOptions(method: .browser, openBrowser: false))
            XCTFail("expected browser sign-in to be unavailable")
        } catch let error as ThalovantApiError {
            XCTAssertNil(error.statusCode)
        }
    }
    #endif

    // MARK: The remaining edges

    func testThisMachineIsNamedAsTheBrowserRuleNamesIt() {
        #if os(Linux)
        XCTAssertEqual(BrowserLogin.platformName, "linux")
        XCTAssertTrue(BrowserLogin.isAvailable)
        #elseif os(macOS)
        XCTAssertEqual(BrowserLogin.platformName, "macos")
        XCTAssertTrue(BrowserLogin.isAvailable)
        #endif
    }

    func testTheBrowserRuleReadsThisProcessByDefault() {
        XCTAssertEqual(
            BrowserLogin.canOpenBrowser(),
            BrowserLogin.canOpenBrowser(environment: ProcessInfo.processInfo.environment, platform: BrowserLogin.platformName))
        XCTAssertFalse(BrowserLogin.canOpenBrowser(environment: [:], platform: "ios"))
        XCTAssertFalse(BrowserLogin.canOpenBrowser(environment: [:], platform: "linux"))
    }

    func testAnAuthorizationEndpointNoBrowserCanOpenIsUnusable() {
        for endpoint in ["https://dash.thalovant.com/author\u{07}ize", "https://dash.thalovant.com /authorize",
                         "https://dash.thalovant.com:99999/authorize", "https://[::1/authorize", "https://dash.thalovant.com:8x/authorize",
                         "https://[127.0.0.1]/authorize", "https:dash.thalovant.com/authorize", "https:///authorize",
                         "ftp://dash.thalovant.com/authorize", "http://[::2]/authorize", "https://dash.thalovant.com/a\u{2028}b",
                         "https://dash.thalovant.com/authorize?", "1https://dash.thalovant.com/authorize",
                         // Anything around the brackets but an optional port.
                         "http://[::1]junk/authorize", "http://[::1]junk:5173/authorize", "https://x[::1]/authorize",
                         "https://[::1]:0/authorize",
                         // Port 0, and hosts that are not a real hostname or address.
                         "https://dash.thalovant.com:0/authorize", "https://%/authorize", "https://dash..thalovant.com/authorize",
                         "https://dash_staging.thalovant.com/authorize", "https://dash.thalovânt.com/authorize",
                         "https://999.1.1.1/authorize", "https://1.2.3/authorize", "https://01.2.3.4/authorize",
                         "https://dash.thalovant.com./authorize", "https://-dash.thalovant.com/authorize",
                         "https://\(String(repeating: "a", count: 64)).example/authorize",
                         // An IPv6 zone is not empty and holds no second `%`, as the reference reads it.
                         "https://[::1%]/authorize", "https://[::1%a%b]/authorize"] {
            XCTAssertFalse(NativeSignInConfig.usableAuthorizationEndpoint(endpoint), endpoint)
        }
        for endpoint in ["https://dash.thalovant.com/authorize", "HTTPS://Dash.Thalovant.com/authorize", "http://[::1]:5173/authorize",
                         "http://LOCALHOST:5173/authorize", "https://[2001:db8::1]:8443/authorize", "https://dash.thalovant.com:/authorize",
                         "http://127.0.0.1/authorize", "https://[::1]/authorize", "https://192.0.2.10/authorize",
                         "https://xn--dsh-0na.example/authorize", "https://dash.thalovant.com:65535/authorize",
                         "https://1.example/authorize", "https://[::1]:/authorize", "https://[fe80::1%25eth0]/authorize",
                         // Only a decimal last label is numeric here, as the reference
                         // (`_real_host`, Python #113 at 39e31d8) reads it: the
                         // cross-SDK contract decides which configurations are usable.
                         "https://auth.0x1/authorize"] {
            XCTAssertTrue(NativeSignInConfig.usableAuthorizationEndpoint(endpoint), endpoint)
        }
    }

    func testATokenEndpointAndAClientIdAreReadStrictly() {
        for path in ["/v1/auth/native/token", "/v1/auth/native/%74oken", "/v1/%2F%2fx"] {
            XCTAssertTrue(NativeSignInConfig.usableTokenEndpoint(path), path)
        }
        for path in ["v1/auth/native/token", "//evil/x", "/v1/x#y", "/v1\\x", "/v1/ x", "/v1/x\u{85}",
                     "/https://collector.example/token", "/collector.example:443/token", "/v1/a:b",
                     "/v1/auth/native/%zz", "/v1/auth/native/token%", "/v1/%4", "/v1/%G1"] {
            XCTAssertFalse(NativeSignInConfig.usableTokenEndpoint(path), path)
        }
        XCTAssertTrue(NativeSignInConfig.usableClientId("thalovant-sdk_2.x"))
        for id in ["", String(repeating: "a", count: 65), "thalovant sdk", "thalovant/sdk", "thålovant"] {
            XCTAssertFalse(NativeSignInConfig.usableClientId(id), id)
        }
    }

    func testAConfigurationThatIsNotAnObjectIsUnusable() {
        for payload: JSONValue in [["not", "an", "object"], .null, "config", 1] {
            XCTAssertThrowsError(try NativeSignInConfig(payload: payload)) { error in
                XCTAssertNil((error as? ThalovantApiError)?.statusCode)
            }
        }
        XCTAssertNil(try NativeSignInConfig(response: [
            "authorization_endpoint": "https://dash.thalovant.com/authorize", "token_endpoint": "/v1/auth/native/token",
            "sdk_client_id": "thalovant-sdk", "code_challenge_methods_supported": ["S256"],
        ]).deviceAuthorizationEndpoint)
    }

    func testQueryValuesAreDecodedOnceAsAFormDecodesThem() {
        XCTAssertEqual(formDecode("a%2Bb%2Fc%3D%2541"), "a+b/c=%41")
        XCTAssertEqual(formDecode("a+b"), "a b")
        XCTAssertEqual(formDecode("%G1%4"), "%G1%4")
        XCTAssertEqual(formDecode("%C3%A9t%C3%A9"), "été")
        XCTAssertEqual(formDecode("%E9"), "\u{FFFD}")
        XCTAssertEqual(loopbackFormPairs("a&&b=&=c&d=1=2").map { [$0.0, $0.1] }, [["a", ""], ["b", ""], ["", "c"], ["d", "1=2"]])
    }

    func testAHeadAnswerCarriesTheHeadersAndNoBody() {
        let full = loopbackResponse(status: 404, text: loopbackNotFoundText)
        let head = loopbackResponse(status: 404, text: loopbackNotFoundText, head: true)
        let text = String(decoding: head, as: UTF8.self)
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
        XCTAssertTrue(text.contains("Content-Length: \(Array(loopbackPage(loopbackNotFoundText).utf8).count)\r\n"))
        XCTAssertEqual(Array(full.prefix(head.count)), head)
    }
}

#if os(macOS) || os(Linux)

/// The loopback listener and `browserLogin`, for real: macOS and Linux.
final class BrowserLoginListenerTests: XCTestCase {
    /// The config and token routes; the token route answers with `token`.
    private func serve(token: @escaping @Sendable (JSONValue?) -> UnitApi.Answer = { _ in .init(200, BrowserLoginTests.token) }) {
        UnitApi.serve { _, path, body in
            switch path {
            case "/v1/auth/native/config": return .init(200, BrowserLoginTests.config)
            case "/v1/auth/native/token": return token(body)
            default: return .init(599, "{}")
            }
        }
    }

    /// Starts a sign-in whose URL is handed to the test rather than printed.
    private func begin(
        _ plane: ThalovantControlPlane, _ options: BrowserLoginOptions = BrowserLoginOptions(openBrowser: false)
    ) async throws -> (Task<Result<DeviceLoginResult, Error>, Never>, port: Int, state: String, query: [String: String]) {
        let opened = LockedBox<String>()
        var base = options
        base.prompt = { opened.setOnce($0) }
        let run = base
        let task = Task { () -> Result<DeviceLoginResult, Error> in
            do { return .success(try await plane.browserLogin(options: run)) } catch { return .failure(error) }
        }
        try await eventually { opened.value != nil }
        let (port, state, query) = try parts(try XCTUnwrap(opened.value))
        return (task, port, state, query)
    }

    private func parts(_ url: String) throws -> (Int, String, [String: String]) {
        let signing = try Signing(url)
        var query: [String: String] = [:]
        for pair in signing.pairs { query[pair[0]] = pair[1] }
        return (signing.port, signing.state, query)
    }

    // MARK: What the person sees

    /// A console browser can hold the call until it exits. This one plays the
    /// tab and then holds on until the sign-in has returned, which it could not
    /// do if it were opened on the waiting path.
    func testTheBrowserIsOpenedOffTheWaitingTaskWithTheURLThePromptGot() async throws {
        serve()
        let plane = UnitApi.controlPlane()
        let shown = LockedBox<String>()
        let opened = LockedBox<String>()
        let tab = LockedBox<String>()
        let release = DispatchSemaphore(value: 0)
        let started = ProcessInfo.processInfo.systemUptime
        let options = BrowserLoginOptions(
            deviceName: "unit",
            prompt: { shown.setOnce($0) },
            opener: { url in
                opened.setOnce(url.absoluteString)
                guard let parsed = try? self.parts(url.absoluteString),
                      let answer = try? RawConnection(port: parsed.0) else { return }
                answer.send(Array("GET /callback?code=c&state=\(parsed.1) HTTP/1.1\r\n\r\n".utf8))
                tab.setOnce((try? RawHTTP.parse(answer.readAll()))?.body ?? "")
                answer.close()
                _ = release.wait(timeout: .now() + 10)
            })
        let token = try await plane.browserLogin(options: options)
        // Opened on the waiting path, the sign-in would never have ended.
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 5)
        release.signal()
        XCTAssertEqual(token.accessToken, "tvpat_unit_token")
        XCTAssertEqual(token.raw["ai_disclosure"], "AI")
        XCTAssertEqual(plane.tokenId, "tok-unit")
        XCTAssertEqual(opened.value, shown.value)
        try await eventually { tab.value != nil }
        XCTAssertTrue(tab.value?.contains("Signed in to Thalovant. You can close this tab.") == true, tab.value ?? "")
    }

    func testWithoutOpenBrowserNothingIsOpened() async throws {
        serve()
        let plane = UnitApi.controlPlane()
        let opened = LockedBox<String>()
        let started = ProcessInfo.processInfo.systemUptime
        do {
            // Nobody comes back to the port, so the sign-in expires.
            try await plane.browserLogin(options: BrowserLoginOptions(
                openBrowser: false, timeout: 0.2, opener: { opened.setOnce($0.absoluteString) }))
            XCTFail("expected the sign-in to expire")
        } catch ThalovantDeviceLoginError.expired {}
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 0.2)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(opened.value)
        XCTAssertNil(plane.accessToken)
    }

    func testTheDefaultDeviceNameReachesTheConsentPage() async throws {
        serve()
        let plane = UnitApi.controlPlane()
        let (task, _, _, query) = try await begin(plane, BrowserLoginOptions(openBrowser: false, timeout: 0.2))
        XCTAssertEqual(query["device_name"], BrowserLogin.defaultDeviceName())
        XCTAssertNil(query["scope"], "no scopes asked for: the API's default")
        guard case .failure(ThalovantDeviceLoginError.expired) = await task.value else {
            return XCTFail("expected the sign-in to expire")
        }
    }

    func testAnEmptyDeviceNameKeepsTheHostnameOffTheConsentPage() async throws {
        serve()
        let plane = UnitApi.controlPlane()
        let (task, _, _, query) = try await begin(plane, BrowserLoginOptions(deviceName: "", openBrowser: false, timeout: 0.2))
        XCTAssertNil(query["device_name"])
        _ = await task.value
    }

    // MARK: The secrets

    func testAnEchoedCodeAndVerifierNeverReachTheError() async throws {
        let sent = LockedBox<JSONObject>()
        serve(token: { body in
            // A validation error lists each field's input, as FastAPI's 422
            // does -- and a secret in a key, too.
            let fields = body?.objectValue ?? [:]
            sent.setOnce(fields)
            let detail = fields.keys.sorted().map { key -> JSONValue in
                ["loc": ["body", .string(key)], "msg": "bad", "input": fields[key] ?? .null]
            }
            let problem: JSONObject = ["detail": .array(detail), "seen:\(fields["code"]?.stringValue ?? "")": "x"]
            return .init(422, (try? ThalovantJSON.encodeToString(problem)) ?? "{}")
        })
        let plane = UnitApi.controlPlane()
        let (task, port, state, _) = try await begin(plane)
        let tab = try await RawHTTP.request(port: port, method: "GET", target: "/callback?code=secret-code-value&state=\(state)")
        XCTAssertEqual(tab.status, 200)
        XCTAssertTrue(tab.body.contains("Sign-in was not completed."))
        guard case .failure(let failure) = await task.value, let error = failure as? ThalovantApiError else {
            return XCTFail("expected the API's refusal")
        }
        XCTAssertEqual(error.statusCode, 422)
        let request = try XCTUnwrap(sent.value)
        let shown = (printedForms(error) + [error.body ?? "", String(describing: error.problem), error.detail ?? "",
                                             error.errorCode ?? ""]).joined(separator: "\n")
        for secret in [request["code"]?.stringValue, request["code_verifier"]?.stringValue, state].compactMap({ $0 }) {
            XCTAssertFalse(shown.contains(secret), "a secret reached the error")
        }
        XCTAssertTrue(String(describing: error.problem).contains("[redacted]"))
        XCTAssertTrue(error.problem?.keys.contains("seen:[redacted]") == true)
        XCTAssertNil(plane.accessToken)
    }

    /// The detail is redacted before the bounded message is made of it.
    func testAMessageCutToLengthKeepsNoPartOfASecret() async throws {
        let sent = LockedBox<String>()
        serve(token: { body in
            let verifier = body?["code_verifier"]?.stringValue ?? ""
            sent.setOnce(verifier)
            // The verifier starts ten characters before the message's 200-character cut.
            let detail: JSONObject = ["detail": .string(String(repeating: "a", count: 190) + verifier)]
            return .init(400, (try? ThalovantJSON.encodeToString(detail)) ?? "{}")
        })
        let plane = UnitApi.controlPlane()
        let (task, port, state, _) = try await begin(plane)
        _ = try await RawHTTP.request(port: port, method: "GET", target: "/callback?code=c&state=\(state)")
        guard case .failure(let failure) = await task.value, let error = failure as? ThalovantApiError else {
            return XCTFail("expected the API's refusal")
        }
        XCTAssertEqual(error.statusCode, 400)
        let prefix = String(try XCTUnwrap(sent.value).prefix(10))
        for shown in printedForms(error) + [error.detail ?? "", error.body ?? "", String(describing: error.problem)] {
            XCTAssertFalse(shown.contains(prefix), shown)
        }
        XCTAssertEqual(error.detail, String(repeating: "a", count: 190) + "[redacted]")
    }

    /// A transport failure's description can carry the request; the error
    /// thrown does not.
    func testATransportFailureDuringTheExchangeCarriesNothingOfTheRequest() async throws {
        UnitApi.serve { _, path, body in
            if path == "/v1/auth/native/config" { return .init(200, BrowserLoginTests.config) }
            return .failure("connection reset while sending \((try? ThalovantJSON.encodeToString(body?.objectValue ?? [:])) ?? "")")
        }
        let plane = UnitApi.controlPlane()
        let (task, port, state, _) = try await begin(plane)
        _ = try await RawHTTP.request(port: port, method: "GET", target: "/callback?code=transport-code&state=\(state)")
        guard case .failure(let failure) = await task.value, let error = failure as? ThalovantApiError else {
            return XCTFail("expected a transport failure")
        }
        XCTAssertNil(error.statusCode)
        let verifier = try XCTUnwrap(UnitApi.bodies.last??["code_verifier"]?.stringValue)
        for shown in printedForms(error) + [error.body ?? "", String(describing: error.problem)] {
            for secret in ["transport-code", verifier, state] {
                XCTAssertFalse(shown.contains(secret), shown)
            }
        }
        if error.message.contains("connection reset") {
            // The transport's own description came through, scrubbed.
            XCTAssertTrue(error.message.contains("[redacted]"), error.message)
        }
    }

    func testACleartextAPIIsRefusedBeforeAnythingIsAskedOrOpened() async throws {
        serve()
        let opened = LockedBox<String>()
        let plane = UnitApi.controlPlane(apiURL: "http://control.example.test")
        for attempt in 0..<2 {
            do {
                if attempt == 0 {
                    try await plane.browserLogin(options: BrowserLoginOptions(opener: { opened.setOnce($0.absoluteString) }))
                } else {
                    try await plane.interactiveLogin(options: InteractiveLoginOptions(
                        method: .browser, opener: { opened.setOnce($0.absoluteString) }))
                }
                XCTFail("expected a refusal")
            } catch let error as ThalovantApiError {
                XCTAssertTrue(error.message.contains("cleartext"), error.message)
                XCTAssertNil(error.statusCode)
            }
        }
        // Chosen automatically, a cleartext API is not usable for the browser:
        // the configuration is never asked for.
        var auto = InteractiveLoginOptions(opener: { opened.setOnce($0.absoluteString) })
        auto.environment = [:]
        auto.platform = "macos"
        _ = try? await plane.interactiveLogin(options: auto)
        XCTAssertFalse(UnitApi.requests.contains("GET /v1/auth/native/config"), "\(UnitApi.requests)")
        XCTAssertNil(opened.value)
    }

    // MARK: The exchange

    /// The configuration refuses such an endpoint; past it, the request layer
    /// still keeps the exchange on the API's origin.
    func testTheExchangeNeverLeavesTheAPIOrigin() async throws {
        serve()
        let plane = UnitApi.controlPlane()
        let config = NativeSignInConfig(
            authorizationEndpoint: "https://dash.thalovant.com/authorize",
            tokenEndpoint: "/http://127.0.0.1:9/v1/auth/native/token", sdkClientId: "thalovant-sdk")
        _ = try? await plane.exchangeBrowserCode(
            config, code: "c", verifier: String(repeating: "v", count: 43), redirectURI: "http://127.0.0.1:1024/callback",
            hidden: ["c"])
        let api = try XCTUnwrap(URL(string: plane.apiURL))
        XCTAssertEqual(UnitApi.urls.count, 1)
        for url in UnitApi.urls {
            XCTAssertEqual(ThalovantControlPlane.origin(of: url), ThalovantControlPlane.origin(of: api))
        }
    }

    /// A reused connection found dead can make an HTTP stack send the request
    /// again on a fresh one; the exchange goes out on a connection of its own,
    /// once, and a code presented twice would revoke the first token.
    func testTheExchangeIsSentOnceEvenWhenItsConnectionDies() async throws {
        let server = try TinyHTTPServer { method, path in
            if method == "GET" && path == "/v1/auth/native/config" { return .answer(BrowserLoginTests.config) }
            return .hangUp
        }
        defer { server.stop() }
        let plane = ThalovantControlPlane(apiURL: "http://127.0.0.1:\(server.port)")
        let (task, port, state, _) = try await begin(plane)
        let tab = try await RawHTTP.request(port: port, method: "GET", target: "/callback?code=c&state=\(state)")
        XCTAssertEqual(tab.status, 200)
        guard case .failure(let failure) = await task.value, let error = failure as? ThalovantApiError else {
            return XCTFail("expected the exchange to fail")
        }
        XCTAssertNil(error.statusCode)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(server.requests.filter { $0.hasPrefix("POST ") }, ["POST /v1/auth/native/token"])
        // Not on the connection the configuration came over, which is still open.
        let config = try XCTUnwrap(server.connection(of: "GET /v1/auth/native/config"))
        let exchange = try XCTUnwrap(server.connection(of: "POST /v1/auth/native/token"))
        XCTAssertNotEqual(config, exchange)
    }

    // MARK: The listener's own edges

    func testCancellingTheSignInClosesThePort() async throws {
        serve()
        let plane = UnitApi.controlPlane()
        let (task, port, _, _) = try await begin(plane)
        task.cancel()
        guard case .failure(let error) = await task.value else { return XCTFail("expected a cancellation") }
        XCTAssertTrue(error is CancellationError, "\(error)")
        XCTAssertTrue(RawHTTP.refused(port: port))
    }

    /// A browser opens connections it never uses; the sign-in must not wait on them.
    func testAConnectionThatSendsNothingDoesNotHoldTheSignIn() async throws {
        serve()
        let plane = UnitApi.controlPlane()
        let (task, port, state, _) = try await begin(plane)
        let idle = try RawConnection(port: port)
        defer { idle.close() }
        let started = ProcessInfo.processInfo.systemUptime
        let tab = try await RawHTTP.request(port: port, method: "GET", target: "/callback?code=c&state=\(state)")
        XCTAssertEqual(tab.status, 200)
        guard case .success = await task.value else { return XCTFail("expected a token") }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.9)
    }

    func testARequestThatIsNotOneIs400AndTheWaitGoesOn() async throws {
        serve()
        let plane = UnitApi.controlPlane()
        let (task, port, state, _) = try await begin(plane)
        let notARequest = try await RawHTTP.raw(port: port, bytes: Array("hello\r\n\r\n".utf8))
        XCTAssertEqual(notARequest.status, 400)
        let tooBig = Array("GET /callback?code=".utf8) + [UInt8](repeating: UInt8(ascii: "a"), count: LoopbackListener.maxRequestHead + 10)
            + Array(" HTTP/1.1\r\n\r\n".utf8)
        let oversized = try await RawHTTP.raw(port: port, bytes: tooBig)
        XCTAssertEqual(oversized.status, 400)
        let favicon = try await RawHTTP.request(port: port, method: "GET", target: "/favicon.ico")
        XCTAssertEqual(favicon.status, 404)
        let stray = try await RawHTTP.request(port: port, method: "GET", target: "/callback?code=c&state=other")
        XCTAssertEqual(stray.status, 400)
        let real = try await RawHTTP.request(port: port, method: "GET", target: "/callback?code=c&state=\(state)")
        XCTAssertEqual(real.status, 200)
        guard case .success(let token) = await task.value else { return XCTFail("expected a token") }
        XCTAssertEqual(token.accessToken, "tvpat_unit_token")
    }

    func testAnAnswerThatIsNotJSONIsAnErrorWithNoStatus() async throws {
        for route in ["config", "token"] {
            UnitApi.serve { _, path, _ in
                if path == "/v1/auth/native/\(route)" { return .init(200, "<html>not json</html>", contentType: "text/html") }
                return path == "/v1/auth/native/config" ? .init(200, BrowserLoginTests.config) : .init(200, BrowserLoginTests.token)
            }
            let plane = UnitApi.controlPlane()
            let failure: Error?
            if route == "token" {
                let (task, port, state, _) = try await begin(plane)
                let tab = try await RawHTTP.request(port: port, method: "GET", target: "/callback?code=c&state=\(state)")
                XCTAssertEqual(tab.status, 200)
                if case .failure(let error) = await task.value { failure = error } else { failure = nil }
            } else {
                do { try await plane.browserLogin(options: BrowserLoginOptions(openBrowser: false)); failure = nil } catch { failure = error }
            }
            let error = try XCTUnwrap(failure as? ThalovantApiError, route)
            XCTAssertNil(error.statusCode, route)
            XCTAssertNil(error.errorCode, route)
        }
    }

    func testASecondAnswerAfterTheFirstIsTurnedAway() async throws {
        let listener = LoopbackListener(state: "the-state-of-this-sign-in")
        let port = try listener.start()
        // Both connected before the first is accepted, so the second still
        // reaches the listener after the port has stopped listening.
        let first = try RawConnection(port: port)
        let second = try RawConnection(port: port)
        defer { first.close(); second.close() }
        let request = Array("GET /callback?code=c&state=the-state-of-this-sign-in HTTP/1.1\r\n\r\n".utf8)
        first.send(request)
        let accepted = await listener.wait(timeout: 5)
        XCTAssertEqual(accepted, .code("c"))
        XCTAssertTrue(RawHTTP.refused(port: port))
        second.send(request)
        let turnedAway = try RawHTTP.parse(second.readAll())
        XCTAssertEqual(turnedAway.status, 400)
        listener.finish(signedIn: true)
        XCTAssertTrue(try RawHTTP.parse(first.readAll()).body.contains("Signed in to Thalovant."))
        await listener.close()
    }

    func testTheWaitIsNeverCutShort() async throws {
        let listener = LoopbackListener(state: "s")
        _ = try listener.start()
        let started = ProcessInfo.processInfo.systemUptime
        let callback = await listener.wait(timeout: 0.25)
        let took = ProcessInfo.processInfo.systemUptime - started
        await listener.close()
        XCTAssertNil(callback)
        XCTAssertGreaterThanOrEqual(took, 0.25)
    }

    func testAWaitIsOverAtItsDeadline() {
        // The rule the loop and the acceptance of a callback share: a callback
        // read once the deadline has passed is not the wait's any more.
        XCTAssertFalse(LoopbackListener.waitIsOver(deadline: 10, now: 9))
        XCTAssertTrue(LoopbackListener.waitIsOver(deadline: 10, now: 10))
        XCTAssertTrue(LoopbackListener.waitIsOver(deadline: 10, now: 11))
    }

    func testWaitingOnAListenerThatWasNeverStartedIsNoCallback() async {
        let listener = LoopbackListener(state: "s")
        let callback = await listener.wait(timeout: 5)
        XCTAssertNil(callback)
        await listener.close()
    }

    func testAConnectionThatClosesBeforeItsHeadChangesNothing() async throws {
        let listener = LoopbackListener(state: "the-state")
        let port = try listener.start()
        // Gone before sending a whole request head.
        let gone = try RawConnection(port: port)
        gone.send(Array("GET /callback?code=c&st".utf8))
        gone.close()
        let none = await listener.wait(timeout: 0.1)
        XCTAssertNil(none)
        // Not accepted, so this sign-in's own answer still is.
        let tab = try RawConnection(port: port)
        defer { tab.close() }
        tab.send(Array("GET /callback?code=c&state=the-state HTTP/1.1\r\n\r\n".utf8))
        let accepted = await listener.wait(timeout: 5)
        XCTAssertEqual(accepted, .code("c"))
        await listener.close()
        let answer = try RawHTTP.parse(tab.readAll())
        XCTAssertEqual(answer.status, 200)
        XCTAssertTrue(answer.body.contains("Sign-in was not completed."))
    }

    /// The page says how the sign-in ended, so it is written once it has,
    /// however long the exchange took: the tab has no deadline of its own.
    func testTheAcceptedTabWaitsAsLongAsTheSignInTakes() async throws {
        let listener = LoopbackListener(state: "the-state")
        let port = try listener.start()
        let started = ProcessInfo.processInfo.systemUptime
        let page = LockedBox<String>()
        Task.detached {
            let answer = try? await RawHTTP.request(port: port, method: "GET", target: "/callback?code=c&state=the-state")
            page.setOnce(answer?.body ?? "")
        }
        let accepted = await listener.wait(timeout: 5)
        XCTAssertEqual(accepted, .code("c"))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(page.value, "the tab was answered before the sign-in ended")
        listener.finish(signedIn: true)
        try await eventually { page.value != nil }
        XCTAssertTrue(page.value?.contains("Signed in to Thalovant. You can close this tab.") == true)
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 0.3)
        await listener.close()
    }

    func testClosingTheListenerAnswersATabThatIsStillWaiting() async throws {
        let listener = LoopbackListener(state: "the-state")
        let port = try listener.start()
        let tab = try RawConnection(port: port)
        defer { tab.close() }
        tab.send(Array("GET /callback?code=c&state=the-state HTTP/1.1\r\n\r\n".utf8))
        let accepted = await listener.wait(timeout: 5)
        XCTAssertEqual(accepted, .code("c"))
        let started = ProcessInfo.processInfo.systemUptime
        await listener.close()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.5)
        let answer = try RawHTTP.parse(tab.readAll())
        XCTAssertEqual(answer.status, 200)
        XCTAssertTrue(answer.body.contains("Sign-in was not completed."))
    }

    func testAHeadRequestGetsTheHeadersAndNoBody() async throws {
        let listener = LoopbackListener(state: "the-state")
        let port = try listener.start()
        let connection = try RawConnection(port: port)
        connection.send(Array("HEAD /callback?code=c&state=the-state HTTP/1.1\r\n\r\n".utf8))
        let raw = connection.readAll()
        connection.close()
        await listener.close()
        let answer = try RawHTTP.parse(raw)
        XCTAssertEqual(answer.status, 404)
        XCTAssertEqual(answer.body, "")
        XCTAssertEqual(answer.headers["Content-Type"], "text/html; charset=utf-8")
        XCTAssertGreaterThan(Int(answer.headers["Content-Length"] ?? "") ?? 0, 0, "what a GET would have carried")
    }

    /// Closing with bytes unread resets the connection, and macOS then drops
    /// the answer the browser had not read; Linux shows the reset as
    /// ECONNRESET. The listener drains first.
    func testAnEarlyAnswerIsNotLostToAReset() async throws {
        let cases: [(String, [UInt8], String)] = [
            // A head far over the listener's limit: most of it is never read.
            ("oversized head", Array("GET /callback?code=".utf8) + [UInt8](repeating: UInt8(ascii: "a"), count: 600_000)
                + Array(" HTTP/1.1\r\nHost: x\r\n\r\n".utf8), "HTTP/1.1 400 Bad Request"),
            // A body nobody asked for, behind a 404.
            ("unread body", Array("POST /callback HTTP/1.1\r\nHost: x\r\nContent-Length: 600000\r\n\r\n".utf8)
                + [UInt8](repeating: UInt8(ascii: "b"), count: 600_000), "HTTP/1.1 404 Not Found"),
        ]
        for (name, bytes, expected) in cases {
            let listener = LoopbackListener(state: "the-state")
            let port = try listener.start()
            let (data, failure, stalled) = try await RawHTTP.sendWhileReading(port: port, bytes: bytes)
            await listener.close()
            let line = String(decoding: data.prefix(while: { $0 != 0x0D }), as: UTF8.self)
            XCTAssertEqual(line, expected, name)
            XCTAssertNil(failure, "\(name): the connection ended with errno \(failure ?? 0)")
            XCTAssertFalse(stalled, "\(name): the request could not be sent within five seconds")
        }
    }

    /// An answer to a HEAD has no body, even when its head is too large to read.
    func testAnOversizedHeadRequestGetsItsAnswerWithNoBody() async throws {
        let listener = LoopbackListener(state: "the-state")
        let port = try listener.start()
        let head = Array("HEAD /callback?code=".utf8) + [UInt8](repeating: UInt8(ascii: "a"), count: LoopbackListener.maxRequestHead + 10)
            + Array(" HTTP/1.1\r\n\r\n".utf8)
        let answer = try await RawHTTP.raw(port: port, bytes: head)
        await listener.close()
        XCTAssertEqual(answer.status, 400)
        XCTAssertEqual(answer.body, "")
        XCTAssertGreaterThan(Int(answer.headers["Content-Length"] ?? "") ?? 0, 0)
        // Another method's oversized head still gets the page.
        let other = LoopbackListener(state: "the-state")
        let otherPort = try other.start()
        let get = try await RawHTTP.raw(port: otherPort, bytes: Array("GET".utf8) + head.dropFirst(4))
        await other.close()
        XCTAssertEqual(get.status, 400)
        XCTAssertFalse(get.body.isEmpty)
    }

    /// At the cap, a connection whose callback has arrived is served before
    /// the oldest one is closed, even when it is the oldest.
    func testACallbackThatHasArrivedIsServedBeforeAnyConnectionIsClosed() async throws {
        let listener = LoopbackListener(state: "the-state")
        let port = try listener.start()
        // The tab connects first, as a browser that preconnects does, so it
        // is the oldest connection when the cap is reached.
        let tab = try RawConnection(port: port)
        defer { tab.close() }
        var idle: [RawConnection] = []
        for _ in 0..<(LoopbackListener.maxConnections - 1) { idle.append(try RawConnection(port: port)) }
        defer { idle.forEach { $0.close() } }
        try await eventually { listener.openConnections >= LoopbackListener.maxConnections }
        tab.send(Array("GET /callback?code=c&state=the-state HTTP/1.1\r\n\r\n".utf8))
        // More connections at once: each would close the oldest, the tab.
        // Once the callback is accepted the port stops listening, so these
        // may be refused, which is the point.
        for _ in 0..<LoopbackListener.acceptBatch {
            if let more = try? RawConnection(port: port) { idle.append(more) }
        }
        let accepted = await listener.wait(timeout: 5)
        XCTAssertEqual(accepted, .code("c"))
        listener.finish(signedIn: true)
        XCTAssertTrue(try RawHTTP.parse(tab.readAll()).body.contains("Signed in to Thalovant."))
        await listener.close()
    }

    /// A browser that never closes its side cannot keep a connection open.
    func testDrainingAConnectionIsBounded() async throws {
        let listener = LoopbackListener(state: "the-state", drainTimeout: 0.2)
        let port = try listener.start()
        let connection = try RawConnection(port: port)
        connection.send(Array("GET /favicon.ico HTTP/1.1\r\n\r\n".utf8))
        // The answer ends because the listener shut its side; ours stays open.
        XCTAssertEqual(try RawHTTP.parse(connection.readAll()).status, 404)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(listener.openConnections, 0)
        connection.close()
        await listener.close()
    }

    /// Idle connections cannot keep the real tab out, nor keep the loop from
    /// its work: the oldest idle one makes room.
    func testAFloodOfIdleConnectionsDoesNotKeepTheTabOut() async throws {
        let listener = LoopbackListener(state: "the-state")
        let port = try listener.start()
        var idle: [RawConnection] = []
        for _ in 0..<(LoopbackListener.maxConnections + 16) { idle.append(try RawConnection(port: port)) }
        defer { idle.forEach { $0.close() } }
        try await eventually { listener.openConnections >= LoopbackListener.maxConnections }
        XCTAssertLessThanOrEqual(listener.openConnections, LoopbackListener.maxConnections)
        let tab = try RawConnection(port: port)
        defer { tab.close() }
        tab.send(Array("GET /callback?code=c&state=the-state HTTP/1.1\r\n\r\n".utf8))
        let accepted = await listener.wait(timeout: 5)
        XCTAssertEqual(accepted, .code("c"))
        listener.finish(signedIn: true)
        XCTAssertTrue(try RawHTTP.parse(tab.readAll()).body.contains("Signed in to Thalovant."))
        await listener.close()
    }

    func testWaitsAreClamped() {
        XCTAssertEqual(LoopbackListener.nanoseconds(-1), 0)
        XCTAssertEqual(LoopbackListener.nanoseconds(.nan), 0)
        XCTAssertEqual(LoopbackListener.nanoseconds(0.25), 250_000_000)
        XCTAssertGreaterThan(LoopbackListener.nanoseconds(.infinity), LoopbackListener.nanoseconds(1e9))
        XCTAssertEqual(LoopbackListener.nanoseconds(1e300), LoopbackListener.nanoseconds(.infinity))
    }
}

#endif

/// An API that answers every request with `handler`'s answer, and notes what was sent.
final class UnitApi: URLProtocol {
    struct Answer: Sendable {
        let status: Int
        let body: String
        let contentType: String
        /// When set, the request fails in transport with this description instead.
        let failure: String?
        init(_ status: Int, _ body: String, contentType: String = "application/json") {
            self.status = status
            self.body = body
            self.contentType = contentType
            self.failure = nil
        }
        private init(failure: String) {
            status = 0
            body = ""
            contentType = ""
            self.failure = failure
        }
        static func failure(_ description: String) -> Answer { Answer(failure: description) }
    }

    typealias Handler = @Sendable (_ method: String, _ path: String, _ body: JSONValue?) -> Answer

    private static let lock = NSLock()
    private static var handler: Handler = { _, _, _ in Answer(599, "{}") }
    private static var seen: [String] = []
    private static var seenURLs: [URL] = []
    private static var seenBodies: [JSONValue?] = []

    static func serve(_ next: @escaping Handler) {
        lock.locked {
            handler = next
            seen = []
            seenURLs = []
            seenBodies = []
        }
    }

    /// What was sent, as `METHOD path`.
    static var requests: [String] { lock.locked { seen } }
    /// The URLs requested, whole.
    static var urls: [URL] { lock.locked { seenURLs } }
    /// The bodies sent, parsed.
    static var bodies: [JSONValue?] { lock.locked { seenBodies } }

    static func controlPlane(apiURL: String = "http://127.0.0.1:8767") -> ThalovantControlPlane {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnitApi.self]
        return ThalovantControlPlane(apiURL: apiURL, session: URLSession(configuration: configuration))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let method = request.httpMethod ?? ""
        let path = request.url?.path ?? ""
        let raw = request.httpBody ?? BrowserApi.drain(request.httpBodyStream) ?? Data()
        let body = raw.isEmpty ? nil : try? JSONDecoder().decode(JSONValue.self, from: raw)
        let handler = Self.lock.locked { () -> Handler in
            Self.seen.append("\(method) \(path)")
            if let url = request.url { Self.seenURLs.append(url) }
            Self.seenBodies.append(body)
            return Self.handler
        }
        let answer = handler(method, path, body)
        if let failure = answer.failure {
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: "UnitApi", code: 1, userInfo: [NSLocalizedDescriptionKey: failure]))
            return
        }
        let bytes = Data(answer.body.utf8)
        var headers = ["Content-Length": String(bytes.count)]
        if !bytes.isEmpty { headers["Content-Type"] = answer.contentType }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://127.0.0.1:8767")!, statusCode: answer.status,
            httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !bytes.isEmpty { client?.urlProtocol(self, didLoad: bytes) }
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// A real HTTP/1.1 server on 127.0.0.1 that keeps connections alive, for
/// what a URLProtocol cannot show: which connection a request went out on,
/// and whether it was sent twice.
final class TinyHTTPServer: @unchecked Sendable {
    enum Reply { case answer(String), hangUp }

    let port: Int
    private let fd: Int32
    private let reply: @Sendable (String, String) -> Reply
    private let lock = NSLock()
    private var stopped = false
    private var seen: [(String, Int)] = []
    private var connections = 0
    private var open: Set<Int32> = []

    /// What arrived, as `METHOD path`, in order.
    var requests: [String] { lock.locked { seen.map(\.0) } }

    /// The connection, numbered from 1 in the order accepted, that a request arrived on.
    func connection(of request: String) -> Int? { lock.locked { seen.first { $0.0 == request }?.1 } }

    init(_ reply: @escaping @Sendable (_ method: String, _ path: String) -> Reply) throws {
        self.reply = reply
        #if canImport(Glibc)
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) }
        }
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard descriptor >= 0, bound == 0, named == 0, listen(descriptor, 16) == 0 else {
            if descriptor >= 0 { Self.systemClose(descriptor) }
            throw RawHTTP.Failure(description: "the test server could not listen")
        }
        fd = descriptor
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    /// Stops accepting, and ends every connection still open: a worker
    /// blocked reading one returns, and closes it.
    func stop() {
        let connections = lock.locked { () -> Set<Int32> in
            stopped = true
            return open
        }
        for connection in connections { Self.systemShutdown(connection) }
        Self.systemShutdown(fd)
        Self.systemClose(fd)
    }

    private static func systemShutdown(_ descriptor: Int32) {
        #if canImport(Glibc)
        _ = Glibc.shutdown(descriptor, Int32(SHUT_RDWR))
        #else
        _ = Darwin.shutdown(descriptor, Int32(SHUT_RDWR))
        #endif
    }

    private static func systemClose(_ descriptor: Int32) {
        #if canImport(Glibc)
        _ = Glibc.close(descriptor)
        #else
        _ = Darwin.close(descriptor)
        #endif
    }

    private func acceptLoop() {
        while !lock.locked({ stopped }) {
            var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, 50) > 0 else { continue }
            let connection = accept(fd, nil, nil)
            guard connection >= 0 else { continue }
            // Registered under the same lock `stop()` takes, so a connection
            // accepted as the server stops is closed rather than left behind.
            let number = lock.locked { () -> Int? in
                guard !stopped else { return nil }
                open.insert(connection)
                connections += 1
                return connections
            }
            guard let number else {
                Self.systemClose(connection)
                continue
            }
            Thread.detachNewThread { [self] in serve(connection, number) }
        }
    }

    /// Requests one after another on one connection, until a hang-up.
    private func serve(_ connection: Int32, _ number: Int) {
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 65_536)
        defer {
            lock.locked { _ = open.remove(connection) }
            Self.systemClose(connection)
        }
        while true {
            while !(buffer.count >= 4 && (0...(buffer.count - 4)).contains(where: { buffer[$0..<$0 + 4].elementsEqual([13, 10, 13, 10]) })) {
                let count = recv(connection, &chunk, chunk.count, 0)
                guard count > 0 else { return }
                buffer += chunk[0..<count]
            }
            let end = (0...(buffer.count - 4)).first(where: { buffer[$0..<$0 + 4].elementsEqual([13, 10, 13, 10]) })! + 4
            let head = String(decoding: buffer[0..<end], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            let parts = lines[0].split(separator: " ")
            let length = lines.compactMap { line -> Int? in
                let pair = line.split(separator: ":", maxSplits: 1)
                return pair.count == 2 && pair[0].lowercased() == "content-length"
                    ? Int(pair[1].trimmingCharacters(in: .whitespaces)) : nil
            }.first ?? 0
            while buffer.count < end + length {
                let count = recv(connection, &chunk, chunk.count, 0)
                guard count > 0 else { return }
                buffer += chunk[0..<count]
            }
            buffer.removeFirst(end + length)
            let method = parts.count > 0 ? String(parts[0]) : ""
            let path = parts.count > 1 ? String(parts[1]) : ""
            lock.locked { seen.append(("\(method) \(path)", number)) }
            switch reply(method, path) {
            case .hangUp:
                // The request was read, and the connection dies without an answer.
                return
            case .answer(let body):
                let bytes = Array(body.utf8)
                let answer = Array(("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\n"
                    + "Connection: keep-alive\r\n\r\n").utf8) + bytes
                _ = answer.withUnsafeBytes { RawConnection.sendAll(connection, $0) }
            }
        }
    }
}
