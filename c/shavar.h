/* shavar — SHA-256 written as a two-dimensional order-4 recurrence.
 *
 * See ../spec/SPEC.md. This header is the reference API; the other six
 * implementations in this repository mirror its behaviour and are tested
 * against it round by round.
 *
 * Portable C99: no compiler extensions, no POSIX, no libraries beyond
 * <stdint.h>, <stddef.h> and <string.h>. Nothing here depends on the host's
 * endianness, word size, or signed-shift behaviour.
 */
#ifndef SHAVAR_H
#define SHAVAR_H

#include <stddef.h>
#include <stdint.h>

#define SHAVAR_ROUNDS 64 /* full SHA-256; reduce for cryptanalysis */
#define SHAVAR_DIGEST_BYTES 32
#define SHAVAR_BLOCK_BYTES 64

/* A complete record of one block's compression.
 *
 * The arrays are offset by 4 so that index [4 + t] holds element t of the
 * spec's sequence, and t may run from -4. Use the accessors below rather
 * than open-coding the +4, which is the obvious place to introduce an
 * off-by-one that the cross-tests would then have to find for you.
 *
 * 544 bytes of A/E history per block is deliberate: retaining the whole
 * trajectory is what makes the implementation usable for the differential
 * work described in SPEC.md §7, and it costs nothing worth saving. */
typedef struct {
    uint32_t A[4 + SHAVAR_ROUNDS]; /* A[-4 .. 63] */
    uint32_t E[4 + SHAVAR_ROUNDS]; /* E[-4 .. 63] */
    uint32_t W[SHAVAR_ROUNDS];     /* message schedule */
    uint32_t T1[SHAVAR_ROUNDS];
    uint32_t T2[SHAVAR_ROUNDS];
    uint32_t h_in[8];  /* chaining value entering this block  */
    uint32_t h_out[8]; /* chaining value leaving it           */
    int rounds;        /* rounds actually run (<= SHAVAR_ROUNDS) */
} shavar_trace;

/* t ranges over [-4, rounds). */
static inline uint32_t shavar_A(const shavar_trace *tr, int t) { return tr->A[4 + t]; }
static inline uint32_t shavar_E(const shavar_trace *tr, int t) { return tr->E[4 + t]; }

/* The FIPS 180-4 initial chaining value. */
extern const uint32_t shavar_iv[8];
extern const uint32_t shavar_k[64];

/* ---- the six round functions, exposed individually ----------------------
 *
 * Kept separate rather than inlined into one expression because SPEC.md §7.1
 * turns on which of them are GF(2)-linear: Sigma0/Sigma1/sigma0/sigma1 are,
 * Ch and Maj are not. Research code needs to substitute or instrument them
 * one at a time. */
uint32_t shavar_ch(uint32_t x, uint32_t y, uint32_t z);
uint32_t shavar_maj(uint32_t x, uint32_t y, uint32_t z);
uint32_t shavar_Sigma0(uint32_t x);
uint32_t shavar_Sigma1(uint32_t x);
uint32_t shavar_sigma0(uint32_t x);
uint32_t shavar_sigma1(uint32_t x);

/* ---- compression --------------------------------------------------------
 *
 * Compress one 64-byte block into h[0..7], recording everything into *tr
 * (which may be NULL if the trace is not wanted).
 *
 * `rounds` must be in 0..64 inclusive: 0 is legal and means feed-forward
 * only, 64 is SHA-256. Anything outside that range denotes no function at all
 * and is REJECTED — the return is -1 and nothing is written. It is not
 * clamped. Clamping would hand a caller who asked for 100 rounds a genuine
 * SHA-256 digest together with a success status, which is the failure mode
 * SPEC.md §6.1 exists to rule out.
 *
 * A reduced count, and an `h` that is any chaining value rather than
 * shavar_iv, are both unreachable through a normal hashing API and both
 * prerequisites for the free-start and reduced-round analyses that this
 * repository exists to support.
 *
 * Returns 0 on success, -1 if `rounds` is out of range. */
int shavar_compress(uint32_t h[8], const unsigned char block[64], int rounds,
                    shavar_trace *tr);

/* ---- hashing ------------------------------------------------------------
 *
 * Hash `nbits` bits of `msg`. `msg` must hold ceil(nbits/8) bytes; when
 * nbits is not a multiple of 8 the final byte carries its significant bits
 * in the HIGH-order positions and its low-order bits must be zero.
 *
 * Returns 0 on success, -1 if those trailing bits are nonzero. Rejecting
 * rather than masking is deliberate: masking would map two distinct inputs
 * to one digest and hide the caller's bug. See SPEC.md §5.1. */
int shavar_hash(const unsigned char *msg, uint64_t nbits,
                unsigned char out[SHAVAR_DIGEST_BYTES]);

/* As above, from a caller-chosen IV and round count. Returns -1 if `rounds`
 * is outside 0..64, on the same reasoning as shavar_compress above. */
int shavar_hash_ex(const unsigned char *msg, uint64_t nbits, const uint32_t iv[8],
                   int rounds, unsigned char out[SHAVAR_DIGEST_BYTES]);

/* Number of 512-bit blocks the padded message occupies. */
uint64_t shavar_padded_blocks(uint64_t nbits);

/* Write block number `idx` of the padded message into `out`. This is what
 * lets a caller walk the padded stream without materialising it. */
int shavar_padded_block(const unsigned char *msg, uint64_t nbits, uint64_t idx,
                        unsigned char out[64]);

/* ---- proof-of-work comparison (SPEC.md §10) -----------------------------
 *
 * `nbits` here is a compact *target* encoding — Bitcoin's nBits, a 23-bit
 * mantissa with an 8-bit exponent — and has nothing to do with the message
 * bit length called nbits elsewhere in this header. The spelling collision is
 * inherited from both conventions and is why this comment exists.
 *
 * shavar_pow_target decodes it into a 32-byte BIG-endian target: target[0] is
 * the most significant byte. Returns 0, or -1 if the encoding is negative,
 * overflows 256 bits, or denotes zero.
 *
 * shavar_pow_check returns 1 if the digest meets the target, 0 if it does
 * not, and -1 if `nbits` is invalid.
 *
 * THE BYTE ORDER, because it is the only thing here that is easy to get
 * wrong: the digest is read LITTLE-endian. digest[0] — the first byte the
 * hash function emitted — is the LEAST significant byte of the 256-bit value,
 * and digest[31] is the MOST significant. This is the reverse of the order
 * the bytes are written in, and it is why a Bitcoin block hash is displayed
 * reversed relative to the digest actually computed. The target array is the
 * other way round, most significant byte first. See SPEC.md §10.1.
 *
 * The comparison is `value <= target`, not `<`. */
int shavar_pow_target(uint32_t nbits, unsigned char target[SHAVAR_DIGEST_BYTES]);
int shavar_pow_check(const unsigned char digest[SHAVAR_DIGEST_BYTES], uint32_t nbits);

#endif /* SHAVAR_H */
