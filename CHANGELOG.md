# Changelog

## 0.3.1

- Apply one Ask timeout across connection admission, authentication, sending and
  reply collection. Clip fixed empty-reply and settling windows to that deadline.
- Freeze Ask collection on policy denial or query timeout, retaining only speech
  received before the hard failure, and interrupt optional waits immediately.
- Apply Query deadlines and terminal replies independently of a retiring send,
  preserving physical transport ownership without replay.
- Propagate non-cancellation write failures during Ask reply phases before
  terminal completion or phase expiry.
- Return the first correlated runtime session ID from Ask and Query while preserving strict request
  correlation and the original request ID.
- Add regressions for blocked connection/send, clipped reply phases, cancellation
  cleanup and explicit event-stream buffer overflow.

## 0.3.0

- Validate both device authorization URLs before displaying a prompt, invoking
  a browser callback, or polling. Accept only HTTP(S) URLs with a host and no
  userinfo, raw whitespace, or control characters; launch with a single URL argument.

- Reject control-plane redirects and credential-bearing HTTP outside explicit
  loopback development endpoints, including caller-supplied session configurations.
  Preserve supplied trust callbacks while retaining SDK redirect ownership.

- Add scoped conversations, direct HiveMind query/cascade replies, bounded event
  streams and waits, action/code input helpers, and local connection/health diagnostics.
- Fall back to engine intent names when the detailed listing is silent as well
  as denied. Discover fallback handlers with a bounded optional probe and expose
  known/unknown discovery plus conservative language answerability.
- Keep query collection open after soft intent misses, recover on later speech,
  and retain partial speech when a policy denial or query timeout terminates it.
- Ignore foreign correlated denials and describe replies; retain content-based
  describe matching only when a reply carries no request id.
- Bound connection timeout across socket open and handshake, and let send
  cancellation skip queued writes without affecting successors. A cancelled write
  that already began sealing retires its session and retains cancellation semantics.
- Propagate task cancellation to URLSession HTTP requests, exclude non-JSON
  response bodies from ordinary errors, and reject unsafe JSON numeric-to-Int conversions.
- Extend network-free inventory, runtime lifecycle, cancellation and security
  regressions while retaining macOS/Linux CI and independent Node Noise interop.

## 0.2.1

- Join concurrent WSS connection attempts instead of rejecting overlapping
  initial requests. Settle all admission waiters and isolate a joining caller's
  cancellation/deadline from the shared handshake.
- Consume the first-party C 0.4.1 pattern-specific handshake bounds fix and
  legacy key-entropy contract; expose AES declarations through the C module.
- Verify all shared C source/header and Swift module-header hashes before CI
  and release artifacts, and retain peer failure logs and startup exit status.
- Add network-free gate cancellation/timeout tests, an imported AES-GCM known
  answer, and XX/KK connection plus encrypted-send interop that verifies all
  three callers joined each pending handshake before releasing peer readiness.

## 0.2.0

- Connect to HiveMind v3 using Noise XXpsk2 or pinned KKpsk0 and the mutually
  advertised `25519_AESGCM_SHA256` suite. Implement exact Argon2id derivation,
  canonical negotiation binding, X25519, ordered AES256-GCM frames and chunks
  using first-party C code shared with the embedded SDK; no external package
  dependency. WSS remains the supported runtime transport.
- Persist static identity and authenticated hub pins in protected files by
  default. Expose `ThalovantNoiseStore` for application Keychain/secure storage.
  Create keys atomically under a separate process lock and reject existing empty
  or truncated state. Conflicting pins and failed authentication are terminal;
  no legacy downgrade.
- Send encrypted HELLO before readiness, serialize nonce assignment with socket
  writes, clear state on disconnect/failure, and isolate old socket callbacks
  during reconnect. Plaintext sends and sends before readiness fail closed.
- Add independent Node XX/KK transcripts, PSK vectors, wire negotiation and
  reconnect, framing/tamper/replay, and persistent-store security tests. Verify
  real Node peer exchanges on macOS and Linux with WebSocket-enabled libcurl.

## 0.1.9

