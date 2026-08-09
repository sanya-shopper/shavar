/* shavar — SHA-256 as a two-dimensional order-4 recurrence.
 *
 * Reference implementation. See ../spec/SPEC.md for the mathematics and
 * ../spec/CLI.md for the command-line contract.
 *
 * PORTABILITY STANCE
 * ------------------
 * Strict C99. No compiler extensions, no POSIX, no libraries beyond
 * <stdint.h>/<stddef.h>/<string.h>. Specifically:
 *
 *   - No dependence on host endianness. Every conversion between bytes and
 *     32-bit words is written out as explicit shifts of individual bytes, so
 *     the code behaves identically on big- and little-endian machines. This
 *     is why you will not see a cast of `unsigned char *` to `uint32_t *`
 *     anywhere; that cast would be both endian-dependent and an alignment
 *     violation.
 *   - No dependence on signed-integer behaviour. Everything is unsigned, so
 *     there is no overflow undefined behaviour: unsigned arithmetic wraps by
 *     definition in C, which is exactly the mod-2^32 semantics we want.
 *   - No dynamic allocation of any kind. There is not one malloc in this
 *     file. All state is caller-provided or automatic. That makes the leak
 *     question trivially answerable and lets the library be used from an
 *     interrupt handler or a freestanding environment.
 *   - No global mutable state, so the library is reentrant and thread-safe
 *     without any locking.
 */

#include "shavar.h"

#include <string.h>

/* ------------------------------------------------------------------ */
/* Constants (SPEC.md §9)                                             */
/* ------------------------------------------------------------------ */

const uint32_t shavar_iv[8] = {0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
                               0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u};

const uint32_t shavar_k[64] = {
    0x428a2f98u, 0x71374491u, 0xb5c0fbcfu, 0xe9b5dba5u, 0x3956c25bu, 0x59f111f1u,
    0x923f82a4u, 0xab1c5ed5u, 0xd807aa98u, 0x12835b01u, 0x243185beu, 0x550c7dc3u,
    0x72be5d74u, 0x80deb1feu, 0x9bdc06a7u, 0xc19bf174u, 0xe49b69c1u, 0xefbe4786u,
    0x0fc19dc6u, 0x240ca1ccu, 0x2de92c6fu, 0x4a7484aau, 0x5cb0a9dcu, 0x76f988dau,
    0x983e5152u, 0xa831c66du, 0xb00327c8u, 0xbf597fc7u, 0xc6e00bf3u, 0xd5a79147u,
    0x06ca6351u, 0x14292967u, 0x27b70a85u, 0x2e1b2138u, 0x4d2c6dfcu, 0x53380d13u,
    0x650a7354u, 0x766a0abbu, 0x81c2c92eu, 0x92722c85u, 0xa2bfe8a1u, 0xa81a664bu,
    0xc24b8b70u, 0xc76c51a3u, 0xd192e819u, 0xd6990624u, 0xf40e3585u, 0x106aa070u,
    0x19a4c116u, 0x1e376c08u, 0x2748774cu, 0x34b0bcb5u, 0x391c0cb3u, 0x4ed8aa4au,
    0x5b9cca4fu, 0x682e6ff3u, 0x748f82eeu, 0x78a5636fu, 0x84c87814u, 0x8cc70208u,
    0x90befffau, 0xa4506cebu, 0xbef9a3f7u, 0xc67178f2u};

/* ------------------------------------------------------------------ */
/* Word primitives                                                     */
/* ------------------------------------------------------------------ */

#define M32 0xFFFFFFFFu

