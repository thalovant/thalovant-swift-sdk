Last Edit: Claude Opus 5.5 - 2026-11-03 - Motive: Note the chat-apps capability this SDK does not implement.

# Audit

Known issues, technical debt and review decisions, each tied to the code that shows it.

## Notes

- **Default key and cache folders follow `NSHomeDirectory()`.** [`Sources/ThalovantSDK/Noise.swift`](Sources/ThalovantSDK/Noise.swift) (`.thalovant`) and [`Sources/ThalovantSDK/Inventory.swift`](Sources/ThalovantSDK/Inventory.swift) (`.cache`) fall back to it when no folder is given. That is the user's home on Linux and unsandboxed macOS, and the app's container on iOS and sandboxed macOS, so two sandboxed apps never share a key by default. An app that must share one identity's key with another program passes the folder explicitly.

## Open

- None recorded.

## Chat apps not covered (2026-11-03)

- **What:** this SDK has no methods for the chat apps routes (`/v1/bridges`), which the Python, Node, Go and Rust SDKs and the MCP server cover. `contracts/sdk-parity.json` records `chat-apps` as not applicable.
- **Status:** a scope decision, not a defect: the API's impact records for chat apps list no obligation here. Revisit if an app built on this SDK needs to manage chat apps.
