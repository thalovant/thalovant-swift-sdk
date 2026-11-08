import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// How `ThalovantControlPlane.interactiveLogin(options:)` signs in.
public enum LoginMethod: String, Sendable, CaseIterable {
    /// The browser when this machine can show one and the API offers it,
    /// a device login otherwise.
    case auto
    /// Browser sign-in, forced. Never becomes a device login.
    case browser
    /// Device login, forced. The browser sign-in configuration is never asked for.
    case device
}

/// Browser sign-in: the OAuth authorization code grant with PKCE (RFC 7636,
/// S256 only) on a loopback redirect (RFC 8252 section 7.3), for a program on
/// a machine with a browser.
///
/// A device code can be passed on: somebody reads it off one screen and types
/// it in anywhere. With a loopback redirect the browser that approves hands the
/// code to its own computer's `127.0.0.1`, so a link or code sent to someone on
/// another computer delivers nothing to the sender. That is all it promises: a
/// forwarded callback port (`ssh -L`, a port-forwarding tool) or another user
/// of the same computer can still complete a sign-in.
/// `ThalovantControlPlane.browserLogin(options:)`
/// signs a program in this way; the pieces it is made of are here, so each can
/// be checked against the shared vectors on its own.
///
/// The loopback listener runs on macOS and Linux. An iOS, tvOS, watchOS or
/// visionOS app signs in with `NativeSignIn` and `ASWebAuthenticationSession`
/// instead (the iOS app is `thalovant-ios`), and `interactiveLogin` uses a
/// device login there.
public enum BrowserLogin {
    /// The SDKs' own registered app, which a program signs in as.
    /// `GET /v1/auth/native/config` names it as `sdk_client_id`.
    public static let sdkClientId = "thalovant-sdk"
    /// The one path the loopback listener answers.
    public static let callbackPath = loopbackCallbackPath
    /// Seconds a browser sign-in waits for the browser to come back.
    public static let defaultTimeout: TimeInterval = 300
    /// Seconds a device login waits when `interactiveLogin` falls back to one.
    public static let defaultDeviceLoginTimeout: TimeInterval = 900
    /// The longest `device_name` the consent page shows and the token is named
    /// by, in Unicode code points (the API refuses a longer one).
    public static let maxDeviceNameLength = 120
    /// The name this SDK gives itself in `defaultDeviceName()`.
    public static let sdkDeviceLabel = "thalovant-swift-sdk"

    /// Whether this build has the loopback listener: macOS and Linux.
    public static var isAvailable: Bool {
        #if os(macOS) || os(Linux)
        return true
        #else
        return false
        #endif
    }

    /// A PKCE verifier: 64 random bytes, base64url, no padding (86 characters).
    public static func newVerifier() -> String { NativeSignIn.newVerifier() }

    /// The S256 challenge for a verifier: base64url(SHA-256(verifier)), no padding.
    public static func challenge(for verifier: String) -> String { NativeSignIn.challenge(for: verifier) }

    /// An OAuth `state`: 24 random bytes (192 bits) from the system's secure
    /// generator, base64url, no padding (32 characters). Compare it in constant time.
    public static func newState() -> String { NativeSignIn.randomURLSafe(byteCount: 24) }

    /// `http://127.0.0.1:<port>/callback`, the one redirect a program is answered on.
    ///
    /// The IP literal, never `localhost`, which a hosts file or a resolver can
    /// send elsewhere; that path; no query, no trailing slash. The API matches
    /// it exactly and only for an unprivileged port, which is what a port bound
    /// as port 0 always is: a port outside 1024-65535 throws.
    public static func loopbackRedirectURI(port: Int) throws -> String {
        guard (1024...65535).contains(port) else {
            throw ThalovantApiError(message: "A loopback redirect needs a port from 1024 to 65535, not \(port).")
        }
        return "http://127.0.0.1:\(port)\(callbackPath)"
    }

    /// The address a browser sign-in opens.
    ///
    /// `{authorizationEndpoint}?response_type=code&client_id=...&redirect_uri=...
    /// &code_challenge=...&code_challenge_method=S256&state=...&scope=...
    /// &device_name=...`, in that order, every value percent-encoded as RFC
    /// 3986 has it (a space is `%20`). Empty strings among `scopes` are dropped
    /// and the rest joined by one space; `scope` is left out when nothing is
    /// left, and the API then grants its default (`hubs:read clients:write`).
    /// `deviceName` is cut to `maxDeviceNameLength` code points, and left out
    /// when empty.
    public static func authorizationURL(
        authorizationEndpoint: String,
        redirectURI: String,
        codeChallenge: String,
        state: String,
        scopes: [String]? = nil,
        deviceName: String? = nil,
        clientId: String = sdkClientId
    ) -> String {
        var parameters: [(String, String)] = [
            ("response_type", "code"),
            ("client_id", clientId),
            ("redirect_uri", redirectURI),
            ("code_challenge", codeChallenge),
            // S256 only: `plain` puts the verifier in the browser.
            ("code_challenge_method", "S256"),
            ("state", state),
        ]
        let scope = (scopes ?? []).filter { !$0.isEmpty }.joined(separator: " ")
        if !scope.isEmpty { parameters.append(("scope", scope)) }
        if let deviceName, !deviceName.isEmpty {
            parameters.append(("device_name", truncatedToCodePoints(deviceName, maxDeviceNameLength)))
        }
        let query = parameters.map { "\($0.0)=\(percentEncoded($0.1))" }.joined(separator: "&")
        return "\(authorizationEndpoint)?\(query)"
    }