/* Rotate right.
 *
 * Two defensive details that matter for strict portability:
 *
 *  1. `x << (32 - n)` is undefined when n == 0, because a shift by the full
 *     width of the type is UB in C. None of SHA-256's rotation amounts are
 *     zero, but writing the guard costs nothing and means the helper is
 *     correct in isolation rather than only correct for the callers we
 *     happen to have.
 *  2. The `& M32` looks redundant when uint32_t is `unsigned int`. It is not
 *     redundant in general: on a hypothetical platform with 64-bit `int`,
 *     uint32_t would be promoted to signed `int` by the integer promotions,
 *     and the left shift could then set bits above position 31. Masking
 *     pins the result to 32 bits regardless of how the promotions land. */
static uint32_t rotr(uint32_t x, unsigned n) {
    n &= 31u;
    if (n == 0u) return x;
    /* The low n bits are masked off before being shifted up, so no bit is
     * ever shifted out of the top of the word.
     *
     * This is not needed for correctness. C99 6.5.7p4 defines left shift of
     * an unsigned type as reduction modulo 2^32, so the classic idiom
     * `(x >> n) | (x << (32 - n))` is perfectly well defined and this code
     * has no undefined behaviour either way. But UBSan's
     * `unsigned-shift-base` check flags *any* left shift that discards bits
     * as suspicious, and a rotation discards bits by design — so the classic
     * idiom produces a permanent false positive that would have to be
     * suppressed. Masking first means the entire sanitizer matrix runs clean
     * with no suppressions and no exclusions to explain away.
     *
     * Verified: at -O2 clang compiles this to the same single `ror`
     * instruction as the classic idiom, so it costs nothing. */
    return ((x >> n) | ((x & ((1u << n) - 1u)) << (32u - n))) & M32;
}

static uint32_t shr(uint32_t x, unsigned n) { return (x >> n) & M32; }

/* The six round functions of SPEC.md §1.1.
 *
 * These are deliberately NOT static and NOT fused into the round body. The
 * research use in SPEC.md §7.1 turns on which of them are GF(2)-linear —
 * the four sigmas are, Ch and Maj are not — and instrumenting or replacing
 * them one at a time requires that they exist as separate, callable,
 * externally visible functions. Performance is not the goal here; the
 * compiler inlines them at -O2 anyway. */
uint32_t shavar_ch(uint32_t x, uint32_t y, uint32_t z) {
    return ((x & y) ^ (~x & z)) & M32;
}

uint32_t shavar_maj(uint32_t x, uint32_t y, uint32_t z) {
    return ((x & y) ^ (x & z) ^ (y & z)) & M32;
}

uint32_t shavar_Sigma0(uint32_t x) { return rotr(x, 2) ^ rotr(x, 13) ^ rotr(x, 22); }
uint32_t shavar_Sigma1(uint32_t x) { return rotr(x, 6) ^ rotr(x, 11) ^ rotr(x, 25); }
uint32_t shavar_sigma0(uint32_t x) { return rotr(x, 7) ^ rotr(x, 18) ^ shr(x, 3); }
uint32_t shavar_sigma1(uint32_t x) { return rotr(x, 17) ^ rotr(x, 19) ^ shr(x, 10); }

/* ------------------------------------------------------------------ */
/* Compression (SPEC.md §3, §4)                                        */
/* ------------------------------------------------------------------ */