- `listIntents(lang:options:)` throws `ThalovantRuntimeError` when the hub
  answers `ovos.intent.list` with `ok: false`, instead of reading the
  missing `intents` key as an empty list. A refused listing is not an empty
  hub, and reporting it as no intents showed a person a device that can do
  nothing; the engine-manifest fallback stays out of it, since a failed
  query is not a policy refusal.
  `describeIntent(skillId:intentName:lang:options:)` keeps returning an
  empty list for `ok: false`, which is a real answer: the hub does not know
  that registration. Reported by the Kotlin port's review, fixed in the
  reference as thalovant-python-sdk 0.4.40.
- `ThalovantPolicyDeniedError.allowed` keeps only string entries — already
  the case here, now pinned by a test alongside the other ports.
- README: listing an inventory needs `ovos.intent.list` alone;
  `ovos.intent.describe` is needed only when definitions are asked for
  (`IntentInventoryOptions(describe: true)`, the default).

## 0.1.8

- Add the intent inventory: `ThalovantClient.intents(languages:options:)` reads
  the hub runtime's intent manifest (OVOS-INTENT-4 §10) over the client's own
  session and returns a `HubIntentInventory` — every intent each skill
  registered, per language, with the sentences a person says to reach it as
  the skill's locale files wrote them, `{slot}` placeholders included. No
  control-plane credential is involved. `listIntents(lang:options:)` and
  `describeIntent(skillId:intentName:lang:options:)` expose the two underlying
  queries (`ovos.intent.list` / `ovos.intent.describe`) as `IntentRegistration`
  rows and `IntentDefinition`s; `IntentInventoryOptions`, `ListIntentsOptions`,
  and `DescribeIntentOptions` carry the deadline and switches.
- `HubIntentInventory`, `HubSkillIntents`, `HubIntent`, `IntentRegistration`,
  and `IntentDefinition` are `Codable` with the snake_case keys the sibling
  SDKs serialize (`asJSON()` gives the `JSONObject` form), and `HubIntentSource`
  names how an inventory was read (`intent-manifest` or `engine-manifests`).
  `HubIntent.phrasesFor(_:)` matches language tags case-insensitively with `_`
  and `-` folded (`sameLanguage`), and `examples(lang:limit:)` prefers whole
  sentences over ones with a slot, shorter first.
- Queries are correlated by `context.request_id` like every other request, and
  a reply delivered more than once is taken once. Describes are sent together
  and matched by request id, or by the definition's own
  `skill_id`/`intent_name`/`lang` for a hub that does not echo the id. A
  describe the hub never answers leaves that intent without sentences rather
  than failing the inventory.
- Add `ThalovantPolicyDeniedError`, thrown at once from the hub's
  `hive.policy.denied` with `deniedType`, `code`, `reason` and the `allowed`
  list, instead of waiting for a timeout. `IntentInventoryOptions.fallback`,
  on by default, falls back to the engines' own manifests
  (`intent.service.adapt.manifest.get` / `intent.service.padatious.manifest.get`)
  when `ovos.intent.list` is refused; the result then carries names only,
  `source: .engineManifests`, and `denied: ["ovos.intent.list"]`.
- A runtime that attaches each row's `definition` to `ovos.intent.list` when
  asked with `include_definitions` is used as such; one that does not is
  described row by row.
- Reads the same as the reference (Python SDK 0.4.37) on the four points the
  ports settled: `hasPhrases` is true only when at least one intent carries at
  least one sentence; `intents(languages:)` trims each tag and asks once per
  language whatever its spellings (`en-us`, `en-US`, `en_us`), keeping the
  first spelling in `languages`; an intent registered under both engines in
  one language keeps the template row's sentences — the keyword row, which
  carries none, never erases them — and the first row names its `engine`; on
  the names-only fallback the first engine to name an intent decides its
  `engine` (adapt is asked before padatious).
- Describes go out in batches of at most 32 (`defaultDescribeBatchSize`), each
  batch its own subscription window, instead of putting every request in flight
  at once. A hub with 69 intents in two languages is 138 requests and, with
  every reply delivered twice, 276 inbound events; an SDK whose reply queue is
  bounded drops replies past its capacity and returns an inventory missing
  sentences. The per-batch deadline also means a hub that answers nothing fails
  after one batch rather than holding every request open. A window that answered
  nothing contributes nothing rather than discarding what the earlier windows
  found — windows are contiguous slices, so a skill that stops answering can own
  a whole window — and the call fails only when no window produced anything, so
  a hub silent from the start still fails at the first window.
