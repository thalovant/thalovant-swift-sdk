import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Default seconds between `POST /v1/auth/device/token` polls when the
/// authorization response does not specify an `interval`.
public let defaultDevicePollInterval: TimeInterval = 5.0

/// The browser device sign-in ended in a terminal state before a token was
/// issued. Timeouts waiting for approval throw `ThalovantTimeoutError` instead.
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

/// The pending authorization returned by `POST /v1/auth/device/authorize`,
/// handed to the `DeviceLoginOptions.prompt` closure so callers can present
/// the code themselves.
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
    /// set; the server may normalize and expand the echoed scopes).
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
    /// and is stored on `accessToken` exactly like `login(email:password:)`.
    @discardableResult
    public func loginWithBrowser(options: DeviceLoginOptions = DeviceLoginOptions()) async throws -> DeviceLoginResult {
        var payload: JSONObject = [:]
        if let scopes = options.scopes {
            payload["scopes"] = .array(scopes.map { .string($0) })
        }
        if let clientName = options.clientName, !clientName.isEmpty {
            payload["client_name"] = .string(clientName)
        }
        let response = try await requestObject("POST", "/v1/auth/device/authorize", body: payload, auth: false)

        guard
            let deviceCode = response["device_code"]?.stringValue, !deviceCode.isEmpty,
            let userCode = response["user_code"]?.stringValue, !userCode.isEmpty,
            let verificationUri = response["verification_uri"]?.stringValue, !verificationUri.isEmpty
        else {
            throw ThalovantApiError(message: "Thalovant API device authorization response was incomplete.")
        }
        let interval: TimeInterval
        if let raw = response["interval"]?.doubleValue, raw >= 0 {
            interval = raw
        } else {
            interval = defaultDevicePollInterval
        }
        let grant = DeviceAuthorizationGrant(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationUri: verificationUri,
            verificationUriComplete: response["verification_uri_complete"]?.stringValue,
            expiresIn: response["expires_in"]?.intValue,
            interval: interval,
            raw: response
        )

        options.prompt(grant)
        if options.openBrowser, let completeUri = grant.verificationUriComplete, !completeUri.isEmpty {
            openBrowserBestEffort(completeUri)
        }

        let token = try await pollDeviceToken(deviceCode: deviceCode, interval: interval, timeout: options.timeout)
        guard let accessToken = token["access_token"]?.stringValue, !accessToken.isEmpty else {
            throw ThalovantApiError(message: "Thalovant API token response did not include access_token.")
        }
        self.accessToken = accessToken
        return DeviceLoginResult(
            accessToken: accessToken,
            tokenType: token["token_type"]?.stringValue,
            scopes: (token["scopes"]?.arrayValue ?? []).compactMap { $0.stringValue },
            expiresAt: token["expires_at"]?.stringValue,
            tokenId: token["token_id"]?.stringValue,
            raw: token
        )
    }

    /// Polls `POST /v1/auth/device/token` until approval or a terminal state.
    ///
    /// `sleep` and `clock` are injectable so tests can drive the loop without
    /// real waiting: `clock` returns monotonic seconds, and `sleep` suspends
    /// for the requested seconds. A `slow_down` response grows the wait by 5
    /// seconds, as the device-flow contract requires.
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
        var wait = interval
        while true {
            let request = try buildRequest(
                "POST",
                "/v1/auth/device/token",
                body: ["device_code": .string(deviceCode)],
                auth: false
            )
            let (data, response) = try await perform(request)
            if (200..<300).contains(response.statusCode) {
                guard let token = try? ThalovantJSON.decodeObject(data) else {
                    throw ThalovantApiError(message: "Thalovant API returned an unexpected response shape.")
                }
                return token
            }
            let body = String(decoding: data, as: UTF8.self)
            let errorCode = response.statusCode == 400
                ? (try? ThalovantJSON.decodeObject(data))?["error"]?.stringValue
                : nil
            switch errorCode {
            case "authorization_pending":
                break
            case "slow_down":
                wait += 5
            case "access_denied":
                throw ThalovantDeviceLoginError.denied
            case "expired_token":
                throw ThalovantDeviceLoginError.expired
            default:
                throw ThalovantApiError.httpFailure(statusCode: response.statusCode, body: body)
            }
            let remaining = deadline - clock()
            if remaining <= 0 {
                throw ThalovantTimeoutError("Timed out waiting for the device sign-in to be approved.")
            }
            try await sleep(min(wait, remaining))
        }
    }
}

/// Opens `url` in the local browser where the platform allows launching a
/// process; never throws — browser availability is best-effort.
func openBrowserBestEffort(_ url: String) {
    #if os(macOS)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url]
    try? process.run()
    #elseif os(Linux)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["xdg-open", url]
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
