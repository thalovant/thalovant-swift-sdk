Last Edit: Claude Opus 5.5 - 2026-11-08 - Motive: Browser sign-in answers for the final contract (prompt, sandbox entitlement, empty device name, wording).

# FAQ: thalovant-swift-sdk

**Can I manage chat apps (Telegram, Discord, Matrix, Mattermost, Twitch bridges) with this SDK?**
No. Chat apps are managed from the console, the Python, Node, Go and Rust SDKs, or the MCP server. `contracts/sdk-parity.json` records the `chat-apps` capability as not applicable here.

**Why does this repository change when the Python SDK adds a feature?**
The Python SDK is the parity reference. Each consumer records the reference digest it has reviewed, and answers every capability, in `contracts/sdk-parity.json`; the reference cannot release until every consumer has.

**How does a command-line tool or a Mac app sign in?**
`try await api.interactiveLogin()`. On a machine that can show a browser (macOS, or Linux with `DISPLAY` or `WAYLAND_DISPLAY`, and never with `CI`, `SSH_CONNECTION` or `SSH_TTY` set) it calls `browserLogin()`: PKCE on a loopback redirect to `http://127.0.0.1:<port>/callback`. Otherwise it uses a device login. `InteractiveLoginOptions(method: .browser)` or `.device` forces one. See `Sources/ThalovantSDK/BrowserLogin.swift`.

**Why browser sign-in instead of the device code?**
A device code can be passed on: somebody reads it off one screen and types it in anywhere (device-code phishing). With a loopback redirect, the browser that approves hands the code to its own computer's `127.0.0.1`, so a link or code sent to someone on another computer delivers nothing to the sender. A forwarded callback port (`ssh -L`) or another user of the same computer can still complete one.

**Does browser sign-in work on iOS?**
No. `browserLogin()` is unavailable on iOS, tvOS, watchOS and visionOS, and `interactiveLogin()` uses a device login there. An app signs in with `NativeSignIn` and `ASWebAuthenticationSession`, as `thalovant-ios` does.

**The browser did not open. What now?**
The URL is always shown as well. Without a `prompt` it is printed (`Opening your browser to sign in to Thalovant. If it does not open, visit:` and the URL on the next line). Open it in any browser on the same machine. `BrowserLoginOptions(prompt:)` receives the URL instead of the print, so a tool that passes one must show it; `opener:` opens it your own way.

**My sandboxed Mac app's browser sign-in fails before the browser opens.**
Listening on `127.0.0.1` needs the `com.apple.security.network.server` entitlement in a sandboxed macOS app. Without it the listener cannot start, so `browserLogin()` throws, and so does `interactiveLogin(.auto)` whenever it picks browser sign-in (the API offers it, so its configuration is usable). When it picks a device login instead (a 404 or an unusable configuration), no listener is started and the entitlement is not needed. The shared contract keeps a listener that cannot start an error rather than a silent device login. Add the entitlement, or use `InteractiveLoginOptions(method: .device)`, or `NativeSignIn` with `ASWebAuthenticationSession`.

**How do I keep my hostname off the consent page?**
Pass an empty `deviceName` (`""`). Nil gets the default, `thalovant-swift-sdk on <hostname>`; an empty name sends none, to a browser sign-in or, through `interactiveLogin`, to a device login.

**What does a browser sign-in throw?**
Denied: `ThalovantDeviceLoginError.denied`. No answer within the timeout (300 s by default): `ThalovantDeviceLoginError.expired`. These are the device login's own types, and their messages still say "device sign-in". A refused exchange: `ThalovantApiError` with status 400 and detail `invalid_grant`. An API without browser sign-in: `ThalovantApiError` with status 404, which `interactiveLogin(.auto)` turns into a device login before anything is opened.

**Is a tab from another sign-in a problem?**
No. A callback with a missing or wrong `state` gets a 400 and the wait goes on. Only the first callback with this sign-in's state is accepted. After that the port stops listening.
