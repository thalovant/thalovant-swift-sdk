/* HiveMind v3 Noise, first-party implementation from Noise revision 34,
 * RFC 7748, RFC 9106, FIPS 180-4 and SP 800-38D. No third-party source.
 * No allocation or networking. All secrets and buffers belong to the caller.
 * Only 25519_AESGCM_SHA256 is supported; never select unadvertised options.
 */
#ifndef THALOVANT_NOISE_H
#define THALOVANT_NOISE_H
#include "thalovant/error.h"
#include <stddef.h>
#include <stdint.h>
#define THALOVANT_NOISE_SUITE "25519_AESGCM_SHA256"
#define THALOVANT_NOISE_PSK_MEMORY_WORDS (65536u * 128u)
#define THALOVANT_NOISE_CHUNK_SIZE 65000u
#define THALOVANT_NOISE_XX 1
#define THALOVANT_NOISE_KK 2

/* Choose only mutually advertised options: pinned KK preferred, else XX. */
int thalovant_noise_select(const char *const *patterns, size_t pattern_count,
                           const char *const *suites, size_t suite_count, int has_pin,
                           int *pattern);

void thalovant_noise_wipe(void *data, size_t len);
int thalovant_x25519(const uint8_t private_key[32], const uint8_t public_key[32], uint8_t out[32]);
int thalovant_x25519_public(const uint8_t private_key[32], uint8_t out[32]);
/* Argon2id v1.3: SHA256(node_id) salt, t=3, m=65536 KiB, p=1, 32 bytes.
 * scratch requires THALOVANT_NOISE_PSK_MEMORY_WORDS uint64_t words (64 MiB).
 * It is wiped before return. Memory-constrained callers may securely provision
 * the exact prederived 32-byte PSK instead; never substitute a cheaper KDF. */
int thalovant_noise_psk(const uint8_t *password, size_t password_len, const uint8_t *node_id,
                        size_t node_id_len, uint64_t *scratch, size_t scratch_words,
                        uint8_t out[32]);

typedef struct {
    uint8_t ck[32], hash[32], key[32], psk[32];
    uint8_t local_static[32], local_public[32], ephemeral[32], remote_static[32],
        remote_ephemeral[32];
    uint8_t pin[32], send_key[32], receive_key[32];
    uint64_t nonce, send_nonce, receive_nonce;
    int pattern, initiator, step, has_key, has_pin, ready, failed;
    int send_chunked, receive_chunked;
} thalovant_noise;
/* prologue is canonical HELLO payload || canonical offer payload || protocol
 * name; callers must retain every advertised field. Keys are 32 raw bytes.
 * ephemeral_private MUST be fresh CSPRNG bytes for each connection; static
 * private persists across connections. pin is optional for XX, required for KK.
 * A known pin is always enforced, including when XX is selected. */
int thalovant_noise_init(thalovant_noise *state, int pattern, int initiator, const uint8_t psk[32],
                         const uint8_t *prologue, size_t prologue_len,
                         const uint8_t static_private[32], const uint8_t ephemeral_private[32],
                         const uint8_t *pin);
/* Handshake payloads are arbitrary bytes; wire JSON wraps resulting bytes as
 * hex in {"msg_type":"shake","payload":{"noise":{"msg":"..."}}}.
 * First outgoing envelope also names pattern/suite. Buffer errors and all
 * protocol/authentication errors poison the connection; re-init to reconnect. */
int thalovant_noise_write(thalovant_noise *state, const uint8_t *payload, size_t len, uint8_t *out,
                          size_t capacity, size_t *written);
int thalovant_noise_read(thalovant_noise *state, const uint8_t *message, size_t len,
                         uint8_t *payload, size_t capacity, size_t *written);
/* Transport plaintext includes one frame marker. 0 JSON,1 binary,2 firstJSON,
 * 3 firstBinary,4 continuation,5 last. Callers own bounded reassembly storage.
 * No interleaving/replay/counter reuse permitted. Only ready sessions accepted.
 * encrypt/decrypt support in-place operation. */
int thalovant_noise_encrypt(thalovant_noise *state, const uint8_t *frame, size_t len, uint8_t *out,
                            size_t capacity, size_t *written);
int thalovant_noise_decrypt(thalovant_noise *state, const uint8_t *ciphertext, size_t len,
                            uint8_t *frame, size_t capacity, size_t *written);
#endif
