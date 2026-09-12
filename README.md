# Thalovant Swift SDK

Swift SDK for connecting iOS, macOS, and Linux apps to Thalovant hubs.

The control API is used to discover hubs and provision a client identity. After
that, the SDK talks directly to the hub data plane over WSS. (HTTPS and MQTTS
data-plane transports are available in the Node and Go SDKs and are not part of
this Swift SDK yet.)

Full docs: <https://docs.thalovant.com/developers/sdks/>

## What You Need

- A Thalovant account with API access for authenticated control-plane actions.
- A hub id or slug.
- A client identity for that hub. You can create one through the API or use one
  downloaded from the dashboard.

## Install

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/thalovant/thalovant-swift-sdk", from: "0.6.0"),
]
```

and depend on the `ThalovantSDK` product. Swift 5.9 or newer is required, on
iOS 15+, macOS 12+, or Linux (Foundation networking). On Linux, WSS also
requires FoundationNetworking/libcurl compiled with WebSocket support.
The stock `swift:5.10` and `swift:6.3.3` images build this SDK but their
FoundationNetworking/libcurl rejects WebSockets. Such builds return a connection error and never
report readiness. CI also verifies real WSS on Swift 6.3.3 with a WebSocket-enabled
libcurl 8.22.0. The reproducible platform build is in
[`tools/interop/build-websocket-curl.sh`](tools/interop/build-websocket-curl.sh);
configure the runtime linker to load that libcurl. The SDK itself retains
Foundation sockets and adds no package dependency.

## Quick Start

```swift
import ThalovantSDK

let api = ThalovantControlPlane()

// Public hub discovery does not require auth.
let publicHubs = try await api.listPublicHubs(limit: 12)
for hub in publicHubs["data"]?.arrayValue ?? [] {
    print(hub["id"]?.stringValue ?? "", hub["slug"]?.stringValue ?? "", hub["title"]?.stringValue ?? "")
}

// Auth is required when creating a client identity.
try await api.login(email: "you@example.com", password: "password")

let result = try await api.createClientIdentity(
    hubId: "hub-id",
    options: CreateClientIdentityOptions(name: "swift-demo-client")
)

let client = try ThalovantClient(identity: result.identity)
do {
    try await client.connect()
    let reply = try await client.ask("Tell me a short clean joke.")
    print(reply.text)
    await client.close()
} catch {
    await client.close()
    throw error
}
```

`ThalovantControlPlane()` uses `https://api.thalovant.com` by default. Pass a
different URL only for local development or a self-hosted control plane.

Keep `result.identity` secret — it carries the client credentials the hub
trusts. `result.asJSON()` redacts the identity, hub, and client credentials, so
only `result.asJSON(includeSecrets: true)` returns the real secrets; never log
or persist that variant.

Default bootstrap and identity JSON displays also remove recognized credential
fields recursively from metadata (`authorization`, `client_secret`,
`private_key`, `api_secret`, `secret_key`, `credentials`, token fields, and
`initial_identify`), ignoring case,
underscores, and hyphens. Reference fields such as `apiKeyRef` remain intact.
This does not sanitize arbitrary text or alter the explicit `includeSecrets`
serialization used for persistence.

Intent descriptions may return partial results after a timeout only when at
least one reply supplied parsed definitions. Empty or refused descriptions
alone do not hide a missing reply, including in a later batch. When every
requested description is answered explicitly, an empty inventory is valid.

## HiveMind v3 and persistent identity

The WSS runtime transport uses HiveMind v3 Noise with `XXpsk2` on first
contact and `KKpsk0` when both peers have pinned static identities. It selects
`25519_AESGCM_SHA256` only when the hub advertises it. A ChaChaPoly-only offer,
legacy preshared-key offer, conflicting hub pin or failed authentication
rejects the connection. The old `crypto_key` is not used by this transport.

