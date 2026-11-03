Last Edit: Claude Opus 5.5 - 2026-11-03 - Motive: Create the suggestions list.

# Suggestions: thalovant-swift-sdk

## Decide whether this SDK should manage chat apps

- **Problem:** chat apps (`/v1/bridges`) are not covered here; they are recorded as not applicable.
- **Proposal:** if an app or service built on this SDK needs to connect or pause chat apps, record the obligation in the API's impact file first, then port the Python reference's `chat-apps` capability (models, `SecretValue`, the twelve owner routes, `fields` on the API error).
- **Impact:** low today; avoids a silent gap if such an app appears.
