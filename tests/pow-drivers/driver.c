/* PoW driver for c/shavar.c. See tests/pow.sh.
 *
 * Reads the vector file named on the command line and writes one
 * `id <TAB> met|unmet|invalid` line per vector. Marshalling only: every
 * decision comes from shavar_pow_check.
 *
 * The CWEB version in cweb/ is not run separately here: cweb/test_cweb.sh
 * already establishes that the tangled library is token-identical to c/, so a
 * second run of these vectors against it would test the same object twice. */
#include <stdio.h>
#include <string.h>

#include "shavar.h"

#define LINEMAX 512

static int hexbyte(const char *h, unsigned char *out) {
    unsigned v;
    if (sscanf(h, "%2x", &v) != 1) return -1;
    *out = (unsigned char)v;
    return 0;
}

int main(int argc, char **argv) {
    char line[LINEMAX];
    FILE *f;

    if (argc != 2) {
        fprintf(stderr, "usage: driver VECTORS.tsv\n");
        return 2;
    }
    f = fopen(argv[1], "r");
    if (!f) {
        fprintf(stderr, "cannot open %s\n", argv[1]);
        return 2;
    }

    while (fgets(line, sizeof line, f)) {
        char *id, *dhex, *nbhex, *save;
        unsigned char digest[SHAVAR_DIGEST_BYTES];
        unsigned long nbits;
        int i, verdict;

        if (line[0] == '#' || line[0] == '\n') continue;

        id = strtok_r(line, "\t", &save);
        dhex = strtok_r(NULL, "\t", &save);
        nbhex = strtok_r(NULL, "\t", &save);
        if (!id || !dhex || !nbhex) continue;

        for (i = 0; i < SHAVAR_DIGEST_BYTES; i++) {
            if (hexbyte(dhex + 2 * i, &digest[i]) != 0) {
                fprintf(stderr, "bad digest hex on line for %s\n", id);
                fclose(f);
                return 2;
            }
        }
        if (sscanf(nbhex, "%8lx", &nbits) != 1) {
            fprintf(stderr, "bad nbits hex for %s\n", id);
            fclose(f);
            return 2;
        }

        verdict = shavar_pow_check(digest, (uint32_t)nbits);
        printf("%s\t%s\n", id,
               verdict < 0 ? "invalid" : (verdict ? "met" : "unmet"));
    }
    fclose(f);
    return 0;
}
