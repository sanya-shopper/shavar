/* collide — find real collisions in reduced-round SHA-0, and fail to find
 * them in SHA-1.
 *
 * WHAT THIS PRODUCES
 *
 * Two distinct 64-byte messages with the same R-round SHA-0 digest. Both are
 * exactly one block, so they pad identically, and a collision in the first
 * compression is therefore a collision of the whole hash — not merely of the
 * compression function.
 *
 * WHAT IT DOES NOT PRODUCE
 *
 * A collision in full 80-round SHA-0 or in SHA-1. Those cost about 2^39 and
 * 2^63 respectively (see ../sha-broken.pdf §6) and are not reachable on one
 * machine in a session. The point here is that the *mechanism* is the same
 * one that produced the historic results, run to the round count a laptop can
 * finish.
 *
 * HOW IT WORKS  (../sha-broken.pdf §4 has the long version)
 *
 * 1. A LOCAL COLLISION. Flip bit i of W[t]. That difference enters register a
 *    at round t; five later message words can be chosen to cancel it before
 *    it escapes. The correcting differences are at
 *
 *        W[t+1] bit i+5     (undoing ROTL5(a) in the next round)
 *        W[t+2] bit i       (undoing the difference now sitting in b)
 *        W[t+3] bit i+30    (b has become ROTL30(b), so the bit has moved)
 *        W[t+4] bit i+30
 *        W[t+5] bit i+30
 *
 *    The cancellation is exact only when the round function f absorbs the
 *    difference the right way, which is a condition on the state and holds
 *    with some probability. `collide verify` measures that probability rather
 *    than asserting it.
 *
 * 2. A DISTURBANCE VECTOR. The W differences are not free: W is expanded from
 *    the sixteen message words, so a difference pattern is usable only if it
 *    is itself an expansion of something. For SHA-0 the expansion is thirty-two
 *    independent copies of one GF(2) recurrence, so the usable patterns in a
 *    single bit column form a 65536-element code that `expansion code`
 *    enumerates outright. Pick a low-weight codeword whose disturbances all
 *    finish five rounds before the end.
 *
 * 3. SEARCH. Each disturbance costs a probability. Try random messages until
 *    all of the conditions happen to hold at once.
 *
 * Step 2 is what the ROTL1 of SHA-1 destroys, and `collide search --sha1`
 * shows the same machinery finding nothing.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "sha01.h"

/* ------------------------------------------------------------ utilities -- */

/* xorshift64*: a small, fast, self-contained PRNG. Not cryptographic, and it
 * does not need to be: it drives a search whose output is checked exactly. */
static uint64_t rng_state = 0x243F6A8885A308D3ull;
static uint32_t rnd32(void) {
    uint64_t x = rng_state;
    x ^= x >> 12; x ^= x << 25; x ^= x >> 27;
    rng_state = x;
    return (uint32_t)((x * 0x2545F4914F6CDD1Dull) >> 32);
}

static void codeword(unsigned seed, unsigned char c[SHA01_ROUNDS]) {
    int t;
    for (t = 0; t < 16; t++) c[t] = (unsigned char)((seed >> t) & 1u);
    for (t = 16; t < SHA01_ROUNDS; t++)
        c[t] = (unsigned char)(c[t - 3] ^ c[t - 8] ^ c[t - 14] ^ c[t - 16]);
}


/* A disturbance vector is only usable if its time shifts are usable too.
 *
 * Each local collision puts corrections 1..5 rounds after its disturbance, so
 * the message difference in a given bit column is a sum of time-shifted
 * copies of the disturbance vector. Every one of those copies has to be a
 * codeword in its own right, or the pattern is not something the expansion
 * can produce and the differential cannot be mounted at all.
 *
 * That is 1+2+3+4+5 = 15 extra linear conditions on a 16-dimensional space,
 * and it is not vacuous: it cuts the 65535 nonzero codewords down to 2047.
 * Leaving it out is what made the first version of this program report
 * "difference is a valid expansion: NO" for every round count. */
