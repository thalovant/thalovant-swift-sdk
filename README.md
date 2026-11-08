<!-- Last Edit: Claude Opus 5.5 - 2026-11-08 - Motive: Document browser sign-in (browserLogin, interactiveLogin) and the 0.12.0 install snippet. -->

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/thalovant/.github/main/profile/assets/thalovant-logo-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/thalovant/.github/main/profile/assets/thalovant-logo-light.png">
    <img src="https://raw.githubusercontent.com/thalovant/.github/main/profile/assets/thalovant-logo-light.png" alt="Thalovant" width="320">
  </picture>
</p>

# Thalovant Swift SDK

[![CI](https://github.com/thalovant/thalovant-swift-sdk/actions/workflows/ci.yml/badge.svg)](https://github.com/thalovant/thalovant-swift-sdk/actions/workflows/ci.yml)
![Licence](https://img.shields.io/github/license/thalovant/thalovant-swift-sdk)
[![Docs](https://img.shields.io/badge/docs-docs.thalovant.com-5c6bc0)](https://docs.thalovant.com/developers/sdks/swift/)

Swift SDK for connecting iOS, macOS, and Linux apps to Thalovant hubs.

The control API is used to discover hubs and provision a client identity. After
that, the SDK talks directly to the hub data plane over WSS. (HTTPS and MQTTS
data-plane transports are available in the Node and Go SDKs and are not part of
this Swift SDK yet.)

Full documentation: <https://docs.thalovant.com/developers/sdks/swift/>

## Requirements

- Swift 5.9 or newer, on iOS 15+, macOS 12+, or Linux (Foundation networking).
- On Linux, WSS also needs FoundationNetworking/libcurl compiled with WebSocket
  support. The stock `swift:5.10` and `swift:6.3.3` images build the SDK but
  their libcurl rejects WebSockets. See
  [`tools/interop/build-websocket-curl.sh`](tools/interop/build-websocket-curl.sh).
- A Thalovant account with API access, a hub id or slug, and a client identity
  for that hub (created through the API or downloaded from the dashboard).

## Install

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/thalovant/thalovant-swift-sdk", from: "0.12.0"),
]
```

and depend on the `ThalovantSDK` product.

## Quick start

```swift
import ThalovantSDK

let api = ThalovantControlPlane()
try await api.login(email: "you@example.com", password: "password")

let result = try await api.createClientIdentity(
    hubId: "hub-id",
    options: CreateClientIdentityOptions(name: "swift-demo-client")
)

let client = try ThalovantClient(identity: result.identity)
do {
    try await client.connect()
    let reply = try await client.ask("Tell me a short clean joke.")
    print(reply.text)
    await client.close()
} catch {
    await client.close()
    throw error
}
```

Keep `result.identity` secret: it carries the client credentials the hub trusts,
and the raw hub and client resources carry bootstrap credentials too.
`result.asJSON()` redacts all of them; only `result.asJSON(includeSecrets:
true)` returns the real secrets, so never log or persist that variant.

## Sign in

A program on a machine with a browser (macOS, or Linux with a display) signs
its user in through that browser. On a machine without one it uses a device
login, whose code can be approved from any browser.

```swift
let api = ThalovantControlPlane()
// The browser when this machine can show one and the API offers it,
// a device login otherwise.
let token = try await api.interactiveLogin()
print(token.scopes)          // api.accessToken and api.tokenId are now set
try await api.revokeApiToken()
```

`browserLogin()` is the browser sign-in on its own: the OAuth authorization code
grant with PKCE (S256) on a loopback redirect (RFC 8252). The SDK listens on
`127.0.0.1` on a port the system picks, opens the dashboard's consent page, and
waits for the browser to come back to `http://127.0.0.1:<port>/callback`. The
browser that approves hands the code to its own computer's `127.0.0.1`, so a
link or code sent to someone on another computer delivers nothing to the
sender. A device code, read off one screen and typed in anywhere, cannot promise
that. A forwarded callback port (`ssh -L`, a port-forwarding tool) or another
user of the same computer can still complete a sign-in.

```swift
let token = try await api.browserLogin(options: BrowserLoginOptions(
    scopes: ["hubs:read", "clients:write"],   // nil: the API's default
    deviceName: "build-bot on studio",        // nil: thalovant-swift-sdk on <hostname>; "": none
    timeout: 300))
```

- The URL is always shown as well as opened (`open` on macOS, `xdg-open` on
  Linux). Without a `prompt` it is printed: `Opening your browser to sign in to
  Thalovant. If it does not open, visit:` and the URL on the next line. A
  `prompt` receives the URL **instead of** the print, so a command-line tool
  that passes one must show the URL itself. `openBrowser: false` only shows it,
  and `opener` opens it your own way.
- Denied in the browser throws `ThalovantDeviceLoginError.denied`; no answer
  within `timeout` seconds throws `ThalovantDeviceLoginError.expired`; a code
  the API will not exchange throws `ThalovantApiError` (`detail` is
  `invalid_grant`). An API without browser sign-in answers
  `GET /v1/auth/native/config` with a 404. Cancelling the task closes the port.
- A sandboxed macOS app needs the `com.apple.security.network.server`
  entitlement (and `network.client`) to listen on `127.0.0.1`. Without it the
  listener cannot start, so `browserLogin()` throws, and so does
  `interactiveLogin()` whenever it picks browser sign-in. A device login it
  picks (a 404 or an unusable configuration) starts no listener. The shared
  contract keeps a listener that cannot start an error rather than a silent
  device login. Such an app passes `method: .device`, or signs in with
  `NativeSignIn` and `ASWebAuthenticationSession`.
- `interactiveLogin(options:)` takes `method: .auto` (the default), `.browser`
  or `.device`. `.auto` uses the browser only when `BrowserLogin.canOpenBrowser()`
  says this machine has one (never with `CI`, `SSH_CONNECTION` or `SSH_TTY` set;
  on Linux only with `DISPLAY` or `WAYLAND_DISPLAY`) and the configuration is
  usable. Once the browser has opened, its outcome stands: a denial or a timeout
  is never turned into a device login.
- Device login is unchanged: `loginWithBrowser()`, or `beginDeviceLogin` and
  `pollDeviceLogin` one step at a time.
- iOS, tvOS, watchOS and visionOS have no loopback listener: `browserLogin()` is
  unavailable there and `interactiveLogin()` uses a device login. An app signs in
  with `NativeSignIn` and `ASWebAuthenticationSession`.

Neither the code, the PKCE verifier, the state nor the token appears in an
error.

## Documentation

| Topic | Where |
| :--- | :--- |
| Install, first request, MFA, browser sign-in, API tokens | [Swift SDK](https://docs.thalovant.com/developers/sdks/swift/) |
| Saved identities, key storage, runtime protocol | [Swift SDK](https://docs.thalovant.com/developers/sdks/swift/) |
| Operations, events, listing what a hub can be asked | [Swift SDK](https://docs.thalovant.com/developers/sdks/swift/) |
| Provisioning, skills, request helpers, sessions, reply claims | [Swift SDK](https://docs.thalovant.com/developers/sdks/swift/) |
| All SDKs and the rest of the developer docs | [docs.thalovant.com](https://docs.thalovant.com) |

## Not yet in the docs

Short notes on features the documentation page does not cover yet. The full
text of each is in the git history of this file.

- Transport security: HiveMind v3 Noise (`XXpsk2`, then `KKpsk0` once both
  peers are pinned). Client keys and hub pins are kept by `ThalovantFileNoiseStore`
  (or your own `ThalovantNoiseStore`) and must survive restarts.
- Home Assistant link: `HubSession.answerHomeRequests` answers
  `thalovant.home.request` with `thalovant.home.response`.
- Workspace analytics: `ThalovantControlPlane.analyticsOverview`.
- Durable memory: `createMemoryItem`, `listMemoryItems`, `getMemorySummary`,
  `deleteMemoryItem`.
- Listing data follows `thalovant-languages` 0.2.1 (270 languages).
- Browser sign-in (`browserLogin`, `interactiveLogin`): see [Sign in](#sign-in).

## Development

```bash
swift build
swift test
```

The test suite is fully offline.

## Security

Report vulnerabilities as described in
[SECURITY.md](https://github.com/thalovant/.github/blob/main/SECURITY.md).

## Licence

MIT. See [LICENSE](LICENSE).
