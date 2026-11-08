Last Edit: Claude Opus 5.5 - 2026-11-08 - Motive: Answer the browser sign-in questions (0.12.0).

# FAQ: thalovant-swift-sdk

**Can I manage chat apps (Telegram, Discord, Matrix, Mattermost, Twitch bridges) with this SDK?**
No. Chat apps are managed from the console, the Python, Node, Go and Rust SDKs, or the MCP server. `contracts/sdk-parity.json` records the `chat-apps` capability as not applicable here.

**Why does this repository change when the Python SDK adds a feature?**
The Python SDK is the parity reference. Each consumer records the reference digest it has reviewed, and answers every capability, in `contracts/sdk-parity.json`; the reference cannot release until every consumer has.

**How does a command-line tool or a Mac app sign in?**
`try await api.interactiveLogin()`. On a machine that can show a browser (macOS, or Linux with `DISPLAY` or `WAYLAND_DISPLAY`, and never with `CI`, `SSH_CONNECTION` or `SSH_TTY` set) it calls `browserLogin()`: PKCE on a loopback redirect to `http://127.0.0.1:<port>/callback`. Otherwise it uses a device login. `InteractiveLoginOptions(method: .browser)` or `.device` forces one. See `Sources/ThalovantSDK/BrowserLogin.swift`.

**Why browser sign-in instead of the device code?**
A device code can be relayed: somebody reads it off one screen and types it in anywhere (device-code phishing). With a loopback redirect, the browser that approves hands the code to its own computer, so a link sent to somebody else delivers nothing.

**Does browser sign-in work on iOS?**
No. `browserLogin()` is unavailable on iOS, tvOS, watchOS and visionOS, and `interactiveLogin()` uses a device login there. An app signs in with `NativeSignIn` and `ASWebAuthenticationSession`, as `thalovant-ios` does.

**The browser did not open. What now?**
The URL is always printed as well (`Opening your browser to sign in to Thalovant. If it does not open, visit:` and the URL on the next line). Open it in any browser on the same machine. Pass `BrowserLoginOptions(prompt:)` to show it yourself, or `opener:` to open it your own way.

**What does a browser sign-in throw?**
Denied: `ThalovantDeviceLoginError.denied`. No answer within the timeout (300 s by default): `ThalovantDeviceLoginError.expired`. These are the device login's own types, and their messages still say "device sign-in". A refused exchange: `ThalovantApiError` with status 400 and detail `invalid_grant`. An API without browser sign-in: `ThalovantApiError` with status 404, which `interactiveLogin(.auto)` turns into a device login before anything is opened.

**Is a tab from another sign-in a problem?**
No. A callback with a missing or wrong `state` gets a 400 and the wait goes on. Only the first callback with this sign-in's state is accepted. After that the port stops listening.
