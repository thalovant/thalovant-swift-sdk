Last Edit: Claude Opus 5.5 - 2026-11-03 - Motive: CodeRabbit follow-up of merged PR #42 (changelog wording).

# Maintenance Report

## 2026-11-03 — CodeRabbit follow-up (#42)

One review thread was still open on merged #42: the 0.10.4 changelog entry said `NSHomeDirectory()` "is the same user folder on macOS and Linux". In a sandboxed macOS app it is the app's container, as on iOS. The entry now says so: the user's home folder on Linux and unsandboxed macOS, the app's container on iOS and sandboxed macOS. Code is unchanged: `Sources/ThalovantSDK/Noise.swift` and `Sources/ThalovantSDK/Inventory.swift` still fall back to `NSHomeDirectory()`, and `FileManager.homeDirectoryForCurrentUser`, which they used before, also answers the container in a sandboxed macOS app, so no default folder moved.

### Verification

- Wording-only change to `CHANGELOG.md`; no source or test file changed, so no new test applies. CI runs the full suite on the pull request.

## Transparency Report

- **AI Model**: Claude Opus 5.5.
- **Actions Taken**: Checked the thread against `main` (81acc01), rewrote one sentence of the 0.10.4 changelog entry, wrote this report and `AUDIT.md`, and replied on the thread.
- **Oversight**: Run by an agent on the repository owner's request to handle every open CodeRabbit thread; merged through the normal CI gates. No release: `CHANGELOG.md` is not a release-relevant path for `auto-release.yml`.