    /// `thalovant-swift-sdk on <hostname>`: what the consent page and the token
    /// show when the caller names nothing, cut to `maxDeviceNameLength` code points.
    public static func defaultDeviceName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let host = gethostname(&buffer, buffer.count - 1) == 0
            ? String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return deviceName(host: host)
    }

    static func deviceName(host: String) -> String {
        truncatedToCodePoints(host.isEmpty ? sdkDeviceLabel : "\(sdkDeviceLabel) on \(host)", maxDeviceNameLength)
    }

    /// This machine as the browser rule names it: `macos`, `windows`, `linux`,
    /// or the platform's own lowercase name (`ios`, `tvos`, `watchos`,
    /// `visionos`, `freebsd`, ...). Android is `linux`, without a display.
    public static var platformName: String {
        #if os(macOS)
        return "macos"
        #elseif os(Windows)
        return "windows"
        #elseif os(Linux) || os(Android)
        return "linux"
        #elseif os(iOS)
        return "ios"
        #elseif os(tvOS)
        return "tvos"
        #elseif os(watchOS)
        return "watchos"
        #elseif os(visionOS)
        return "visionos"
        #elseif os(FreeBSD)
        return "freebsd"
        #elseif os(OpenBSD)
        return "openbsd"
        #else
        return "unknown"
        #endif
    }

    /// Whether this machine can show a browser to the person signing in.
    ///
    /// Never in CI (`CI` set) or over SSH (`SSH_CONNECTION` or `SSH_TTY` set):
    /// the browser would open on another machine, or nowhere. Otherwise yes on
    /// `macos` and `windows`; anywhere else -- Linux, the BSDs, iOS -- only
    /// with a display (`DISPLAY` or `WAYLAND_DISPLAY`). A variable counts as set
    /// when it has a value: an empty one is not set, and `CI=false` is set.
    /// `environment` and `platform` default to this process's.
    public static func canOpenBrowser(environment: [String: String]? = nil, platform: String? = nil) -> Bool {
        let variables = environment ?? ProcessInfo.processInfo.environment
        func present(_ name: String) -> Bool { !(variables[name] ?? "").isEmpty }
        if present("CI") || present("SSH_CONNECTION") || present("SSH_TTY") { return false }
        let system = platform ?? platformName
        if system == "macos" || system == "windows" { return true }
        return present("DISPLAY") || present("WAYLAND_DISPLAY")
    }

    /// What is printed when no `prompt` is given, the URL on the line after.
    static func notice(for url: String, openBrowser: Bool) -> String {
        openBrowser
            ? "Opening your browser to sign in to Thalovant. If it does not open, visit:\n\(url)"
            : "To sign in to Thalovant, visit:\n\(url)"
    }

    static func unavailableError() -> ThalovantApiError {
        ThalovantApiError(
            message: "Browser sign-in on a loopback redirect is not available on \(platformName). "
                + "An app signs in with NativeSignIn and ASWebAuthenticationSession; "
                + "interactiveLogin() uses a device login here.")
    }

    /// RFC 3986: `A-Z a-z 0-9 - . _ ~` as they are, every other byte of the
    /// UTF-8 form as `%XX` with uppercase hex.
    static func percentEncoded(_ value: String) -> String {
        let digits = Array("0123456789ABCDEF")
        var out = ""
        out.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."),
                 UInt8(ascii: "_"), UInt8(ascii: "~"):
                out.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                out.append("%")
                out.append(digits[Int(byte >> 4)])
                out.append(digits[Int(byte & 0x0F)])
            }
        }
        return out
    }

    /// The first `limit` Unicode scalars (code points), never a grapheme
    /// count: `String.count` is not the API's limit.
    static func truncatedToCodePoints(_ text: String, _ limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.prefix(limit))
        return String(scalars)
    }
}

/// Where a program signs in through the browser: `GET /v1/auth/native/config`.
///
/// `authorizationEndpoint` is the dashboard page the browser opens;
/// `tokenEndpoint` the path on the API the code is exchanged at; `sdkClientId`
/// the registered app the program signs in as. The API reads it from its own
/// settings, so a staging or self-hosted API sends the browser to its own
/// dashboard. The redirect is never read from here: it is always
/// `http://127.0.0.1:<port>/callback`.
public struct NativeSignInConfig: Equatable, Sendable {
    public let authorizationEndpoint: String
    public let tokenEndpoint: String
    public let sdkClientId: String
    public let deviceAuthorizationEndpoint: String?

