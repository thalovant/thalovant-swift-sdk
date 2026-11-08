Last Edit: Claude Opus 5.5 - 2026-11-08 - Motive: Browser sign-in follow-ups after the CodeRabbit round and the final producer.

# Suggestions: thalovant-swift-sdk

## Decide whether this SDK should manage chat apps

- **Problem:** chat apps (`/v1/bridges`) are not covered here; they are recorded as not applicable.
- **Proposal:** if an app or service built on this SDK needs to connect or pause chat apps, record the obligation in the API's impact file first, then port the Python reference's `chat-apps` capability (models, `SecretValue`, the twelve owner routes, `fields` on the API error).
- **Impact:** low today; avoids a silent gap if such an app appears.

## Browser-specific wording for a denied or expired browser sign-in

- **Problem:** `browserLogin` reuses `ThalovantDeviceLoginError.denied` and `.expired`, as the porting brief requires. Their messages are fixed and name the device sign-in: "... Call loginWithBrowser() again to request a new code." That advice is wrong after a browser timeout.
- **Proposal:** at the next major version, give `ThalovantDeviceLoginError` neutral messages ("The sign-in was denied in the browser.", "The sign-in expired before it was approved."). Or add a `message` that the browser path can set, without a new case, which would break an exhaustive `switch`. Coordinate with the reference, whose errors carry per-call messages.
- **Impact:** low; wording only, no behaviour change.

## Update the Swift page on docs.thalovant.com

- **Problem:** the README now documents `browserLogin` and `interactiveLogin`. The docs page at `docs.thalovant.com/developers/sdks/swift/` lives in another repository.
- **Proposal:** add a "Sign in" section there in the same release train as 0.12.0, mirroring the README's.
- **Impact:** medium for discoverability.

## Drop the old reference digest after the Python merge

- **Problem:** `contracts/sdk-parity.json` accepts both `57c7e71f6456` (current) and `6dfb3bb31ac7` (the final candidate) during the rollout.
- **Proposal:** once thalovant-python-sdk `main` carries `6dfb3bb31ac7`, the record can stay as it is: the checker needs the current digest among the acknowledged ones, and this list has always kept every digest acknowledged so far. Prune superseded entries only if the checker or the lead asks.
- **Impact:** low; housekeeping.

## Read the device login's token id from its own answer

- **Problem:** `acceptDeviceToken` (`Sources/ThalovantSDK/DeviceLogin.swift`) returns `tokenId: self.tokenId`, read back after `keepSignIn` stored it. A sign-in finishing on another task in between could hand back the other sign-in's id beside this one's token. Browser sign-in reads the id from its answer (`browserTokenResult`); device login was left unchanged in this port.
- **Proposal:** build the device login's result the same way, with the id from the token answer. It is a device-login change, so it needs its own review.
- **Impact:** low; only concurrent sign-ins on one control plane can see it.

## Fall back to device login when the listener cannot start?

- **Problem:** in a sandboxed macOS app without `com.apple.security.network.server`, `interactiveLogin(.auto)` throws, though a device login would work.
- **Proposal:** the porting brief (`39e31d8`) decided to keep this an error in every SDK, and that is the contract. If it is revisited, it changes for all SDKs at once, with a vector that injects a bind failure. Until then, README and FAQ tell such an app to add the entitlement or pass `method: .device`.
- **Impact:** medium for sandboxed Mac apps; none elsewhere.

## Make `DeviceLoginResult` `Sendable`

- **Problem:** `DeviceLoginResult` is a public struct of `Sendable` members, but it does not conform, so a caller cannot return it from a `Task` without copying it out. The browser tests project it into a record for that reason.
- **Proposal:** declare `extension DeviceLoginResult: Sendable {}` (checked conformance; every stored property is `Sendable`).
- **Impact:** low; additive.