static int shifts_are_codewords(unsigned seed) {
    unsigned char c[SHA01_ROUNDS], sh[SHA01_ROUNDS];
    int k, t;
    codeword(seed, c);
    for (k = 1; k <= 5; k++) {
        for (t = 0; t < SHA01_ROUNDS; t++) sh[t] = (t >= k) ? c[t - k] : 0;
        for (t = 16; t < SHA01_ROUNDS; t++)
            if (sh[t] != (sh[t - 3] ^ sh[t - 8] ^ sh[t - 14] ^ sh[t - 16]))
                return 0;
    }
    return 1;
}

/* The six-word local-collision pattern for a disturbance at round d, bit i. */
static void add_local_collision(uint32_t dW[SHA01_ROUNDS], int d, int i, int R) {
    const int off[6] = {0, 5, 0, 30, 30, 30};
    int k;
    for (k = 0; k < 6; k++) {
        int t = d + k;
        if (t >= R) continue;
        dW[t] ^= 1u << ((unsigned)(i + off[k]) & 31u);
    }
}

/* ---------------------------------------------------------------- verify --
 *
 * Measure, empirically, how often one local collision actually cancels.
 * Nothing is assumed: random states are run forwards six rounds with and
 * without the disturbance pattern, and the two are compared.
 */
static int cmd_verify(void) {
    const int TRIALS = 200000;
    int start, i;

    printf("LOCAL COLLISION, MEASURED\n");
    printf("A disturbance at bit i of W[t], with the five corrections of\n");
    printf("sha-broken.pdf §4.1, cancels only if the round function absorbs\n");
    printf("it. This runs %d random states through six rounds and counts.\n\n",
           TRIALS);
    printf("  round f      i    P(cancels)   note\n");
    printf("  -----------  ---  ----------   ----------------------------\n");

    for (start = 0; start < 4; start++) {
        static const char *fname[4] = {"Ch    ", "Parity", "Maj   ", "Parity"};
        int base = start * 20 + 2;   /* clear of the range boundaries */
        for (i = 1; i <= 2; i++) {
            long ok = 0;
            int trial;
            for (trial = 0; trial < TRIALS; trial++) {
                uint32_t W1[SHA01_ROUNDS], W2[SHA01_ROUNDS];
                uint32_t h1[5], h2[5];
                sha01_trace t1, t2;
                int k, R = base + 6;

                for (k = 0; k < SHA01_ROUNDS; k++) { W1[k] = rnd32(); W2[k] = W1[k]; }
                for (k = 0; k < 5; k++) { h1[k] = rnd32(); h2[k] = h1[k]; }
                add_local_collision(W2, base, i, SHA01_ROUNDS);

                if (sha01_compress_w(h1, W1, R, &t1) != 0) return 1;
                if (sha01_compress_w(h2, W2, R, &t2) != 0) return 1;

                /* Cancelled iff the five registers agree after round base+5. */
                if (sha01_a(&t1, R - 1) == sha01_a(&t2, R - 1) &&
                    sha01_b(&t1, R - 1) == sha01_b(&t2, R - 1) &&
                    sha01_c(&t1, R - 1) == sha01_c(&t2, R - 1) &&
                    sha01_d(&t1, R - 1) == sha01_d(&t2, R - 1) &&
                    sha01_e(&t1, R - 1) == sha01_e(&t2, R - 1)) {
                    ok++;
                }
            }
            printf("  %2d-%2d %s  %2d   %.6f     %s\n",
                   start * 20, start * 20 + 19, fname[start], i,
                   (double)ok / TRIALS,
                   (start == 1 || start == 3)
                       ? "f is XOR: cheapest, but not free"
                       : "f is nonlinear: extra conditions");
        }
    }
    printf("\n  Two things the numbers say, neither of them folklore -- these\n");
    printf("  are measured, not asserted:\n\n");
    printf("  * The Parity rounds are about eight times cheaper than the Ch\n");
    printf("    and Maj rounds, so a disturbance vector wants its weight in\n");
    printf("    rounds 20-39 and 60-79. But they are NOT free, and the reason\n");
    printf("    is worth being precise about: f being XOR removes the\n");
    printf("    conditions on f, and what is left is the additions. The round\n");
    printf("    adds mod 2^32 while the differential is stated in XOR, so the\n");
    printf("    correction is exact only when no carry crosses the bit being\n");
    printf("    corrected. That residual is the ~2^-3 above.\n\n");
    printf("  * Bit 1 beats bit 2 by a factor of about eight, for the same\n");
    printf("    reason: the corrections sit at i+5 and i+30, and at i=1 the\n");
    printf("    i+30 corrections land at bit 31, where a carry out of the top\n");
    printf("    is discarded rather than propagating. This is why the\n");
    printf("    literature's disturbance vectors all use bit 1.\n");
    return 0;
}