    /// Reads the answer, refusing one a browser sign-in cannot safely use, with
    /// a `ThalovantApiError` that has no status.
    ///
    /// Unusable: not a JSON object; an `authorization_endpoint` that is not
    /// https (or http on `localhost`, `127.0.0.1` or `::1`), carries
    /// credentials, a query or a fragment, whitespace or a control character,
    /// names port 0 or one above 65535, or whose host as written is not an
    /// IPv6 address between brackets, an IPv4 address or an ASCII DNS name; a
    /// `token_endpoint` that is not a path on the API (one leading `/`, not
    /// `//`, every `%` followed by two hex digits, and no `:`, `?`, `#`, `\` or
    /// whitespace); an `sdk_client_id` that is not 1-64 of `[A-Za-z0-9._-]`; or
    /// a `code_challenge_methods_supported` that is not a list with `S256`.
    /// Other members are ignored.
    public init(payload: JSONValue) throws {
        guard case .object(let object) = payload else {
            throw Self.unusable("The browser sign-in configuration is not an object.")
        }
        guard case .string(let authorization)? = object["authorization_endpoint"],
              Self.usableAuthorizationEndpoint(authorization) else {
            throw Self.unusable("The browser sign-in configuration has no usable authorization_endpoint.")
        }
        guard case .string(let token)? = object["token_endpoint"], Self.usableTokenEndpoint(token) else {
            throw Self.unusable("The browser sign-in configuration has no usable token_endpoint.")
        }
        guard case .string(let clientId)? = object["sdk_client_id"], Self.usableClientId(clientId) else {
            throw Self.unusable("The browser sign-in configuration has no usable sdk_client_id.")
        }
        guard case .array(let methods)? = object["code_challenge_methods_supported"],
              methods.contains(.string("S256")) else {
            throw Self.unusable("The browser sign-in configuration does not offer S256.")
        }
        authorizationEndpoint = authorization
        tokenEndpoint = token
        sdkClientId = clientId
        if case .string(let device)? = object["device_authorization_endpoint"], !device.isEmpty {
            deviceAuthorizationEndpoint = device
        } else {
            deviceAuthorizationEndpoint = nil
        }
    }

    /// `init(payload:)` for an answer already read as an object.
    public init(response: JSONObject) throws {
        try self.init(payload: .object(response))
    }

    /// A configuration as given, past the checks `init(payload:)` makes (tests).
    init(authorizationEndpoint: String, tokenEndpoint: String, sdkClientId: String, deviceAuthorizationEndpoint: String? = nil) {
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.sdkClientId = sdkClientId
        self.deviceAuthorizationEndpoint = deviceAuthorizationEndpoint
    }

    private static func unusable(_ message: String) -> ThalovantApiError {
        ThalovantApiError(message: message)
    }

