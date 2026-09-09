#!/usr/bin/env bash
# Explicit loopback integration; regular swift test remains network-free.
set -euo pipefail
interop_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
node_sdk="${1:?supply built Node SDK directory}"
swift build --package-path "$interop_dir"
peer_log="$(mktemp)"
node "$interop_dir/peer.mjs" "$node_sdk" >"$peer_log" 2>&1 &
peer_pid=$!
trap 'status=$?; kill "$peer_pid" 2>/dev/null || true; cat "$peer_log"; rm -f "$peer_log"; exit "$status"' EXIT
endpoint=""
for attempt in {1..100}; do
    endpoint="$(sed -n '1p' "$peer_log")"
    if [[ "$endpoint" == ws://127.0.0.1:* ]]; then break; fi
    if ! kill -0 "$peer_pid" 2>/dev/null; then exit 1; fi
    sleep 0.1
done
if [[ "$endpoint" != ws://127.0.0.1:* ]]; then exit 1; fi
swift run --skip-build --package-path "$interop_dir" NoiseInterop "$endpoint"
wait "$peer_pid"