/* ---------------------------------------------------------------- search --
 *
 * Build the message difference from a disturbance vector, then look for a
 * message pair for which every local collision happens to cancel.
 */
static int search(sha01_variant v, int R, unsigned seed, int bit,
                  double seconds, int quiet) {
    unsigned char c[SHA01_ROUNDS];
    uint32_t idealW[SHA01_ROUNDS], dM[16], checkW[SHA01_ROUNDS];
    int t, weight = 0, usable;
    clock_t t0;
    unsigned long tries = 0;

    codeword(seed, c);
    memset(idealW, 0, sizeof idealW);
    for (t = 0; t < R; t++) {
        if (c[t]) { add_local_collision(idealW, t, bit, R); weight++; }
    }

    /* The difference must itself be an expansion: W is derived from the first
     * sixteen words, so an arbitrary pattern is not reachable. Take the first
     * sixteen words of the ideal difference, expand them, and require the
     * result to match over the rounds the attack uses. This is the step that
     * silently fails for SHA-1. */
    for (t = 0; t < 16; t++) dM[t] = idealW[t];
    if (sha01_expand(dM, v, R < 16 ? 16 : R, checkW) != 0) return -1;
    usable = 1;
    for (t = 0; t < R; t++) if (checkW[t] != idealW[t]) { usable = 0; break; }

    if (!quiet) {
        printf("  variant        : %s\n", v == SHA01_SHA1 ? "SHA-1" : "SHA-0");
        printf("  rounds         : %d\n", R);
        printf("  disturbance    : seed %04x, weight %d, bit %d\n", seed, weight, bit);
        printf("  difference is a valid expansion: %s\n", usable ? "yes" : "NO");
    }
    if (!usable) {
        if (!quiet) {
            printf("\n  The differential cannot be mounted: the pattern the local\n");
            printf("  collisions require is not something the message expansion can\n");
            printf("  produce. For SHA-1 this is the normal outcome -- ROTL1 moves\n");
            printf("  every difference out of its column, so a pattern built from\n");
            printf("  column-wise local collisions is not in the image of the\n");
            printf("  expansion at all.\n");
        }
        return 0;
    }

    t0 = clock();
    for (;;) {
        uint32_t M[16], W1[SHA01_ROUNDS], W2[SHA01_ROUNDS];
        uint32_t h1[5], h2[5];
        int k;

        for (k = 0; k < 16; k++) M[k] = rnd32();
        for (k = 0; k < 5; k++) { h1[k] = sha01_iv[k]; h2[k] = sha01_iv[k]; }
        if (sha01_expand(M, v, R < 16 ? 16 : R, W1) != 0) return -1;
        {
            uint32_t M2[16];
            for (k = 0; k < 16; k++) M2[k] = M[k] ^ dM[k];
            if (sha01_expand(M2, v, R < 16 ? 16 : R, W2) != 0) return -1;
            if (sha01_compress_w(h1, W1, R, NULL) != 0) return -1;
            if (sha01_compress_w(h2, W2, R, NULL) != 0) return -1;
            tries++;

            if (memcmp(h1, h2, sizeof h1) == 0) {
                unsigned char b1[64], b2[64], d1[20], d2[20];
                int j;
                if (!quiet) {
                    printf("  tries          : %lu\n", tries);
                    printf("  elapsed        : %.2fs\n",
                           (double)(clock() - t0) / CLOCKS_PER_SEC);
                }
                for (k = 0; k < 16; k++) {
                    for (j = 0; j < 4; j++) {
                        b1[4 * k + j] = (unsigned char)((M[k] >> (8 * (3 - j))) & 0xFFu);
                        b2[4 * k + j] = (unsigned char)(((M[k] ^ dM[k]) >> (8 * (3 - j))) & 0xFFu);
                    }
                }
                /* The two messages are each exactly one block, so they pad
                 * identically and this is a collision of the whole hash. */
                if (sha01_hash_ex(b1, 64, v, sha01_iv, R, d1) != 0) return -1;
                if (sha01_hash_ex(b2, 64, v, sha01_iv, R, d2) != 0) return -1;

                printf("\n  COLLISION\n");
                printf("  m1     = "); for (k = 0; k < 64; k++) printf("%02x", b1[k]);
                printf("\n  m2     = "); for (k = 0; k < 64; k++) printf("%02x", b2[k]);
                printf("\n  m1 xor m2 is nonzero: %s\n",
                       memcmp(b1, b2, 64) ? "yes" : "NO -- messages are equal!");
                printf("  %s-%d(m1) = ", v == SHA01_SHA1 ? "SHA1" : "SHA0", R);
                for (k = 0; k < 20; k++) printf("%02x", d1[k]);
                printf("\n  %s-%d(m2) = ", v == SHA01_SHA1 ? "SHA1" : "SHA0", R);
                for (k = 0; k < 20; k++) printf("%02x", d2[k]);
                printf("\n  digests equal: %s\n",
                       memcmp(d1, d2, 20) == 0 ? "yes" : "NO");
                return (memcmp(b1, b2, 64) != 0 && memcmp(d1, d2, 20) == 0) ? 1 : -1;
            }
        }
        if ((tries & 0xFFFFu) == 0 &&
            (double)(clock() - t0) / CLOCKS_PER_SEC > seconds) {
            if (!quiet) printf("  gave up after %lu tries (%.0fs)\n", tries, seconds);
            return 0;
        }
    }
}

