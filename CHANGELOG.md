# Changelog

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