    /// Whitespace (Unicode White_Space), a C0 control or DEL and the C1 controls.
    private static func hasSpaceOrControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.properties.isWhitespace || $0.value < 32 || (127...159).contains($0.value) }
    }

    /// https, or http on a loopback host while developing; a host that is an IP
    /// address or a real hostname; a port a browser can open; no credentials,
    /// query, fragment, whitespace or control characters. Read the way the
    /// reference's `urlsplit` reads it, with its bracket rule: nothing before
    /// `[`, and nothing but an optional `:port` after `]`.
    static func usableAuthorizationEndpoint(_ value: String) -> Bool {
        guard !value.isEmpty, !hasSpaceOrControl(value), !value.contains("?"), !value.contains("#"),
              let colon = value.firstIndex(of: ":") else { return false }
        let scheme = value[..<colon]
        guard let first = scheme.unicodeScalars.first, first.isASCII, first.properties.isAlphabetic,
              scheme.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "+-.".unicodeScalars.contains($0)) })
        else { return false }
        let rest = value[value.index(after: colon)...]
        guard rest.hasPrefix("//") else { return false }
        let authority = rest.dropFirst(2).prefix { $0 != "/" }
        guard !authority.contains("@") else { return false }
        let opens = authority.contains("["), closes = authority.contains("]")
        guard opens == closes else { return false }
        let host: Substring
        let port: Substring?
        if opens {
            guard authority.first == "[", let close = authority.firstIndex(of: "]") else { return false }
            host = authority[authority.index(after: authority.startIndex)..<close]
            let after = authority[authority.index(after: close)...]
            if after.isEmpty {
                port = nil
            } else {
                guard after.first == ":" else { return false }
                port = after.dropFirst()
            }
        } else if let mark = authority.firstIndex(of: ":") {
            host = authority[..<mark]
            port = authority[authority.index(after: mark)...]
        } else {
            host = authority
            port = nil
        }
        if let port, !port.isEmpty {
            // 0 parses, and no browser can open it; neither can one above 65535.
            guard port.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
                  let number = Int(port), (1...65535).contains(number) else { return false }
        }
        let name = host.lowercased()
        guard !name.isEmpty, isRealHost(name, bracketed: opens) else { return false }
        switch scheme.lowercased() {
        case "https": return true
        case "http": return ["localhost", "127.0.0.1", "::1"].contains(name)
        default: return false
        }
    }

    /// Whether `host` (lowercased, brackets off) names something a browser can
    /// reach: an IPv6 address between brackets; an IPv4 address whenever the
    /// last label is a number, as a browser reads it; otherwise a DNS name of
    /// ASCII labels, each of letters, digits and inner hyphens and 1-63
    /// characters long, at most 253 characters in all. So `%`, `_`, an empty
    /// label, a trailing dot and a non-ASCII host are not one: an international
    /// name is written in its `xn--` form.
    static func isRealHost(_ host: String, bracketed: Bool) -> Bool {
        if bracketed { return isIPv6(host) }
        if isIPv4(host) { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if let last = labels.last, !last.isEmpty, last.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }) {
            return false  // numeric like an IPv4 address, and not one
        }
        return host.unicodeScalars.count <= 253 && labels.allSatisfy(isHostLabel)
    }

    /// `[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?`
    private static func isHostLabel(_ label: Substring) -> Bool {
        let scalars = Array(label.unicodeScalars)
        guard (1...63).contains(scalars.count) else { return false }
        func alphanumeric(_ scalar: Unicode.Scalar) -> Bool { ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) }
        guard alphanumeric(scalars[0]), alphanumeric(scalars[scalars.count - 1]) else { return false }
        return scalars.allSatisfy { alphanumeric($0) || $0 == "-" }
    }

    /// An IPv6 address, with an optional `%zone`, as the reference's
    /// `ipaddress` reads one: a zone, when there is a `%`, is not empty and
    /// holds no second `%`.
    private static func isIPv6(_ text: String) -> Bool {
        var address = in6_addr()
        let parts = text.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2, parts[1].isEmpty || parts[1].contains("%") { return false }
        return inet_pton(AF_INET6, String(parts[0]), &address) == 1
    }

    /// Four decimal octets, 0-255 each, no leading zeros.
    private static func isIPv4(_ text: String) -> Bool {
        var address = in_addr()
        return inet_pton(AF_INET, text, &address) == 1
    }

    /// A path on the API: one leading slash, not two, every `%` followed by two
    /// hex digits, and no colon, query, fragment, backslash, whitespace or
    /// control character.
    ///
    /// No colon, because a URL joiner can read what follows the slash as a URL
    /// of its own (`/https://collector.example/token`,
    /// `/collector.example:443/token`), and the exchange carries the code and
    /// the verifier. A broken escape (`/v1/%zz`) is found here, while a device
    /// login can still stand in, rather than after somebody approved.
    static func usableTokenEndpoint(_ value: String) -> Bool {
        guard value.hasPrefix("/"), !value.hasPrefix("//") else { return false }
        guard !hasSpaceOrControl(value), !value.contains(where: { ":?#\\".contains($0) }) else { return false }
        let scalars = Array(value.unicodeScalars)
        for (index, scalar) in scalars.enumerated() where scalar == "%" {
            guard index + 2 < scalars.count, scalars[index + 1].properties.isASCIIHexDigit,
                  scalars[index + 2].properties.isASCIIHexDigit else { return false }
        }
        return true
    }

    /// 1-64 of `A-Z a-z 0-9 . _ -`.
    static func usableClientId(_ value: String) -> Bool {
        (1...64).contains(value.unicodeScalars.count) && value.unicodeScalars.allSatisfy {
            ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) || "._-".unicodeScalars.contains($0)
        }
    }
}

/// Options for `ThalovantControlPlane.browserLogin(options:)`.
public struct BrowserLoginOptions: Sendable {
    /// Scopes the token carries. Nil or none asks for the API's default,
    /// `hubs:read` and `clients:write`; empty strings are dropped.
    public var scopes: [String]?
    /// What the consent page and the token show, cut to 120 code points. Nil
    /// is `BrowserLogin.defaultDeviceName()` (`thalovant-swift-sdk on
    /// <hostname>`); an empty name sends none, and keeps the hostname off the
    /// consent page.
    public var deviceName: String?
    /// Open the browser at the consent page (best-effort; the URL is shown
    /// either way). False only shows the URL.
    public var openBrowser: Bool
    /// Seconds to wait for the browser to come back before throwing
    /// `ThalovantDeviceLoginError.expired`.
    public var timeout: TimeInterval
    /// Receives the URL in place of the printed notice. It does not stop the
    /// browser from opening.
    public var prompt: (@Sendable (String) -> Void)?
    /// Opens the URL in place of the platform's browser (`open` on macOS,
    /// `xdg-open` on Linux). Called off the waiting task; its failure changes
    /// nothing, since the URL was already shown.
    public var opener: (@Sendable (URL) -> Void)?

    public init(
        scopes: [String]? = nil,
        deviceName: String? = nil,
        openBrowser: Bool = true,
        timeout: TimeInterval = BrowserLogin.defaultTimeout,
        prompt: (@Sendable (String) -> Void)? = nil,
        opener: (@Sendable (URL) -> Void)? = nil
    ) {
        self.scopes = scopes
        self.deviceName = deviceName
        self.openBrowser = openBrowser
        self.timeout = timeout
        self.prompt = prompt
        self.opener = opener
    }
}

