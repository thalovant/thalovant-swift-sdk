# Repository instructions

This repository owns the published Swift client and agent SDK for supported
Thalovant public API and HiveMind runtime contracts. Read the platform
contracts in `../infra-manifests/docs/thalovant-platform/` when available.

Rules:

- Preserve compatibility with the documented Swift (5.9+), Apple platform
  (iOS 15+/macOS 12+), Linux, and Thalovant API support windows.
- Keep zero third-party dependencies: Foundation URLSession for HTTP,
  URLSessionWebSocketTask for WSS, Codable for JSON, and the in-tree
  AES-128-GCM implementation for the HiveMind wire.
- JSON field names on the wire are snake_case exactly as the API pydantic
  schemas define them; map them with explicit `CodingKeys`.
- Update types, implementation, examples, tests, changelog, version, and
  public documentation together for observable contract changes. The `VERSION`
  file, `defaultThalovantUserAgent` (`ThalovantSwiftSDK/<version>`),
  `CHANGELOG.md`, and the `README.md` install snippet must move together in a
  release (`VersionTests` enforces the user-agent half).
- Consume additive server behavior only after compatible server support exists.
- Never publish credentials, identity files, or generated secrets.
- Do not create a release for internal platform changes with no Swift SDK
  impact; record `no SDK impact` in the coordinated change instead.
- Update affected `docs.thalovant.com` SDK pages in the same release train.

Validate with `swift build` and `swift test` on both macOS and Linux (CI runs
both; the Linux job uses the `swift:5.10` container). The test suite must stay
network-free.

Releases are automated: `auto-release.yml` tags and creates the GitHub release
for an untagged `VERSION` on `main` (auto-bumping a patch version first when
needed), and `release.yml` validates the tag on macOS and Linux, attaches the
attested source archive and CycloneDX SBOM, and verifies SwiftPM tag
resolution. There is no registry publish — consumers resolve the git tag
directly. See `RELEASING.md` for the flow and rollback rules.

Rollback by tagging a corrected patch release; never move or delete an
existing tag that consumers may already resolve.