The exact Argon2id password derivation uses 64 MiB temporarily. Transport
messages use ordered AES256-GCM binary frames; `connect()` returns after the
Noise exchange and encrypted application HELLO have been sent. Reconnect
creates fresh ephemeral keys and counters while retaining the static identity
and hub pin. Preserve that state across app restarts. Certificate verification
uses Foundation's normal trust evaluation. Concurrent initial requests join the
same connection and wait for authenticated readiness. A joining caller's own
timeout or cancellation does not abort other waiters. The caller that starts
the connection owns its teardown if that initial attempt fails or is cancelled.

By default the SDK stores client keys and hub pins in private 0600 files under
`Application Support/Thalovant/noise-swift` (platform-specific base directory),
with one client scope per access key. Directory mode is 0700. Existing insecure
files and symlinks are rejected. New keys are published atomically under a
separate process lock; existing empty or truncated keys are treated as corruption
and must be restored, never silently regenerated. To choose a directory:

```swift
let store = ThalovantFileNoiseStore(
    directory: applicationSupportURL.appendingPathComponent("hub-identity"),
    identityScope: identity.accessKey
)
let client = try ThalovantClient(identity: identity, noiseStore: store)
try await client.connect(timeout: 15)
```

For Keychain or another protected store, implement `ThalovantNoiseStore` and
pass it through the same initializer. Persist the 32-byte static private key
and bind each 32-byte authenticated hub public key to its `nodeID`. A pin
change requires verifying the new hub identity and explicitly updating your
stored pin; failed connections never automatically erase it.

`HiveWire` and `ThalovantCrypto` retain legacy v2 codecs for compatibility with
existing callers. `HiveMindWSSTransport` always uses v3 and rejects
`send(..., encrypt: false)` and application sends before readiness.

The cryptographic core is first-party C shared with `thalovant-embedded-c`,
compiled directly by SwiftPM on Apple and Linux with no third-party
packages. [Source and fixture provenance](Sources/CThalovantNoise/PROVENANCE.md)
documents the independent reference vectors and coordinated maintenance.

## Log In With MFA

Accounts with multi-factor authentication enabled must include a TOTP code or a
recovery code with the login. Without one the API responds with HTTP 401 and
code `mfa_required` (surfaced as `ThalovantApiError.errorCode`).

```swift
try await api.login(email: "you@example.com", password: "password", otpCode: "123456")

// Or use a one-time recovery code instead:
try await api.login(email: "you@example.com", password: "password", recoveryCode: "abcd-efgh-ijkl")
```

## Sign In With the Browser (Device Flow)

Accounts without a password (for example Google sign-in) authenticate through
the browser device flow. `loginWithBrowser` requests a device authorization,
prints the verification URL and short user code (pass `prompt` to present them
yourself), opens the browser at the pre-filled URL where the platform allows
it (`/usr/bin/open` on macOS, `xdg-open` on Linux, skipped on iOS — always
best-effort), and polls until the request is approved:

```swift
let api = ThalovantControlPlane()
let token = try await api.loginWithBrowser(options: DeviceLoginOptions(
    scopes: ["hubs:read", "clients:write"],
    clientName: "my-macbook"
))
print(token.tokenId ?? "", token.scopes)
```

On approval the issued `accessToken` is a durable scoped API token and is
stored on the control plane exactly like `login`. The server may normalize and
expand the echoed `scopes`. A denied request throws
`ThalovantDeviceLoginError.denied`, an expired code throws
`ThalovantDeviceLoginError.expired`, and giving up after `timeout` seconds
(900 by default) throws `ThalovantTimeoutError`.

## Use a Pre-Made API Token

Construct the control plane with an existing API token (for example one issued
by `loginWithBrowser` or created for CI) to skip interactive sign-in entirely:

```swift
let api = ThalovantControlPlane(accessToken: ProcessInfo.processInfo.environment["THALOVANT_API_TOKEN"])
```

The token is sent as `Authorization: Bearer <token>` on every authenticated
call, and `api.accessToken` can also be assigned later at any time.

## List Your Hubs

Authenticated accounts can list owned or visible hubs:

