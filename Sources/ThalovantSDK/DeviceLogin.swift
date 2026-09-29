import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Default seconds between `POST /v1/auth/device/token` polls when the
/// authorization response does not specify an `interval`.
public let defaultDevicePollInterval: TimeInterval = 5.0

/// The browser device sign-in ended in a terminal state before a token was
/// issued. Timeouts waiting for approval throw `ThalovantTimeoutError` instead.
///
/// `loginWithBrowser` throws this. The one-step `pollDeviceLogin` throws
/// `ThalovantApiError` instead, whose `kind` (`.deviceLoginDenied`,
/// `.deviceLoginExpired`) says the same thing and which keeps the HTTP status
/// and body beside it.
public enum ThalovantDeviceLoginError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// The sign-in request was denied in the browser (`access_denied`).
    case denied
    /// The user code expired before it was approved (`expired_token`).
    case expired

    public var message: String {
        switch self {
        case .denied:
            return "The device sign-in request was denied in the browser."
        case .expired:
            return "The device sign-in code expired before it was approved. "
                + "Call loginWithBrowser() again to request a new code."
        }
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

/// The pending authorization returned by `POST /v1/auth/device/authorize`:
/// what `beginDeviceLogin` returns, and what the `DeviceLoginOptions.prompt`
/// closure is handed so callers can present the code themselves.
/// `deviceCode` is the secret half; it never needs showing.
public struct DeviceAuthorizationGrant: Sendable {
    public let deviceCode: String
    /// Short code the user types at `verificationUri`.
    public let userCode: String
    public let verificationUri: String
    /// `verificationUri` with the code pre-filled, when the API provides one.
    public let verificationUriComplete: String?
    /// Seconds until the grant expires server-side.
    public let expiresIn: Int?
    /// Seconds to wait between token polls.
    public let interval: TimeInterval
    /// The raw authorization response.
    public let raw: JSONObject
}

/// Options for `ThalovantControlPlane.loginWithBrowser`.
public struct DeviceLoginOptions: Sendable {
    /// Scopes to request for the issued API token (sent as `scopes` only when
    /// set and not empty; the server may normalize and expand the echoed
    /// scopes).
    public var scopes: [String]?
    /// Human-readable name recorded on the issued token (sent as
    /// `client_name` only when set).
    public var clientName: String?
    /// Open `verificationUriComplete` in the local browser (best-effort:
    /// `/usr/bin/open` on macOS, `xdg-open` on Linux, skipped on other
    /// platforms; failures are ignored).
    public var openBrowser: Bool
    /// Presents the pending authorization to the user. The default prints
    /// `To sign in, visit <verification_uri> and enter the code <user_code>`.
    public var prompt: @Sendable (DeviceAuthorizationGrant) -> Void
    /// Seconds to keep polling before throwing `ThalovantTimeoutError`.
    public var timeout: TimeInterval
    /// The registered app signing in, such as `homeAssistantClientId` (sent
    /// as `client_id` when set). See `beginDeviceLogin(scopes:clientName:clientId:)`.
    public var clientId: String?

    public init(
        scopes: [String]? = nil,
        clientName: String? = nil,
        openBrowser: Bool = true,
        prompt: @escaping @Sendable (DeviceAuthorizationGrant) -> Void = { grant in
            print("To sign in, visit \(grant.verificationUri) and enter the code \(grant.userCode)")
        },
        timeout: TimeInterval = 900
    ) {
        self.scopes = scopes
        self.clientName = clientName
        self.openBrowser = openBrowser
        self.prompt = prompt
        self.timeout = timeout
        self.clientId = nil
    }

    /// The same options, signing in as the registered app `clientId`.
    ///
    /// A second initializer rather than a new defaulted parameter on the first,
    /// so a reference to `init(scopes:clientName:openBrowser:prompt:timeout:)`
    /// still compiles.
    public init(
        scopes: [String]? = nil,
        clientName: String? = nil,
        openBrowser: Bool = true,
        prompt: @escaping @Sendable (DeviceAuthorizationGrant) -> Void = { grant in
            print("To sign in, visit \(grant.verificationUri) and enter the code \(grant.userCode)")
        },
        timeout: TimeInterval = 900,
        clientId: String?
    ) {
        self.init(scopes: scopes, clientName: clientName, openBrowser: openBrowser, prompt: prompt, timeout: timeout)
        self.clientId = clientId
    }
}

/// A pending device sign-in as the person approving it sees it: what
/// `describeDeviceLogin(userCode:)` returns.
///
/// `clientVerified` is true only when a registered app asked (it named its
/// `clientId`): `clientName` is then the platform's own name for that app, and
/// `deviceName` whatever the device called itself, which nothing checks.
/// Otherwise `clientName` is the device's own claim.
public struct DeviceLoginRequest: Sendable {
    /// The scopes the device asked for.
    public let scopes: [String]
    public let clientName: String?
    /// When the code expires, as the API wrote it (ISO 8601).
    public let expiresAt: String?
    public let clientId: String?
    public let clientVerified: Bool
    public let deviceName: String?
    /// The raw response.
    public let raw: JSONObject

    /// Reads `GET /v1/auth/device/codes/{user_code}`; absent or empty fields are nil.
    public init(response: JSONObject) {
        func text(_ key: String) -> String? {
            guard let value = response[key]?.stringValue, !value.isEmpty else { return nil }
            return value
        }
        scopes = response["scopes"]?.arrayValue?.compactMap(\.stringValue) ?? []
        clientName = text("client_name")
        expiresAt = text("expires_at")
        clientId = text("client_id")
        // Verified only as the API says it, and only with the app named: a
        // true without an id says nothing about who asked.
        clientVerified = response["client_verified"]?.boolValue == true && clientId != nil
        deviceName = text("device_name")
        raw = response
    }
}

/// The durable scoped API token issued when the device sign-in is approved.
public struct DeviceLoginResult {
    public let accessToken: String
    public let tokenType: String?
    /// Scopes granted to the token (the server may have normalized or
    /// expanded the requested scopes).
    public let scopes: [String]
    public let expiresAt: String?
    public let tokenId: String?
    /// The raw token response.
    public let raw: JSONObject
}

extension ThalovantControlPlane {
    /// Signs in through the browser device flow and stores the API token.
    ///
    /// This is the sign-in path for accounts without a password (for example
    /// Google sign-in). It requests a device authorization
    /// (`POST /v1/auth/device/authorize`), presents `verificationUri` and
    /// `userCode` through `options.prompt`, optionally opens the browser at
    /// `verificationUriComplete`, and polls `POST /v1/auth/device/token`
    /// until the request is approved, denied (`ThalovantDeviceLoginError.denied`),
    /// expired (`ThalovantDeviceLoginError.expired`), or `options.timeout`
    /// seconds elapse (`ThalovantTimeoutError`).
    ///
    /// On approval the returned `accessToken` is a durable scoped API token
    /// and is stored on `accessToken` exactly like `login(email:password:)`,
    /// with its id on `tokenId`. `beginDeviceLogin` and `pollDeviceLogin` are
    /// the same flow one step at a time, for a caller that runs its own loop.
    @discardableResult
    public func loginWithBrowser(options: DeviceLoginOptions = DeviceLoginOptions()) async throws -> DeviceLoginResult {
        let grant = try await beginDeviceLogin(
            scopes: options.scopes, clientName: options.clientName, clientId: options.clientId)
        defer { setDeviceInterval(grant.deviceCode, nil) }

        options.prompt(grant)
        if options.openBrowser, let completeUri = grant.verificationUriComplete, !completeUri.isEmpty {
            openBrowserBestEffort(completeUri)
        }

        let token = try await pollDeviceToken(deviceCode: grant.deviceCode, interval: grant.interval, timeout: options.timeout)
        return try acceptDeviceToken(token)
    }

    /// Starts a device sign-in: a code for a person to approve in a browser.
    ///
    /// `POST /v1/auth/device/authorize` with `scopes` and `clientName`, each
    /// sent only when given; the API defaults the scopes to `hubs:read` and
    /// `clients:write`. An empty scope list is left out exactly as none is:
    /// the API requires at least one scope and answers `[]` with a 422. A Free plan can approve only `homeAssistantScopes`
    /// (`hubs:read`, `clients:read`, `clients:write`). Show the person
    /// `verificationUri` and `userCode` (or `verificationUriComplete`, which
    /// carries the code), then call `pollDeviceLogin(_:)` every `interval`
    /// seconds. A verification URL that is not http(s), has no host, or
    /// carries credentials throws: it is about to be opened in a browser.
    ///
    /// `clientId` signs in as a registered app, such as `homeAssistantClientId`:
    /// the approval screen shows the platform's name for the app as verified
    /// (`clientName` becomes the device's own label beside it), and approving
    /// the app again replaces the token it already holds. Such an app may ask
    /// only for its own scopes, and an id the API does not know is refused
    /// (400 `unknown_client`). `nil` leaves the field out.
    public func beginDeviceLogin(scopes: [String]? = nil, clientName: String? = nil) async throws -> DeviceAuthorizationGrant {
        try await beginDeviceLogin(scopes: scopes, clientName: clientName, clientId: nil)
    }

    /// `beginDeviceLogin(scopes:clientName:)`, signing in as the registered
    /// app `clientId` when it is not nil. A method of its own rather than a
    /// new defaulted parameter, so a reference to the two-argument form still
    /// compiles.
    public func beginDeviceLogin(
        scopes: [String]? = nil, clientName: String? = nil, clientId: String?
    ) async throws -> DeviceAuthorizationGrant {
        var payload: JSONObject = [:]
        if let scopes, !scopes.isEmpty {
            payload["scopes"] = .array(scopes.map { .string($0) })
        }
        if let clientName, !clientName.isEmpty {
            payload["client_name"] = .string(clientName)
        }
        if let clientId {
            // Sent as given, an empty string included: the API refuses one,
            // which is better than signing in unverified in silence.
            payload["client_id"] = .string(clientId)
        }
        let response = try await requestObject("POST", "/v1/auth/device/authorize", body: payload, auth: false)
        let grant = try DeviceAuthorizationGrant(authorizationResponse: response)
        setDeviceInterval(grant.deviceCode, grant.interval)
        return grant
    }

    /// Reads a pending device sign-in by its `userCode`, as its approver sees it.
    ///
    /// `GET /v1/auth/device/codes/{user_code}`, signed in as the person who
    /// would approve it. Says which app asked and whether the platform vouches
    /// for its name (`clientVerified`). A code that is unknown, expired or
    /// already answered is a `ThalovantApiError` with status 404.
    public func describeDeviceLogin(userCode: String) async throws -> DeviceLoginRequest {
        DeviceLoginRequest(
            response: try await requestObject("GET", "/v1/auth/device/codes/\(encodePathComponent(userCode))"))
    }

    /// Asks once whether the device sign-in was approved.
    ///
    /// Returns the token and stores it on this control plane (`accessToken`
    /// and `tokenId`). Otherwise throws `ThalovantApiError` whose `kind` says
    /// why there is none yet: `.deviceLoginPending(interval:)` -- poll again
    /// after `interval` seconds, already five seconds longer for every
    /// `slow_down` the API sent for this code -- `.deviceLoginExpired` or
    /// `.deviceLoginDenied`. Any other failure is a `ThalovantApiError` with
    /// what the API said. Neither the device code nor the token ever appears
    /// in an error's message.
    @discardableResult
    public func pollDeviceLogin(_ grant: DeviceAuthorizationGrant) async throws -> DeviceLoginResult {
        setDeviceInterval(grant.deviceCode, grant.interval, onlyIfUnset: true)
        return try acceptDeviceToken(try await deviceTokenOnce(grant.deviceCode))
    }

    /// `pollDeviceLogin(_:)` for a device code alone, such as one kept from a
    /// sign-in begun in another process. The interval starts from what this
    /// control plane last saw for the code, else `defaultDevicePollInterval`.
    @discardableResult
    public func pollDeviceLogin(deviceCode: String) async throws -> DeviceLoginResult {
        try acceptDeviceToken(try await deviceTokenOnce(deviceCode))
    }

    /// Revokes an API token; by default the one this control plane signed in
    /// with (`tokenId`).
    ///
    /// A token may always revoke itself (`DELETE /v1/auth/api-tokens/{id}`),
    /// whatever its scopes. Revoking the token in use forgets it here too, so
    /// a later call fails locally rather than with a 401.
    ///
    /// Revoking the token in use is idempotent. A token already revoked, or
    /// expired, cannot authenticate its own revoke, so the API answers 401;
    /// the token is dead either way, so that counts as revoked and forgets it,
    /// and revoking again sends nothing and succeeds, until the next sign-in.
    /// Revoking another token by id is not: a 404 for one the API does not
    /// know throws as usual.
    public func revokeApiToken(tokenId: String? = nil) async throws {
        // The credentials this revoke is about, read whole. A sign-in that
        // completes while the DELETE is on its way installs others, which are
        // not forgotten.
        let held = credentialSnapshot()
        guard let target = tokenId.flatMap({ $0.isEmpty ? nil : $0 }) ?? held.tokenId, !target.isEmpty else {
            // Already revoked and forgotten: revoking again changes nothing.
            if held.revokedOwn && held.accessToken == nil { return }
            throw ThalovantApiError(
                message: "No API token id to revoke: pass tokenId, or sign in with a device login first."
            )
        }
        let own = target == held.tokenId
        do {
            _ = try await requestData("DELETE", "/v1/auth/api-tokens/\(encodePathComponent(target))")
        } catch let error as ThalovantApiError where own && error.statusCode == 401 {
            // The token in use could not authenticate its own revoke: it is
            // revoked or expired already.
        }
        if own { forgetRevoked(held) }
    }

    /// One `POST /v1/auth/device/token`: the token, or why there is none yet.
    func deviceTokenOnce(_ deviceCode: String) async throws -> JSONObject {
        let request = try buildRequest(
            "POST",
            "/v1/auth/device/token",
            body: ["device_code": .string(deviceCode)],
            auth: false
        )
        let (data, response) = try await perform(request)
        if (200..<300).contains(response.statusCode) {
            setDeviceInterval(deviceCode, nil)
            guard let token = try? ThalovantJSON.decodeObject(data) else {
                throw ThalovantApiError(message: "Thalovant API returned an unexpected response shape.")
            }
            return token
        }
        let body = String(decoding: data, as: UTF8.self)
        let errorCode = response.statusCode == 400
            ? (try? ThalovantJSON.decodeObject(data))?["error"]?.stringValue
            : nil
        var interval = deviceInterval(deviceCode) ?? defaultDevicePollInterval
        switch errorCode {
        case "slow_down", "authorization_pending":
            if errorCode == "slow_down" {
                // RFC 8628 §3.5: every slow_down adds five seconds, for good.
                interval += 5
                setDeviceInterval(deviceCode, interval)
            }
            throw ThalovantApiError(
                message: "The device sign-in has not been approved yet.",
                statusCode: response.statusCode,
                body: body,
                kind: .deviceLoginPending(interval: interval)
            )
        case "access_denied":
            setDeviceInterval(deviceCode, nil)
            throw ThalovantApiError(
                message: "The device sign-in request was denied in the browser.",
                statusCode: response.statusCode,
                body: body,
                kind: .deviceLoginDenied
            )
        case "expired_token":
            setDeviceInterval(deviceCode, nil)
            throw ThalovantApiError(
                message: "The device sign-in code expired before it was approved. "
                    + "Call beginDeviceLogin() again to request a new code.",
                statusCode: response.statusCode,
                body: body,
                kind: .deviceLoginExpired
            )
        default:
            throw ThalovantApiError.httpFailure(
                statusCode: response.statusCode, body: body, header: { response.value(forHTTPHeaderField: $0) })
        }
    }

    /// Stores an approved token -- `accessToken` and `tokenId` -- and returns it.
    func acceptDeviceToken(_ token: JSONObject) throws -> DeviceLoginResult {
        let accessToken = try keepSignIn(token)
        return DeviceLoginResult(
            accessToken: accessToken,
            tokenType: token["token_type"]?.stringValue,
            scopes: (token["scopes"]?.arrayValue ?? []).compactMap { $0.stringValue },
            expiresAt: token["expires_at"]?.stringValue,
            tokenId: self.tokenId,
            raw: token
        )
    }

    /// Polls `POST /v1/auth/device/token` until approval or a terminal state.
    ///
    /// `sleep` and `clock` are injectable so tests can drive the loop without
    /// real waiting: `clock` returns monotonic seconds, and `sleep` suspends
    /// for the requested seconds. A `slow_down` response grows the wait by 5
    /// seconds, as the device-flow contract requires. A denied or expired code
    /// throws `ThalovantDeviceLoginError`, as `loginWithBrowser` always has.
    func pollDeviceToken(
        deviceCode: String,
        interval: TimeInterval,
        timeout: TimeInterval,
        sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
            if seconds > 0 {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        },
        clock: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) async throws -> JSONObject {
        let deadline = clock() + timeout
        setDeviceInterval(deviceCode, interval)
        while true {
            let wait: TimeInterval
            do {
                return try await deviceTokenOnce(deviceCode)
            } catch let error as ThalovantApiError {
                switch error.kind {
                case .deviceLoginPending(let interval):
                    wait = interval
                case .deviceLoginDenied:
                    throw ThalovantDeviceLoginError.denied
                case .deviceLoginExpired:
                    throw ThalovantDeviceLoginError.expired
                default:
                    throw error
                }
            }
            let remaining = deadline - clock()
            if remaining <= 0 {
                throw ThalovantTimeoutError("Timed out waiting for the device sign-in to be approved.")
            }
            try await sleep(min(wait, remaining))
        }
    }
}

extension DeviceAuthorizationGrant {
    /// A grant from what a caller kept, to poll a sign-in begun elsewhere:
    /// only `deviceCode` and `interval` matter to `pollDeviceLogin(_:)`.
    public init(
        deviceCode: String,
        userCode: String = "",
        verificationUri: String = "",
        verificationUriComplete: String? = nil,
        expiresIn: Int? = nil,
        interval: TimeInterval = defaultDevicePollInterval
    ) {
        self.init(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationUri: verificationUri,
            verificationUriComplete: verificationUriComplete,
            expiresIn: expiresIn,
            interval: interval,
            raw: [:]
        )
    }

    /// Parses `POST /v1/auth/device/authorize`, refusing URLs a browser should
    /// not open.
    init(authorizationResponse response: JSONObject) throws {
        guard
            let deviceCode = response["device_code"]?.stringValue, !deviceCode.isEmpty,
            let userCode = response["user_code"]?.stringValue, !userCode.isEmpty,
            let verificationUri = response["verification_uri"]?.stringValue, !verificationUri.isEmpty
        else {
            throw ThalovantApiError(message: "Thalovant API device authorization response was incomplete.")
        }
        let complete = response["verification_uri_complete"]
        guard deviceVerificationURL(verificationUri) != nil,
            complete == nil || complete == .null || complete?.stringValue.flatMap(deviceVerificationURL) != nil else {
            throw ThalovantApiError(message: "Thalovant API device authorization returned an invalid verification URI.")
        }
        let interval: TimeInterval
        if let raw = response["interval"]?.doubleValue, raw >= 0 {
            interval = raw
        } else {
            interval = defaultDevicePollInterval
        }
        self.init(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationUri: verificationUri,
            verificationUriComplete: response["verification_uri_complete"]?.stringValue,
            expiresIn: response["expires_in"]?.intValue,
            interval: interval,
            raw: response
        )
    }
}

/// Opens `url` in the local browser where the platform allows launching a
/// process; never throws — browser availability is best-effort.
func deviceVerificationURL(_ url: String) -> URL? {
    guard !url.unicodeScalars.contains(where: { CharacterSet.controlCharacters.union(.whitespacesAndNewlines).contains($0) }),
        let target = URL(string: url), ["http", "https"].contains(target.scheme?.lowercased() ?? ""),
        let host = target.host, !host.isEmpty, target.user == nil, target.password == nil else { return nil }
    return target
}

func openBrowserBestEffort(_ url: String, launch: ((URL) -> Void)? = nil) {
    guard let target = deviceVerificationURL(url) else { return }
    if let launch { launch(target); return }
    #if os(macOS)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [target.absoluteString]
    try? process.run()
    #elseif os(Linux)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["xdg-open", target.absoluteString]
    try? process.run()
    #endif
    // iOS, tvOS, watchOS: no process launching; callers surface the URL
    // through the prompt instead.
}

// MARK: - Redacted reflection
//
// The device grant carries the polling `deviceCode` and the result carries the
// durable `accessToken`; both also keep the raw server response (which repeats
// those secrets). Default reflection (`"\(x)"`, `String(describing:)`,
// `dump()`) would print them, so redact every printing/reflection path while
// leaving the stored values and the `raw` payload intact for real use.

extension DeviceAuthorizationGrant: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "DeviceAuthorizationGrant(userCode: \(userCode), "
            + "verificationUri: \(verificationUri), deviceCode: <redacted>)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "userCode": userCode,
                "verificationUri": verificationUri,
                "verificationUriComplete": verificationUriComplete as Any,
                "expiresIn": expiresIn as Any,
                "interval": interval,
                "deviceCode": "<redacted>",
                "raw": "<redacted>",
            ],
            displayStyle: .struct
        )
    }
}

extension DeviceLoginResult: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "DeviceLoginResult(tokenId: \(tokenId ?? "nil"), tokenType: \(tokenType ?? "nil"), "
            + "scopes: \(scopes), expiresAt: \(expiresAt ?? "nil"), accessToken: <redacted>)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "tokenId": tokenId as Any,
                "tokenType": tokenType as Any,
                "scopes": scopes,
                "expiresAt": expiresAt as Any,
                "accessToken": "<redacted>",
                "raw": "<redacted>",
            ],
            displayStyle: .struct
        )
    }
}
