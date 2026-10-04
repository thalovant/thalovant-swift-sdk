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
    .package(url: "https://github.com/thalovant/thalovant-swift-sdk", from: "0.10.4"),
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