```swift
let page = try await api.listHubs(limit: 50)
for hub in page["data"]?.arrayValue ?? [] {
    print(hub["id"]?.stringValue ?? "", hub["title"]?.stringValue ?? "")
}
```

## Provision Hubs

Hubs, runtime groups, and skills can be created and managed from code. These
routes need a **paid plan** and a token with the **`hubs:write`** scope
("Create and update your hubs" on the dashboard's API Tokens page). A free-plan
token fails with HTTP 402 (`API access requires a paid plan.`), and a token
without the scope fails with HTTP 403 (`Insufficient scopes`).

```swift
let api = ThalovantControlPlane(accessToken: ProcessInfo.processInfo.environment["THALOVANT_API_TOKEN"])

// 1. Discover what is installable before provisioning anything.
for skill in try await api.listMarketplaceSkills()["data"]?.arrayValue ?? [] {
    print(skill["skill_id"]?.stringValue ?? "", skill["access_tier"]?.stringValue ?? "")
}

// 2. Create a runtime group to run the skills.
let group = try await api.createRuntimeGroup(["name": "kiosks", "description": "Lobby kiosks"])
let groupId = group["id"]?.stringValue ?? ""

// 3. Create a hub attached to it.
let hubPayload: JSONObject = [
    "name": "joke-garden",
    "runtimeGroupId": .string(groupId),
    "spec": .object([
        "version": "1.0.0",
        "protocols": .object(["wss": .object(["enabled": .bool(true)])]),
    ]),
]
let createKey = UUID().uuidString
let hub = try await api.createHub(hubPayload, idempotencyKey: createKey)
let hubId = hub["id"]?.stringValue ?? ""

// 4. Install a skill from the marketplace catalog.
_ = try await api.installRuntimeGroupSkill(groupId, skillId: "skill-weather")

// 5. Release: roll the runtime and the hub onto a release channel.
_ = try await api.releaseRuntimeGroup(groupId, ReleaseOptions(channel: "stable"))
_ = try await api.releaseHub(hubId, ReleaseOptions(channel: "stable"))
```

`createHub` sends an `Idempotency-Key` header. Omitting `idempotencyKey`
generates a new key for each call. For a retryable create, generate and retain
one key before the first attempt, then reuse that key and the same payload if
you retry after a timeout. The SDK does not retry automatically:

```swift
// Retry only when needed, using the original hubPayload and createKey above.
let hub = try await api.createHub(hubPayload, idempotencyKey: createKey)
// If this call times out, retry with the same hubPayload and createKey.
```

Updating and deleting a hub use optimistic locking, so `etag` is a required
argument rather than an option. Pass the `etag` from the hub resource you read;
the SDK sends it as `If-Match`, and the API rejects a stale **or missing** value
with HTTP 412 without changing anything:

```swift
var current = try await api.getHub(hubId)
let etag = current["etag"]?.stringValue ?? ""
current = try await api.updateHub(hubId, ["active": false], etag: etag)
try await api.deleteHub(hubId, etag: current["etag"]?.stringValue ?? etag)
```

Deleting a hub also deletes its clients and ACLs. Runtime groups have no
`If-Match` requirement, but the API refuses to delete the workspace default
group or a group that still has hubs attached (HTTP 409).

Runtime configuration is deep-merged using a revision precondition:

```swift
_ = try await api.updateRuntimeGroupConfig(groupId, config: ["lang": "en-us"])
let config = try await api.getRuntimeGroupConfig(groupId)
print(config["config"] ?? [:])
```

Rating a public hub is the exception to the paid-plan rule: `setHubRating` and
`clearHubRating` need the `hubs:write` scope but **no** paid plan. Only public
hubs can be rated, and owners cannot rate their own hubs (HTTP 400).

Reading what a hub is actually running needs the `hubs:inspect` scope instead,
and is likewise not paid-gated:

```swift
let capabilities = try await api.getHubRuntimeCapabilities(hubId)
print(capabilities["counts"]?["total_intents"]?.intValue ?? 0)
```

## Discover Skills

The marketplace catalog is readable with the **`hubs:read`** scope and, unlike
the provisioning routes above, is **not paid-gated** — a free-plan token can
browse the whole catalog before upgrading, and only the install needs a paid
plan.

```swift
for skill in try await api.listMarketplaceSkills()["data"]?.arrayValue ?? [] {
    print(skill["skill_id"]?.stringValue ?? "", skill["category"]?.stringValue ?? "")
}
```

Each entry carries what an install needs (`skill_id`, `source_type`,
`source_ref`, `config_schema`, `secret_schema`) next to presentation fields
(`title`, `summary`, `tags`, `verified`). Admin tokens can additionally pass
`ownerId` to read another tenant's catalog and `includeInactive: true` to see
retired entries; both are silently ignored for non-admin callers rather than
failing. `forceRefresh: true` re-syncs the global catalog from source first,
which is slower.

Two group-scoped reads need the **`hubs:inspect`** scope and are likewise not
paid-gated. The first resolves the catalog against one runtime group, so each
entry reports whether it is already desired, whether it was observed running,
and whether the tenant plan allows installing it:

```swift
let view = try await api.listRuntimeGroupMarketplace(groupId)
for entry in view["data"]?.arrayValue ?? [] where entry["installable"]?.boolValue == true {
    if entry["active"]?.boolValue != true {
        print("available:", entry["skill_id"]?.stringValue ?? "")
    }
}
```

The second answers what the group is actually running right now, rather than
what could be installed:

```swift
let inventory = try await api.listRuntimeGroupInventory(groupId, refresh: true)
print(inventory["source"]?.stringValue ?? "", inventory["data"]?.arrayValue?.count ?? 0)
```

Both answer from a cached inventory snapshot by default; pass
`refreshInventory: true` or `refresh: true` to force a live read from the
runtime operator. When nothing is reporting yet, `listRuntimeGroupInventory`
returns an empty `data` list with a pending `source`
(`ovos-runtime-operator-pending`) rather than failing —
`getHubRuntimeCapabilities` is the one route here that can answer HTTP 409 in
that case.

## Operations

Mutating endpoints return durable operations you can poll:

```swift
let operation = try await api.getOperation(id: "operation-id")
print(operation.status)  // .requested, .committed, .applied, .ready, .failed, .timedOut
```

## Workspace Analytics

Authenticated accounts can read the same overview used by the dashboard:

```swift
let overview = try await api.analyticsOverview(AnalyticsOverviewOptions(range: "7d", hubId: "hub-id"))
print(overview["totals"] ?? [:])
```

## Durable Memory

Private Daily Desk and workspace assistants can manage explicit opt-in memory:

```swift
let memory = try await api.createMemoryItem(MemoryCreatePayload(
    content: "Prefer America/Toronto for scheduling.",
    scope: .workspace,
    kind: .preference,
    tags: ["timezone"]
))
print(memory.id)

let items = try await api.listMemoryItems(MemoryListOptions(scope: .workspace, query: "timezone"))
print(items.data.count, items.meta.count)

let summary = try await api.getMemorySummary()
print(summary.total, summary.byScope)

try await api.deleteMemoryItem(memory.id)
```

## Identities

Identities can be built from JSON or loaded from a JSON file (the file must not
be group- or world-readable; run `chmod 600 <path>` first):

```swift
let identity = try ThalovantIdentity.fromFile("/path/to/identity.json")
let client = try ThalovantClient(identity: identity)
```

The identity document uses the same snake_case fields the API returns from
`initial_identify`: `access_key`, `password`, `crypto_key`, `site_id`,
`default_master`, `default_port`, plus optional `data_plane_endpoints`,
`protocols`, and `mqtt` broker credentials.

## Runtime helpers

```swift
let conversation = client.conversation(lang: "fr-fr")
let reply = try await conversation.query("bonjour")
try await conversation.sendAction("show-details", title: "Details")
try await conversation.sendCode("001-09", label: "Ticket")
let health = try await client.healthcheck()
print(health.ok)
```

Conversations keep a stable session and merge nested context without changing
caller input. Requests receive fresh request ids. `query()` uses HiveMind
query/cascade frames, accepts only a matching query id, and waits for query
completion. It does not automatically replay requests after disconnects.

`waitForEvent()` accepts session/request filters and a predicate. `listen()`
returns an `AsyncThrowingStream`, with optional `timeout` and `maxEvents`, and
starts its subscription when called. Both remove subscriptions on completion,
timeout or task cancellation and fail promptly after transport loss. Streams
buffer at most 64 events and fail explicitly on overflow.

`connectWithInfo()`, `connectionInfo()`, `healthcheck()` and `doctor()` report
local authenticated transport state, without claiming health of every hub
skill or external dependency. Cancelling a control-plane task cancels its
underlying URLSession request.

## Events

Handlers can observe hub bus events directly:

```swift
let subscription = client.on("speak") { event in
    print(event.displayText)
}
// later:
subscription.close()
```

## What Can I Ask?

A connected client can ask its hub what it can be asked, over its own session,
with no control-plane token:

```swift
let client = try ThalovantClient.fromIdentityFile("/path/to/identity.json")
let inventory = try await client.intents(languages: ["en-us", "fr-fr"])
for skill in inventory.skills {
    for intent in skill.intents {
        print(intent.id, intent.engine, intent.examples(lang: "fr-fr"))
    }
}
await client.close()
```

Each intent carries the sentences a person says to reach it, per language, as
the skill wrote them (`{location}` marks a slot): `phrasesFor("fr-FR")` finds
them whatever the case or separator of the tag, and `examples(lang:limit:)`
picks a couple worth showing, whole sentences before ones with a slot. The
languages asked for are folded the same way — `en-us`, `en-US` and `en_us` are
one language, asked once. The inventory is grouped by skill, sorted, and
`Codable` — `asJSON()` or a `JSONEncoder` produce the same snake_case document
the other SDKs write.

The hub's connection must be allowed to publish `ovos.intent.list`; asking for
the sentences needs `ovos.intent.describe` as well, which the default
`IntentInventoryOptions(describe: true)` does — a listing alone
(`describe: false`, or `listIntents(lang:options:)`) needs only
`ovos.intent.list`. Connections the control plane provisions for SDK clients
are allowed both by default. A hub that refuses throws
`ThalovantPolicyDeniedError` naming the type at once — `deniedType`, `code`,
`reason`, and the `allowed` list — rather than waiting out the deadline; with
the default `IntentInventoryOptions(fallback: true)` a hub allowed for only the
engines' own manifests answers with intent names alone, marked
`source: .engineManifests` and `denied: ["ovos.intent.list"]`, so check
`inventory.hasPhrases` before promising sentences.

The two queries underneath are exposed as well: `listIntents(lang:options:)`
returns the manifest rows (`IntentRegistration`, one per registration, with
`engine` mapping the runtime's `template`/`keyword` methods to `padatious`/
`adapt`), and `describeIntent(skillId:intentName:lang:options:)` returns the
registrations behind one intent (`IntentDefinition`, with its `samples`), empty
for one the hub does not know. A hub that answers the listing itself with
`ok: false` has failed the query rather than reported an empty hub, and
`listIntents` throws `ThalovantRuntimeError` carrying the hub's reason:

```swift
let rows = try await client.listIntents(lang: "en-us")
let definitions = try await client.describeIntent(
    skillId: rows[0].skillId, intentName: rows[0].intentName, lang: "en-us"
)
print(definitions.first?.samples ?? [])
```

Every query is correlated by request id and answered within
`options.timeout` seconds (5 by default); a describe the hub never answers
leaves that one intent without sentences instead of failing the inventory.
Describes go out in batches of at most `defaultDescribeBatchSize` (32), each
batch its own window with its own deadline, so a large hub never has more
replies in flight than a bounded queue can hold; a window the hub does not
answer costs those intents their sentences, not the whole inventory. Language tags are sent as you
spell them — the hub folds the tag it receives, so `fr_FR` finds what `fr-fr`
registered.

A silent detailed listing now takes the same default engine-manifest fallback
as an explicit policy denial. Set `fallback: false` to keep strict listing
timeouts. The `denied` marker records which query triggered fallback and is
not, on its own, proof of a policy denial. Engine-query failures still propagate.

`listFallbacks()` discovers registered fallback handlers. Inventory collection
also makes an optional probe capped at 1.5 seconds across connection, send and
reply wait. `fallbacksKnown` distinguishes known empty from unknown (denied,
silent or explicitly failed discovery). `inventory.mayAnswer(lang)` is true
when an enabled intent has phrases, a fallback handler exists, or fallback
discovery is unknown. It is false only when discovery is known, no fallback
handlers exist, and no enabled intent has phrases for the requested language.

## Ask deadlines and correlation

Each logical Ask or Query operation needs a fresh correlation ID. Defaults
already generate one. If you supply an ID, simultaneous Ask calls on one client
must use distinct request IDs, and simultaneous Query calls must use distinct
query IDs. A duplicate active ID raises a runtime error before dispatch. Ask
and Query have separate namespaces, and separate clients are independent.
The reservation ends when its collector unsubscribes, including on cancellation;
it does not cancel or release an admitted physical write. Never reuse an ID for
a later logical operation while a delayed reply from an earlier operation may
still arrive.

Ask uses one total timeout across connection, authentication, send, and replies.
The first nonempty speech starts a fixed settling window (250ms by default).
The first handled or soft-miss event without speech starts a fixed empty-reply
window (5s by default); subsequent speech switches to settling. Both windows
are clipped to the original deadline, and an empty window does not add settling.
Hard policy denial or query timeout freezes collection immediately: prior speech
is returned as a failed partial reply; otherwise the call raises a runtime error.
Caller cancellation removes owned subscriptions and preserves a different caller's
connection attempt. Ask requires a matching request ID and returns the first
nonblank correlated runtime session ID, falling back to the requested session.
Query replies use the same session selection from accepted query events.
Query also uses one deadline across connection, send, and collection; completion
or hard failure returns independently of a retiring send. Non-cancellation write
failures before a terminal reply or phase expiry remain errors. An admitted write
keeps transport ownership until its actual cleanup finishes and is never replayed.
An admitted Swift write has an independent 20-second physical budget. Cancelling
its caller leaves that write and the shared connection owned; only a real write
failure or physical expiry retires the captured connection. Queued cancellation
skips sealing and leaves the predecessor intact.

## Control-Plane HTTP Security

Device login validates both verification URLs before displaying a prompt,
invoking a browser callback, or polling. Each URL must use HTTP(S), include a
host, and contain no userinfo, raw whitespace, or control characters. Invalid
grants fail with a generic API error; their URLs are not displayed or launched.

Control-plane requests never follow redirects automatically. Credentials and
request bodies require HTTPS, except explicit `localhost`, `127.0.0.1`, and
`[::1]` HTTP development endpoints. Anonymous body-free reads may use HTTP.
URLs containing userinfo are rejected before I/O. Configure the intended API
endpoint directly instead of relying on a redirect.

If you supply a `URLSession`, the SDK creates its own session from that
configuration. It retains redirect decisions and forwards only authentication-
challenge callbacks to the supplied delegate, preserving custom trust handling.
Supplied protocol implementations remain trusted application code.

## Protocol Selection

Hubs advertise enabled protocols (`spec.protocols.{wss,http,mqtt}.enabled`,
WSS enabled by default) and concrete `data_plane_endpoints`. The SDK prefers
`wss`, then `https`, then `mqtt`:

```swift
let selected = selectDataPlaneEndpoint(
    endpoints: HubDataPlaneEndpoints.fromHub(hub),
    protocols: HubProtocolSettings.from(hub)
)
```

`ThalovantClient` itself is WSS-only in 0.1.0; constructing it with
`hubProtocol: .https` or `.mqtt` throws `ThalovantUnsupportedProtocolError`.

## Errors

- `ThalovantApiError` — control API failures, with `statusCode`, raw `body`,
  and the decoded `errorCode` where the API provides one.
- `ThalovantDeviceLoginError` — the browser device sign-in was `.denied` or
  the user code `.expired` before approval.
- `ThalovantConnectionError` / `ThalovantTimeoutError` /
  `ThalovantRuntimeError` — data-plane connection, deadline, and hub failures.
- `ThalovantPolicyDeniedError` — the hub refused a message type this
  connection may not publish (`hive.policy.denied`), with `deniedType`,
  `code`, `reason`, and the `allowed` list; thrown at once by the intent
  inventory queries instead of a timeout.
- `ThalovantIdentityError` — malformed or insecure identity documents.
- `ThalovantUnsupportedProtocolError` — the protocol is disabled, missing an
  endpoint, or not supported by this SDK.

API-token calls are limited per plan. Both limits surface as
`ThalovantApiError` with HTTP 429 in `statusCode`, a `Retry-After` header, and
a matching `retry_after_seconds` in the body:

- `token_rate_limited` — the plan's per-minute request rate was exceeded (60
  requests per minute on the free plan). Retry once the current minute resets.
