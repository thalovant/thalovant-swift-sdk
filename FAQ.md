Last Edit: Claude Opus 5.5 - 2026-11-03 - Motive: Create the FAQ.

# FAQ: thalovant-swift-sdk

**Can I manage chat apps (Telegram, Discord, Matrix, Mattermost, Twitch bridges) with this SDK?**
No. Chat apps are managed from the console, the Python, Node, Go and Rust SDKs, or the MCP server. `contracts/sdk-parity.json` records the `chat-apps` capability as not applicable here.

**Why does this repository change when the Python SDK adds a feature?**
The Python SDK is the parity reference. Each consumer records the reference digest it has reviewed, and answers every capability, in `contracts/sdk-parity.json`; the reference cannot release until every consumer has.
