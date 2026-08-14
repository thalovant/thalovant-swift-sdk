# Changelog

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