- `token_quota_exceeded` — the plan's daily or monthly call quota is exhausted.
  The body names which in `quota` (`daily` or `monthly`) alongside `limit` and
  `used`. Retry after the next UTC day or month starts.

Both apply to token-authenticated control-plane calls. `errorCode` decodes the
code for you, since the API nests it under `detail` in its Problem+JSON body.
The SDK does not retry automatically, and `ThalovantApiError` carries the
status, raw `body`, and `errorCode` — not response headers — so read
`retry_after_seconds` out of the body rather than reaching for the
`Retry-After` header. It is authoritative: honor it before resending. Per-plan
limits are listed in the dashboard and at
<https://docs.thalovant.com/developers/sdks/swift/>.

## Development

```bash
swift build
swift test
```

The test suite is fully offline: HTTP requests are intercepted with a
`URLProtocol` stub, the WSS wire protocol is tested through its pure
encode/decode functions, and the client's request/reply paths (the intent
inventory) run against an in-memory hub that reproduces the observed wire
behaviour — replies delivered twice, `hive.policy.denied` refusals, a hub that
does not echo the request id.

## License

MIT — see [LICENSE](LICENSE).


### Shared-runtime skill management

Hub-addressed skill methods select the runtime group attached to the hub UUID.
Every hub sharing that group sees the same skill changes and history. The API
requires a restricted token to cover all served hubs. Reads need `hubs:inspect`
(`hubs:read` implies it); writes need `hubs:write`, an eligible paid plan and ownership.

