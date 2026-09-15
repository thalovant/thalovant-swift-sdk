import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The authorization-code grant with PKCE (RFC 7636), for an app that can open
/// a browser.
///
/// `loginWithBrowser()` is the device grant, and it exists for something that
/// *cannot* open one: somebody reads a code off one screen and types it into
/// another. An app on a phone is not in that position -- it is the screen --
/// and asking its owner to copy a code between two windows on the same device
/// is a worse experience than the one every other app on that phone offers.
///
/// ```swift
/// let begun = try NativeSignIn.begin(clientID: "my-app", redirectURI: "myapp://auth")
/// // open begun.authorizationURL in ASWebAuthenticationSession / SFSafariViewController
/// guard let code = begun.code(from: redirect) else { return }   // state checked
/// try await plane.completeNativeSignIn(
///     code: code, verifier: begun.verifier,
///     clientID: "my-app", redirectURI: "myapp://auth")
/// ```
///
/// `begun.verifier` never leaves the device and never enters the browser. That
/// is what PKCE is for: a code intercepted by another app claiming the same
/// redirect scheme is useless without it.
public enum NativeSignIn {

    /// Where a person approves the request.
    public static let defaultDashboardURL = "https://dash.thalovant.com"

    /// The three a phone needs; also the three a free plan may mint.
    public static let defaultScopes = ["hubs:read", "clients:read", "clients:write"]

    /// A sign-in in progress. Keep it until the browser comes back: it holds
    /// the two secrets that make the round trip safe.
    public struct Begun: Equatable, Sendable {
        /// Open this in a browser.
        public let authorizationURL: String
        /// Proves the redirect answers *this* attempt, not a replayed one.
        public let state: String
        /// Never send this to the browser. Exchanged with the code, once.
        public let verifier: String

        /// The authorization code out of the redirect, or nil when it is not
        /// an answer to this attempt.
        ///
        /// nil rather than a throw on a state mismatch, a missing code, or an
        /// `error=` response -- including one that also carries a code: all of
        /// those mean "do not continue", and an app that
        /// treats them alike cannot accidentally treat one of them as success.
        public func code(from redirect: String) -> String? {
            guard
                let components = URLComponents(string: redirect),
                let items = components.queryItems
            else { return nil }
            var found: [String: String] = [:]
            for item in items where item.value != nil {
                found[item.name] = item.value
            }
            guard found["state"] == state else { return nil }
            // A refusal that also carries a code is still a refusal. Checking
            // only for a missing code accepted that pair and would have
            // started an exchange on a code the server had just declined.
            guard found["error"] == nil else { return nil }
            guard let code = found["code"], !code.isEmpty else { return nil }
            return code
        }
    }

