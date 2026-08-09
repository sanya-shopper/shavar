/* shavar C command-line driver. Implements ../spec/CLI.md exactly.
 *
 * Kept separate from shavar.c so that the library object contains no I/O and
 * no global state, and so the static and shared libraries can be built from
 * shavar.c alone.
 *
 * Allocation policy: this driver, like the library, calls no allocator. The
 * message buffer is a single static array. That bounds the maximum message
 * (see MSGMAX) but makes the memory-safety story trivial to state and to
 * check: there is nothing to leak and nothing to double-free. */

#include "shavar.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MSGMAX (1u << 20) /* 1 MiB, enough for the million-'a' vector */

static unsigned char g_msg[MSGMAX];

/* ---- small helpers ------------------------------------------------- */

static int hexval(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* Decode `hex` into `out`. The literal "-" means an empty message.
 * Returns the byte count, or -1 on malformed input. */
static long unhex(const char *hex, unsigned char *out, size_t cap) {
    size_t n, i;
    if (strcmp(hex, "-") == 0) return 0;
    n = strlen(hex);
    if (n % 2u != 0u) return -1;
    if (n / 2u > cap) return -1;
    for (i = 0; i < n; i += 2) {
        int hi = hexval((unsigned char)hex[i]);
        int lo = hexval((unsigned char)hex[i + 1]);
        if (hi < 0 || lo < 0) return -1;
        out[i / 2] = (unsigned char)((hi << 4) | lo);
    }
    return (long)(n / 2u);
}

static void put_digest(const unsigned char d[32]) {
    int i;
    for (i = 0; i < 32; i++) printf("%02x", d[i]);
    putchar('\n');
}

/* Parse a decimal u64. Returns 0 on success. */
static int parse_u64(const char *s, uint64_t *out) {
    uint64_t v = 0;
    if (*s == '\0') return -1;
    for (; *s; s++) {
        if (*s < '0' || *s > '9') return -1;
        if (v > (UINT64_MAX - (uint64_t)(*s - '0')) / 10u) return -1; /* overflow */
        v = v * 10u + (uint64_t)(*s - '0');
    }
    *out = v;
    return 0;
}

/* Check that hex byte count and bit count agree: nbytes == ceil(nbits/8). */
static int lengths_agree(long nbytes, uint64_t nbits) {
    uint64_t need = nbits / 8u + ((nbits % 8u) ? 1u : 0u);
    return (uint64_t)nbytes == need;
}

/* ---- subcommands ---------------------------------------------------- */

static int cmd_hash(const char *hex, const char *bits, const char *roundstr) {
    unsigned char digest[32];
    uint64_t nbits;
    long nbytes;
    int rounds = SHAVAR_ROUNDS;

    if (parse_u64(bits, &nbits) != 0) {
        fprintf(stderr, "shavar: bad bit count '%s'\n", bits);
        return 2;
    }
    nbytes = unhex(hex, g_msg, MSGMAX);
    if (nbytes < 0) {
        fprintf(stderr, "shavar: malformed hex, or message exceeds %u bytes\n", MSGMAX);
        return 2;
    }
    if (!lengths_agree(nbytes, nbits)) {
        fprintf(stderr, "shavar: %ld hex bytes does not match %llu bits\n", nbytes,
                (unsigned long long)nbits);
        return 2;
    }
    if (roundstr) rounds = atoi(roundstr);

    if (shavar_hash_ex(g_msg, nbits, shavar_iv, rounds, digest) != 0) {
        fprintf(stderr, "shavar: nonzero trailing bits in final byte\n");
        return 2;
    }
    put_digest(digest);
    return 0;
}

static int cmd_trace(const char *hex, const char *bits, const char *idxstr,
                     const char *roundstr) {
    shavar_trace tr;
    unsigned char block[64];
    uint32_t h[8];
    uint64_t nbits, idx = 0, nblocks, i;
    long nbytes;
    int rounds = SHAVAR_ROUNDS, t;

    if (parse_u64(bits, &nbits) != 0) {
        fprintf(stderr, "shavar: bad bit count '%s'\n", bits);
        return 2;
    }
    nbytes = unhex(hex, g_msg, MSGMAX);
    if (nbytes < 0 || !lengths_agree(nbytes, nbits)) {
        fprintf(stderr, "shavar: malformed message\n");
        return 2;
    }
    if (idxstr && parse_u64(idxstr, &idx) != 0) {
        fprintf(stderr, "shavar: bad block index\n");
        return 2;
    }
    if (roundstr) rounds = atoi(roundstr);

    nblocks = shavar_padded_blocks(nbits);
    if (idx >= nblocks) {
        fprintf(stderr, "shavar: block %llu out of range (%llu blocks)\n",
                (unsigned long long)idx, (unsigned long long)nblocks);
        return 2;
    }

    /* Run the blocks before `idx` to obtain the chaining value entering it.
     * A trace of block 3 is meaningless without the state blocks 0-2 left
     * behind, so we cannot simply jump to the requested block. */
    for (t = 0; t < 8; t++) h[t] = shavar_iv[t];
    for (i = 0; i <= idx; i++) {
        if (shavar_padded_block(g_msg, nbits, i, block) != 0) {
            fprintf(stderr, "shavar: nonzero trailing bits in final byte\n");
            return 2;
        }
        shavar_compress(h, block, rounds, &tr);
    }

    for (t = 0; t < 8; t++) printf("HIN\t%d\t%08x\n", t, tr.h_in[t]);
    for (t = 0; t < SHAVAR_ROUNDS; t++) printf("W\t%d\t%08x\n", t, tr.W[t]);
    for (t = -4; t < tr.rounds; t++) printf("A\t%d\t%08x\n", t, shavar_A(&tr, t));
    for (t = -4; t < tr.rounds; t++) printf("E\t%d\t%08x\n", t, shavar_E(&tr, t));
    for (t = 0; t < tr.rounds; t++) printf("T1\t%d\t%08x\n", t, tr.T1[t]);
    for (t = 0; t < tr.rounds; t++) printf("T2\t%d\t%08x\n", t, tr.T2[t]);
    for (t = 0; t < 8; t++) printf("HOUT\t%d\t%08x\n", t, tr.h_out[t]);
    return 0;
}

/* Known-answer vectors. These are the classic FIPS 180-2 examples plus the
 * empty string; the bit-oriented vectors live in tests/ because they come
 * from the NIST CAVP set and are too numerous to inline. */
struct kat {
    const char *msg; /* NULL means "one million 'a' characters" */
    const char *want;
};

static const struct kat kats[] = {
    {"", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},
    {"abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"},
    {"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
     "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"},
    {"abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopq"
     "rlmnopqrsmnopqrstnopqrstu",
     "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"},
    {NULL, "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"},
};

static int cmd_selftest(void) {
    size_t i;
    int fails = 0;
    char got[65];

    for (i = 0; i < sizeof kats / sizeof kats[0]; i++) {
        unsigned char digest[32];
        uint64_t nbits;
        size_t len, j;

        if (kats[i].msg == NULL) {
            len = 1000000u;
            memset(g_msg, 'a', len);
        } else {
            len = strlen(kats[i].msg);
            memcpy(g_msg, kats[i].msg, len);
        }
        nbits = (uint64_t)len * 8u;

        if (shavar_hash(g_msg, nbits, digest) != 0) {
            printf("FAIL vector %u: hash returned error\n", (unsigned)i);
            fails++;
            continue;
        }
        for (j = 0; j < 32; j++) sprintf(got + 2 * j, "%02x", digest[j]);
        got[64] = '\0';

        if (strcmp(got, kats[i].want) != 0) {
            printf("FAIL vector %u\n  want %s\n  got  %s\n", (unsigned)i, kats[i].want, got);
            fails++;
        }
    }

    /* Padding arithmetic: block counts at the boundaries where it is easy to
     * be off by one. 447 bits still fits one block; 448 needs two. */
    {
        struct {
            uint64_t bits;
            uint64_t blocks;
        } pb[] = {{0, 1}, {1, 1}, {446, 1}, {447, 1}, {448, 2}, {511, 2}, {512, 2}, {959, 2},
                  {960, 3}};
        size_t n;
        for (n = 0; n < sizeof pb / sizeof pb[0]; n++) {
            uint64_t got_b = shavar_padded_blocks(pb[n].bits);
            if (got_b != pb[n].blocks) {
                printf("FAIL padding: %llu bits -> %llu blocks, want %llu\n",
                       (unsigned long long)pb[n].bits, (unsigned long long)got_b,
                       (unsigned long long)pb[n].blocks);
                fails++;
            }
        }
    }

    /* Trailing-bit rejection must actually reject. */
    {
        /* 0xb4 is 1011 0100: the top five bits are the message and the low
         * three are 100, which is nonzero and therefore illegal. Contrast
         * 0xb0 (1011 0000), which is the same five-bit message correctly
         * encoded and must be accepted. Both directions are checked, because
         * a validator that rejects everything would pass a one-sided test. */
        unsigned char bad[1] = {0xb4};
        unsigned char good[1] = {0xb0};
        unsigned char digest[32];
        if (shavar_hash(bad, 5, digest) == 0) {
            printf("FAIL: nonzero trailing bits were accepted\n");
            fails++;
        }
        if (shavar_hash(good, 5, digest) != 0) {
            printf("FAIL: valid 5-bit message was rejected\n");
            fails++;
        }
    }

    if (fails == 0) {
        printf("ok %u\n", (unsigned)(sizeof kats / sizeof kats[0]));
        return 0;
    }
    return 1;
}

static void usage(void) {
    fputs("usage: shavar hash  <hex|-> <nbits> [rounds]\n"
          "       shavar trace <hex|-> <nbits> [blockidx] [rounds]\n"
          "       shavar selftest\n",
          stderr);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        usage();
        return 2;
    }
    if (strcmp(argv[1], "hash") == 0 && argc >= 4) {
        return cmd_hash(argv[2], argv[3], argc >= 5 ? argv[4] : NULL);
    }
    if (strcmp(argv[1], "trace") == 0 && argc >= 4) {
        return cmd_trace(argv[2], argv[3], argc >= 5 ? argv[4] : NULL,
                         argc >= 6 ? argv[5] : NULL);
    }
    if (strcmp(argv[1], "selftest") == 0 && argc == 2) {
        return cmd_selftest();
    }
    usage();
    return 2;
}
