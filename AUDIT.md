Last Edit: Claude Opus 5.5 - 2026-11-08 - Motive: Record the browser sign-in review (0.12.0): decisions, known limits and the test evidence.

# Audit

Known issues, technical debt and review decisions, each tied to the code that shows it.

## Notes

- **Default key and cache folders follow `NSHomeDirectory()`.** [`Sources/ThalovantSDK/Noise.swift`](Sources/ThalovantSDK/Noise.swift) (`.thalovant`) and [`Sources/ThalovantSDK/Inventory.swift`](Sources/ThalovantSDK/Inventory.swift) (`.cache`) fall back to it when no folder is given. That is the user's home on Linux and unsandboxed macOS, and the app's container on iOS and sandboxed macOS, so two sandboxed apps never share a key by default. An app that must share one identity's key with another program passes the folder explicitly.

## Open

- None recorded.

## Chat apps not covered (2026-11-03)

- **What:** this SDK has no methods for the chat apps routes (`/v1/bridges`), which the Python, Node, Go and Rust SDKs and the MCP server cover. `contracts/sdk-parity.json` records `chat-apps` as not applicable.
- **Status:** a scope decision, not a defect: the API's impact records for chat apps list no obligation here. Revisit if an app built on this SDK needs to manage chat apps.

## Browser sign-in (2026-11-08, 0.12.0)

Evidence: `swift test` on Linux (Swift 6.3.2 and the CI's `swift:5.10` image) runs `Tests/ThalovantSDKTests/BrowserLoginVectorTests.swift` (all 98 cases of `browser-login-vectors.json`, every recorded digest equal to the Python reference's) and `Tests/ThalovantSDKTests/BrowserLoginTests.swift` (27 edge tests). macOS and iOS were not built locally; hosted CI builds and tests macOS.

- **The denied and expired messages still say "device sign-in".** `browserLogin` throws the device login's own `ThalovantDeviceLoginError.denied` and `.expired` ([`BrowserLogin.swift` L635-L637](Sources/ThalovantSDK/BrowserLogin.swift#L635-L637)), as the porting brief requires: there are no new error types. Their fixed messages ([`DeviceLogin.swift` L25-L29](Sources/ThalovantSDK/DeviceLogin.swift#L25-L29)) read "The device sign-in request was denied" and "... Call loginWithBrowser() again". Changing them would change device login. A caller should branch on the case, not the text. See `SUGGESTIONS.md`.
- **Accepted connections become close-on-exec one call after `accept`.** Swift's Glibc module does not export `accept4`, so each accepted socket is made close-on-exec with `fcntl` right after `accept` ([`Loopback.swift` L446](Sources/ThalovantSDK/Loopback.swift#L446), [L600](Sources/ThalovantSDK/Loopback.swift#L600)). A child process spawned in that window could inherit one browser connection. On Linux the listening socket itself is created with `SOCK_CLOEXEC` ([L587](Sources/ThalovantSDK/Loopback.swift#L587)), so the port is never inherited. On Apple platforms every socket, the listening one included, gets the same `fcntl` one call after it is created. Not verified on macOS here. Risk: low. The browser is opened once, right after the port is bound and before any tab connects.
- **At most 64 connections at once** ([`Loopback.swift` L228](Sources/ThalovantSDK/Loopback.swift#L228)). Beyond that, a new connection is closed as it arrives, so a page probing local ports cannot exhaust descriptors. The Python reference has no cap. The vectors open one connection at a time, so no case is affected.
- **No exclusive-address option.** The porting brief's `SO_EXCLUSIVEADDRUSE` is Windows-only, and this package does not support Windows. On Linux and macOS, another process cannot bind the same port unless both sockets set `SO_REUSEPORT`, and this one does not.
- **The scripted API is a URLProtocol, not a loopback HTTP server.** `BrowserApi` ([`BrowserLoginVectorTests.swift` L489](Tests/ThalovantSDKTests/BrowserLoginVectorTests.swift#L489)) checks every request (method, path, the four exchange fields, the verifier's S256 against the URL's challenge with a second, C SHA-256, and `Authorization`) through the SDK's real URLSession path, as this SDK runs every other vector file. The browser side is a real TCP client against the bound port ([`RawHTTP`, L647](Tests/ThalovantSDKTests/BrowserLoginVectorTests.swift#L647)).
- **Secrets.** The code, the verifier and the state are replaced by `[redacted]` in a refused exchange's message, body, code, detail and problem, keys included (`withoutSecrets`, [`BrowserLogin.swift` L719](Sources/ThalovantSDK/BrowserLogin.swift#L719)). The listener logs nothing, and `LoopbackCallback`'s description hides the code. Tested by `testAnEchoedCodeAndVerifierNeverReachTheError` and every vector case's `message_excludes` check.
- **Swift-specific behaviour.** The printed notice is flushed (`fflush(stdout)`), so a piped CLI shows the URL at once. A timeout is clamped: negative or NaN is none, and infinity is a century. A `LoopbackListener` that was never started answers `wait` with no callback, where Python raises.
