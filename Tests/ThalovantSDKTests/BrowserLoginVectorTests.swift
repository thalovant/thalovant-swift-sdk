import CThalovantNoise
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

/// Browser sign-in against `contracts/conformance/browser-login-vectors.json`,
/// vendored byte for byte from the Python reference.
///
/// The pure sections (PKCE, the redirect, the authorization URL, the
/// configuration, the browser rule, what a callback means) run against the
/// functions that decide them. `sign_ins` and `chooser` run for real: a scripted
/// API answers each case's exchanges in order through URLSession and checks
/// every request the SDK sends, and a raw TCP client plays the browser against
/// the port the SDK bound. What the SDK produced is recorded for the
/// conformance record, under `<section>/<name>`, and compared with the case.
final class BrowserLoginVectorTests: XCTestCase {
    static let vectorFile = "browser-login-vectors.json"
    static let syntheticState = "Xx0-_yLq7m3Vw9ZtR2cKp4HdN8sFjB6a"

    private func vectors() throws -> JSONObject { try loadVectors("browser-login-vectors") }

    private func cases(_ section: String) throws -> [JSONObject] {
        try XCTUnwrap(vectors()[section]?.arrayValue, section).compactMap(\.objectValue)
    }

    private func record(_ section: String, _ row: JSONObject, _ produced: JSONValue) {
        ConformanceRecord.record(Self.vectorFile, "\(section)/\(row["name"]?.stringValue ?? "")", produced)
    }

    // MARK: The pure sections

    func testPKCE() throws {
        for row in try cases("pkce") {
            let produced: JSONValue = ["challenge": .string(BrowserLogin.challenge(for: try XCTUnwrap(row["verifier"]?.stringValue)))]
            record("pkce", row, produced)
            XCTAssertEqual(produced, row["expect"], row["name"]?.stringValue ?? "")
        }
    }

    func testRedirectURIs() throws {
        for row in try cases("redirect_uris") {
            let produced: JSONValue
            do {
                produced = ["redirect_uri": .string(try BrowserLogin.loopbackRedirectURI(port: try XCTUnwrap(row["port"]?.intValue)))]
            } catch is ThalovantApiError {
                produced = ["error": "invalid_port"]
            }
            record("redirect_uris", row, produced)
            XCTAssertEqual(produced, row["expect"], row["name"]?.stringValue ?? "")
        }
    }

    func testAuthorizationURLs() throws {
        for row in try cases("authorization_urls") {
            let given = try XCTUnwrap(row["input"]?.objectValue)
            let url = BrowserLogin.authorizationURL(
                authorizationEndpoint: try XCTUnwrap(given["authorization_endpoint"]?.stringValue),
                redirectURI: try BrowserLogin.loopbackRedirectURI(port: try XCTUnwrap(given["port"]?.intValue)),
                codeChallenge: try XCTUnwrap(given["code_challenge"]?.stringValue),
                state: try XCTUnwrap(given["state"]?.stringValue),
                scopes: given["scopes"]?.arrayValue?.compactMap(\.stringValue),
                deviceName: given["device_name"]?.stringValue,
                clientId: try XCTUnwrap(given["client_id"]?.stringValue))
            let produced: JSONValue = ["url": .string(url)]
            record("authorization_urls", row, produced)
            XCTAssertEqual(produced, row["expect"], row["name"]?.stringValue ?? "")
        }
    }

    func testConfig() throws {
        for row in try cases("config") {
            let produced: JSONValue
            do {
                let config = try NativeSignInConfig(payload: try XCTUnwrap(row["body"]))
                produced = [
                    "usable": true,
                    "authorization_endpoint": .string(config.authorizationEndpoint),
                    "token_endpoint": .string(config.tokenEndpoint),
                    "sdk_client_id": .string(config.sdkClientId),
                ]
            } catch let error as ThalovantApiError {
                XCTAssertNil(error.statusCode)
                produced = ["usable": false]
            }
            record("config", row, produced)
            XCTAssertEqual(produced, row["expect"], row["name"]?.stringValue ?? "")
        }
    }

