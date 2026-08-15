# Changelog

## Unreleased

- **BREAKING:** removed the admin analytics path. `AnalyticsOverviewOptions` no
  longer has `admin` or `ownerId`, and `analyticsOverview` always calls
  `GET /v1/analytics/overview`; the `GET /v1/admin/analytics/overview` branch
  and its admin-only `owner_id` filter are gone. This SDK ships to non-admin
  customers, so the admin surface is removed rather than exposed.
- Security: `BootstrapIdentityResult.asJSON()` now redacts the `hub` and
  `client` resources by default, matching `identity`. The `client`
  (`POST /v1/clients` response) carries the provisioned credentials —
  `initial_identify` access_key/password/crypto_key/mqtt.password, the
  `initial_identify_token`, and the echoed `spec` apiKey/password/cryptoKey —
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
  and a short, single-line server detail. The full body remains on
  `ThalovantApiError.body` for `errorCode` decoding.

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
