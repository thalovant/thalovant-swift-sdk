/* SHA-256 (FIPS 180-4), used for hashed MQTT topic satellite ids. */
#ifndef THALOVANT_SHA256_H
#define THALOVANT_SHA256_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint32_t state[8];
    uint64_t length;
    uint8_t buffer[64];
    size_t buffered;
} thalovant_sha256_ctx;

void thalovant_sha256_init(thalovant_sha256_ctx *ctx);
void thalovant_sha256_update(thalovant_sha256_ctx *ctx, const uint8_t *data, size_t len);
void thalovant_sha256_final(thalovant_sha256_ctx *ctx, uint8_t out[32]);

/* One-shot convenience. */
void thalovant_sha256(const uint8_t *data, size_t len, uint8_t out[32]);

#endif /* THALOVANT_SHA256_H */