/// Options for `ThalovantControlPlane.interactiveLogin(options:)`.
public struct InteractiveLoginOptions: Sendable {
    /// `.auto` (the default), or one of the two methods, forced.
    public var method: LoginMethod
    /// Scopes the token carries; nil asks for the API's default.
    public var scopes: [String]?
    /// Names this machine on the consent page: a browser sign-in's
    /// `device_name`, a device login's `client_name`. Nil is
    /// `BrowserLogin.defaultDeviceName()`; an empty name sends none, to either.
    public var deviceName: String?
    /// Open the browser (the consent page, or the device login's verification page).
    public var openBrowser: Bool
    /// Nil is each method's own: 300 seconds for the browser, 900 for a device login.
    public var timeout: TimeInterval?
    /// Opens a URL in place of the platform's browser; it receives the device
    /// login's verification page too.
    public var opener: (@Sendable (URL) -> Void)?
    /// The variables the browser rule reads, in place of this process's (tests).
    var environment: [String: String]?
    /// The platform the browser rule names, in place of this one (tests).
    var platform: String?

    public init(
        method: LoginMethod = .auto,
        scopes: [String]? = nil,
        deviceName: String? = nil,
        openBrowser: Bool = true,
        timeout: TimeInterval? = nil,
        opener: (@Sendable (URL) -> Void)? = nil
    ) {
        self.method = method
        self.scopes = scopes
        self.deviceName = deviceName
        self.openBrowser = openBrowser
        self.timeout = timeout
        self.opener = opener
    }
}

extension ThalovantControlPlane {
    /// Signs in through the browser and stores the API token.
    ///
    /// The authorization code grant with PKCE on a loopback redirect (RFC
    /// 8252): the SDK listens on `127.0.0.1` on a port the system picks, opens
    /// the browser at the dashboard's consent page (read from `GET
    /// /v1/auth/native/config`), and waits for the browser to come back to
    /// `http://127.0.0.1:<port>/callback`. The browser that approves hands the
    /// code to its own computer's `127.0.0.1`, so a link or code sent to
    /// someone on another computer delivers nothing to the sender -- which a
    /// device code, read off one screen and typed in anywhere, cannot promise.
    /// A forwarded callback port or another user of the same computer is
    /// another matter.
    ///
    /// The URL is always shown as well as opened. Without `options.prompt` it
    /// is printed (`Opening your browser to sign in to Thalovant. If it does
    /// not open, visit:` and the URL); a `prompt` receives it instead of the
    /// print. `openBrowser: false` only shows it. A sandboxed macOS app needs
    /// the `com.apple.security.network.server` entitlement to listen; without
    /// it the listener cannot start and this throws, as `interactiveLogin`
    /// does whenever it picks browser sign-in.
    ///
    /// Returns the token answer as a `DeviceLoginResult` and stores
    /// `accessToken` and `tokenId` exactly as a device login does, so
    /// `revokeApiToken()` revokes it the same way. A tab that answers with
    /// another sign-in's `state` is turned away and the wait goes on. Denied in
    /// the browser throws `ThalovantDeviceLoginError.denied`; no answer within
    /// `options.timeout` seconds (default 300) throws
    /// `ThalovantDeviceLoginError.expired`; a code the API will not exchange
    /// throws `ThalovantApiError` with its `statusCode` and `detail`
    /// (`invalid_grant`). An API without browser sign-in answers the
    /// configuration with a 404, thrown as a `ThalovantApiError` with that
    /// status: `interactiveLogin` falls back to a device login for it. A
    /// cleartext API URL (neither https nor loopback http) is refused before
    /// anything is asked or opened. Cancelling the task closes the port and
    /// throws `CancellationError`. Neither the code, the verifier, the state
    /// nor the token appears in an error.
    ///
    /// macOS and Linux. On iOS, tvOS, watchOS and visionOS sign in with
    /// `NativeSignIn` and `ASWebAuthenticationSession`.
    @available(iOS, unavailable, message: "Sign in with NativeSignIn and ASWebAuthenticationSession; interactiveLogin() uses a device login on iOS.")
    @available(tvOS, unavailable, message: "Sign in with a device login: loginWithBrowser() or interactiveLogin().")
    @available(watchOS, unavailable, message: "Sign in with a device login: loginWithBrowser() or interactiveLogin().")
    @available(visionOS, unavailable, message: "Sign in with NativeSignIn and ASWebAuthenticationSession.")
    @discardableResult
    public func browserLogin(options: BrowserLoginOptions = BrowserLoginOptions()) async throws -> DeviceLoginResult {
        #if os(macOS) || os(Linux)
        // Before anything is asked or opened: a code and its verifier never
        // cross the network in cleartext.
        try NativeSignIn.requireSecureTokenExchange(apiURL)
        let config = try await nativeSignInConfig()
        return try await signInThroughBrowser(
            config, scopes: options.scopes, deviceName: options.deviceName, openBrowser: options.openBrowser,
            timeout: options.timeout, prompt: options.prompt, opener: options.opener)
        #else
        throw BrowserLogin.unavailableError()
        #endif
    }

