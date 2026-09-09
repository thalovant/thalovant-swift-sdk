#!/usr/bin/env bash
# Reproduce the Linux CI platform dependency, without changing the SDK sockets.
# Requires make, gcc, pkg-config, and OpenSSL development headers.
set -euo pipefail
prefix="${1:?supply an absolute installation directory}"
[[ "$prefix" == /* ]] || { echo 'Installation directory must be absolute.' >&2; exit 1; }
source_dir="$(mktemp -d)"
trap 'rm -rf "$source_dir"' EXIT
curl --fail --location --proto '=https' --tlsv1.2 \
  https://github.com/curl/curl/releases/download/curl-8_22_0/curl-8.22.0.tar.xz \
  --output "$source_dir/curl.tar.xz"
(cd "$source_dir" && echo 'f7ef3ae8a22e521f289803fe93543eb64c329b58aa73a9e224dfd915a2a5f4f7  curl.tar.xz' | sha256sum --check)
tar -xJf "$source_dir/curl.tar.xz" -C "$source_dir"
cd "$source_dir/curl-8.22.0"
if ! (./configure --prefix="$prefix" --enable-websockets --enable-versioned-symbols \
    --disable-static --with-openssl --without-libpsl --without-libidn2 \
    --without-zstd --without-brotli --without-libssh2 --without-nghttp2 && \
    make -j2 && make install) > "$source_dir/build.log" 2>&1; then
  tail -100 "$source_dir/build.log"
  exit 1
fi
LD_LIBRARY_PATH="$prefix/lib:${LD_LIBRARY_PATH:-}" "$prefix/bin/curl" --version
