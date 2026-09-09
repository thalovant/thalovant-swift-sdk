#include "thalovant/noise.h"
#include <string.h>

void thalovant_noise_wipe(void *data, size_t len)
{
    volatile uint8_t *p = (volatile uint8_t *)data;
    while (len--)
        *p++ = 0;
}
/* Radix 2^16 field arithmetic modulo 2^255-19. Every loop bound and memory
 * access is independent of scalar bits. Wide accumulators fit in uint64_t. */
typedef uint32_t fe[16];
static void reduce(fe out, uint64_t t[32])
{
    unsigned i, round;
    for (i = 32; i-- > 16;)
        t[i - 16] += 38u * t[i];
    for (round = 0; round < 3; round++) {
        for (i = 0; i < 15; i++) {
            t[i + 1] += t[i] >> 16;
            t[i] &= 65535;
        }
        t[0] += 19u * (t[15] >> 15);
        t[15] &= 32767;
    }
    for (i = 0; i < 16; i++)
        out[i] = (uint32_t)t[i];
}
static void mul(fe out, const fe a, const fe b)
{
    uint64_t t[32] = {0};
    for (unsigned i = 0; i < 16; i++)
        for (unsigned j = 0; j < 16; j++)
            t[i + j] += (uint64_t)a[i] * b[j];
    reduce(out, t);
}
static void add(fe out, const fe a, const fe b)
{
    uint64_t t[32] = {0};
    for (unsigned i = 0; i < 16; i++)
        t[i] = (uint64_t)a[i] + b[i];
    reduce(out, t);
}
static void sub(fe out, const fe a, const fe b)
{
    uint64_t t[32] = {0};
    for (unsigned i = 0; i < 16; i++)
        t[i] = (uint64_t)a[i] + (i == 0 ? 131034u : i == 15 ? 65534u : 131070u) - b[i];
    reduce(out, t);
}
static void swap(fe a, fe b, uint32_t bit)
{
    uint32_t mask = 0u - bit;
    for (unsigned i = 0; i < 16; i++) {
        uint32_t t = mask & (a[i] ^ b[i]);
        a[i] ^= t;
        b[i] ^= t;
    }
}
static void invert(fe out, const fe a)
{
    fe r = {1};
    /* p-2 = 2^255-21. Exponent is public, scalar never controls this branch. */
    for (int i = 254; i >= 0; i--) {
        mul(r, r, r);
        if (i >= 5 || ((11u >> i) & 1u))
            mul(r, r, a);
    }
    memcpy(out, r, sizeof r);
    thalovant_noise_wipe(r, sizeof r);
}
static void encode(uint8_t out[32], const fe a)
{
    uint32_t candidate[16], borrow = 0;
    for (unsigned i = 0; i < 16; i++) {
        uint32_t p = i == 0 ? 65517u : i == 15 ? 32767u : 65535u;
        uint32_t d = a[i] - p - borrow;
        borrow = d >> 31;
        candidate[i] = d & 65535u;
    }
    uint32_t mask = 0u - (1u - borrow);
    for (unsigned i = 0; i < 16; i++) {
        uint32_t v = (a[i] & ~mask) | (candidate[i] & mask);
        out[2 * i] = (uint8_t)v;
        out[2 * i + 1] = (uint8_t)(v >> 8);
    }
}
int thalovant_x25519(const uint8_t private_key[32], const uint8_t public_key[32], uint8_t out[32])
{
    uint8_t k[32], nz = 0;
    fe x1, x2 = {1}, z2 = {0}, x3, z3 = {1}, a, aa, b, bb, e, c, d, da, cb, t, u,
           constant = {121665};
    uint32_t exchanged = 0;
    if (!private_key || !public_key || !out)
        return THALOVANT_ERR_INVALID;
    memcpy(k, private_key, 32);
    k[0] &= 248;
    k[31] = (uint8_t)((k[31] & 127) | 64);
    for (unsigned i = 0; i < 16; i++)
        x1[i] = (uint32_t)public_key[2 * i] | ((uint32_t)public_key[2 * i + 1] << 8);
    x1[15] &= 32767;
    memcpy(x3, x1, sizeof x1);
    for (int bit = 254; bit >= 0; bit--) {
        uint32_t selected = (k[bit / 8] >> (bit % 8)) & 1u;
        exchanged ^= selected;
        swap(x2, x3, exchanged);
        swap(z2, z3, exchanged);
        exchanged = selected;
        add(a, x2, z2);
        mul(aa, a, a);
        sub(b, x2, z2);
        mul(bb, b, b);
        sub(e, aa, bb);
        add(c, x3, z3);
        sub(d, x3, z3);
        mul(da, d, a);
        mul(cb, c, b);
        add(t, da, cb);
        mul(x3, t, t);
        sub(t, da, cb);
        mul(u, t, t);
        mul(z3, x1, u);
        mul(x2, aa, bb);
        mul(t, constant, e);
        add(u, aa, t);
        mul(z2, e, u);
    }
    swap(x2, x3, exchanged);
    swap(z2, z3, exchanged);
    invert(t, z2);
    mul(u, x2, t);
    encode(out, u);
    for (unsigned i = 0; i < 32; i++)
        nz |= out[i];
    thalovant_noise_wipe(k, sizeof k);
    thalovant_noise_wipe(x2, sizeof x2);
    thalovant_noise_wipe(z2, sizeof z2);
    thalovant_noise_wipe(x3, sizeof x3);
    thalovant_noise_wipe(z3, sizeof z3);
    thalovant_noise_wipe(a, sizeof a);
    thalovant_noise_wipe(aa, sizeof aa);
    thalovant_noise_wipe(b, sizeof b);
    thalovant_noise_wipe(bb, sizeof bb);
    thalovant_noise_wipe(e, sizeof e);
    thalovant_noise_wipe(c, sizeof c);
    thalovant_noise_wipe(d, sizeof d);
    thalovant_noise_wipe(da, sizeof da);
    thalovant_noise_wipe(cb, sizeof cb);
    thalovant_noise_wipe(t, sizeof t);
    thalovant_noise_wipe(u, sizeof u);
    return nz ? THALOVANT_OK : THALOVANT_ERR_AUTH;
}
int thalovant_x25519_public(const uint8_t private_key[32], uint8_t out[32])
{
    const uint8_t base[32] = {9};
    return thalovant_x25519(private_key, base, out);
}
