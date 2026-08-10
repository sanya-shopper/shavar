/* sha01 — SHA-0 and SHA-1. See sha01.h for the API and the warning.
 *
 * The two functions are one function with one rotation switched on or off.
 * That is stated in the header and it is worth seeing in the code, so the
 * variant is threaded down to the single expression where it matters and
 * appears nowhere else: grep for `v` in this file and there is exactly one
 * use of it that is not a parameter being passed along.
 */

#include "sha01.h"

#include <string.h>

#define M32 0xFFFFFFFFu

/* Shared by both functions: FIPS 180 §5. */
const uint32_t sha01_iv[5] = {0x67452301u, 0xEFCDAB89u, 0x98BADCFEu,
                              0x10325476u, 0xC3D2E1F0u};

/* One constant per twenty rounds. Their derivation is stated in FIPS 180-1:
 * 5A827999 = floor(2^30 * sqrt(2)), 6ED9EBA1 = floor(2^30 * sqrt(3)),
 * 8F1BBCDC = floor(2^30 * sqrt(5)), CA62C1D6 = floor(2^30 * sqrt(10)).
 * ../attack/constants.c recomputes them rather than trusting this comment. */
const uint32_t sha01_k[4] = {0x5A827999u, 0x6ED9EBA1u, 0x8F1BBCDCu, 0xCA62C1D6u};

/* Rotate left.
 *
 * The low bits are masked off before being shifted up for the same reason
 * ../../c/shavar.c does it: it is not needed for correctness — C99 6.5.7p4
 * defines unsigned left shift as reduction mod 2^32 — but UBSan's
 * `unsigned-shift-base` check flags any left shift that discards bits, and a
 * rotation discards bits by design. Masking first keeps the sanitizer matrix
 * clean with no suppressions. */
uint32_t sha01_rotl(uint32_t x, unsigned n) {
    n &= 31u;
    if (n == 0u) return x;
    return (((x & ((1u << (32u - n)) - 1u)) << n) | (x >> (32u - n))) & M32;
}

uint32_t sha01_ch(uint32_t b, uint32_t c, uint32_t d) {
    return ((b & c) ^ (~b & d)) & M32;
}

/* GF(2)-linear. The attack lives on this fact: see sha-broken.pdf §4.2. */
uint32_t sha01_parity(uint32_t b, uint32_t c, uint32_t d) {
    return (b ^ c ^ d) & M32;
}

uint32_t sha01_maj(uint32_t b, uint32_t c, uint32_t d) {
    return ((b & c) ^ (b & d) ^ (c & d)) & M32;
}

uint32_t sha01_f(int t, uint32_t b, uint32_t c, uint32_t d) {
    if (t < 20) return sha01_ch(b, c, d);
    if (t < 40) return sha01_parity(b, c, d);
    if (t < 60) return sha01_maj(b, c, d);
    return sha01_parity(b, c, d);
}

uint32_t sha01_kt(int t) {
    if (t < 20) return sha01_k[0];
    if (t < 40) return sha01_k[1];
    if (t < 60) return sha01_k[2];
    return sha01_k[3];
}

/* ------------------------------------------------------------------ */
/* Message expansion — the one place the two functions differ          */
/* ------------------------------------------------------------------ */

int sha01_expand(const uint32_t block_words[16], sha01_variant v, int rounds,
                 uint32_t W[SHA01_ROUNDS]) {
    int t;

    if (rounds < 16 || rounds > SHA01_ROUNDS) return -1;

    for (t = 0; t < 16; t++) W[t] = block_words[t] & M32;

    for (t = 16; t < rounds; t++) {
        uint32_t f = W[t - 3] ^ W[t - 8] ^ W[t - 14] ^ W[t - 16];
        /* ================================================================
         * THE ENTIRE DIFFERENCE BETWEEN SHA-0 AND SHA-1.
         *
         * sha01_rotl(f, 0) is f, so SHA-0 is the rotation by zero and SHA-1
         * the rotation by one. Written as one expression rather than as a
         * branch because the point of this directory is that the two
         * functions are separated by a single parameter.
         *
         * Without the rotation each bit position of W evolves under its own
         * copy of the recurrence x[t] = x[t-3]^x[t-8]^x[t-14]^x[t-16], with
         * no interaction between positions. The expansion is then thirty-two
         * independent instances of a [80,16] binary linear code, whose
         * minimum weight ../attack/expansion.c computes by enumerating all
         * 65536 codewords. The rotation couples the positions and destroys
         * exactly that. See sha-broken.pdf §3.
         * ================================================================ */
        W[t] = sha01_rotl(f, (unsigned)v);
    }
    for (; t < SHA01_ROUNDS; t++) W[t] = 0u;
    return 0;
}

/* ------------------------------------------------------------------ */
/* Compression                                                         */
/* ------------------------------------------------------------------ */