    /// Start a sign-in. Returns the URL to open and the secrets to keep.
    ///
    /// `redirectURI` must be one the API has registered for `clientID`; the
    /// authorization endpoint matches it exactly and refuses anything else, so
    /// it cannot be turned into an open redirect.
    public static func begin(
        clientID: String,
        redirectURI: String,
        scopes: [String] = defaultScopes,
        dashboardURL: String = defaultDashboardURL
    ) throws -> Begun {
        guard !clientID.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ThalovantApiError(message: "clientID is required to start a sign-in.")
        }
        guard !redirectURI.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ThalovantApiError(message: "redirectURI is required to start a sign-in.")
        }
        let verifier = newVerifier()
        let state = randomURLSafe(byteCount: 24)
        var components = URLComponents(string: dashboardURL.hasSuffix("/")
            ? String(dashboardURL.dropLast()) + "/authorize"
            : dashboardURL + "/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: challenge(for: verifier)),
            // S256 only. `plain` is refused by the API, and offering it here
            // would only give a caller a way to ask for the weaker one.
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components?.string else {
            throw ThalovantApiError(message: "Could not build the sign-in address.")
        }
        return Begun(authorizationURL: url, state: state, verifier: verifier)
    }

    /// A PKCE verifier: 64 random bytes, base64url, no padding.
    public static func newVerifier() -> String { randomURLSafe(byteCount: 64) }

    /// The S256 challenge for a verifier.
    public static func challenge(for verifier: String) -> String {
        base64URL(SHA256.hash(Array(verifier.utf8)))
    }

    /// Whether a URL belongs to Thalovant, for an app that wants to show where
    /// it is about to send somebody. Scheme and host only: a display check, not
    /// an authorization one.
    public static func isThalovantURL(_ url: String) -> Bool {
        guard
            let components = URLComponents(string: url),
            components.scheme?.lowercased() == "https",
            // Reject embedded credentials: https://evil.test@dash.thalovant.com/
            // has a host that passes, and a URL somebody is about to be sent to
            // should not read as one host and resolve to another.
            components.user == nil, components.password == nil,
            let host = components.host?.lowercased()
        else { return false }
        return host == "thalovant.com" || host.hasSuffix(".thalovant.com")
    }

    /// Refuse to put an authorization code and its PKCE verifier on the wire
    /// in cleartext.
    ///
    /// The control-plane URL accepts an `http` scheme -- a self-hosted or
    /// local deployment may legitimately be served that way -- and the request
    /// path hands whatever it is given to URLSession without looking. Every
    /// other call that would leak over http leaks a bearer token the caller
    /// already holds; this one leaks the two secrets that are about to become
    /// one, and a code is exchangeable by whoever sees it first.
    ///
    /// Loopback is allowed: a request that never leaves the machine has no
    /// cleartext to observe, and that is how the control plane is run while
    /// somebody is working on it.
    static func requireSecureTokenExchange(_ apiURL: String) throws {
        guard let components = URLComponents(string: apiURL) else {
            throw ThalovantApiError(message: "Thalovant API URL could not be read: \(apiURL)")
        }
        if components.scheme?.lowercased() == "https" { return }
        switch components.host?.lowercased() {
        case "localhost", "127.0.0.1", "::1": return
        default: break
        }
        throw ThalovantApiError(
            message: "Refusing to send an authorization code and PKCE verifier in cleartext to "
                + "\(components.host ?? apiURL). Use https, or a loopback address while developing.")
    }

    static func randomURLSafe(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        return base64URL(bytes)
    }

    static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// SHA-256, in Swift.
///
/// CryptoKit has this and is not on Linux, where this package's own CI builds
/// and tests it. Rather than two code paths that differ on the one thing PKCE
/// depends on being exactly right, there is one -- the same choice this SDK
/// already made for AES-GCM in `Crypto.swift`. `NativeSignInTests` checks it
/// against the published vectors.
enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        var padded = message
        let bitCount = UInt64(message.count) * 8
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8(truncatingIfNeeded: bitCount >> UInt64(shift)))
        }

        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: padded.count, by: 64) {
            for index in 0..<16 {
                let base = chunk + index * 4
                w[index] = UInt32(padded[base]) << 24 | UInt32(padded[base + 1]) << 16
                    | UInt32(padded[base + 2]) << 8 | UInt32(padded[base + 3])
            }
            for index in 16..<64 {
                let s0 = rotr(w[index - 15], 7) ^ rotr(w[index - 15], 18) ^ (w[index - 15] >> 3)
                let s1 = rotr(w[index - 2], 17) ^ rotr(w[index - 2], 19) ^ (w[index - 2] >> 10)
                w[index] = w[index - 16] &+ s0 &+ w[index - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for index in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hh &+ s1 &+ ch &+ k[index] &+ w[index]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ temp1
                d = c; c = b; b = a; a = temp1 &+ temp2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.flatMap { word in
            [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: word >> UInt32($0)) }
        }
    }

    private static func rotr(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}

extension ThalovantControlPlane {
    /// Exchange an authorization code for a scoped access token and store it.
    ///
    /// The other half of `NativeSignIn`. The verifier is sent here and nowhere
    /// else; it never entered the browser, which is what makes an intercepted
    /// code useless to whoever intercepted it.
    ///
    /// A code presented twice revokes the token the first exchange minted
    /// (RFC 9700), so retrying a failed exchange with the same code destroys
    /// the token it is trying to obtain. Start again from `NativeSignIn.begin`.
    @discardableResult
    public func completeNativeSignIn(
        code: String,
        verifier: String,
        clientID: String,
        redirectURI: String
    ) async throws -> JSONObject {
        try NativeSignIn.requireSecureTokenExchange(apiURL)
        let payload: JSONObject = [
            "code": .string(code),
            "code_verifier": .string(verifier),
            "client_id": .string(clientID),
            "redirect_uri": .string(redirectURI),
        ]
        let response = try await requestObject("POST", "/v1/auth/native/token", body: payload, auth: false)
        guard let token = response["access_token"]?.stringValue, !token.isEmpty else {
            throw ThalovantApiError(message: "Thalovant API token response did not include access_token.")
        }
        accessToken = token
        return response
    }
}