    /// Signs a person in the best way this machine allows, and stores the API token.
    ///
    /// `.auto` signs in through the browser (`browserLogin(options:)`) when this
    /// machine can show one (`BrowserLogin.canOpenBrowser()`: never over SSH or
    /// in CI; on Linux only with a display) and the API answers `GET
    /// /v1/auth/native/config` with a usable configuration; otherwise -- a 404,
    /// another failure, an unusable answer, a cleartext API URL -- it uses a
    /// device login (`loginWithBrowser(options:)`), whose code can be approved
    /// from any browser. Nothing has been opened by then, so that is not a
    /// downgrade. `.browser` and `.device` force one: a forced browser sign-in
    /// throws its configuration failure, and a forced device login never asks
    /// for the configuration. Once the browser has been sent to the consent
    /// page, the browser sign-in's own outcome stands: denied, expired or a
    /// refused exchange is thrown, never turned into a device login.
    ///
    /// `deviceName` names this machine on the consent page (a device login's
    /// `client_name`). `timeout` defaults to each method's own: 300 seconds for
    /// the browser, 900 for a device login, whose own timeout still throws
    /// `ThalovantTimeoutError`. Returns the token, as both methods do.
    ///
    /// On iOS, tvOS, watchOS and visionOS there is no loopback listener: `.auto`
    /// is a device login and `.browser` throws.
    @discardableResult
    public func interactiveLogin(options: InteractiveLoginOptions = InteractiveLoginOptions()) async throws -> DeviceLoginResult {
        // Only nil asks for the default: an empty name is the caller's way of
        // sending none, and keeps the hostname out.
        let name = options.deviceName ?? BrowserLogin.defaultDeviceName()
        var config: NativeSignInConfig?
        switch options.method {
        case .browser:
            guard BrowserLogin.isAvailable else { throw BrowserLogin.unavailableError() }
            try NativeSignIn.requireSecureTokenExchange(apiURL)
            config = try await nativeSignInConfig()
        case .auto:
            if BrowserLogin.isAvailable,
               BrowserLogin.canOpenBrowser(environment: options.environment, platform: options.platform) {
                do {
                    try NativeSignIn.requireSecureTokenExchange(apiURL)
                    config = try await nativeSignInConfig()
                } catch is ThalovantApiError {
                    // An older API (404), or one that cannot say: the browser
                    // has not been opened, so a device login is not a downgrade.
                    config = nil
                }
            }
        case .device:
            config = nil
        }
        guard let config else {
            var device = DeviceLoginOptions(scopes: options.scopes, clientName: name, openBrowser: options.openBrowser)
            device.timeout = options.timeout ?? BrowserLogin.defaultDeviceLoginTimeout
            // A caller's opener runs off the polling task, as the browser
            // sign-in's does: one that waits for a console browser to exit
            // must not hold the polls, or the timeout, back.
            let launch = options.opener.map { open in
                { (url: URL) in DispatchQueue.global(qos: .userInitiated).async { open(url) } }
            }
            return try await deviceLogin(options: device, launch: launch)
        }
        #if os(macOS) || os(Linux)
        return try await signInThroughBrowser(
            config, scopes: options.scopes, deviceName: name, openBrowser: options.openBrowser,
            timeout: options.timeout ?? BrowserLogin.defaultTimeout, prompt: nil, opener: options.opener)
        #else
        throw BrowserLogin.unavailableError()
        #endif
    }

    /// `GET /v1/auth/native/config`: where to send the browser, where to exchange.
    ///
    /// A 404 is an API without browser sign-in, thrown with its status and the
    /// body's fields; any other refusal is the api-errors error; a 2xx this SDK
    /// cannot use is an error with no status, because the API did not refuse.
    func nativeSignInConfig() async throws -> NativeSignInConfig {
        let request = try buildRequest("GET", "/v1/auth/native/config", auth: false)
        let (data, response) = try await perform(request)
        guard (200..<300).contains(response.statusCode) else {
            let failure = ThalovantApiError.httpFailure(
                statusCode: response.statusCode, body: String(decoding: data, as: UTF8.self),
                header: { response.value(forHTTPHeaderField: $0) })
            if response.statusCode == 404 {
                throw failure.reclassified(
                    as: failure.kind,
                    message: "This Thalovant API does not offer browser sign-in; sign in with a device login instead.")
            }
            throw failure
        }
        let payload = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
        do {
            return try NativeSignInConfig(payload: payload)
        } catch let error as ThalovantApiError {
            throw ThalovantApiError(
                message: "Thalovant API answered an unusable browser sign-in configuration. \(error.message)")
        }
    }

