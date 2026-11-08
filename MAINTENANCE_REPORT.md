Last Edit: Claude Opus 5.5 - 2026-11-08 - Motive: Record browser sign-in (0.12.0), its verification and the Transparency Report.

# Maintenance Report

## 2026-11-08 — Browser sign-in (0.12.0)

**What changed:**

- `browserLogin(options:)` and `interactiveLogin(options:)` (`Sources/ThalovantSDK/BrowserLogin.swift`): browser sign-in with PKCE on a `127.0.0.1` loopback redirect, and the auto/browser/device chooser, ported from thalovant-python-sdk #113 (`e3999cb`, Python 0.11.0).
- `Sources/ThalovantSDK/Loopback.swift`: the listener (POSIX sockets and `poll(2)`) and the callback rules.
- An internal `deviceLogin(options:launch:)` in `Sources/ThalovantSDK/DeviceLogin.swift`, which `loginWithBrowser` now delegates to, so the chooser's device fallback can take the injected opener. Device login's behaviour is unchanged.
- `browser-login-vectors.json` vendored byte for byte, with `Tests/ThalovantSDKTests/BrowserLoginVectorTests.swift` (all 98 cases) and `Tests/ThalovantSDKTests/BrowserLoginTests.swift` (27 edges).
- `contracts/sdk-parity.json`: the candidate digest `49744ee385bf` beside the current `57c7e71f6456`; `browser-login` bound to its implementation and test hashes; `device-login`'s `DeviceLogin.swift` hash moved after its vectors were re-run.
- `contracts/conformance-results.json`: recorded by the full suite.
- Version 0.12.0 (`VERSION`, `defaultThalovantUserAgent`, the README install snippet, `CHANGELOG.md`).
- Updated `README.md` (Sign in), `AGENTS.md` (sign-in rule), `QUICK_FACTS.md`, `FAQ.md`, `AUDIT.md` and `SUGGESTIONS.md`.

**Why:** a device code can be relayed to somebody else (device-code phishing). A loopback redirect cannot, because the browser that approves hands the code to its own computer. The cross-SDK contract (`browser-login`, Python reference) makes it required here.

**Verification:**

- `swift build` (Linux, Swift 6.3.2): build complete.
- `THALOVANT_CONFORMANCE_OUT=contracts/conformance-results.json swift test` (Linux, Swift 6.3.2): **469 tests, 0 failures** (846 s). That is 428 on `main` before the change, plus 41 new: 14 vector tests and 27 edge tests.
- The recorded `browser-login-vectors.json` results match the Python reference's: 98/98 case digests, and the same file digest (`b17cb43466c0`). Every other vector file's recorded results are unchanged.
- `swift build` and `swift test --skip-build --filter "BrowserLogin|DeviceLogin|NativeSignIn|VersionTests"` in the CI's `swift:5.10` image (5.10.1): build complete, **78 tests, 0 failures**.
- `python3 tools/check-source-hashes.py` and `python3 -m unittest discover -s tools/tests` (13 tests): pass.
- `check-sdk-parity.py --workspace <checkouts> --consumer thalovant-swift-sdk` passes against the Python PR head `e3999cb`, which carries the candidate digest `49744ee385bf`, and against Python `main` `44b6e2b`, where `browser-login` is reported as not known yet, the expected rollout state.
- The vendored vectors' sha256 is `9058adf2ad30fd8b7f255882ce718865170d0d4b84d36f8fbfa23bde51d1651e`, identical to the reference's file.
- **Not run:** no macOS or iOS build was done locally. Hosted CI builds and tests macOS, and nothing here builds iOS. The `@available(iOS/tvOS/watchOS/visionOS, unavailable)` path and the `#else` branches are compiled only there.

### Transparency Report

- **AI Model:** Claude Opus 5.5 (claude-opus-5-5), as a Claude Code agent working for the lead's cross-SDK rollout.
- **Actions Taken:**
  - Read the contract, the Python reference and its porting brief.
  - Wrote the Swift implementation, the listener, both test files and the scripted API and raw-socket browser harness.
  - Vendored the vectors.
  - Ran the suites on Linux (Swift 6.3.2, and the CI's `swift:5.10` image) and recorded the conformance results.
  - Bound the parity record and wrote the docs and these records.
- **Oversight:** no human review yet. Hosted CI (macOS and Linux), the SDK parity workflow and the PR review gate the merge, and only the lead merges. macOS and iOS were not built locally.

## 2026-11-03 — Chat apps parity acknowledgment

**What changed:** `contracts/sdk-parity.json` records the Python reference digest `1e56099da5db` (thalovant-python-sdk#108) and answers its new `chat-apps` capability as not applicable, with the reason the reference gives:

> The iOS SDK is the app's data plane to its hubs. The API's impact records for chat apps record no Swift obligation: an owner connects and manages chat apps from the console, the Python, Node, Go and Rust SDKs or the MCP server, never from the phone app.

No source, test or version file changes, so `auto-release.yml` publishes nothing.

**Why:** the reference's release gate refuses to publish while any consumer has not answered a capability. Chat apps (the `/v1/bridges` owner routes) ship in the Python, Node, Go and Rust SDKs and the MCP server.

**Verification:** `check-sdk-parity.py --workspace <checkouts> --consumer thalovant-swift-sdk` verifies this acceptance against the reference branch, and against `main` (where the new digest is only a candidate). The language suite runs in hosted CI on this PR.

### Transparency Report

- **AI Model:** Claude Opus 5.5 (claude-opus-5-5), as a Claude Code agent.
- **Actions Taken:** added the digest and the `chat-apps` entry; wrote this entry and the quick facts, FAQ and suggestions files.
- **Oversight:** hosted CI and the CodeRabbit review gate the merge; the platform owner's coordinating agent merges.

## 2026-11-03 — CodeRabbit follow-up (#42)

One review thread was still open on merged #42: the 0.10.4 changelog entry said `NSHomeDirectory()` "is the same user folder on macOS and Linux". In a sandboxed macOS app it is the app's container, as on iOS. The entry now says so: the user's home folder on Linux and unsandboxed macOS, the app's container on iOS and sandboxed macOS. Code is unchanged: `Sources/ThalovantSDK/Noise.swift` and `Sources/ThalovantSDK/Inventory.swift` still fall back to `NSHomeDirectory()`, and `FileManager.homeDirectoryForCurrentUser`, which they used before, also answers the container in a sandboxed macOS app, so no default folder moved.

### Verification

- Wording-only change to `CHANGELOG.md`; no source or test file changed, so no new test applies. CI runs the full suite on the pull request.

## Transparency Report

- **AI Model**: Claude Opus 5.5.
- **Actions Taken**: Checked the thread against `main` (81acc01), rewrote one sentence of the 0.10.4 changelog entry, wrote this report and `AUDIT.md`, and replied on the thread.
- **Oversight**: Run by an agent on the repository owner's request to handle every open CodeRabbit thread; merged through the normal CI gates. No release: `CHANGELOG.md` is not a release-relevant path for `auto-release.yml`.