int sha01_compress_w(uint32_t h[5], const uint32_t W[SHA01_ROUNDS],
                     int rounds, sha01_trace *tr) {
    sha01_trace local;
    sha01_trace *s = tr ? tr : &local;
    uint32_t a, b, c, d, e;
    int t;

    /* Range checked, never clamped — ../../spec/SPEC.md §6.1. */
    if (rounds < 0 || rounds > SHA01_ROUNDS) return -1;
    s->rounds = rounds;

    for (t = 0; t < 5; t++) s->h_in[t] = h[t];
    for (t = 0; t < SHA01_ROUNDS; t++) s->W[t] = W[t];

    a = h[0]; b = h[1]; c = h[2]; d = h[3]; e = h[4];

    s->a[0] = a; s->b[0] = b; s->c[0] = c; s->d[0] = d; s->e[0] = e;

    for (t = 0; t < rounds; t++) {
        /* FIPS 180-1 §7:
         *   TEMP = ROTL5(a) + f(t,b,c,d) + e + W[t] + K[t]
         *   e = d; d = c; c = ROTL30(b); b = a; a = TEMP            */
        uint32_t temp = (sha01_rotl(a, 5) + sha01_f(t, b, c, d) + e + W[t]
                         + sha01_kt(t)) & M32;
        e = d;
        d = c;
        c = sha01_rotl(b, 30);
        b = a;
        a = temp;

        s->a[1 + t] = a; s->b[1 + t] = b; s->c[1 + t] = c;
        s->d[1 + t] = d; s->e[1 + t] = e;
    }

    h[0] = (h[0] + a) & M32;
    h[1] = (h[1] + b) & M32;
    h[2] = (h[2] + c) & M32;
    h[3] = (h[3] + d) & M32;
    h[4] = (h[4] + e) & M32;

    for (t = 0; t < 5; t++) s->h_out[t] = h[t];
    return 0;
}

int sha01_compress(uint32_t h[5], const unsigned char block[64],
                   sha01_variant v, int rounds, sha01_trace *tr) {
    uint32_t words[16];
    uint32_t W[SHA01_ROUNDS];
    int t;

    /* Big-endian by explicit shifts, so no host-endianness assumption and no
     * alignment-violating cast. */
    for (t = 0; t < 16; t++) {
        words[t] = ((uint32_t)block[4 * t + 0] << 24) |
                   ((uint32_t)block[4 * t + 1] << 16) |
                   ((uint32_t)block[4 * t + 2] << 8) |
                   ((uint32_t)block[4 * t + 3]);
    }
    /* The expansion needs at least sixteen rounds' worth of schedule; a
     * caller asking for fewer rounds still gets a well-defined schedule
     * because the first sixteen words are copied, not derived. */
    if (sha01_expand(words, v, rounds < 16 ? 16 : rounds, W) != 0) return -1;
    return sha01_compress_w(h, W, rounds, tr);
}

/* ------------------------------------------------------------------ */
/* Padding and hashing                                                 */
/* ------------------------------------------------------------------ */

/* Padding is FIPS 180 §4 and is identical in both functions: a 1 bit, then
 * zeros, then the message length in BITS as a 64-bit big-endian integer, to
 * a multiple of 512 bits. It is the same construction ../../spec/SPEC.md §5
 * describes for SHA-256, and it is injective for the same reason. */
int sha01_hash_ex(const unsigned char *msg, uint64_t len, sha01_variant v,
                  const uint32_t iv[5], int rounds,
                  unsigned char out[SHA01_DIGEST_BYTES]) {
    uint32_t h[5];
    unsigned char block[64];
    uint64_t nbits = len * 8u;
    uint64_t i, full = len / 64u;
    size_t rem = (size_t)(len % 64u);
    int j;

    if (rounds < 0 || rounds > SHA01_ROUNDS) return -1;

    for (j = 0; j < 5; j++) h[j] = iv[j];

    for (i = 0; i < full; i++) {
        if (sha01_compress(h, msg + i * 64u, v, rounds, NULL) != 0) return -1;
    }

    /* The tail: the remainder, the 0x80 byte, zeros, and the length. This
     * needs one block, or two when the remainder leaves no room for the
     * eight length bytes. */
    memset(block, 0, sizeof block);
    if (rem) memcpy(block, msg + full * 64u, rem);
    block[rem] = 0x80u;

    if (rem >= 56u) {
        if (sha01_compress(h, block, v, rounds, NULL) != 0) return -1;
        memset(block, 0, sizeof block);
    }

    for (j = 0; j < 8; j++) {
        block[56 + j] = (unsigned char)((nbits >> (8 * (7 - j))) & 0xFFu);
    }
    if (sha01_compress(h, block, v, rounds, NULL) != 0) return -1;

    for (j = 0; j < 5; j++) {
        out[4 * j + 0] = (unsigned char)((h[j] >> 24) & 0xFFu);
        out[4 * j + 1] = (unsigned char)((h[j] >> 16) & 0xFFu);
        out[4 * j + 2] = (unsigned char)((h[j] >> 8) & 0xFFu);
        out[4 * j + 3] = (unsigned char)(h[j] & 0xFFu);
    }

    memset(block, 0, sizeof block);
    memset(h, 0, sizeof h);
    return 0;
}

int sha01_hash(const unsigned char *msg, uint64_t len, sha01_variant v,
               unsigned char out[SHA01_DIGEST_BYTES]) {
    return sha01_hash_ex(msg, len, v, sha01_iv, SHA01_ROUNDS, out);
}