    #if os(macOS) || os(Linux)
    /// One browser sign-in against `config`: listen, show and open, wait,
    /// exchange, answer the tab.
    func signInThroughBrowser(
        _ config: NativeSignInConfig,
        scopes: [String]?,
        deviceName: String?,
        openBrowser: Bool,
        timeout: TimeInterval,
        prompt: (@Sendable (String) -> Void)?,
        opener: (@Sendable (URL) -> Void)?
    ) async throws -> DeviceLoginResult {
        try NativeSignIn.requireSecureTokenExchange(apiURL)
        let verifier = BrowserLogin.newVerifier()
        let state = BrowserLogin.newState()
        let listener = LoopbackListener(state: state)
        // Bound before the URL is built: the redirect names the port.
        let port = try listener.start()
        let outcome: Result<DeviceLoginResult, Error>
        do {
            outcome = .success(try await browserSignIn(
                config, listener: listener, port: port, verifier: verifier, state: state, scopes: scopes,
                deviceName: deviceName, openBrowser: openBrowser, timeout: timeout, prompt: prompt, opener: opener))
        } catch {
            outcome = .failure(error)
        }
        // Accepted, timed out, cancelled or failed: the port closes either way.
        await listener.close()
        return try outcome.get()
    }

    private func browserSignIn(
        _ config: NativeSignInConfig,
        listener: LoopbackListener,
        port: Int,
        verifier: String,
        state: String,
        scopes: [String]?,
        deviceName: String?,
        openBrowser: Bool,
        timeout: TimeInterval,
        prompt: (@Sendable (String) -> Void)?,
        opener: (@Sendable (URL) -> Void)?
    ) async throws -> DeviceLoginResult {
        let redirectURI = try BrowserLogin.loopbackRedirectURI(port: port)
        let url = BrowserLogin.authorizationURL(
            authorizationEndpoint: config.authorizationEndpoint,
            redirectURI: redirectURI,
            codeChallenge: BrowserLogin.challenge(for: verifier),
            state: state,
            scopes: scopes,
            deviceName: deviceName ?? BrowserLogin.defaultDeviceName(),
            clientId: config.sdkClientId)
        presentBrowserLogin(url, prompt: prompt, openBrowser: openBrowser, opener: opener)
        let callback = await listener.wait(timeout: timeout)
        try Task.checkCancellation()
        switch callback {
        case nil:
            throw ThalovantDeviceLoginError.expired
        case .denied?:
            throw ThalovantDeviceLoginError.denied
        case .failed(let error)?:
            // `error` is one of RFC 6749's codes or nothing: a value the page
            // chose could be the state or a code.
            throw ThalovantApiError(
                message: "The browser came back without a sign-in code" + (error.map { " (\($0))." } ?? "."),
                errorCode: error)
        case .code(let code)?:
            let hidden = [code, verifier, state]
            do {
                let token = try await exchangeBrowserCode(
                    config, code: code, verifier: verifier, redirectURI: redirectURI, hidden: hidden)
                listener.finish(signedIn: true)
                return token
            } catch let error as ThalovantApiError {
                // A code is single-use: retrying the exchange would only
                // revoke the token a first exchange minted (RFC 9700).
                throw error.withoutSecrets(hidden)
            }
        }
    }

    /// `POST {token_endpoint}` with exactly the four fields, and keep the token.
    ///
    /// Read as a device-login token answer is: a 2xx whose body is not a JSON
    /// object with an `access_token` is an error with no status -- the API did
    /// not refuse, its answer could not be used -- and any other failure
    /// carries the api-errors fields (`invalid_grant` for every way an exchange
    /// fails). The answer has every value in `hidden` taken out before the
    /// error's message is built, so a message cut to length keeps no part of
    /// one.
    ///
    /// Sent once, on a connection of its own: an HTTP stack that finds a reused
    /// connection dead may resend the request on a fresh one, and a code
    /// presented twice revokes the token the first exchange minted.
    /// `buildRequest` keeps it on the API's origin, as every request.
    func exchangeBrowserCode(
        _ config: NativeSignInConfig, code: String, verifier: String, redirectURI: String, hidden: [String]
    ) async throws -> DeviceLoginResult {
        try NativeSignIn.requireSecureTokenExchange(apiURL)
        let payload: JSONObject = [
            "code": .string(code),
            "code_verifier": .string(verifier),
            "client_id": .string(config.sdkClientId),
            "redirect_uri": .string(redirectURI),
        ]
        let request = try buildRequest("POST", config.tokenEndpoint, body: payload, auth: false)
        let (data, response) = try await performOnce(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ThalovantApiError.httpFailure(
                statusCode: response.statusCode, body: redactedBody(data, hidden),
                header: { response.value(forHTTPHeaderField: $0) })
        }
        guard let token = try? ThalovantJSON.decodeObject(data) else {
            throw ThalovantApiError(message: "Thalovant API returned an unexpected response shape.")
        }
        return try browserTokenResult(token)
    }

