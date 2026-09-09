# First-party Noise core

These C99 files are maintained by Thalovant in `thalovant-embedded-c` and copied
here so SwiftPM compiles the same first-party implementation on Apple and
Linux without third-party packages or system crypto library requirements.
They are not vendored third-party code. Both repositories use their existing
project licenses; the cryptographic algorithms were implemented from public
specifications, not copied from another implementation.

- `noise.c`, `noise.h`: Noise Framework revision 34, XXpsk2 and KKpsk0, AESGCM.
- `noise_curve.c`: RFC 7748 X25519, fixed Montgomery ladder, radix 2^16.
- `noise_psk.c`: RFC 9106 Argon2id and RFC 7693 BLAKE2b, fixed HiveMind PSK
  parameters: t=3, m=65536 KiB, p=1, SHA256(node_id) salt, 32-byte output.
- `aes_gcm.c/.h`: existing first-party AES128 extended with an algebraic S-box
  AES256 implementation, SP 800-38D GCM and Noise big-endian nonce counters.
- `sha256.c/.h`: existing first-party FIPS 180-4 implementation.

`Tests/ThalovantSDKTests/Fixtures/noise-node.json` comes from the independent
Node SDK with @noble crypto. Fixed synthetic ephemeral RNG bytes are the only
reference-code substitution. It captures XX/KK messages, Unicode canonical
prologues, PSK and transport counters 0–2 in both directions. The generator is
`tools/generate-noise-vectors.mjs` in `thalovant-embedded-c`. Swift tests also
exercise the production cleartext WSS negotiation binding and secure storage.
C tests verify RFC X25519, NIST AES256, legacy AES vectors and adverse paths
with both GCC and Clang. Keep these shared files byte-identical when fixing
core behavior, and rerun both SDK suites; `source-hashes.json` records this
release's copy.

This copy comes from `thalovant-embedded-c` version `0.4.1`, source commit
`718ee9497c3e50516a3a8e6df5868114a59af784`. The commit is available from
https://github.com/thalovant/thalovant-embedded-c/commit/718ee9497c3e50516a3a8e6df5868114a59af784.
Run `python3 tools/check-source-hashes.py` from the Swift repository root to
verify every shared C source and public header. CI and release jobs run this
check and reject missing, additional, or changed files with stale hashes.

Manifest schema version 2 separates the nine byte-identical upstream files in
`shared_c` from the Swift-owned umbrella header in `swift_module`. Both groups
are verified, including every header beneath `include/`. The previous flat
manifest is rejected with a migration error: regroup its existing shared-file
hashes and record the current Swift module header hash explicitly. Validation
never rewrites the manifest or accepts stale hashes automatically.

References: https://noiseprotocol.org/noise.html,
https://www.rfc-editor.org/rfc/rfc7748,
https://www.rfc-editor.org/rfc/rfc9106,
https://www.rfc-editor.org/rfc/rfc7693.
