/* expansion — why SHA-0's message expansion is the weak part.
 *
 * Both functions expand sixteen words into eighty by the same recurrence,
 * and in both the expansion is LINEAR over GF(2): the expansion of an XOR
 * difference is the XOR difference of the expansions. That is what lets an
 * attacker reason about differences at all.
 *
 * The difference between the two is what the linearity is *over*.
 *
 *   SHA-0   W[t] = W[t-3] ^ W[t-8] ^ W[t-14] ^ W[t-16]
 *
 *           No bit ever moves between positions. Bit 7 of every W depends
 *           only on bit 7 of earlier Ws. The expansion is therefore thirty-two
 *           independent, identical copies of one scalar recurrence over GF(2),
 *           and the set of possible expanded differences in a single bit
 *           position is a [80,16] binary linear code with 65536 codewords —
 *           small enough to enumerate exhaustively, which is what this program
 *           does.
 *
 *   SHA-1   W[t] = ROTL1(W[t-3] ^ W[t-8] ^ W[t-14] ^ W[t-16])
 *
 *           The rotation carries bit i into position i+1 on every step, so the
 *           thirty-two copies are stitched into one recurrence on 512 bits.
 *           A difference cannot stay in its column.
 *
 * Subcommands:
 *   spread     expand a one-bit input difference and count where it goes
 *   code       enumerate the SHA-0 expansion code and report minimum weights
 *   dv R       the best disturbance vector usable for an R-round attack
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sha01.h"

/* ---------------------------------------------------------------- spread --
 *
 * Expansion is linear, so to see what happens to a difference we simply
 * expand the difference itself. A single set bit goes in; this counts how
 * many bits come out, round by round.
 */
static int cmd_spread(void) {
    uint32_t in[16];
    int v, t;

    printf("A ONE-BIT INPUT DIFFERENCE, EXPANDED\n");
    printf("Difference is bit 1 of W[0] and nothing else. Because the\n");
    printf("expansion is GF(2)-linear, expanding the difference IS the\n");
    printf("difference of the expansions.\n\n");
    printf("           SHA-0                     SHA-1\n");
    printf("  t   popcount  columns touched   popcount  columns touched\n");
    printf("  --  --------  ---------------   --------  ---------------\n");

    {
        uint32_t colmask[2] = {0u, 0u};
        long total[2] = {0, 0};
        uint32_t Ws[2][SHA01_ROUNDS];

        for (v = 0; v < 2; v++) {
            memset(in, 0, sizeof in);
            in[0] = 1u << 1;
            if (sha01_expand(in, v ? SHA01_SHA1 : SHA01_SHA0, SHA01_ROUNDS,
                             Ws[v]) != 0) {
                fprintf(stderr, "expand failed\n");
                return 1;
            }
        }
        for (t = 0; t < SHA01_ROUNDS; t++) {
            int pc[2];
            for (v = 0; v < 2; v++) {
                uint32_t x = Ws[v][t];
                int n = 0;
                while (x) { n += (int)(x & 1u); x >>= 1; }
                pc[v] = n;
                total[v] += n;
                colmask[v] |= Ws[v][t];
            }
            /* Print the first sixteen rounds (the copied words) and then
             * every fourth, so the table stays readable. */
            if (t < 20 || t % 8 == 0 || t == SHA01_ROUNDS - 1) {
                int nc[2];
                for (v = 0; v < 2; v++) {
                    uint32_t x = colmask[v];
                    int n = 0;
                    while (x) { n += (int)(x & 1u); x >>= 1; }
                    nc[v] = n;
                }
                printf("  %2d  %8d  %15d   %8d  %15d\n",
                       t, pc[0], nc[0], pc[1], nc[1]);
            }
        }
        printf("\n");
        for (v = 0; v < 2; v++) {
            uint32_t x = colmask[v];
            int n = 0;
            while (x) { n += (int)(x & 1u); x >>= 1; }
            printf("  %-5s total difference bits over 80 rounds: %4ld\n",
                   v ? "SHA-1" : "SHA-0", total[v]);
            printf("        distinct bit positions ever touched: %4d  (mask %08x)\n",
                   n, colmask[v]);
        }
        printf("\n");
        printf("  SHA-0 keeps the difference in the single column it started\n");
        printf("  in. SHA-1 spreads it across the word. An attacker choosing a\n");
        printf("  difference pattern for SHA-0 therefore works in a 2^16 space\n");
        printf("  per column; for SHA-1 the columns cannot be treated apart.\n");
    }
    return 0;
}

/* ------------------------------------------------------------------ code --
 *
 * The scalar recurrence, one bit position of SHA-0's expansion. A codeword is
 * determined by its first sixteen bits, so there are exactly 65536 of them.
 */