- Language tags are sent as the caller spelled them: the hub runtime folds the
  tag it receives (`standardize_lang` on both store and query in ovos-core's
  manifest), so `fr_FR` matches what `fr-fr` registered, and the SDK does not
  rewrite what the caller asked for.
- `ThalovantEvents` gains the eight intent-manifest and engine-manifest event
  names.
- Internal: `ThalovantClient` drives its transport through the
  `HiveMindBusTransport` seam so the test suite can run the request/reply paths
  against an in-memory hub; `HiveMindWSSTransport` is unchanged. The release
  literals that had drifted (`README.md` install snippet and
  `WireProtocolTests` at 0.1.4 while `VERSION` was 0.1.7) are realigned, which
  the auto-release bump requires.

## 0.1.4

- Automated patch release of the unreleased changes on `main` since v0.1.3.

## Unreleased

- **BREAKING:** removed the admin analytics path. `AnalyticsOverviewOptions` no
  longer has `admin` or `ownerId`, and `analyticsOverview` always calls
  `GET /v1/analytics/overview`; the `GET /v1/admin/analytics/overview` branch
  and its admin-only `owner_id` filter are gone. This SDK ships to non-admin
  customers, so the admin surface is removed rather than exposed.
- Security: `BootstrapIdentityResult.asJSON()` now redacts the `hub` and
  `client` resources by default, matching `identity`. The `client`
  (`POST /v1/clients` response) carries the provisioned credentials —
  `initial_identify` access_key/password/crypto_key/mqtt.username/mqtt.password,
  the `initial_identify_token`, and the echoed `spec` apiKey/password/cryptoKey —
  which previously appeared in the default serialization.
  `asJSON(includeSecrets: true)` is unchanged and still returns everything.
- Security: the secret-bearing types (`ThalovantIdentity`,
  `MqttBrokerCredentials`, `DeviceAuthorizationGrant`, `DeviceLoginResult`) now
  redact their credentials from string interpolation, `String(describing:)`,
  `String(reflecting:)`, and `dump()`. The `asJSON(includeSecrets:)` serializer
  and stored values are unchanged.
- Security: the WSS transport's `lastError` and surfaced connection error no
  longer interpolate the raw `URLError`, which embeds the connection URL and its
  `?authorization=` access-key query; they use the localized failure reason and
  scrub any `authorization=` query value that remains.
- Security: control API HTTP failures (including `POST /v1/clients`,
  `auth/token`, and `device/token`) no longer embed the raw response body in the
  error `message`/`errorDescription` that a UI alert renders — only the status
  and an allowlisted server detail (the error `code` and the server's own
  message), never a validation error's echoed request `input`. The full body
  remains on `ThalovantApiError.body` for `errorCode` decoding.

## 0.1.3

- Hub provisioning on `ThalovantControlPlane`: `createHub` (sends a generated
  `Idempotency-Key` unless you pass your own, so a retried create returns the
  first hub), `updateHub` and `deleteHub` (both take a **required** `etag`
  sent as `If-Match` — the API rejects a stale *or missing* value with HTTP
  412 and changes nothing), `releaseHub`, `setHubRating`/`clearHubRating`, and
  `getHubRuntimeCapabilities`.
- Runtime groups: `listRuntimeGroups`, `getRuntimeGroup`, `createRuntimeGroup`,
  `updateRuntimeGroup`, `getRuntimeGroupConfig`, `updateRuntimeGroupConfig`
  (the API merges `config` rather than replacing it; `personas` is sent only
  when provided), `releaseRuntimeGroup`, and `deleteRuntimeGroup` (HTTP 409 for
  the workspace default group and for a group that still has hubs attached).
  None of these routes use `If-Match` or an idempotency header.
- Skills: `installRuntimeGroupSkill` (defaults to the `catalog` source;
  `git` installs need a `sourceRef`), `uninstallRuntimeGroupSkill`,
  `listMarketplaceSkills`, `listRuntimeGroupMarketplace`, and
  `listRuntimeGroupInventory`.
- `ReleaseOptions`, `MarketplaceSkillListOptions`, and
  `InstallRuntimeGroupSkillOptions` option structs; every unset field is
  omitted from the request rather than sent as null.