void shavar_compress(uint32_t h[8], const unsigned char block[64], int rounds,
                     shavar_trace *tr) {
    /* Local trace. If the caller did not want one we still build it, because
     * the 2D form needs the A and E histories anyway — the "trace" and the
     * "state" are the same object in this formulation. That is a real
     * consequence of the reformulation: in the 8-register form you would
     * keep 8 words and pay extra to record history, whereas here the history
     * IS the state and recording it is free. */
    shavar_trace local;
    shavar_trace *s = tr ? tr : &local;

    int t;

    if (rounds < 0) rounds = 0;
    if (rounds > SHAVAR_ROUNDS) rounds = SHAVAR_ROUNDS;
    s->rounds = rounds;

    for (t = 0; t < 8; t++) s->h_in[t] = h[t];

    /* --- message schedule: the order-16 recurrence of SPEC.md §4 ------ */

    /* First sixteen words come straight from the block, big-endian.
     * Written as explicit byte shifts for the endianness reason above. */
    for (t = 0; t < 16; t++) {
        s->W[t] = ((uint32_t)block[4 * t + 0] << 24) | ((uint32_t)block[4 * t + 1] << 16) |
                  ((uint32_t)block[4 * t + 2] << 8) | ((uint32_t)block[4 * t + 3]);
    }
    /* The remaining 48 are generated. Note this always runs to 64 even for a
     * reduced-round compression: the schedule is defined independently of
     * how many rounds consume it, and CLI.md requires all 64 be reported. */
    for (t = 16; t < SHAVAR_ROUNDS; t++) {
        s->W[t] = (shavar_sigma1(s->W[t - 2]) + s->W[t - 7] + shavar_sigma0(s->W[t - 15]) +
                   s->W[t - 16]) &
                  M32;
    }

    /* --- seed the two tracks ------------------------------------------
     *
     * A[-1..-4] = H[0..3] and E[-1..-4] = H[4..7]. Note the reversal: the
     * more negative the index, the later the H. This is the window
     * correspondence a=A[t-1], b=A[t-2], c=A[t-3], d=A[t-4] read at t=0. */
    s->A[4 - 1] = h[0];
    s->A[4 - 2] = h[1];
    s->A[4 - 3] = h[2];
    s->A[4 - 4] = h[3];
    s->E[4 - 1] = h[4];
    s->E[4 - 2] = h[5];
    s->E[4 - 3] = h[6];
    s->E[4 - 4] = h[7];

    /* --- the recurrence ------------------------------------------------
     *
     * This is the whole compression function. Compare SPEC.md §3; the four
     * lines below are a transcription of the four lines there, and there is
     * no register shuffle because there are no registers to shuffle. */
    for (t = 0; t < rounds; t++) {
        uint32_t *A = s->A + 4; /* so A[t-4] is legal C for t >= 0 */
        uint32_t *E = s->E + 4;

        uint32_t t1 = (E[t - 4] + shavar_Sigma1(E[t - 1]) +
                       shavar_ch(E[t - 1], E[t - 2], E[t - 3]) + shavar_k[t] + s->W[t]) &
                      M32;
        uint32_t t2 = (shavar_Sigma0(A[t - 1]) + shavar_maj(A[t - 1], A[t - 2], A[t - 3])) & M32;

        E[t] = (A[t - 4] + t1) & M32;
        A[t] = (t1 + t2) & M32;

        s->T1[t] = t1;
        s->T2[t] = t2;
    }

    /* --- feed-forward --------------------------------------------------
     *
     * The final window of each track, added into the incoming chaining
     * value. When rounds < 64 the window is the last four computed values,
     * which for rounds < 4 reaches back into the seeds — handled correctly
     * because the seeds live in the same array at negative indices. */
    {
        uint32_t *A = s->A + 4;
        uint32_t *E = s->E + 4;
        int r = rounds;
        h[0] = (h[0] + A[r - 1]) & M32;
        h[1] = (h[1] + A[r - 2]) & M32;
        h[2] = (h[2] + A[r - 3]) & M32;
        h[3] = (h[3] + A[r - 4]) & M32;
        h[4] = (h[4] + E[r - 1]) & M32;
        h[5] = (h[5] + E[r - 2]) & M32;
        h[6] = (h[6] + E[r - 3]) & M32;
        h[7] = (h[7] + E[r - 4]) & M32;
    }

    for (t = 0; t < 8; t++) s->h_out[t] = h[t];
}

/* ------------------------------------------------------------------ */
/* Padding (SPEC.md §5)                                                */
/* ------------------------------------------------------------------ */

