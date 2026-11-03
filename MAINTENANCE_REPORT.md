Last Edit: Claude Opus 5.5 - 2026-11-03 - Motive: Record the chat-apps parity acknowledgment (not applicable).

# Maintenance Report

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