    func testEnvironment() throws {
        for row in try cases("environment") {
            let environment = (row["env"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
            let produced: JSONValue = [
                "browser": .bool(BrowserLogin.canOpenBrowser(environment: environment, platform: row["platform"]?.stringValue)),
            ]
            record("environment", row, produced)
            XCTAssertEqual(produced, row["expect"], row["name"]?.stringValue ?? "")
        }
    }

    static func callbackOutcome(_ status: Int, _ callback: LoopbackCallback?) -> JSONValue {
        switch callback {
        case nil: return ["status": .integer(status), "outcome": "ignored"]
        case .code(let code)?: return ["status": .integer(status), "outcome": "code", "code": .string(code)]
        case .denied?: return ["status": .integer(status), "outcome": "denied"]
        case .failed(let error)?:
            return ["status": .integer(status), "outcome": "failed", "error": error.map { .string($0) } ?? .null]
        }
    }

    func testCallbacks() throws {
        for row in try cases("callbacks") {
            let request = try XCTUnwrap(row["request"]?.objectValue)
            let (status, callback) = classifyLoopbackRequest(
                method: try XCTUnwrap(request["method"]?.stringValue),
                target: try XCTUnwrap(request["target"]?.stringValue).replacingOccurrences(of: "{state}", with: Self.syntheticState),
                state: Self.syntheticState)
            let produced = Self.callbackOutcome(status, callback)
            record("callbacks", row, produced)
            XCTAssertEqual(produced, row["expect"], row["name"]?.stringValue ?? "")
        }
    }

    // The loopback listener and `browserLogin` exist on macOS and Linux only:
    // on iOS, tvOS, watchOS and visionOS the pure sections above still run.
    #if os(macOS) || os(Linux)

    /// The same cases through a real socket: the listener answers as the rule says.
    func testCallbacksOverTheListener() async throws {
        let pages = try XCTUnwrap(vectors()["page_headers"]?.objectValue)
        for row in try cases("callbacks") {
            let name = row["name"]?.stringValue ?? ""
            let request = try XCTUnwrap(row["request"]?.objectValue)
            let listener = LoopbackListener(state: Self.syntheticState)
            let port = try listener.start()
            let answer = try await RawHTTP.request(
                port: port, method: try XCTUnwrap(request["method"]?.stringValue),
                target: try XCTUnwrap(request["target"]?.stringValue).replacingOccurrences(of: "{state}", with: Self.syntheticState),
                beforeReading: { usleep(50_000); listener.finish(signedIn: false) })
            Self.checkPageHeaders(answer, pages, name)
            let accepted = await listener.wait(timeout: 0)
            await listener.close()
            XCTAssertEqual(Self.callbackOutcome(answer.status, accepted), row["expect"], name)
        }
    }

    // MARK: Sign-ins and the chooser, for real

    func testSignIns() async throws {
        let vectors = try vectors()
        for row in try cases("sign_ins") {
            let name = row["name"]?.stringValue ?? ""
            let call = try XCTUnwrap(row["call"]?.objectValue, name)
            var options = BrowserLoginOptions(
                scopes: call["scopes"]?.arrayValue?.compactMap(\.stringValue),
                deviceName: call["device_name"]?.stringValue,
                openBrowser: false)
            if let milliseconds = call["timeout_ms"]?.doubleValue { options.timeout = milliseconds / 1000 }
            let base = options
            let (produced, _) = try await signIn(row, vectors) { plane, handOver in
                var local = base
                local.prompt = { handOver($0) }
                return try await plane.browserLogin(options: local)
            }
            let value = JSONValue.object(produced)
            record("sign_ins", row, value)
            XCTAssertEqual(BrowserApi.mismatches, [], name)
            XCTAssertEqual(BrowserApi.used, row["exchanges"]?.arrayValue?.count, "\(name): not every exchange was used: \(BrowserApi.sent)")
            XCTAssertEqual(value, row["expect"], name)
        }
    }

    func testChooser() async throws {
        let vectors = try vectors()
        for row in try cases("chooser") {
            let name = row["name"]?.stringValue ?? ""
            let call = try XCTUnwrap(row["call"]?.objectValue, name)
            var options = InteractiveLoginOptions(
                method: try XCTUnwrap(LoginMethod(rawValue: call["method"]?.stringValue ?? ""), name),
                deviceName: call["device_name"]?.stringValue)
            if let milliseconds = call["timeout_ms"]?.doubleValue { options.timeout = milliseconds / 1000 }
            // This process as the case's machine: exactly its variables, and its platform.
            options.environment = (row["env"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
            options.platform = row["platform"]?.stringValue
            let base = options
            let (produced, sent) = try await signIn(row, vectors) { plane, handOver in
                var local = base
                // The browser the SDK opens. A device login opens its
                // verification page too; only the consent page is this test's
                // to answer.
                local.opener = { url in
                    if url.absoluteString.contains("response_type=code") { handOver(url.absoluteString) }
                }
                return try await plane.interactiveLogin(options: local)
            }
            let method = sent.contains("POST /v1/auth/device/authorize") ? "device" : "browser"
            let value: JSONValue = ["method": .string(method), "result": produced["result"] ?? .null]
            record("chooser", row, value)
            XCTAssertEqual(BrowserApi.mismatches, [], name)
            XCTAssertEqual(BrowserApi.used, row["exchanges"]?.arrayValue?.count, "\(name): not every exchange was used: \(sent)")
            XCTAssertEqual(value, row["expect"], name)
            if method == "browser", produced["browser"] != nil {
                XCTAssertEqual(produced["closed"], true, name)
            }
        }
    }

    /// Runs one case: serves its exchanges, takes the URL the SDK showed or
    /// opened, plays its browser requests, and records what came of it.
    private func signIn(
        _ row: JSONObject, _ vectors: JSONObject,
        start: @escaping @Sendable (ThalovantControlPlane, @escaping @Sendable (String) -> Void) async throws -> DeviceLoginResult
    ) async throws -> (JSONObject, [String]) {
        let name = row["name"]?.stringValue ?? ""
        let pages = try XCTUnwrap(vectors["pages"]?.objectValue)
        let headers = try XCTUnwrap(vectors["page_headers"]?.objectValue)
        BrowserApi.serve((row["exchanges"]?.arrayValue ?? []).compactMap(\.objectValue))
        let plane = BrowserApi.controlPlane()
        let opened = LockedBox<String>()
        let finished = LockedBox<Bool>()
        let task = Task { () -> SignInOutcome in
            defer { finished.setOnce(true) }
            do {
                let token = try await start(plane) { opened.setOnce($0) }
                return .token(accessToken: token.accessToken, tokenId: token.tokenId, record: Self.approved(token))
            } catch {
                return .failure(error)
            }
        }
        let watchdog = Task {
            try await Task.sleep(nanoseconds: 20_000_000_000)
            task.cancel()
        }
        defer { watchdog.cancel() }
        let end = ProcessInfo.processInfo.systemUptime + 10
        while opened.value == nil && finished.value == nil {
            guard ProcessInfo.processInfo.systemUptime < end else {
                XCTFail("\(name): the sign-in neither showed a URL nor ended")
                break
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        var produced: JSONObject = [:]
        var signing: Signing?
        if let url = opened.value {
            let read = try Signing(url)
            signing = read
            BrowserApi.signing = read
            produced["authorization_url"] = read.urlRecord()
            var browser: [JSONValue] = []
            for request in (row["requests"]?.arrayValue ?? []).compactMap(\.objectValue) {
                let answer = try await RawHTTP.request(
                    port: read.port, method: try XCTUnwrap(request["method"]?.stringValue),
                    target: try XCTUnwrap(request["target"]?.stringValue).replacingOccurrences(of: "{state}", with: read.state))
                Self.checkPageHeaders(answer, headers, name)
                var step: JSONObject = ["status": .integer(answer.status)]
                if answer.status == 200 { step["page"] = answer.page(pages).map { .string($0) } ?? .null }
                browser.append(.object(step))
            }
            produced["browser"] = .array(browser)
        }
        switch await task.value {
        case .failure(let error):
            assertNoSecrets(error, vectors, signing, name)
            produced["result"] = Self.failure(error, name)
        case .token(let accessToken, let tokenId, let approved):
            XCTAssertEqual(plane.accessToken, accessToken, name)
            XCTAssertEqual(plane.tokenId, tokenId, name)
            produced["result"] = approved
        }
        if let signing { produced["closed"] = .bool(RawHTTP.refused(port: signing.port)) }
        if let exchange = BrowserApi.exchange { produced["exchange"] = exchange }
        if row["call"]?["then"]?.stringValue == "revoke", produced["result"]?["outcome"] == "approved" {
            try await plane.revokeApiToken()
            XCTAssertNil(plane.accessToken, name)
            XCTAssertNil(plane.tokenId, name)
            // Idempotent: revoking again sends nothing.
            try await plane.revokeApiToken()
            produced["result"] = ["outcome": "revoked"]
        }
        return (produced, BrowserApi.sent)
    }

    private enum SignInOutcome: Sendable {
        case token(accessToken: String, tokenId: String?, record: JSONValue)
        case failure(any Error)
    }

    static func approved(_ token: DeviceLoginResult) -> JSONValue {
        [
            "outcome": "approved",
            "token_type": token.tokenType.map { .string($0) } ?? .null,
            "scopes": .array(token.scopes.map { .string($0) }),
            "expires_at": token.expiresAt.map { .string($0) } ?? .null,
            "token_id": token.tokenId.map { .string($0) } ?? .null,
        ]
    }

    static func failure(_ error: any Error, _ name: String) -> JSONValue {
        switch error {
        case ThalovantDeviceLoginError.denied:
            return ["outcome": "denied", "status": .null]
        case ThalovantDeviceLoginError.expired:
            return ["outcome": "expired", "status": .null]
        case let api as ThalovantApiError:
            var produced: JSONObject = [
                "outcome": "error",
                "status": api.statusCode.map { .integer($0) } ?? .null,
                "code": api.errorCode.map { .string($0) } ?? .null,
            ]
            if api.statusCode != nil { produced["detail"] = api.detail.map { .string($0) } ?? .null }
            return .object(produced)
        default:
            XCTFail("\(name): unexpected \(type(of: error))")
            return ["outcome": "unexpected"]
        }
    }

    private func assertNoSecrets(_ error: any Error, _ vectors: JSONObject, _ signing: Signing?, _ name: String) {
        var hidden = (vectors["message_excludes"]?.arrayValue ?? []).compactMap(\.stringValue)
        hidden += [BrowserApi.verifier, signing?.state].compactMap { $0 }
        var shown = printedForms(error)
        if let api = error as? ThalovantApiError {
            shown += [String(describing: api.problem), api.body ?? "", api.detail ?? "", api.errorCode ?? ""]
        }
        for secret in hidden {
            XCTAssertFalse(shown.contains { $0.contains(secret) }, "\(name): a secret reached the error")
        }
    }

    static func checkPageHeaders(_ answer: RawAnswer, _ headers: JSONObject, _ name: String) {
        for (header, value) in headers {
            XCTAssertEqual(answer.headers[header], value.stringValue, "\(name): \(header)")
        }
        // Self-contained: nothing for the page to load.
        XCTAssertFalse(answer.body.contains("src=") || answer.body.contains("href=") || answer.body.contains("http"), name)
    }

    #endif

    // MARK: The rest of the file

    func testEverySectionIsRun() throws {
        let sections: Set<String> = ["pkce", "redirect_uris", "authorization_urls", "config", "environment", "callbacks", "sign_ins", "chooser"]
        let present = Set(try vectors().compactMap { key, value -> String? in
            guard let first = value.arrayValue?.first?.objectValue, first["name"] != nil else { return nil }
            return key
        })
        XCTAssertEqual(present, sections)
    }

    func testTheRFC7636VectorIsTheFirstPKCECase() throws {
        let first = try XCTUnwrap(cases("pkce").first)
        XCTAssertEqual(first["verifier"], "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(first["expect"]?["challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testTheConstantsAreTheContracts() throws {
        let vectors = try vectors()
        XCTAssertEqual(vectors["client_id"], .string(BrowserLogin.sdkClientId))
        XCTAssertEqual(vectors["redirect_uri"], .string("http://127.0.0.1:{port}\(BrowserLogin.callbackPath)"))
        XCTAssertEqual(vectors["default_timeout_ms"]?.doubleValue, BrowserLogin.defaultTimeout * 1000)
        XCTAssertEqual(vectors["device_name_max_code_points"]?.intValue, BrowserLogin.maxDeviceNameLength)
        XCTAssertEqual(vectors["pages"]?["signed_in"], .string(loopbackSignedInText))
        XCTAssertEqual(vectors["pages"]?["not_completed"], .string(loopbackNotCompletedText))
        XCTAssertEqual(vectors["page_headers"], .object(Dictionary(uniqueKeysWithValues: loopbackPageHeaders.map { ($0.0, .string($0.1)) })))
        XCTAssertEqual(vectors["prompt"]?["opening"], .string(BrowserLogin.notice(for: "{url}", openBrowser: true)))
        XCTAssertEqual(vectors["prompt"]?["not_opening"], .string(BrowserLogin.notice(for: "{url}", openBrowser: false)))
    }

    func testGeneratedVerifiersAndStatesMeetTheirRules() throws {
        let vectors = try vectors()
        let verifier = try XCTUnwrap(vectors["verifier"]?.objectValue)
        let state = try XCTUnwrap(vectors["state"]?.objectValue)
        let verifierAlphabet = Set(try XCTUnwrap(verifier["alphabet"]?.stringValue))
        let stateAlphabet = Set(try XCTUnwrap(state["alphabet"]?.stringValue))
        for _ in 0..<20 {
            let made = BrowserLogin.newVerifier()
            XCTAssertTrue((try XCTUnwrap(verifier["min_length"]?.intValue)...(try XCTUnwrap(verifier["max_length"]?.intValue))).contains(made.count))
            XCTAssertTrue(made.allSatisfy(verifierAlphabet.contains))
            let tied = BrowserLogin.newState()
            XCTAssertGreaterThanOrEqual(tied.count, try XCTUnwrap(state["min_length"]?.intValue))
            // 24 bytes in base64url: 192 bits, over the 128 the contract asks for.
            XCTAssertGreaterThanOrEqual(tied.count * 6, try XCTUnwrap(state["min_random_bits"]?.intValue))
            XCTAssertTrue(tied.allSatisfy(stateAlphabet.contains))
        }
    }

    #if os(macOS) || os(Linux)
    func testTheListenerBindsLoopbackOnly() async throws {
        let listener = LoopbackListener(state: String(repeating: "s", count: 32))
        let port = try listener.start()
        XCTAssertEqual(listener.localAddress, "127.0.0.1")
        XCTAssertTrue((1024...65535).contains(port))
        await listener.close()
        XCTAssertTrue(RawHTTP.refused(port: port))
    }
    #endif
}

// MARK: - What the test learnt from the URL the SDK built

struct Signing: Sendable {
    let endpoint: String
    let pairs: [[String]]
    let port: Int
    let state: String
    let challenge: String

    struct Malformed: Error, CustomStringConvertible { let description: String }

    init(_ url: String) throws {
        let mark = url.firstIndex(of: "?") ?? url.endIndex
        endpoint = String(url[..<mark])
        let query = mark < url.endIndex ? url[url.index(after: mark)...] : ""
        pairs = query.split(separator: "&").map { field in
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
            }
            return [parts[0], parts.count > 1 ? parts[1] : ""]
        }
        var values: [String: String] = [:]
        for pair in pairs { values[pair[0]] = pair[1] }
        guard let redirect = values["redirect_uri"], let components = URLComponents(string: redirect),
              let port = components.port, let state = values["state"], let challenge = values["code_challenge"]
        else { throw Malformed(description: "the URL carries no redirect, state or challenge") }
        self.port = port
        self.state = state
        self.challenge = challenge
        let base64URL = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard state.count >= 22, state.unicodeScalars.allSatisfy(base64URL.contains) else {
            throw Malformed(description: "state must be at least 128 bits of base64url")
        }
        guard challenge.count == 43, challenge.unicodeScalars.allSatisfy(base64URL.contains) else {
            throw Malformed(description: "the challenge must be 43 base64url characters")
        }
        guard redirect == "http://127.0.0.1:\(port)/callback", (1024...65535).contains(port) else {
            throw Malformed(description: "the redirect must be http://127.0.0.1:<port>/callback")
        }
    }

    func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "http://127.0.0.1:\(port)/callback", with: "http://127.0.0.1:{port}/callback")
            .replacingOccurrences(of: state, with: "{state}")
            .replacingOccurrences(of: challenge, with: "{challenge}")
    }

    func urlRecord() -> JSONValue {
        [
            "endpoint": .string(endpoint),
            "query": .array(pairs.map { .array([.string($0[0]), .string(normalized($0[1]))]) }),
        ]
    }
}

/// base64url(SHA-256(text)), no padding, with the C SHA-256 the SDK carries for
/// Noise: a second implementation beside the Swift one PKCE uses.
func referenceChallenge(_ text: String) -> String {
    var context = thalovant_sha256_ctx()
    thalovant_sha256_init(&context)
    let bytes = Array(text.utf8)
    bytes.withUnsafeBufferPointer { thalovant_sha256_update(&context, $0.baseAddress, $0.count) }
    var digest = [UInt8](repeating: 0, count: 32)
    digest.withUnsafeMutableBufferPointer { thalovant_sha256_final(&context, $0.baseAddress) }
    return Data(digest).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

/// A value set once from any thread.
final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    var value: Value? { lock.locked { stored } }
    func setOnce(_ value: Value) { lock.locked { if stored == nil { stored = value } } }
}

// MARK: - The API, scripted

/// Serves one case's exchanges in order through URLSession and checks every
/// request against the one the case names: method, path, `json` and
/// `authorization`. The token exchange is checked before it is compared: it
/// must carry exactly the four fields, and its `code_verifier` must be 43-128
/// unreserved characters whose S256 challenge is the URL's; only then are the
/// generated values put back as `{verifier}`, `{port}`, `{state}` and
/// `{challenge}`. A request the case does not list is a mismatch, which is how
/// a device-login fallback is caught.
final class BrowserApi: URLProtocol {
    private static let lock = NSLock()
    private static var exchanges: [JSONObject] = []
    private static var index = 0
    private static var sentLines: [String] = []
    private static var mismatchLines: [String] = []
    private static var generation = 0
    private static var currentSigning: Signing?
    private static var exchangeRecord: JSONValue?
    private static var seenVerifier: String?

    static let apiURL = "http://127.0.0.1:8766"
    private static let casePrefix = "browser-case/"

    static func serve(_ next: [JSONObject]) {
        lock.locked {
            exchanges = next
            index = 0
            sentLines = []
            mismatchLines = []
            currentSigning = nil
            exchangeRecord = nil
            seenVerifier = nil
            generation += 1
        }
    }

    static func controlPlane(apiURL: String = apiURL) -> ThalovantControlPlane {
        let tag = lock.locked { generation }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BrowserApi.self]
        return ThalovantControlPlane(
            apiURL: apiURL, userAgent: "\(defaultThalovantUserAgent) \(casePrefix)\(tag)",
            session: URLSession(configuration: configuration))
    }

    static var signing: Signing? {
        get { lock.locked { currentSigning } }
        set { lock.locked { currentSigning = newValue } }
    }
    static var sent: [String] { lock.locked { sentLines } }
    static var mismatches: [String] { lock.locked { mismatchLines } }
    static var used: Int { lock.locked { index } }
    static var exchange: JSONValue? { lock.locked { exchangeRecord } }
    static var verifier: String? { lock.locked { seenVerifier } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        if let agent = request.value(forHTTPHeaderField: "User-Agent"), let range = agent.range(of: Self.casePrefix),
           let tag = Int(agent[range.upperBound...]), tag != Self.lock.locked({ Self.generation }) {
            answer(status: 599, contentType: "application/json", body: "{}")
            return
        }
        let method = request.httpMethod ?? ""
        let path = request.url?.path ?? ""
        let raw = request.httpBody ?? Self.drain(request.httpBodyStream) ?? Data()
        var body = raw.isEmpty ? nil : try? JSONDecoder().decode(JSONValue.self, from: raw)
        let next = Self.lock.locked { () -> JSONObject? in
            Self.sentLines.append("\(method) \(path)")
            guard Self.index < Self.exchanges.count else {
                Self.mismatchLines.append("unexpected \(method) \(path)")
                return nil
            }
            defer { Self.index += 1 }
            return Self.exchanges[Self.index]
        }
        guard let next, let expected = next["request"]?.objectValue, let response = next["response"]?.objectValue else {
            answer(status: 599, contentType: "application/json", body: "{}")
            return
        }
        var differences: [String] = []
        if method != expected["method"]?.stringValue || path != expected["path"]?.stringValue {
            differences.append("\(method) \(path) != \(expected["method"]?.stringValue ?? "") \(expected["path"]?.stringValue ?? "")")
        }
        if (path == "/v1/auth/native/token" && expected["path"]?.stringValue == path) || body?["code_verifier"] != nil {
            body = Self.tokenBody(body, &differences)
        }
        if let json = expected["json"], body != json {
            differences.append("body \(String(describing: body)) != \(json)")
        }
        if let wanted = expected["authorization"], request.value(forHTTPHeaderField: "Authorization") != wanted.stringValue {
            differences.append("wrong Authorization header")
        }
        if !differences.isEmpty { Self.lock.locked { Self.mismatchLines += differences } }
        answer(
            status: response["status"]?.intValue ?? 599,
            contentType: response["content_type"]?.stringValue ?? "application/json",
            body: response["body"]?.stringValue ?? "")
    }

    /// The exchange body with the generated values put back as placeholders, once proven.
    private static func tokenBody(_ body: JSONValue?, _ differences: inout [String]) -> JSONValue? {
        guard case .object(let fields)? = body, let signing = Self.signing else { return body }
        if Set(fields.keys) != ["code", "code_verifier", "client_id", "redirect_uri"] {
            differences.append("the exchange must carry exactly four fields, not \(fields.keys.sorted())")
        }
        var clean: JSONObject = [:]
        for (key, value) in fields {
            clean[key] = value.stringValue.map { .string(signing.normalized($0)) } ?? value
        }
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if let verifier = fields["code_verifier"]?.stringValue, (43...128).contains(verifier.count),
           verifier.unicodeScalars.allSatisfy(unreserved.contains), referenceChallenge(verifier) == signing.challenge {
            clean["code_verifier"] = "{verifier}"
            lock.locked { seenVerifier = verifier }
        } else {
            differences.append("the code_verifier is not the one the challenge was made from")
        }
        lock.locked { exchangeRecord = .object(clean) }
        return .object(clean)
    }

    private func answer(status: Int, contentType: String, body: String) {
        let bytes = Data(body.utf8)
        var headers = ["Content-Length": String(bytes.count)]
        if !bytes.isEmpty { headers["Content-Type"] = contentType }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: Self.apiURL)!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !bytes.isEmpty { client?.urlProtocol(self, didLoad: bytes) }
        client?.urlProtocolDidFinishLoading(self)
    }

    /// Apple platforms hand the body to URLProtocol as a stream.
    static func drain(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// MARK: - A browser tab, over a raw socket

struct RawAnswer {
    let status: Int
    let headers: [String: String]
    let body: String

    /// Which of the vectors' pages the body shows.
    func page(_ pages: JSONObject) -> String? {
        for key in pages.keys.sorted() where body.contains(pages[key]?.stringValue ?? "\u{0}") {
            return key
        }
        return nil
    }
}

enum RawHTTP {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// One request on its own connection, as a browser tab sends it.
    static func request(
        port: Int, method: String, target: String, beforeReading: (@Sendable () -> Void)? = nil
    ) async throws -> RawAnswer {
        let head = "\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"
        return try await raw(port: port, bytes: Array(head.utf8), beforeReading: beforeReading)
    }

    /// Bytes sent as they are, then everything the listener answers until it closes.
    static func raw(port: Int, bytes: [UInt8], beforeReading: (@Sendable () -> Void)? = nil) async throws -> RawAnswer {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    let connection = try RawConnection(port: port)
                    defer { connection.close() }
                    connection.send(bytes)
                    beforeReading?()
                    continuation.resume(returning: try parse(connection.readAll()))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    static func parse(_ data: [UInt8]) throws -> RawAnswer {
        let text = String(decoding: data, as: UTF8.self)
        guard let split = text.range(of: "\r\n\r\n") else { throw Failure(description: "no answer: \(text.prefix(80))") }
        let lines = text[..<split.lowerBound].components(separatedBy: "\r\n")
        let status = lines[0].split(separator: " ").dropFirst().first.flatMap { Int($0) }
        guard let status else { throw Failure(description: "no status line") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces)] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return RawAnswer(status: status, headers: headers, body: String(text[split.upperBound...]))
    }

    /// Sends `bytes` from one thread while reading the answer on another, as
    /// a browser does. Returns what was read, the errno the read ended with
    /// (nil for a clean end), and whether the sender was still sending five
    /// seconds after the read ended. The descriptor is closed only once the
    /// sender has returned: a stalled one is unblocked with `shutdown` first,
    /// never by closing a descriptor another socket could reuse.
    static func sendWhileReading(port: Int, bytes: [UInt8]) async throws -> ([UInt8], Int32?, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    let connection = try RawConnection(port: port)
                    let sent = DispatchSemaphore(value: 0)
                    let fd = connection.fd
                    Thread.detachNewThread {
                        _ = bytes.withUnsafeBytes { RawConnection.sendAll(fd, $0) }
                        sent.signal()
                    }
                    var data: [UInt8] = []
                    var failure: Int32?
                    var buffer = [UInt8](repeating: 0, count: 65_536)
                    while true {
                        let count = recv(fd, &buffer, buffer.count, 0)
                        if count > 0 { data += buffer[0..<count]; continue }
                        if count < 0 { failure = errno }
                        break
                    }
                    var stalled = false
                    if sent.wait(timeout: .now() + 5) == .timedOut {
                        stalled = true
                        #if canImport(Glibc)
                        _ = Glibc.shutdown(fd, Int32(SHUT_RDWR))
                        #else
                        _ = Darwin.shutdown(fd, Int32(SHUT_RDWR))
                        #endif
                        sent.wait()
                    }
                    connection.close()
                    continuation.resume(returning: (data, failure, stalled))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Whether a new connection to the port is refused.
    static func refused(port: Int) -> Bool {
        guard let connection = try? RawConnection(port: port) else { return true }
        connection.close()
        return false
    }
}

/// A blocking TCP connection to 127.0.0.1, bounded by a ten-second receive timeout.
final class RawConnection: @unchecked Sendable {
    let fd: Int32

    init(port: Int) throws {
        #if canImport(Glibc)
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard descriptor >= 0 else { throw RawHTTP.Failure(description: "socket() failed") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        var on: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            Self.systemClose(descriptor)
            throw RawHTTP.Failure(description: "connection refused")
        }
        fd = descriptor
    }

    func send(_ bytes: [UInt8]) {
        #if canImport(Glibc)
        let flags = Int32(MSG_NOSIGNAL)
        #else
        let flags: Int32 = 0
        #endif
        var sent = 0
        while sent < bytes.count {
            let wrote = bytes[sent...].withUnsafeBytes { buffer in
                #if canImport(Glibc)
                Glibc.send(fd, buffer.baseAddress, buffer.count, flags)
                #else
                Darwin.send(fd, buffer.baseAddress, buffer.count, flags)
                #endif
            }
            if wrote <= 0 { return }
            sent += wrote
        }
    }

    func readAll() -> [UInt8] {
        var data: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { return data }
            data += buffer[0..<count]
        }
    }

    func close() { Self.systemClose(fd) }

    /// Writes all of `bytes` on `fd`, or as much as goes before an error.
    @discardableResult
    static func sendAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
        #if canImport(Glibc)
        let flags = Int32(MSG_NOSIGNAL)
        #else
        let flags: Int32 = 0
        #endif
        var sent = 0
        while sent < bytes.count {
            #if canImport(Glibc)
            let wrote = Glibc.send(fd, bytes.baseAddress! + sent, bytes.count - sent, flags)
            #else
            let wrote = Darwin.send(fd, bytes.baseAddress! + sent, bytes.count - sent, flags)
            #endif
            if wrote <= 0 { return false }
            sent += wrote
        }
        return true
    }

    private static func systemClose(_ descriptor: Int32) {
        #if canImport(Glibc)
        _ = Glibc.close(descriptor)
        #else
        _ = Darwin.close(descriptor)
        #endif
    }
}
