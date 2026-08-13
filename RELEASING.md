# Releasing the Thalovant Swift SDK

Swift Package Manager has no package registry publish step: consumers resolve
the package directly from git tags on this repository. "Publishing" a release
therefore means creating an immutable `v<version>` tag with a validated,
attested GitHub release. `VERSION` at the repository root is the canonical
version; `defaultThalovantUserAgent` (`ThalovantSwiftSDK/<version>`),
`CHANGELOG.md`, and the `README.md` install snippet must move together with it
(the `VersionTests` suite fails if the user-agent constant drifts from
`VERSION`).

## Prerequisites

None. No registry accounts, signing keys, or repository secrets are required:
both workflows run entirely on the built-in `github.token`, and provenance and
SBOM attestations use GitHub's OIDC identity.

## Publish

1. Update `VERSION`, `defaultThalovantUserAgent` in
   `Sources/ThalovantSDK/ControlPlane.swift` (and the user-agent literals in
   the tests), `CHANGELOG.md`, and the `README.md` install snippet to the same
   version. Run `swift build` and `swift test`.
2. Merge to `main`. The **Auto Release** workflow skips pushes with no
   release-relevant changes since the latest `v*` tag; otherwise it detects
   that `VERSION` has no matching `v<version>` tag, runs the build and tests
   in the `swift:5.10` container, creates the tag and GitHub release, and
   dispatches the **Release** workflow. (If the current version is already
   tagged but release-relevant files changed, it first auto-bumps a patch
   version across `VERSION`, the user-agent constant and test literals, the
   `README.md` install snippet, and `CHANGELOG.md`, and pushes that commit.)
3. The release workflow checks out the tag, verifies the tag equals
   `v<VERSION>`, and builds and tests on both `macos-latest` and
   `ubuntu-latest` (`swift:5.10` container, matching CI). It then produces a
   deterministic `git archive` source tarball and a CycloneDX SBOM (the SDK
   has zero third-party dependencies, so the SBOM is metadata-only), attests
   provenance and SBOM with `actions/attest`, and attaches both artifacts to
   the GitHub release.
4. A final job proves SwiftPM consumability: a scratch package depending on
   the repository URL with `exact: "<version>"` must `swift package resolve`
   the new tag. It first tries the anonymous public URL and falls back to the
   workflow token (the fallback path means the repository is private, so
   external consumers cannot resolve it until the repository is public).

A release validation can also be run manually: **Actions → Release → Run
workflow** with the immutable `release_tag` (for example `v0.1.0`).

## Consuming

```swift
dependencies: [
    .package(url: "https://github.com/thalovant/thalovant-swift-sdk", from: "0.1.0"),
]
```

SwiftPM resolves the `v`-prefixed tags (`v0.1.0`) for version `0.1.0`.

## Rollback

Tags are immutable once consumers may have resolved them: SwiftPM pins
revisions in `Package.resolved`, so a moved or deleted tag breaks or, worse,
silently changes downstream builds.

1. Never move, delete, or re-point an existing `v*` tag.
2. Publish a corrected patch release with aligned `VERSION`, user-agent
   constant, changelog, and README.
3. Update `docs.thalovant.com` and compatibility notes to name the
   replacement version.