static int cmd_search(int argc, char **argv) {
    sha01_variant v = SHA01_SHA0;
    int R = 34, bit = 1, i;
    double seconds = 20.0;
    unsigned seed = 0;
    unsigned char c[SHA01_ROUNDS];

    for (i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--sha1") == 0) v = SHA01_SHA1;
        else if (strcmp(argv[i], "--sha0") == 0) v = SHA01_SHA0;
        else if (strcmp(argv[i], "--rounds") == 0 && i + 1 < argc) R = atoi(argv[++i]);
        else if (strcmp(argv[i], "--bit") == 0 && i + 1 < argc) bit = atoi(argv[++i]);
        else if (strcmp(argv[i], "--seconds") == 0 && i + 1 < argc) seconds = atof(argv[++i]);
        else if (strcmp(argv[i], "--seed") == 0 && i + 1 < argc)
            seed = (unsigned)strtoul(argv[++i], NULL, 16);
        else { fprintf(stderr, "collide: unknown option %s\n", argv[i]); return 2; }
    }
    if (R < 20 || R > SHA01_ROUNDS) {
        fprintf(stderr, "collide: rounds must be 20..80\n");
        return 2;
    }

    /* Choose the lowest-weight disturbance vector that finishes in time. */
    if (!seed) {
        int bw = SHA01_ROUNDS + 1;
        unsigned s;
        for (s = 1; s < 65536u; s++) {
            int w = 0, ok = 1, t;
            if (!shifts_are_codewords(s)) continue;
            codeword(s, c);
            for (t = R - 5; t < R; t++) if (c[t]) { ok = 0; break; }
            if (!ok) continue;
            for (t = 0; t < R; t++) w += c[t];
            if (w > 0 && w < bw) { bw = w; seed = s; }
        }
        if (!seed) { fprintf(stderr, "collide: no disturbance vector for R=%d\n", R); return 1; }
    }

    printf("COLLISION SEARCH\n");
    return search(v, R, seed, bit, seconds, 0) == 1 ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "verify") == 0) return cmd_verify();
    if (argc >= 2 && strcmp(argv[1], "search") == 0) return cmd_search(argc, argv);
    fprintf(stderr,
        "usage: collide verify\n"
        "       collide search [--sha0|--sha1] [--rounds R] [--bit i]\n"
        "                      [--seed hhhh] [--seconds N]\n");
    return 2;
}
