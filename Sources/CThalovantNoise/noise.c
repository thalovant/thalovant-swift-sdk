/* Noise Protocol Framework revision 34, XXpsk2 / KKpsk0 initiator+responder.
 * The state machine is first-party; vectors come from independent Node/Python
 * implementations. Every error is terminal, including capacity errors. */
#include "thalovant/noise.h"
#include "thalovant/aes_gcm.h"
#include "thalovant/sha256.h"
#include <string.h>

enum token { END, E, S, EE, ES, SE, SS, PSK };
static const int xx[3][6] = {{E, END}, {E, EE, S, ES, PSK, END}, {S, SE, END}};
static const int kk[2][6] = {{PSK, E, ES, SS, END}, {E, EE, SE, END}};
static int valid_handshake_step(const thalovant_noise *s)
{
    return (s->pattern == THALOVANT_NOISE_XX && s->step >= 0 && s->step < 3) ||
           (s->pattern == THALOVANT_NOISE_KK && s->step >= 0 && s->step < 2);
}
static int fail(thalovant_noise *s, int error)
{
    if (s) {
        thalovant_noise_wipe(s, sizeof *s);
        s->failed = 1;
    }
    return error;
}
static void digest_pair(const uint8_t *a, size_t alen, const uint8_t *b, size_t blen,
                        uint8_t out[32])
{
    thalovant_sha256_ctx h;
    thalovant_sha256_init(&h);
    thalovant_sha256_update(&h, a, alen);
    thalovant_sha256_update(&h, b, blen);
    thalovant_sha256_final(&h, out);
    thalovant_noise_wipe(&h, sizeof h);
}
static void hmac(const uint8_t key[32], const uint8_t *data, size_t len, uint8_t out[32])
{
    uint8_t pad[64], inner[32];
    for (unsigned i = 0; i < 64; i++)
        pad[i] = (uint8_t)((i < 32 ? key[i] : 0) ^ 0x36);
    digest_pair(pad, 64, data, len, inner);
    for (unsigned i = 0; i < 64; i++)
        pad[i] = (uint8_t)((i < 32 ? key[i] : 0) ^ 0x5c);
    digest_pair(pad, 64, inner, 32, out);
    thalovant_noise_wipe(pad, 64);
    thalovant_noise_wipe(inner, 32);
}
static void hkdf(const uint8_t ck[32], const uint8_t *input, size_t len, uint8_t out[3][32],
                 int count)
{
    uint8_t temp[32], value[33] = {0};
    hmac(ck, input, len, temp);
    for (int i = 0; i < count; i++) {
        size_t n = i ? 33 : 1;
        if (i)
            memcpy(value, out[i - 1], 32);
        value[n - 1] = (uint8_t)(i + 1);
        hmac(temp, value, n, out[i]);
    }
    thalovant_noise_wipe(temp, 32);
    thalovant_noise_wipe(value, 33);
}
static void mix_hash(thalovant_noise *s, const uint8_t *data, size_t len)
{
    digest_pair(s->hash, 32, data, len, s->hash);
}
static void mix_key(thalovant_noise *s, const uint8_t *data, size_t len, int and_hash)
{
    uint8_t out[3][32];
    hkdf(s->ck, data, len, out, and_hash ? 3 : 2);
    memcpy(s->ck, out[0], 32);
    if (and_hash) {
        mix_hash(s, out[1], 32);
    }
    memcpy(s->key, out[and_hash ? 2 : 1], 32);
    s->nonce = 0;
    s->has_key = 1;
    thalovant_noise_wipe(out, sizeof out);
}
static void nonce_bytes(uint64_t n, uint8_t out[12])
{
    memset(out, 0, 4);
    for (unsigned i = 0; i < 8; i++)
        out[4 + i] = (uint8_t)(n >> (56 - 8 * i));
}
static int seal(const uint8_t key[32], uint64_t *counter, const uint8_t *ad, size_t adlen,
                const uint8_t *data, size_t len, uint8_t *out)
{
    uint8_t nonce[12];
    int rc;
    if (*counter == UINT64_MAX)
        return THALOVANT_ERR_AUTH;
    nonce_bytes(*counter, nonce);
    rc = thalovant_aes256_gcm_encrypt(key, nonce, 12, ad, adlen, data, len, out, out + len);
    if (!rc) {
        (*counter)++;
    }
    return rc;
}
static int unseal(const uint8_t key[32], uint64_t *counter, const uint8_t *ad, size_t adlen,
                  const uint8_t *data, size_t len, uint8_t *out)
{
    uint8_t nonce[12];
    int rc;
    if (len < 16 || *counter == UINT64_MAX)
        return THALOVANT_ERR_AUTH;
    nonce_bytes(*counter, nonce);
    rc = thalovant_aes256_gcm_decrypt(key, nonce, 12, ad, adlen, data, len - 16, data + len - 16,
                                      out);
    if (!rc) {
        (*counter)++;
    }
    return rc;
}
static int encrypt_hash(thalovant_noise *s, const uint8_t *data, size_t len, uint8_t *out)
{
    int rc = 0;
    if (s->has_key)
        rc = seal(s->key, &s->nonce, s->hash, 32, data, len, out);
    else if (len)
        memmove(out, data, len);
    if (!rc) {
        mix_hash(s, out, len + (s->has_key ? 16 : 0));
    }
    return rc;
}
static int decrypt_hash(thalovant_noise *s, const uint8_t *data, size_t len, uint8_t *out)
{
    uint8_t next[32];
    int rc = 0;
    /* Hash ciphertext before potentially decrypting it in place. */
    digest_pair(s->hash, 32, data, len, next);
    if (s->has_key)
        rc = unseal(s->key, &s->nonce, s->hash, 32, data, len, out);
    else if (len)
        memmove(out, data, len);
    if (!rc) {
        memcpy(s->hash, next, 32);
    }
    return rc;
}
static int dh(thalovant_noise *s, int token)
{
    const uint8_t *local = NULL, *remote = NULL;
    uint8_t shared[32];
    int rc;
    if (token == EE) {
        local = s->ephemeral;
        remote = s->remote_ephemeral;
    }
    if (token == ES) {
        local = s->initiator ? s->ephemeral : s->local_static;
        remote = s->initiator ? s->remote_static : s->remote_ephemeral;
    }
    if (token == SE) {
        local = s->initiator ? s->local_static : s->ephemeral;
        remote = s->initiator ? s->remote_ephemeral : s->remote_static;
    }
    if (token == SS) {
        local = s->local_static;
        remote = s->remote_static;
    }
    if (!local || !remote)
        return THALOVANT_ERR_INVALID;
    rc = thalovant_x25519(local, remote, shared);
    if (!rc)
        mix_key(s, shared, 32, 0);
    thalovant_noise_wipe(shared, 32);
    return rc;
}
static void split(thalovant_noise *s)
{
    if (++s->step != (s->pattern == THALOVANT_NOISE_XX ? 3 : 2))
        return;
    uint8_t out[3][32];
    hkdf(s->ck, NULL, 0, out, 2);
    memcpy(s->send_key, out[s->initiator ? 0 : 1], 32);
    memcpy(s->receive_key, out[s->initiator ? 1 : 0], 32);
    thalovant_noise_wipe(out, sizeof out);
    thalovant_noise_wipe(s->local_static, 32);
    thalovant_noise_wipe(s->ephemeral, 32);
    thalovant_noise_wipe(s->ck, 32);
    thalovant_noise_wipe(s->key, 32);
    thalovant_noise_wipe(s->psk, 32);
    s->ready = 1;
}
int thalovant_noise_init(thalovant_noise *s, int pattern, int initiator, const uint8_t psk[32],
                         const uint8_t *prologue, size_t len, const uint8_t static_private[32],
                         const uint8_t ephemeral_private[32], const uint8_t *pin)
{
    const char *name = pattern == THALOVANT_NOISE_XX ? "Noise_XXpsk2_25519_AESGCM_SHA256"
                                                     : "Noise_KKpsk0_25519_AESGCM_SHA256";
    if (!s)
        return THALOVANT_ERR_INVALID;
    memset(s, 0, sizeof *s);
    if ((pattern != THALOVANT_NOISE_XX && pattern != THALOVANT_NOISE_KK) || !psk ||
        (!prologue && len) || !static_private || !ephemeral_private ||
        (pattern == THALOVANT_NOISE_KK && !pin))
        return fail(s, THALOVANT_ERR_INVALID);
    s->pattern = pattern;
    s->initiator = !!initiator;
    memcpy(s->psk, psk, 32);
    memcpy(s->local_static, static_private, 32);
    memcpy(s->ephemeral, ephemeral_private, 32);
    if (thalovant_x25519_public(static_private, s->local_public))
        return fail(s, THALOVANT_ERR_INVALID);
    if (pin) {
        s->has_pin = 1;
        memcpy(s->pin, pin, 32);
        if (pattern == THALOVANT_NOISE_KK)
            memcpy(s->remote_static, pin, 32);
    }
    if (strlen(name) <= 32)
        memcpy(s->hash, name, strlen(name));
    else
        thalovant_sha256((const uint8_t *)name, strlen(name), s->hash);
    memcpy(s->ck, s->hash, 32);
    mix_hash(s, prologue, len);
    if (pattern == THALOVANT_NOISE_KK) {
        mix_hash(s, initiator ? s->local_public : s->remote_static, 32);
        mix_hash(s, initiator ? s->remote_static : s->local_public, 32);
    }
    return THALOVANT_OK;
}
int thalovant_noise_write(thalovant_noise *s, const uint8_t *payload, size_t len, uint8_t *out,
                          size_t capacity, size_t *written)
{
    const int *tokens;
    size_t offset = 0;
    int rc;
    if (written)
        *written = 0;
    if (!s || !written || !out || (!payload && len) || s->failed || s->ready ||
        !valid_handshake_step(s) || ((s->step % 2 == 0) != s->initiator))
        return fail(s, THALOVANT_ERR_INVALID);
    /* Maximum possible overhead is ephemeral+encrypted static+payload tag. */
    if (len > 65535 - 96 || capacity < len + 96)
        return fail(s, THALOVANT_ERR_NOMEM);
    tokens = s->pattern == THALOVANT_NOISE_XX ? xx[s->step] : kk[s->step];
    for (unsigned i = 0; tokens[i]; i++) {
        switch (tokens[i]) {
        case E:
            rc = thalovant_x25519_public(s->ephemeral, out + offset);
            if (rc)
                return fail(s, rc);
            mix_hash(s, out + offset, 32);
            mix_key(s, out + offset, 32, 0);
            offset += 32;
            break;
        case S:
            rc = encrypt_hash(s, s->local_public, 32, out + offset);
            if (rc)
                return fail(s, rc);
            offset += 32 + (s->has_key ? 16 : 0);
            break;
        case PSK:
            mix_key(s, s->psk, 32, 1);
            break;
        default:
            rc = dh(s, tokens[i]);
            if (rc)
                return fail(s, rc);
            break;
        }
    }
    rc = encrypt_hash(s, payload, len, out + offset);
    if (rc)
        return fail(s, rc);
    offset += len + (s->has_key ? 16 : 0);
    *written = offset;
    split(s);
    return 0;
}
int thalovant_noise_read(thalovant_noise *s, const uint8_t *message, size_t len, uint8_t *payload,
                         size_t capacity, size_t *written)
{
    const int *tokens;
    size_t offset = 0;
    int rc;
    if (written)
        *written = 0;
    if (!s || !written || !payload || !message || s->failed || s->ready ||
        !valid_handshake_step(s) || ((s->step % 2 == 0) == s->initiator) || len > 65535)
        return fail(s, THALOVANT_ERR_INVALID);
    tokens = s->pattern == THALOVANT_NOISE_XX ? xx[s->step] : kk[s->step];
    for (unsigned i = 0; tokens[i]; i++) {
        switch (tokens[i]) {
        case E:
            if (len - offset < 32)
                return fail(s, THALOVANT_ERR_INVALID);
            memcpy(s->remote_ephemeral, message + offset, 32);
            mix_hash(s, message + offset, 32);
            mix_key(s, message + offset, 32, 0);
            offset += 32;
            break;
        case S: {
            size_t take = 32 + (s->has_key ? 16 : 0);
            if (len - offset < take)
                return fail(s, THALOVANT_ERR_INVALID);
            rc = decrypt_hash(s, message + offset, take, s->remote_static);
            if (rc)
                return fail(s, rc);
            if (s->has_pin && thalovant_ct_compare(s->pin, s->remote_static, 32))
                return fail(s, THALOVANT_ERR_AUTH);
            offset += take;
            break;
        }
        case PSK:
            mix_key(s, s->psk, 32, 1);
            break;
        default:
            rc = dh(s, tokens[i]);
            if (rc)
                return fail(s, rc);
            break;
        }
    }
    size_t tag = s->has_key ? 16 : 0;
    if (len - offset < tag)
        return fail(s, THALOVANT_ERR_AUTH);
    if (capacity < len - offset - tag)
        return fail(s, THALOVANT_ERR_NOMEM);
    rc = decrypt_hash(s, message + offset, len - offset, payload);
    if (rc)
        return fail(s, rc);
    *written = len - offset - tag;
    split(s);
    return 0;
}
static int marker(int *chunked, const uint8_t *data, size_t len)
{
    if (!len || data[0] > 5)
        return THALOVANT_ERR_INVALID;
    if (data[0] < 2) {
        if (*chunked)
            return THALOVANT_ERR_INVALID;
    } else if (data[0] < 4) {
        if (*chunked)
            return THALOVANT_ERR_INVALID;
        *chunked = 1;
    } else {
        if (!*chunked)
            return THALOVANT_ERR_INVALID;
        if (data[0] == 5)
            *chunked = 0;
    }
    return 0;
}
int thalovant_noise_encrypt(thalovant_noise *s, const uint8_t *frame, size_t len, uint8_t *out,
                            size_t capacity, size_t *written)
{
    int rc;
    if (written)
        *written = 0;
    if (!s || !written || !frame || !out || !s->ready || s->failed ||
        len > THALOVANT_NOISE_CHUNK_SIZE + 1)
        return fail(s, THALOVANT_ERR_INVALID);
    if (capacity < len + 16)
        return fail(s, THALOVANT_ERR_NOMEM);
    rc = marker(&s->send_chunked, frame, len);
    if (rc)
        return fail(s, rc);
    rc = seal(s->send_key, &s->send_nonce, NULL, 0, frame, len, out);
    if (rc)
        return fail(s, rc);
    *written = len + 16;
    return 0;
}
int thalovant_noise_decrypt(thalovant_noise *s, const uint8_t *ciphertext, size_t len,
                            uint8_t *frame, size_t capacity, size_t *written)
{
    int rc;
    if (written)
        *written = 0;
    if (!s || !written || !ciphertext || !frame || !s->ready || s->failed || len < 17 ||
        len > 65535)
        return fail(s, THALOVANT_ERR_INVALID);
    if (capacity < len - 16)
        return fail(s, THALOVANT_ERR_NOMEM);
    rc = unseal(s->receive_key, &s->receive_nonce, NULL, 0, ciphertext, len, frame);
    if (rc)
        return fail(s, rc);
    rc = marker(&s->receive_chunked, frame, len - 16);
    if (rc) {
        thalovant_noise_wipe(frame, len - 16);
        return fail(s, rc);
    }
    *written = len - 16;
    return 0;
}

int thalovant_noise_select(const char *const *patterns, size_t pattern_count,
                           const char *const *suites, size_t suite_count, int has_pin, int *pattern)
{
    int xx_offer = 0, kk_offer = 0, suite_offer = 0;
    if (!pattern || (!patterns && pattern_count) || (!suites && suite_count))
        return THALOVANT_ERR_INVALID;
    *pattern = 0;
    for (size_t i = 0; i < suite_count; i++)
        if (suites[i] && strcmp(suites[i], THALOVANT_NOISE_SUITE) == 0)
            suite_offer = 1;
    for (size_t i = 0; i < pattern_count; i++) {
        if (!patterns[i])
            continue;
        if (strcmp(patterns[i], "XXpsk2") == 0)
            xx_offer = 1;
        if (strcmp(patterns[i], "KKpsk0") == 0)
            kk_offer = 1;
    }
    if (!suite_offer)
        return THALOVANT_ERR_UNSUPPORTED;
    if (has_pin && kk_offer)
        *pattern = THALOVANT_NOISE_KK;
    else if (xx_offer)
        *pattern = THALOVANT_NOISE_XX;
    else
        return THALOVANT_ERR_UNSUPPORTED;
    return THALOVANT_OK;
}