uint64_t shavar_padded_blocks(uint64_t nbits) {
    /* Smallest multiple of 512 that is at least nbits + 1 + 64.
     *
     * Computed as quotient-plus-remainder rather than (nbits + 576) / 512
     * because the latter overflows for nbits near UINT64_MAX. The bit length
     * is allowed to be any 64-bit value, so the arithmetic has to survive
     * the top of the range even though no real message gets there. */
    uint64_t q = nbits / 512u;
    uint64_t r = nbits % 512u; /* r < 512, so r + 576 < 1088: no overflow */
    return q + (r + 576u) / 512u;
}

int shavar_padded_block(const unsigned char *msg, uint64_t nbits, uint64_t idx,
                        unsigned char out[64]) {
    uint64_t nblocks = shavar_padded_blocks(nbits);
    uint64_t full_bytes = nbits / 8u;   /* wholly-message bytes */
    unsigned partial = (unsigned)(nbits % 8u); /* significant bits in the next byte */
    uint64_t base;                      /* index of this block's first byte */
    uint64_t last_base;                 /* first byte of the length field */
    int j;

    if (idx >= nblocks) return -1;

    /* Reject a final byte whose unused low bits are nonzero. See SPEC.md
     * §5.1: masking silently would map two different inputs to one digest. */
    if (partial != 0u) {
        unsigned char junk = (unsigned char)(msg[full_bytes] & (0xFFu >> partial));
        if (junk != 0u) return -1;
    }

    base = idx * 64u;
    last_base = nblocks * 64u - 8u;

    for (j = 0; j < 64; j++) {
        uint64_t gb = base + (uint64_t)j; /* global byte index in the padded stream */
        unsigned char v;

        if (gb >= last_base) {
            /* 64-bit big-endian bit length in the final eight bytes. */
            unsigned shift = (unsigned)(8u * (7u - (gb - last_base)));
            v = (unsigned char)((nbits >> shift) & 0xFFu);
        } else if (gb < full_bytes) {
            v = msg[gb];
        } else if (gb == full_bytes) {
            /* The byte where the message ends and the '1' bit begins.
             * If partial == 0 the message ended on a byte boundary and this
             * byte is purely the padding bit: 0x80. Otherwise the message
             * supplies the top `partial` bits and the '1' goes immediately
             * below them. The low bits were checked to be zero above, so an
             * OR is enough and no masking is needed. */
            v = partial ? (unsigned char)(msg[gb] | (0x80u >> partial)) : (unsigned char)0x80u;
        } else {
            v = 0u;
        }
        out[j] = v;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* Hashing                                                             */
/* ------------------------------------------------------------------ */

int shavar_hash_ex(const unsigned char *msg, uint64_t nbits, const uint32_t iv[8], int rounds,
                   unsigned char out[SHAVAR_DIGEST_BYTES]) {
    uint32_t h[8];
    unsigned char block[64];
    uint64_t nblocks = shavar_padded_blocks(nbits);
    uint64_t i;
    int j;

    for (j = 0; j < 8; j++) h[j] = iv[j];

    for (i = 0; i < nblocks; i++) {
        if (shavar_padded_block(msg, nbits, i, block) != 0) return -1;
        shavar_compress(h, block, rounds, NULL);
    }

    /* Serialise big-endian, again by explicit shifts. */
    for (j = 0; j < 8; j++) {
        out[4 * j + 0] = (unsigned char)((h[j] >> 24) & 0xFFu);
        out[4 * j + 1] = (unsigned char)((h[j] >> 16) & 0xFFu);
        out[4 * j + 2] = (unsigned char)((h[j] >> 8) & 0xFFu);
        out[4 * j + 3] = (unsigned char)(h[j] & 0xFFu);
    }

    /* Scrub the working state. Not a security guarantee — the compiler is
     * permitted to elide a memset to a dead object, and a hash of public
     * data does not need it — but it keeps the sanitizer runs honest about
     * what remains live, and costs nothing on a 64-byte buffer. */
    memset(block, 0, sizeof block);
    memset(h, 0, sizeof h);
    return 0;
}

int shavar_hash(const unsigned char *msg, uint64_t nbits, unsigned char out[SHAVAR_DIGEST_BYTES]) {
    return shavar_hash_ex(msg, nbits, shavar_iv, SHAVAR_ROUNDS, out);
}

/* ------------------------------------------------------------------ */
/* Proof-of-work comparison (SPEC.md §10)                              */
/* ------------------------------------------------------------------ */

int shavar_pow_target(uint32_t nbits, unsigned char target[SHAVAR_DIGEST_BYTES]) {
    uint32_t exponent = nbits >> 24;
    uint32_t mantissa = nbits & 0x007FFFFFu;
    int shift; /* byte offset of the mantissa's low byte from the LSB end */
    int i;

    /* The sign bit. A target is an unsigned magnitude, so this is an error
     * rather than something to mask off. A zero mantissa means a zero target,
     * which the final test rejects anyway, hence the mantissa != 0 guard —
     * it matches Bitcoin's SetCompact exactly. */
    if (mantissa != 0u && (nbits & 0x00800000u) != 0u) return -1;

    /* Does not fit in 256 bits. Same three-way test as SetCompact. */
    if (mantissa != 0u &&
        (exponent > 34u || (mantissa > 0xFFu && exponent > 33u) ||
         (mantissa > 0xFFFFu && exponent > 32u))) {
        return -1;
    }

    for (i = 0; i < SHAVAR_DIGEST_BYTES; i++) target[i] = 0u;

    if (exponent <= 3u) {
        /* Mantissa shifts down and may vanish entirely. Done as a value shift
         * because the result is small enough to hold in the low bytes. */
        uint32_t v = mantissa >> (8u * (3u - exponent));
        target[31] = (unsigned char)(v & 0xFFu);
        target[30] = (unsigned char)((v >> 8) & 0xFFu);
        target[29] = (unsigned char)((v >> 16) & 0xFFu);
    } else {
        /* target = mantissa << 8*(exponent-3). No bignum: place the three
         * mantissa bytes directly. `shift` is a byte offset from the least
         * significant end, so big-endian index 31 - shift holds the low byte.
         * The overflow test above guarantees every nonzero byte lands at a
         * non-negative index. */
        shift = (int)exponent - 3;
        if (31 - shift >= 0) target[31 - shift] = (unsigned char)(mantissa & 0xFFu);
        if (30 - shift >= 0) target[30 - shift] = (unsigned char)((mantissa >> 8) & 0xFFu);
        if (29 - shift >= 0) target[29 - shift] = (unsigned char)((mantissa >> 16) & 0xFFu);
    }

    /* A zero target is unsatisfiable, so treat it as a malformed request
     * rather than answering "no" to every digest. */
    for (i = 0; i < SHAVAR_DIGEST_BYTES; i++) {
        if (target[i] != 0u) return 0;
    }
    return -1;
}

int shavar_pow_check(const unsigned char digest[SHAVAR_DIGEST_BYTES], uint32_t nbits) {
    unsigned char target[SHAVAR_DIGEST_BYTES];
    int i;

    if (shavar_pow_target(nbits, target) != 0) return -1;

    /* SPEC.md §10.4. The digest is read LITTLE-endian: digest[0] is its least
     * significant byte, so the most significant byte is digest[31] and the
     * scan runs backwards through it. The target array is already big-endian.
     *
     * `digest[31 - i]` is the whole convention. Writing `digest[i]` here is
     * the classic byte-order bug: it compiles, it runs, and it is wrong. */
    for (i = 0; i < SHAVAR_DIGEST_BYTES; i++) {
        unsigned char a = digest[SHAVAR_DIGEST_BYTES - 1 - i];
        unsigned char b = target[i];
        if (a < b) return 1;
        if (a > b) return 0;
    }
    return 1; /* every byte equal: value == target, and the relation is <= */
}
