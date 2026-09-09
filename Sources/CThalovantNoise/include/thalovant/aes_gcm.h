/*
 * AES-128-GCM as used on the HiveMind wire.
 *
 * HiveMind seals frames with AES-128-GCM using a **16-byte nonce** (the
 * non-standard length the Node SDK feeds `crypto.createCipheriv`); 12-byte
 * legacy nonces are also accepted. Both lengths — and any other — are
 * handled through the standard GCM J0 derivation, so the output is
 * bit-compatible with Node's OpenSSL-backed implementation.
 *
 * The wire key is derived from `identity.crypto_key`: trim whitespace, then
 * take the first 16 UTF-8 bytes.
 *
 * The implementation favours portability and code size over speed: the
 * S-box lookups are not cache-timing hardened, which matches the threat
 * model of a satellite device talking to its own hub. The tag comparison
 * on decrypt *is* constant-time.
 */
#ifndef THALOVANT_AES_GCM_H
#define THALOVANT_AES_GCM_H

#include <stddef.h>
#include <stdint.h>

#include "thalovant/error.h"

#define THALOVANT_GCM_TAG_LEN 16
#define THALOVANT_GCM_NONCE_LEN 16       /* HiveMind wire nonce */
#define THALOVANT_GCM_NONCE_LEN_LEGACY 12

typedef struct {
    uint8_t round_keys[176];
} thalovant_aes128_ctx;

void thalovant_aes128_init(thalovant_aes128_ctx *ctx, const uint8_t key[16]);
void thalovant_aes128_encrypt_block(const thalovant_aes128_ctx *ctx, const uint8_t in[16],
                                    uint8_t out[16]);

/*
 * `ciphertext` receives exactly `plaintext_len` bytes; `ciphertext` may
 * alias `plaintext` for in-place operation. `aad` may be NULL when
 * `aad_len` is 0 (the HiveMind wire uses no AAD).
 */
int thalovant_aes_gcm_encrypt(const uint8_t key[16], const uint8_t *nonce, size_t nonce_len,
                              const uint8_t *aad, size_t aad_len, const uint8_t *plaintext,
                              size_t plaintext_len, uint8_t *ciphertext,
                              uint8_t tag[THALOVANT_GCM_TAG_LEN]);

/*
 * Verifies the tag (constant-time) before writing any plaintext. Returns
 * THALOVANT_ERR_AUTH on mismatch. `plaintext` may alias `ciphertext`.
 */
int thalovant_aes_gcm_decrypt(const uint8_t key[16], const uint8_t *nonce, size_t nonce_len,
                              const uint8_t *aad, size_t aad_len, const uint8_t *ciphertext,
                              size_t ciphertext_len, const uint8_t tag[THALOVANT_GCM_TAG_LEN],
                              uint8_t *plaintext);

/*
 * Derive the 16-byte runtime key from `identity.crypto_key`: trim, then take
 * the first 16 bytes. Returns THALOVANT_ERR_MISSING when the key is NULL or
 * blank and THALOVANT_ERR_INVALID when fewer than 16 bytes remain.
 */
int thalovant_crypto_runtime_key(const char *crypto_key, uint8_t out[16]);

/* Constant-time byte comparison; returns 0 when equal. */
int thalovant_ct_compare(const uint8_t *a, const uint8_t *b, size_t len);

/* AES-256-GCM with constant-time algebraic S-box, used by v3 Noise. */
typedef struct { uint8_t round_keys[240]; } thalovant_aes256_ctx;
void thalovant_aes256_init(thalovant_aes256_ctx *ctx, const uint8_t key[32]);
void thalovant_aes256_encrypt_block(const thalovant_aes256_ctx *ctx,
                                   const uint8_t in[16], uint8_t out[16]);
int thalovant_aes256_gcm_encrypt(const uint8_t key[32], const uint8_t *nonce, size_t nonce_len,
 const uint8_t *aad, size_t aad_len, const uint8_t *plaintext, size_t plaintext_len,
 uint8_t *ciphertext, uint8_t tag[16]);
int thalovant_aes256_gcm_decrypt(const uint8_t key[32], const uint8_t *nonce, size_t nonce_len,
 const uint8_t *aad, size_t aad_len, const uint8_t *ciphertext, size_t ciphertext_len,
 const uint8_t tag[16], uint8_t *plaintext);
#endif /* THALOVANT_AES_GCM_H */
