/* Rounds-contract driver for c/shavar.c. See tests/rounds.sh.
 *
 * Prints `<rounds> <TAB> accepted|rejected <TAB> <digest|->` per row.
 * Marshalling only: every verdict comes from shavar_hash_ex. */
#include <stdio.h>
#include <string.h>

#include "shavar.h"

int main(int argc, char **argv) {
    char line[512];
    FILE *f;
    static const unsigned char msg[3] = {0x61, 0x62, 0x63};

    if (argc != 2) { fprintf(stderr, "usage: driver VECTORS.tsv\n"); return 2; }
    f = fopen(argv[1], "r");
    if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }

    while (fgets(line, sizeof line, f)) {
        long r;
        unsigned char digest[SHAVAR_DIGEST_BYTES];
        int i;

        if (line[0] == '#' || line[0] == '\n') continue;
        if (sscanf(line, "%ld", &r) != 1) continue;

        if (shavar_hash_ex(msg, 24, shavar_iv, (int)r, digest) != 0) {
            printf("%ld\trejected\t-\n", r);
        } else {
            printf("%ld\taccepted\t", r);
            for (i = 0; i < SHAVAR_DIGEST_BYTES; i++) printf("%02x", digest[i]);
            printf("\n");
        }
    }
    fclose(f);
    return 0;
}