    /// Keeps the token as a device login does (`keepSignIn`) and returns it,
    /// its id read from this same answer: never `tokenId` read back, which a
    /// sign-in completing meanwhile on another task could have replaced.
    func browserTokenResult(_ token: JSONObject) throws -> DeviceLoginResult {
        let accessToken = try keepSignIn(token)
        return DeviceLoginResult(
            accessToken: accessToken,
            tokenType: token["token_type"]?.stringValue,
            scopes: (token["scopes"]?.arrayValue ?? []).compactMap { $0.stringValue },
            expiresAt: token["expires_at"]?.stringValue,
            tokenId: token["token_id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
            raw: token)
    }

    /// An error answer's body with every value in `hidden` taken out: scrubbed
    /// as parsed JSON when it parses (an escaped value is still the value) and
    /// written back, else as text.
    func redactedBody(_ data: Data, _ hidden: [String]) -> String {
        if let parsed = try? JSONDecoder().decode(JSONValue.self, from: data),
           let encoded = try? JSONEncoder.sortedKeys.encode(redacting(parsed, hidden)) {
            return String(decoding: encoded, as: UTF8.self)
        }
        return redacting(String(decoding: data, as: UTF8.self), hidden)
    }

    /// Shows the URL (opening a browser can fail without a word) and opens it
    /// off the waiting task: a console browser can hold the call until it exits.
    private func presentBrowserLogin(
        _ url: String, prompt: (@Sendable (String) -> Void)?, openBrowser: Bool, opener: (@Sendable (URL) -> Void)?
    ) {
        if let prompt {
            prompt(url)
        } else {
            print(BrowserLogin.notice(for: url, openBrowser: openBrowser))
            fflush(stdout)
        }
        guard openBrowser else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            openBrowserBestEffort(url, launch: opener)
        }
    }
    #endif

}

/// The marker every redacted value becomes.
let redactedMarker = "[redacted]"

/// `text` with every value in `hidden` replaced by `[redacted]`, in one pass.
///
/// Every place any value occurs is found in the text as it was given, before
/// anything is replaced, and each run of covered characters becomes one
/// `[redacted]`. So a value that is part of a longer one cannot break it up
/// before it is matched, and two values that overlap leave nothing of either.
/// A value is matched across a `[redacted]` already there too, so a secret
/// that contains the marker is still taken out. Only a match lying wholly
/// inside an existing `[redacted]` is left alone, so scrubbing twice changes
/// nothing; a marker a match runs into is replaced whole. Empty values are
/// ignored.
func redacting(_ text: String, _ hidden: [String]) -> String {
    let values = Set(hidden.filter { !$0.isEmpty })
    guard !values.isEmpty else { return text }
    let scalars = Array(text.unicodeScalars)
    let marker = Array(redactedMarker.unicodeScalars)
    func occurrences(_ needle: [Unicode.Scalar]) -> [Int] {
        guard !needle.isEmpty, needle.count <= scalars.count else { return [] }
        return (0...(scalars.count - needle.count)).filter { scalars[$0..<$0 + needle.count].elementsEqual(needle) }
    }
    // The markers already there, left to right, never overlapping.
    var markers: [Range<Int>] = []
    for start in occurrences(marker) where markers.last.map({ start >= $0.upperBound }) ?? true {
        markers.append(start..<start + marker.count)
    }
    var covered = [Bool](repeating: false, count: scalars.count)
    for value in values {
        let needle = Array(value.unicodeScalars)
        for start in occurrences(needle) {
            let match = start..<start + needle.count
            if markers.contains(where: { $0.lowerBound <= match.lowerBound && match.upperBound <= $0.upperBound }) { continue }
            for index in match { covered[index] = true }
        }
    }
    for range in markers where range.contains(where: { covered[$0] }) {
        for index in range { covered[index] = true }
    }
    var out = String.UnicodeScalarView()
    var index = 0
    while index < scalars.count {
        if covered[index] {
            out.append(contentsOf: marker)
            while index < scalars.count && covered[index] { index += 1 }
        } else {
            out.append(scalars[index])
            index += 1
        }
    }
    return String(out)
}

/// `redacting(_:_:)` through a JSON value, keys included.
func redacting(_ value: JSONValue, _ hidden: [String]) -> JSONValue {
    switch value {
    case .string(let text): return .string(redacting(text, hidden))
    case .array(let items): return .array(items.map { redacting($0, hidden) })
    case .object(let fields): return .object(redacting(fields, hidden))
    default: return value
    }
}

func redacting(_ fields: JSONObject, _ hidden: [String]) -> JSONObject {
    var out: JSONObject = [:]
    for (key, value) in fields { out[redacting(key, hidden)] = redacting(value, hidden) }
    return out
}

extension JSONEncoder {
    /// Keys sorted, so a re-encoded body reads the same every time.
    static var sortedKeys: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension ThalovantApiError {
    /// A new error like this one, with every value in `hidden` replaced by
    /// `[redacted]` in its message, body, code, detail and problem (keys
    /// included).
    ///
    /// An API that echoes a request back (a 422 lists each field's `input`)
    /// would otherwise hand the code and the verifier to whoever logs the
    /// error. Always a new value, built from the scrubbed fields alone.
    func withoutSecrets(_ hidden: [String]) -> ThalovantApiError {
        ThalovantApiError(
            message: redacting(message, hidden), statusCode: statusCode, body: body.map { redacting($0, hidden) },
            errorCode: errorCode.map { redacting($0, hidden) }, detail: detail.map { redacting($0, hidden) },
            problem: problem.map { redacting($0, hidden) }, kind: kind, retryAfterSeconds: retryAfterSeconds)
    }
}