The history response contains newest-first `event` and `operation` entries,
including nullable actor/version fields. Its limit is 1–200 (50 where omitted).
An accepted mutation is not proof the skill is ready. Optional waiting polls the
operation, with a 120-second default timeout and two-second interval. Polling
never repeats an accepted mutation and starts no new read after its deadline;
an already-running HTTP request retains its normal request timeout.

Methods: `listHubSkills / listHubSkillHistory / installHubSkill / updateHubSkill / removeHubSkill / waitForHubSkillOperation`. Responses preserve API JSON fields. Use
`HubSkillWaitOptions` to opt into waiting. For cancellation-sensitive work, submit
without waiting, retain the complete accepted response (including `operation_id`
and `state`), then pass that response to the wait helper separately. Cancelling waiting does not undo the server operation. After a polling
failure, inspect/resume that operation instead of submitting the write again.

## Request helpers and safe configuration updates

Request hints carry a recognized language, ordered intent pipeline, and caller
location without changing the caller's context. Empty hints are omitted. The
location helper requires a city and omits invalid or zero/zero coordinates.
The hub validates language hints against its configured languages.

Replies expose their reported language, ordered speech/audio events, and a
count of dropped media. Embedded skill clips are limited to 4 MiB each and
16 MiB per reply, checked before retention and decoding. Audio does not extend
the reply settlement window. Decoding accepts hexadecimal bytes with ASCII
whitespace between bytes; it never fetches a skill-supplied URL or file path.
The application owns playback (the `play`/`Play` function in this example).

