# Thalovant Swift SDK

Swift SDK for connecting iOS, macOS, and Linux apps to Thalovant hubs.

The control API is used to discover hubs and provision a client identity. After
that, the SDK talks directly to the hub data plane over WSS. (HTTPS and MQTTS
data-plane transports are available in the Node and Go SDKs and are not part of
this Swift SDK yet.)

Full docs: <https://docs.thalovant.com/developers/sdks/>

## What You Need

- A Thalovant account with API access for authenticated control-plane actions.
- A hub id or slug.
- A client identity for that hub. You can create one through the API or use one
  downloaded from the dashboard.

## Install

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/thalovant/thalovant-swift-sdk", from: "0.1.2"),
]
```

and depend on the `ThalovantSDK` product. Swift 5.9 or newer is required, on
iOS 15+, macOS 12+, or Linux (Foundation networking).

## Quick Start

```swift
import ThalovantSDK

let api = ThalovantControlPlane()

// Public hub discovery does not require auth.
let publicHubs = try await api.listPublicHubs(limit: 12)
for hub in publicHubs["data"]?.arrayValue ?? [] {
    print(hub["id"]?.stringValue ?? "", hub["slug"]?.stringValue ?? "", hub["title"]?.stringValue ?? "")
}

// Auth is required when creating a client identity.
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

`ThalovantControlPlane()` uses `https://api.thalovant.com` by default. Pass a
different URL only for local development or a self-hosted control plane.

Keep `result.identity` secret. It contains the client credentials used by the
hub. Do not log `result.asJSON(includeSecrets: true)`.

## Log In With MFA

Accounts with multi-factor authentication enabled must include a TOTP code or a
recovery code with the login. Without one the API responds with HTTP 401 and
code `mfa_required` (surfaced as `ThalovantApiError.errorCode`).

```swift
try await api.login(email: "you@example.com", password: "password", otpCode: "123456")

// Or use a one-time recovery code instead:
try await api.login(email: "you@example.com", password: "password", recoveryCode: "abcd-efgh-ijkl")
```

## Sign In With the Browser (Device Flow)

Accounts without a password (for example Google sign-in) authenticate through
the browser device flow. `loginWithBrowser` requests a device authorization,
prints the verification URL and short user code (pass `prompt` to present them
yourself), opens the browser at the pre-filled URL where the platform allows
it (`/usr/bin/open` on macOS, `xdg-open` on Linux, skipped on iOS — always
best-effort), and polls until the request is approved:

```swift
let api = ThalovantControlPlane()
let token = try await api.loginWithBrowser(options: DeviceLoginOptions(
    scopes: ["hubs:read", "clients:write"],
    clientName: "my-macbook"
))
print(token.tokenId ?? "", token.scopes)
```

On approval the issued `accessToken` is a durable scoped API token and is
stored on the control plane exactly like `login`. The server may normalize and
expand the echoed `scopes`. A denied request throws
`ThalovantDeviceLoginError.denied`, an expired code throws
`ThalovantDeviceLoginError.expired`, and giving up after `timeout` seconds
(900 by default) throws `ThalovantTimeoutError`.

## Use a Pre-Made API Token

Construct the control plane with an existing API token (for example one issued
by `loginWithBrowser` or created for CI) to skip interactive sign-in entirely:

```swift
let api = ThalovantControlPlane(accessToken: ProcessInfo.processInfo.environment["THALOVANT_API_TOKEN"])
```

The token is sent as `Authorization: Bearer <token>` on every authenticated
call, and `api.accessToken` can also be assigned later at any time.

## List Your Hubs

Authenticated accounts can list owned or visible hubs:

```swift
let page = try await api.listHubs(limit: 50)
for hub in page["data"]?.arrayValue ?? [] {
    print(hub["id"]?.stringValue ?? "", hub["title"]?.stringValue ?? "")
}
```

## Operations

Mutating endpoints return durable operations you can poll:

```swift
let operation = try await api.getOperation(id: "operation-id")
print(operation.status)  // .requested, .committed, .applied, .ready, .failed, .timedOut
```

## Workspace Analytics

Authenticated accounts can read the same overview used by the dashboard:

