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
/// generated secrets, the listener's own edges, and what never reaches an
/// error. `BrowserLoginVectorTests` runs the contract every SDK shares; these
/// are the parts that are this SDK's own -- its threads, its sockets -- or
/// that are about what must not happen.
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

    /// The config and token routes; the token route answers with `token`.
    private func serve(token: @escaping @Sendable (JSONValue?) -> UnitApi.Answer = { _ in .init(200, BrowserLoginTests.token) }) {
        UnitApi.serve { _, path, body in
            switch path {
            case "/v1/auth/native/config": return .init(200, Self.config)
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

    func testTheNoticeShowsTheURLOnTheLineAfter() {
        XCTAssertEqual(
            BrowserLogin.notice(for: "https://x.test/a", openBrowser: true),
            "Opening your browser to sign in to Thalovant. If it does not open, visit:\nhttps://x.test/a")
        XCTAssertEqual(BrowserLogin.notice(for: "https://x.test/a", openBrowser: false), "To sign in to Thalovant, visit:\nhttps://x.test/a")
    }

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
        // Opened on the waiting path, the tab would have been told the sign-in
        // was not completed, a minute later.
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

    func testTheDeviceNameDefaultsToThisSDKOnThisHost() {
        XCTAssertEqual(BrowserLogin.deviceName(host: "workstation"), "thalovant-swift-sdk on workstation")
        XCTAssertEqual(BrowserLogin.deviceName(host: String(repeating: "h", count: 300)).unicodeScalars.count, 120)
        XCTAssertEqual(BrowserLogin.deviceName(host: ""), "thalovant-swift-sdk")
        XCTAssertTrue(BrowserLogin.defaultDeviceName().hasPrefix("thalovant-swift-sdk"))
        XCTAssertLessThanOrEqual(BrowserLogin.defaultDeviceName().unicodeScalars.count, 120)
        // Code points, not grapheme clusters: a flag is two of them.
        XCTAssertEqual(BrowserLogin.truncatedToCodePoints("🇨🇦🇫🇷", 3).unicodeScalars.count, 3)
    }

    func testTheDefaultDeviceNameReachesTheConsentPage() async throws {
        serve()
        let plane = UnitApi.controlPlane()
        let (task, _, _, query) = try await begin(plane, BrowserLoginOptions(deviceName: "", openBrowser: false, timeout: 0.2))
        XCTAssertEqual(query["device_name"], BrowserLogin.defaultDeviceName())
        XCTAssertNil(query["scope"], "no scopes asked for: the API's default")
        guard case .failure(ThalovantDeviceLoginError.expired) = await task.value else {
            return XCTFail("expected the sign-in to expire")
        }
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

    func testADeviceLoginChosenByTheChooserOpensItsPageWithTheOpener() async throws {
        UnitApi.serve { _, path, _ in
            switch path {
            case "/v1/auth/device/authorize":
                return .init(200, """
                    {"device_code": "dc-unit", "user_code": "WDJB-MJHT", "verification_uri": "https://thalovant.com/activate",
                     "verification_uri_complete": "https://thalovant.com/activate?code=WDJB-MJHT", "interval": 0}
                    """)
            case "/v1/auth/device/token": return .init(200, Self.token)
            default: return .init(599, "{}")
            }
        }
        let opened = LockedBox<String>()
        let plane = UnitApi.controlPlane()
        let token = try await plane.interactiveLogin(options: InteractiveLoginOptions(
            method: .device, deviceName: "unit", opener: { opened.setOnce($0.absoluteString) }))
        XCTAssertEqual(token.tokenId, "tok-unit")
        XCTAssertEqual(opened.value, "https://thalovant.com/activate?code=WDJB-MJHT")
        XCTAssertEqual(UnitApi.requests, ["POST /v1/auth/device/authorize", "POST /v1/auth/device/token"])
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

    func testWaitingOnAListenerThatWasNeverStartedIsNoCallback() async {
        let listener = LoopbackListener(state: "s")
        let callback = await listener.wait(timeout: 5)
        XCTAssertNil(callback)
        await listener.close()
    }

    func testAConnectionThatClosesBeforeItsAnswerChangesNothing() async throws {
        let listener = LoopbackListener(state: "the-state", answerTimeout: 0.05)
        let port = try listener.start()
        // Gone before sending a whole request head.
        let gone = try RawConnection(port: port)
        gone.send(Array("GET /callback?code=c&st".utf8))
        gone.close()
        let none = await listener.wait(timeout: 0.1)
        XCTAssertNil(none)
        // Not accepted, so this sign-in's own answer still is; nobody says how
        // it ended, so its tab is told it was not completed.
        let tab = try await RawHTTP.request(port: port, method: "GET", target: "/callback?code=c&state=the-state")
        XCTAssertEqual(tab.status, 200)
        XCTAssertTrue(tab.body.contains("Sign-in was not completed."))
        let accepted = await listener.wait(timeout: 0)
        XCTAssertEqual(accepted, .code("c"))
        await listener.close()
    }

    func testClosingAnswersTheAcceptedTabAtOnce() async throws {
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

    func testACallbackIsNeverPrintedWithItsCode() {
        XCTAssertFalse(String(describing: LoopbackCallback.code("nc_secret")).contains("nc_secret"))
        XCTAssertFalse(String(reflecting: LoopbackCallback.code("nc_secret")).contains("nc_secret"))
    }

    // MARK: The remaining edges

    func testThisMachineIsNamedAsTheBrowserRuleNamesIt() {
        #if os(Linux)
        XCTAssertEqual(BrowserLogin.platformName, "linux")
        #elseif os(macOS)
        XCTAssertEqual(BrowserLogin.platformName, "macos")
        #endif
        XCTAssertTrue(BrowserLogin.isAvailable)
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
                         "https://dash.thalovant.com/authorize?", "1https://dash.thalovant.com/authorize"] {
            XCTAssertFalse(NativeSignInConfig.usableAuthorizationEndpoint(endpoint), endpoint)
        }
        for endpoint in ["https://dash.thalovant.com/authorize", "HTTPS://Dash.Thalovant.com/authorize", "http://[::1]:5173/authorize",
                         "http://LOCALHOST:5173/authorize", "https://[2001:db8::1]:8443/authorize", "https://dash.thalovant.com:/authorize",
                         "http://127.0.0.1/authorize"] {
            XCTAssertTrue(NativeSignInConfig.usableAuthorizationEndpoint(endpoint), endpoint)
        }
    }

    func testATokenEndpointAndAClientIdAreReadStrictly() {
        XCTAssertTrue(NativeSignInConfig.usableTokenEndpoint("/v1/auth/native/token"))
        for path in ["v1/auth/native/token", "//evil/x", "/v1/x#y", "/v1\\x", "/v1/ x", "/v1/x\u{85}"] {
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

    func testAnAnswerThatIsNotJSONIsAnErrorWithNoStatus() async throws {
        for route in ["config", "token"] {
            UnitApi.serve { _, path, _ in
                if path == "/v1/auth/native/\(route)" { return .init(200, "<html>not json</html>", contentType: "text/html") }
                return path == "/v1/auth/native/config" ? .init(200, Self.config) : .init(200, Self.token)
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

    func testQueryValuesAreDecodedOnceAsAFormDecodesThem() {
        XCTAssertEqual(formDecode("a%2Bb%2Fc%3D%2541"), "a+b/c=%41")
        XCTAssertEqual(formDecode("a+b"), "a b")
        XCTAssertEqual(formDecode("%G1%4"), "%G1%4")
        XCTAssertEqual(formDecode("%C3%A9t%C3%A9"), "été")
        XCTAssertEqual(formDecode("%E9"), "\u{FFFD}")
        XCTAssertEqual(loopbackFormPairs("a&&b=&=c&d=1=2").map { [$0.0, $0.1] }, [["a", ""], ["b", ""], ["", "c"], ["d", "1=2"]])
    }

    func testWaitsAreClamped() {
        XCTAssertEqual(LoopbackListener.nanoseconds(-1), 0)
        XCTAssertEqual(LoopbackListener.nanoseconds(.nan), 0)
        XCTAssertEqual(LoopbackListener.nanoseconds(0.25), 250_000_000)
        XCTAssertGreaterThan(LoopbackListener.nanoseconds(.infinity), LoopbackListener.nanoseconds(1e9))
        XCTAssertEqual(LoopbackListener.nanoseconds(1e300), LoopbackListener.nanoseconds(.infinity))
    }

    func testOnlyAWellFormedErrorIsKeptAsTheCode() {
        XCTAssertTrue(ThalovantControlPlane.isProblemCode("server_error"))
        XCTAssertFalse(ThalovantControlPlane.isProblemCode(""))
        XCTAssertFalse(ThalovantControlPlane.isProblemCode("<script>"))
        XCTAssertFalse(ThalovantControlPlane.isProblemCode(String(repeating: "a", count: 81)))
    }
}

/// An API that answers every request with `handler`'s answer, and notes what was sent.
final class UnitApi: URLProtocol {
    struct Answer: Sendable {
        let status: Int
        let body: String
        let contentType: String
        init(_ status: Int, _ body: String, contentType: String = "application/json") {
            self.status = status
            self.body = body
            self.contentType = contentType
        }
    }

    typealias Handler = @Sendable (_ method: String, _ path: String, _ body: JSONValue?) -> Answer

    private static let lock = NSLock()
    private static var handler: Handler = { _, _, _ in Answer(599, "{}") }
    private static var seen: [String] = []

    static func serve(_ next: @escaping Handler) {
        lock.locked {
            handler = next
            seen = []
        }
    }

    static var requests: [String] { lock.locked { seen } }

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
            return Self.handler
        }
        let answer = handler(method, path, body)
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