```swift
let location = buildLocation(city: "Montréal", country: "CA")
let reply = try await client.askWithHints("Quel temps fait-il ?", sttLang: "fr-ca", location: location)
for event in reply.mediaEvents where event.isAudio { play(try event.audioBytes()) }
let examples = intent.examples(lang: "en-us", speakable: true)
try await api.updateRuntimeGroupConfig(groupId, config: delta)
// Explicit full replacement:
try await api.replaceRuntimeGroupConfig(groupId, config: fullConfig)
```

Guarded merging requires the `hubs:read` and `hubs:write` scopes and a paid plan.
Safe merging requires an API whose configuration GET returns a valid `revision`
and whose configuration PUT checks `expected_revision`. The SDK rereads and
reapplies the original delta only after HTTP 412, with at most three attempts.
Arrays and scalar values replace; objects merge recursively. Personas replace
only when explicitly supplied. Connection failures, redirects, other statuses,
and ambiguous write results are never retried. No unsafe PATCH fallback is used.
Unconditional replacements must still be coordinated with other writers.

Use the explicit replacement operation shown above when a complete replacement
is intended, including when working with an older API. Existing code relying on
replacement must opt into it when upgrading. Raw intent patterns remain the
default; speakable examples remove optional parts, choose alternatives, and
substitute caller-supplied slots while retaining complete-phrase priority.

