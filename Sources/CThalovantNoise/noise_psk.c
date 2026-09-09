/* Fixed HiveMind Argon2id derivation. Written from RFC 9106 and RFC 7693;
 * intentionally no alternate parameters that could silently weaken the PSK. */
#include "thalovant/noise.h"
#include "thalovant/sha256.h"
#include <string.h>

static const uint64_t iv[8] = {UINT64_C(0x6a09e667f3bcc908), UINT64_C(0xbb67ae8584caa73b),
                               UINT64_C(0x3c6ef372fe94f82b), UINT64_C(0xa54ff53a5f1d36f1),
                               UINT64_C(0x510e527fade682d1), UINT64_C(0x9b05688c2b3e6c1f),
                               UINT64_C(0x1f83d9abfb41bd6b), UINT64_C(0x5be0cd19137e2179)};
static const uint8_t sigma[10][16] = {{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
                                      {14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3},
                                      {11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4},
                                      {7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8},
                                      {9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13},
                                      {2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9},
                                      {12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11},
                                      {13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10},
                                      {6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5},
                                      {10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0}};
static uint64_t rotate(uint64_t x, unsigned n) { return (x >> n) | (x << (64 - n)); }
static uint64_t get64(const uint8_t *p)
{
    uint64_t v = 0;
    for (unsigned i = 0; i < 8; i++)
        v |= (uint64_t)p[i] << (8 * i);
    return v;
}
static void put64(uint8_t *p, uint64_t v)
{
    for (unsigned i = 0; i < 8; i++)
        p[i] = (uint8_t)(v >> (8 * i));
}
static void put32(uint8_t *p, uint32_t v)
{
    for (unsigned i = 0; i < 4; i++)
        p[i] = (uint8_t)(v >> (8 * i));
}
static void bg(uint64_t *v, unsigned a, unsigned b, unsigned c, unsigned d, uint64_t x, uint64_t y)
{
    v[a] += v[b] + x;
    v[d] = rotate(v[d] ^ v[a], 32);
    v[c] += v[d];
    v[b] = rotate(v[b] ^ v[c], 24);
    v[a] += v[b] + y;
    v[d] = rotate(v[d] ^ v[a], 16);
    v[c] += v[d];
    v[b] = rotate(v[b] ^ v[c], 63);
}
typedef struct {
    uint64_t h[8], count;
    uint8_t block[128];
    size_t used, output;
} blake;
static void compress(blake *b, int last)
{
    uint64_t v[16], m[16];
    memcpy(v, b->h, 64);
    memcpy(v + 8, iv, 64);
    v[12] ^= b->count;
    if (last)
        v[14] = ~v[14];
    for (unsigned i = 0; i < 16; i++)
        m[i] = get64(b->block + 8 * i);
    for (unsigned r = 0; r < 12; r++) {
        const uint8_t *s = sigma[r % 10];
        bg(v, 0, 4, 8, 12, m[s[0]], m[s[1]]);
        bg(v, 1, 5, 9, 13, m[s[2]], m[s[3]]);
        bg(v, 2, 6, 10, 14, m[s[4]], m[s[5]]);
        bg(v, 3, 7, 11, 15, m[s[6]], m[s[7]]);
        bg(v, 0, 5, 10, 15, m[s[8]], m[s[9]]);
        bg(v, 1, 6, 11, 12, m[s[10]], m[s[11]]);
        bg(v, 2, 7, 8, 13, m[s[12]], m[s[13]]);
        bg(v, 3, 4, 9, 14, m[s[14]], m[s[15]]);
    }
    for (unsigned i = 0; i < 8; i++)
        b->h[i] ^= v[i] ^ v[i + 8];
    thalovant_noise_wipe(v, sizeof v);
    thalovant_noise_wipe(m, sizeof m);
}
static void binit(blake *b, size_t output)
{
    memset(b, 0, sizeof *b);
    memcpy(b->h, iv, 64);
    b->h[0] ^= 0x01010000u | output;
    b->output = output;
}
static void update(blake *b, const uint8_t *data, size_t len)
{
    while (len) {
        if (b->used == 128) {
            b->count += 128;
            compress(b, 0);
            b->used = 0;
        }
        size_t take = 128 - b->used;
        if (take > len)
            take = len;
        memcpy(b->block + b->used, data, take);
        b->used += take;
        data += take;
        len -= take;
    }
}
static void final(blake *b, uint8_t *out)
{
    b->count += b->used;
    memset(b->block + b->used, 0, 128 - b->used);
    compress(b, 1);
    for (size_t i = 0; i < b->output; i++)
        out[i] = (uint8_t)(b->h[i / 8] >> (8 * (i % 8)));
    thalovant_noise_wipe(b, sizeof *b);
}
static void hash(const uint8_t *data, size_t len, uint8_t *out, size_t output)
{
    blake b;
    binit(&b, output);
    update(&b, data, len);
    final(&b, out);
}
static void longhash(const uint8_t *data, size_t len, uint8_t *out, size_t output)
{
    uint8_t n[4], v[64];
    blake b;
    put32(n, (uint32_t)output);
    binit(&b, output <= 64 ? output : 64);
    update(&b, n, 4);
    update(&b, data, len);
    if (output <= 64) {
        final(&b, out);
        return;
    }
    final(&b, v);
    while (output > 64) {
        memcpy(out, v, 32);
        out += 32;
        output -= 32;
        if (output > 64)
            hash(v, 64, v, 64);
    }
    hash(v, 64, out, output);
    thalovant_noise_wipe(v, sizeof v);
}
static uint64_t plus(uint64_t a, uint64_t b)
{
    return a + b + 2u * (uint64_t)(uint32_t)a * (uint32_t)b;
}
static void ag(uint64_t *v, unsigned a, unsigned b, unsigned c, unsigned d)
{
    v[a] = plus(v[a], v[b]);
    v[d] = rotate(v[d] ^ v[a], 32);
    v[c] = plus(v[c], v[d]);
    v[b] = rotate(v[b] ^ v[c], 24);
    v[a] = plus(v[a], v[b]);
    v[d] = rotate(v[d] ^ v[a], 16);
    v[c] = plus(v[c], v[d]);
    v[b] = rotate(v[b] ^ v[c], 63);
}
static void permute(uint64_t v[16])
{
    ag(v, 0, 4, 8, 12);
    ag(v, 1, 5, 9, 13);
    ag(v, 2, 6, 10, 14);
    ag(v, 3, 7, 11, 15);
    ag(v, 0, 5, 10, 15);
    ag(v, 1, 6, 11, 12);
    ag(v, 2, 7, 8, 13);
    ag(v, 3, 4, 9, 14);
}
static void fill(const uint64_t *x, const uint64_t *y, uint64_t *out, int xor_old)
{
    uint64_t r[128], z[128], column[16];
    for (unsigned i = 0; i < 128; i++)
        r[i] = z[i] = x[i] ^ y[i];
    for (unsigned i = 0; i < 8; i++)
        permute(z + 16 * i);
    for (unsigned c = 0; c < 8; c++) {
        for (unsigned row = 0; row < 8; row++) {
            column[2 * row] = z[16 * row + 2 * c];
            column[2 * row + 1] = z[16 * row + 2 * c + 1];
        }
        permute(column);
        for (unsigned row = 0; row < 8; row++) {
            z[16 * row + 2 * c] = column[2 * row];
            z[16 * row + 2 * c + 1] = column[2 * row + 1];
        }
    }
    for (unsigned i = 0; i < 128; i++)
        out[i] = r[i] ^ z[i] ^ (xor_old ? out[i] : 0);
    thalovant_noise_wipe(r, sizeof r);
    thalovant_noise_wipe(z, sizeof z);
    thalovant_noise_wipe(column, sizeof column);
}
int thalovant_noise_psk(const uint8_t *password, size_t password_len, const uint8_t *node_id,
                        size_t node_id_len, uint64_t *scratch, size_t scratch_words,
                        uint8_t out[32])
{
    blake b;
    uint8_t prefix[28], salt[32], initial[72] = {0}, block[1024], n[4], zeros[8] = {0};
    uint64_t zero[128] = {0}, input[128] = {0}, address[128] = {0};
    const uint32_t blocks = 65536, segment = 16384;
    if ((!password && password_len) || (!node_id && node_id_len) || !scratch || !out ||
        password_len > UINT32_MAX)
        return THALOVANT_ERR_INVALID;
    if (scratch_words < THALOVANT_NOISE_PSK_MEMORY_WORDS)
        return THALOVANT_ERR_NOMEM;
    thalovant_sha256(node_id, node_id_len, salt);
    put32(prefix, 1);
    put32(prefix + 4, 32);
    put32(prefix + 8, blocks);
    put32(prefix + 12, 3);
    put32(prefix + 16, 19);
    put32(prefix + 20, 2);
    put32(prefix + 24, (uint32_t)password_len);
    binit(&b, 64);
    update(&b, prefix, 28);
    update(&b, password, password_len);
    put32(n, 32);
    update(&b, n, 4);
    update(&b, salt, 32);
    update(&b, zeros, 8);
    final(&b, initial);
    for (unsigned i = 0; i < 2; i++) {
        put32(initial + 64, i);
        longhash(initial, 72, block, 1024);
        for (unsigned j = 0; j < 128; j++)
            scratch[i * 128 + j] = get64(block + j * 8);
    }
    for (unsigned pass = 0; pass < 3; pass++)
        for (unsigned slice = 0; slice < 4; slice++) {
            int independent = pass == 0 && slice < 2;
            unsigned start = pass == 0 && slice == 0 ? 2 : 0;
            memset(input, 0, sizeof input);
            input[0] = pass;
            input[2] = slice;
            input[3] = blocks;
            input[4] = 3;
            input[5] = 2;
            if (independent && start) {
                input[6]++;
                fill(zero, input, address, 0);
                fill(zero, address, address, 0);
            }
            for (unsigned i = start; i < segment; i++) {
                uint32_t current = slice * segment + i,
                         previous = current ? current - 1 : blocks - 1;
                uint64_t random;
                if (independent) {
                    if (i % 128 == 0) {
                        input[6]++;
                        fill(zero, input, address, 0);
                        fill(zero, address, address, 0);
                    }
                    random = address[i % 128];
                } else
                    random = scratch[previous * 128];
                uint32_t area = pass ? blocks - segment + i - 1 : current - 1;
                uint64_t relative = (uint32_t)random;
                relative = (relative * relative) >> 32;
                relative = area - 1 - (((uint64_t)area * relative) >> 32);
                uint32_t offset = pass ? (slice == 3 ? 0 : (slice + 1) * segment) : 0;
                uint32_t reference = (offset + (uint32_t)relative) % blocks;
                fill(scratch + previous * 128, scratch + reference * 128, scratch + current * 128,
                     pass != 0);
            }
        }
    for (unsigned j = 0; j < 128; j++)
        put64(block + 8 * j, scratch[(blocks - 1) * 128 + j]);
    longhash(block, 1024, out, 32);
    thalovant_noise_wipe(scratch, THALOVANT_NOISE_PSK_MEMORY_WORDS * sizeof(uint64_t));
    thalovant_noise_wipe(initial, sizeof initial);
    thalovant_noise_wipe(block, sizeof block);
    thalovant_noise_wipe(address, sizeof address);
    return THALOVANT_OK;
}