- Scope and plan notes carried in the API docs: the provisioning writes need a
  paid plan plus `hubs:write` (HTTP 402 on the free plan), while the rating
  routes need `hubs:write` **without** a paid plan, the catalog reads need only
  `hubs:read`, and the runtime inspection reads need `hubs:inspect`. Neither
  `listRuntimeGroupInventory` nor `listRuntimeGroupMarketplace` fails when
  nothing is reporting — they answer with an empty list and a pending `source`,
  and `getHubRuntimeCapabilities` is the only route here that can answer HTTP
  409 for a quiet runtime.
- `createHub`/`updateHub` and `createRuntimeGroup`/`updateRuntimeGroup` accept
  the camelCase spellings of the API's snake_case body fields
  (`runtimeGroupId`, `capacityProfile`, `isLocked`, `ownerId`,
  `cloneFromDefault`) and send them as snake_case.
- README: a provisioning walkthrough (discover, create hub, create runtime
  group, install skill, release) with the paid-plan and scope notes.

## 0.1.2

- Documented the two token 429 responses in the README's Errors section: `token_rate_limited` (per-plan per-minute request rate, 60/min on the free plan) and `token_quota_exceeded` (per-plan daily/monthly call quota, with `quota`, `limit`, and `used`). Both carry a `Retry-After` header and a matching `retry_after_seconds`, which is authoritative; the SDK does not retry them, and `ThalovantApiError` exposes no response headers, so `retry_after_seconds` must be read from the body. `errorCode` decodes both codes out of the API's Problem+JSON `detail` object.

## 0.1.1

- `ThalovantControlPlane.loginWithBrowser(options:)`: browser device-flow
  sign-in (`POST /v1/auth/device/authorize` + `POST /v1/auth/device/token`)
  for accounts without a password. `DeviceLoginOptions` carries `scopes`,
  `clientName`, `openBrowser` (best-effort `/usr/bin/open` on macOS and
  `xdg-open` on Linux, skipped on iOS), a `prompt` closure (defaults to
  printing the verification URI and user code), and `timeout` (900 s).
  Polling honors the server `interval` and grows it by 5 s on `slow_down`;
  the approved token is stored on `accessToken` exactly like `login`.
- `ThalovantDeviceLoginError` (`.denied`, `.expired`) for terminal device-flow
  states; polling past `timeout` throws `ThalovantTimeoutError`.
- `DeviceAuthorizationGrant` and `DeviceLoginResult` types, and the
  `defaultDevicePollInterval` constant.
- README: documented device-flow sign-in and constructing
  `ThalovantControlPlane(accessToken:)` with a pre-made API token (CI).

## 0.1.0

Initial release of the Thalovant Swift SDK for iOS 15+, macOS 12+, and Linux.
Swift Package Manager package with zero third-party dependencies.

- `ThalovantControlPlane`: `login` with optional `scope`/`otpCode`/`recoveryCode`
  (MFA fields are sent as `otp_code`/`recovery_code` only when provided;
  MFA-enabled accounts receive HTTP 401 `mfa_required` without one), hubs and
  public hubs (public discovery is unauthenticated), typed `getOperation`,
  memory list/summary/create/get/update/delete with all documented filters,
  `analyticsOverview` with the 13 filters and the admin endpoint switch
  (`owner_id` admin-only), and `createClientIdentity` with an
  `Idempotency-Key` header, `active` option, and `initial_identify` parsing.
- `ThalovantIdentity` and `MqttBrokerCredentials` matching the API client
  identify schema, with JSON and secure-file loading.
- Hub protocol settings (`spec.protocols.{wss,http,mqtt}.enabled`, WSS enabled
  by default) and `data_plane_endpoints` selection with the `wss`, `https`,
  `mqtt` preference order.
- `ThalovantClient` data plane v0.1 over WSS (`URLSessionWebSocketTask`):
  authorization query credential, preshared-key handshake with plaintext
  `hello` reply, AES-128-GCM encrypted HiveMessage frames (pure-Swift cipher
  compatible with the Node and Go SDKs), `ask()` with request-id correlated
  reply aggregation, event handler registration, and `close()`. HTTPS and MQTT
  data-plane transports throw `ThalovantUnsupportedProtocolError`.
- `ThalovantApiError` with HTTP status code, raw body, and decoded error code.