```swift
let overview = try await api.analyticsOverview(AnalyticsOverviewOptions(range: "7d", hubId: "hub-id"))
print(overview["totals"] ?? [:])
```

Admins can pass `admin: true` (and optionally `ownerId`) to read the
platform-wide `/v1/admin/analytics/overview` rollup instead.

## Durable Memory

Private Daily Desk and workspace assistants can manage explicit opt-in memory:

```swift
let memory = try await api.createMemoryItem(MemoryCreatePayload(
    content: "Prefer America/Toronto for scheduling.",
    scope: .workspace,
    kind: .preference,
    tags: ["timezone"]
))
print(memory.id)

let items = try await api.listMemoryItems(MemoryListOptions(scope: .workspace, query: "timezone"))
print(items.data.count, items.meta.count)

let summary = try await api.getMemorySummary()
print(summary.total, summary.byScope)

try await api.deleteMemoryItem(memory.id)
```

## Identities

Identities can be built from JSON or loaded from a JSON file (the file must not
be group- or world-readable; run `chmod 600 <path>` first):

```swift
let identity = try ThalovantIdentity.fromFile("/path/to/identity.json")
let client = try ThalovantClient(identity: identity)
```

The identity document uses the same snake_case fields the API returns from
`initial_identify`: `access_key`, `password`, `crypto_key`, `site_id`,
`default_master`, `default_port`, plus optional `data_plane_endpoints`,
`protocols`, and `mqtt` broker credentials.

## Events

Handlers can observe hub bus events directly:

```swift
let subscription = client.on("speak") { event in
    print(event.displayText)
}
// later:
subscription.close()
```

## Protocol Selection

Hubs advertise enabled protocols (`spec.protocols.{wss,http,mqtt}.enabled`,
WSS enabled by default) and concrete `data_plane_endpoints`. The SDK prefers
`wss`, then `https`, then `mqtt`:

```swift
let selected = selectDataPlaneEndpoint(
    endpoints: HubDataPlaneEndpoints.fromHub(hub),
    protocols: HubProtocolSettings.from(hub)
)
```

`ThalovantClient` itself is WSS-only in 0.1.0; constructing it with
`hubProtocol: .https` or `.mqtt` throws `ThalovantUnsupportedProtocolError`.

## Errors

- `ThalovantApiError` — control API failures, with `statusCode`, raw `body`,
  and the decoded `errorCode` where the API provides one.
- `ThalovantDeviceLoginError` — the browser device sign-in was `.denied` or
  the user code `.expired` before approval.
- `ThalovantConnectionError` / `ThalovantTimeoutError` /
  `ThalovantRuntimeError` — data-plane connection, deadline, and hub failures.
- `ThalovantIdentityError` — malformed or insecure identity documents.
- `ThalovantUnsupportedProtocolError` — the protocol is disabled, missing an
  endpoint, or not supported by this SDK.

API-token calls are limited per plan. Both limits surface as
`ThalovantApiError` with HTTP 429 in `statusCode`, a `Retry-After` header, and
a matching `retry_after_seconds` in the body:

- `token_rate_limited` — the plan's per-minute request rate was exceeded (60
  requests per minute on the free plan). Retry once the current minute resets.
- `token_quota_exceeded` — the plan's daily or monthly call quota is exhausted.
  The body names which in `quota` (`daily` or `monthly`) alongside `limit` and
  `used`. Retry after the next UTC day or month starts.

Both apply to token-authenticated control-plane calls. `errorCode` decodes the
code for you, since the API nests it under `detail` in its Problem+JSON body.
The SDK does not retry automatically, and `ThalovantApiError` carries the
status, raw `body`, and `errorCode` — not response headers — so read
`retry_after_seconds` out of the body rather than reaching for the
`Retry-After` header. It is authoritative: honor it before resending. Per-plan
limits are listed in the dashboard and at
<https://docs.thalovant.com/developers/sdks/swift/>.

## Development

```bash
swift build
swift test
```

The test suite is fully offline: HTTP requests are intercepted with a
`URLProtocol` stub and the WSS wire protocol is tested through its pure
encode/decode functions.

## License

MIT — see [LICENSE](LICENSE).
