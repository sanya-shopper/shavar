/* sha01 — SHA-0 and SHA-1, in one file, because they are one function.
 *
 * SHA-0 is FIPS 180 (1993). SHA-1 is FIPS 180-1 (1995). They differ in
 * exactly one place: SHA-1 rotates the message-expansion feedback left by one
 * bit and SHA-0 does not. Everything else — the initial value, the round
 * constants, the five round functions, the 80 rounds, the padding — is
 * identical. See ../sha-broken.pdf §2.
 *
 * That single rotation is the subject of this directory. Without it the
 * expansion is thirty-two independent copies of one small linear recurrence,
 * which is what makes the collision attacks of 1998–2005 possible. With it
 * the bit positions are coupled and the same attack costs roughly 2^18 times
 * more work. Both functions are broken; SHA-0 is broken much harder.
 *
 * NOTHING HERE IS FOR PRODUCTION USE. Both functions are cryptographically
 * dead. This code exists to demonstrate how they died.
 *
 * Portable C99, in the style of ../../c/shavar.h: no compiler extensions, no
 * POSIX, no libraries beyond <stdint.h>/<stddef.h>/<string.h>, no allocation,
 * no global mutable state, and no dependence on host endianness.
 */
#ifndef SHA01_H
#define SHA01_H

#include <stddef.h>
#include <stdint.h>

#define SHA01_ROUNDS 80
#define SHA01_DIGEST_BYTES 20
#define SHA01_BLOCK_BYTES 64

/* Which of the two functions. The value is also the rotation amount applied
 * to the expansion feedback, which is the entire difference between them:
 * SHA-0 rotates by 0, SHA-1 by 1. */
typedef enum {
    SHA01_SHA0 = 0,
    SHA01_SHA1 = 1
} sha01_variant;

/* A complete record of one block's compression, in the style of
 * shavar_trace: the whole trajectory, so that a differential path can be
 * inspected round by round rather than inferred from the digest.
 *
 * The five registers are kept as `a[t]` for t in [-1, rounds); a[-1] is the
 * value entering round 0. SHA-1's state is genuinely five registers with a
 * rotation in the middle, so unlike SHA-256 it does not collapse to a pair of
 * clean recurrences — see sha-broken.pdf §2.2 for why. */
typedef struct {
    uint32_t W[SHA01_ROUNDS];      /* the expanded message schedule */
    uint32_t a[1 + SHA01_ROUNDS];  /* a[-1 .. rounds-1], offset by 1 */
    uint32_t b[1 + SHA01_ROUNDS];
    uint32_t c[1 + SHA01_ROUNDS];
    uint32_t d[1 + SHA01_ROUNDS];
    uint32_t e[1 + SHA01_ROUNDS];
    uint32_t h_in[5];
    uint32_t h_out[5];
    int rounds;
} sha01_trace;

/* t ranges over [-1, rounds). */
static inline uint32_t sha01_a(const sha01_trace *tr, int t) { return tr->a[1 + t]; }
static inline uint32_t sha01_b(const sha01_trace *tr, int t) { return tr->b[1 + t]; }
static inline uint32_t sha01_c(const sha01_trace *tr, int t) { return tr->c[1 + t]; }
static inline uint32_t sha01_d(const sha01_trace *tr, int t) { return tr->d[1 + t]; }
static inline uint32_t sha01_e(const sha01_trace *tr, int t) { return tr->e[1 + t]; }

/* The FIPS 180 initial chaining value, shared by both functions. */
extern const uint32_t sha01_iv[5];

/* The four round constants, one per twenty rounds. */
extern const uint32_t sha01_k[4];

/* Rotate left. Exposed because the attack code reasons about rotations
 * constantly and needs the same one the compression function uses. */
uint32_t sha01_rotl(uint32_t x, unsigned n);

/* The three round functions, by round index (SPEC of FIPS 180-1 §5):
 *   rounds  0..19   Ch(b,c,d)
 *   rounds 20..39   Parity(b,c,d) = b ^ c ^ d
 *   rounds 40..59   Maj(b,c,d)
 *   rounds 60..79   Parity(b,c,d)
 *
 * The two Parity ranges matter to the attack out of all proportion to their
 * simplicity: Parity is GF(2)-linear, so a local collision placed inside one
 * of those ranges corrects with probability 1 rather than probabilistically.
 * See sha-broken.pdf §4.2. */
uint32_t sha01_ch(uint32_t b, uint32_t c, uint32_t d);
uint32_t sha01_parity(uint32_t b, uint32_t c, uint32_t d);
uint32_t sha01_maj(uint32_t b, uint32_t c, uint32_t d);
uint32_t sha01_f(int t, uint32_t b, uint32_t c, uint32_t d);
uint32_t sha01_kt(int t);

/* ---- message expansion ---------------------------------------------------
 *
 * Expand the sixteen words of a block into `rounds` schedule words.
 *
 *   W[t] = W[t-3] ^ W[t-8] ^ W[t-14] ^ W[t-16]          (SHA-0)
 *   W[t] = ROTL1(W[t-3] ^ W[t-8] ^ W[t-14] ^ W[t-16])   (SHA-1)
 *
 * `rounds` must be in 16..80. Out of range is rejected, not clamped: see
 * ../../spec/SPEC.md §6.1, which this directory follows for the same reason.
 * Returns 0, or -1 if `rounds` is out of range. */
int sha01_expand(const uint32_t block_words[16], sha01_variant v, int rounds,
                 uint32_t W[SHA01_ROUNDS]);

/* ---- compression ---------------------------------------------------------
 *
 * Compress one 64-byte block into h[0..4]. `tr` may be NULL.
 *
 * `rounds` must be in 0..80. A reduced count is not SHA-0 or SHA-1; it is
 * what the collision search in ../attack/ actually breaks, and exposing it is
 * the whole reason this argument exists. Returns 0, or -1 if `rounds` is out
 * of range. */
int sha01_compress(uint32_t h[5], const unsigned char block[64],
                   sha01_variant v, int rounds, sha01_trace *tr);

/* As above, but from schedule words that the caller has already expanded.
 * The attack needs this: it constructs W directly from a differential path
 * and never has a block to expand. */
int sha01_compress_w(uint32_t h[5], const uint32_t W[SHA01_ROUNDS],
                     int rounds, sha01_trace *tr);

/* ---- hashing -------------------------------------------------------------
 *
 * Hash `len` BYTES. Unlike ../../c/shavar.h this takes a byte count, not a
 * bit count: FIPS 180 defines both functions on bit strings, but every attack
 * in the literature and every tool in the world works on whole bytes, and the
 * sub-byte machinery would be carried here only to go unused.
 *
 * Returns 0, or -1 if `rounds` is out of range. */
int sha01_hash(const unsigned char *msg, uint64_t len, sha01_variant v,
               unsigned char out[SHA01_DIGEST_BYTES]);

int sha01_hash_ex(const unsigned char *msg, uint64_t len, sha01_variant v,
                  const uint32_t iv[5], int rounds,
                  unsigned char out[SHA01_DIGEST_BYTES]);

#endif /* SHA01_H */