The audio limits use encoded-length upper bounds before decoding, so formatting
whitespace consumes budget too. Like Python's `bytes.fromhex`, ASCII whitespace
alone decodes to zero bytes. Bounded malformed clips remain available as event
metadata and fail when decoded; they are never fetched or played automatically.
Distinct audio events may intentionally repeat identical sound content. Only
repeated delivery of the same event object is suppressed where object identity
is available, without counting it as a dropped clip. Rendered example ranking
uses the original pattern's slot presence even when sample values are supplied.

Guarded merges in 0.5.1 preserve native `Int` values, but reject non-finite
`Double` values and floating-point magnitudes above 9,007,199,254,740,991 in
configuration/personas or stored snapshots. This prevents silent rounding of
JSON integers outside native `Int` storage. Use string identifiers for larger
integers.

The SDK code and CLDR matching tables are MIT-licensed; bundled
`thalovant-languages` data is Apache-2.0-licensed. Both notices ship with the SDK.

## Locale-aware intent listings

Version 0.6.0 bundles the same language rules as Python 0.6.5 with
`thalovant-languages` 0.1.1. Locale selection follows OVOS language distances,
including regional variants and stable ties. No network request is required.

```swift
let sentences = intent.examplesWithListing(lang: "fr-CA", sentence: true)
let text = asSentence("what time is it", lang: "en-US")
let example = speakableWithLanguage("play {song}", lang: "en-US")
let bare = try ListingRules(data: nil)
```

Sentence rendering implies speakable rendering. Locale slot examples are defaults;
explicit `slots` values override them. Original complete phrases rank before
prefixes and slot patterns. Rendered limits count unique nonempty results.
Existing `examples` signatures remain available and raw patterns remain the default.

`ListingRules(data:)` accepts a complete custom JSON snapshot. Invalid regexes
fail construction; question evaluation has a bounded execution window. `asks`
throws on exhaustion and sentence rendering returns a bare line. Unknown locales
and explicit nil data do not invent punctuation. Bundled data is packaged as a
SwiftPM resource; source references and both licenses ship with it.