static void codeword(unsigned seed, unsigned char c[SHA01_ROUNDS]) {
    int t;
    for (t = 0; t < 16; t++) c[t] = (unsigned char)((seed >> t) & 1u);
    for (t = 16; t < SHA01_ROUNDS; t++)
        c[t] = (unsigned char)(c[t - 3] ^ c[t - 8] ^ c[t - 14] ^ c[t - 16]);
}

static int weight_range(const unsigned char c[SHA01_ROUNDS], int lo, int hi) {
    int t, n = 0;
    for (t = lo; t < hi; t++) n += c[t];
    return n;
}

static int cmd_code(void) {
    unsigned char c[SHA01_ROUNDS];
    unsigned seed;
    int best_w = SHA01_ROUNDS + 1;
    unsigned best_seed = 0;

    printf("THE SHA-0 EXPANSION CODE\n");
    printf("Each bit position of SHA-0's expansion is an independent copy of\n");
    printf("  x[t] = x[t-3] ^ x[t-8] ^ x[t-14] ^ x[t-16]\n");
    printf("so the possible difference patterns in one column form a [80,16]\n");
    printf("binary linear code. All 65536 codewords are enumerated below.\n\n");

    for (seed = 1; seed < 65536u; seed++) {
        int w;
        codeword(seed, c);
        w = weight_range(c, 0, SHA01_ROUNDS);
        if (w < best_w) { best_w = w; best_seed = seed; }
    }
    printf("  minimum weight over all 80 rounds : %d   (from W[0..15] = %04x)\n",
           best_w, best_seed);
    printf("  codewords enumerated              : 65535 (all but zero)\n\n");

    printf("A low-weight codeword is what an attacker wants: its weight is the\n");
    printf("number of local collisions that have to be paid for, and each one\n");
    printf("costs a probability. The full-80-round minimum above is the reason\n");
    printf("SHA-0 fell to 2^51 work in 2004 and then to 2^39 in 2005.\n\n");

    printf("Minimum weight of a codeword whose disturbances all fit inside an\n");
    printf("R-round attack -- support confined to rounds [0, R-6), so that the\n");
    printf("five correcting rounds of every local collision also fit:\n\n");
    printf("     R    min weight   seed\n");
    printf("   ----   ----------   ----\n");
    {
        int R;
        for (R = 20; R <= SHA01_ROUNDS; R += 5) {
            int bw = SHA01_ROUNDS + 1;
            unsigned bs = 0;
            for (seed = 1; seed < 65536u; seed++) {
                int w, ok = 1, t;
                codeword(seed, c);
                for (t = R - 5; t < R; t++)
                    if (c[t]) { ok = 0; break; }
                if (!ok) continue;
                w = weight_range(c, 0, R);
                if (w > 0 && w < bw) { bw = w; bs = seed; }
            }
            if (bs) printf("   %4d   %10d   %04x\n", R, bw, bs);
            else    printf("   %4d   %10s   %4s\n", R, "none", "-");
        }
    }
    printf("\n  The last five rounds must be free of disturbances: a local\n");
    printf("  collision started at round t is not finished until t+5, so a\n");
    printf("  disturbance any later than R-6 cannot be corrected before the\n");
    printf("  block ends and leaves a difference in the output.\n");
    return 0;
}

/* -------------------------------------------------------------------- dv --
 *
 * Print the disturbance vector chosen for an R-round attack, in the form the
 * collision search consumes.
 */
static int cmd_dv(int R) {
    unsigned char c[SHA01_ROUNDS];
    unsigned seed, best_seed = 0;
    int best_w = SHA01_ROUNDS + 1, t;

    if (R < 20 || R > SHA01_ROUNDS) {
        fprintf(stderr, "dv: R must be 20..80\n");
        return 2;
    }
    for (seed = 1; seed < 65536u; seed++) {
        int w, ok = 1;
        codeword(seed, c);
        for (t = R - 5; t < R; t++) if (c[t]) { ok = 0; break; }
        if (!ok) continue;
        w = weight_range(c, 0, R);
        if (w > 0 && w < best_w) { best_w = w; best_seed = seed; }
    }
    if (!best_seed) {
        printf("no usable disturbance vector for R = %d\n", R);
        return 1;
    }
    codeword(best_seed, c);
    printf("R = %d   seed = %04x   weight = %d\n", R, best_seed, best_w);
    printf("disturbance rounds:");
    for (t = 0; t < R; t++) if (c[t]) printf(" %d", t);
    printf("\n");
    return 0;
}

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "spread") == 0) return cmd_spread();
    if (argc >= 2 && strcmp(argv[1], "code") == 0) return cmd_code();
    if (argc >= 3 && strcmp(argv[1], "dv") == 0) return cmd_dv(atoi(argv[2]));
    fprintf(stderr, "usage: expansion spread | code | dv R\n");
    return 2;
}
