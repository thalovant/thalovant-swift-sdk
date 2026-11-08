Last Edit: Claude Opus 5.5 - 2026-11-08 - Motive: Record browser sign-in (0.12.0), its platforms and the parity digests.

# Quick facts: thalovant-swift-sdk

| Fact | Value |
| :--- | :--- |
| Package | ThalovantSDK (Swift Package Manager) |
| Version | 0.12.0 (VERSION) |
| Public surface | ThalovantClient, ThalovantControlPlane (Sources/ThalovantSDK) |
| Parity | consumer of the Python reference; acknowledges `57c7e71f6456` (current) and `49744ee385bf` (candidate, browser-login) in `contracts/sdk-parity.json` |
| Chat apps (`/v1/bridges`) | not covered (`chat-apps` not applicable); see the Python, Node, Go or Rust SDK or the MCP server |
| Release | merge to `main` with release-relevant changes -> `auto-release.yml` |
| Sign-in | `interactiveLogin()` (browser when the machine has one, else device login), `browserLogin()` (PKCE on `http://127.0.0.1:<port>/callback`), `loginWithBrowser()` (device login, unchanged), `NativeSignIn` (apps) |
| Browser sign-in files | `Sources/ThalovantSDK/BrowserLogin.swift` (API, URL, config, chooser), `Sources/ThalovantSDK/Loopback.swift` (POSIX listener, callback rules) |
| Browser sign-in platforms | macOS and Linux; unavailable on iOS, tvOS, watchOS, visionOS (device login, or `NativeSignIn` + `ASWebAuthenticationSession`) |
| SDK client id | `thalovant-sdk` (`BrowserLogin.sdkClientId`); device name `thalovant-swift-sdk on <hostname>` |
| Shared vectors | `Tests/ThalovantSDKTests/Fixtures/*.json`, `browser-login-vectors.json` included (98 cases); results in `contracts/conformance-results.json` |
