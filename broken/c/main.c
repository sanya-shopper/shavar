/* sha01 command-line driver.
 *
 *   sha01 hash  <sha0|sha1> <hex|->  [rounds]   digest of a hex byte string
 *   sha01 trace <sha0|sha1> <hex|->  [rounds]   every intermediate value
 *   sha01 selftest                              built-in known answers
 *
 * `-` is the empty message. `rounds` defaults to 80 and must be 0..80; out of
 * range is rejected, not clamped (../../spec/SPEC.md §6.1).
 *
 * The output shape follows ../../spec/CLI.md as closely as a 160-bit function
 * can: 40 lowercase hex digits and a newline for `hash`, tab-separated
 * `TAG<TAB>index<TAB>value` records for `trace`. It is deliberately not the
 * same contract, because these are not the same function and pretending
 * otherwise would let the SHA-256 harness try to cross-test them.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sha01.h"

#define MSGMAX (1u << 20)
static unsigned char g_msg[MSGMAX];

static int hexval(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* Decode hex into g_msg. Returns the byte count, or -1. */
static long decode_hex(const char *h) {
    size_t n, i;
    if (strcmp(h, "-") == 0) return 0;
    n = strlen(h);
    if (n % 2u != 0u) return -1;
    if (n / 2u > MSGMAX) return -1;
    for (i = 0; i < n; i += 2) {
        int hi = hexval((unsigned char)h[i]);
        int lo = hexval((unsigned char)h[i + 1]);
        if (hi < 0 || lo < 0) return -1;
        g_msg[i / 2] = (unsigned char)((hi << 4) | lo);
    }
    return (long)(n / 2u);
}

static int parse_variant(const char *s, sha01_variant *v) {
    if (strcmp(s, "sha0") == 0) { *v = SHA01_SHA0; return 0; }
    if (strcmp(s, "sha1") == 0) { *v = SHA01_SHA1; return 0; }
    return -1;
}

static int parse_rounds(const char *s, int *out) {
    char *end;
    long v;
    if (!s) { *out = SHA01_ROUNDS; return 0; }
    v = strtol(s, &end, 10);
    if (*end != '\0' || end == s) return -1;
    if (v < 0 || v > SHA01_ROUNDS) return -1;
    *out = (int)v;
    return 0;
}

static void print_digest(const unsigned char d[SHA01_DIGEST_BYTES]) {
    int i;
    for (i = 0; i < SHA01_DIGEST_BYTES; i++) printf("%02x", d[i]);
    printf("\n");
}

/* ---- known answers -------------------------------------------------------
 *
 * The SHA-1 entries are checkable against any SHA-1 in the world, and
 * ../tests/oracle.sh does exactly that against three of them.
 *
 * The SHA-0 entries cannot be: no SHA-0 exists on this machine or in any
 * current library, which is the practical consequence of its having been
 * withdrawn in 1995. They are the values published in the literature, and the
 * structural check in ../tests/oracle.sh is what actually pins them down —
 * setting the rotation to 1 must turn every SHA-0 answer below into the
 * SHA-1 answer beside it. A transcription error in one column would have to
 * be matched by a compensating error in the other to survive that. */
static const struct {
    const char *hex;
    const char *sha0;
    const char *sha1;
} KATS[] = {
    /* "" */
    {"-",
     "f96cea198ad1dd5617ac084a3d92c6107708c0ef",
     "da39a3ee5e6b4b0d3255bfef95601890afd80709"},
    /* "abc" */
    {"616263",
     "0164b8a914cd2a5e74c4f7ff082c4d97f1edf880",
     "a9993e364706816aba3e25717850c26c9cd0d89d"},
    /* "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq" — the
     * two-block vector from FIPS 180-1 Appendix B. */
    {"6162636462636465636465666465666765666768666768696768696a68696a6b"
     "696a6b6c6a6b6c6d6b6c6d6e6c6d6e6f6d6e6f706e6f7071",
     "d2516ee1acfa5baf33dfc1c471e438449ef134c8",
     "84983e441c3bd26ebaae4aa1f95129e5e54670f1"}
};

static int cmd_selftest(void) {
    unsigned char d[SHA01_DIGEST_BYTES];
    char got[2 * SHA01_DIGEST_BYTES + 1];
    size_t i;
    int j, fails = 0;

    for (i = 0; i < sizeof KATS / sizeof KATS[0]; i++) {
        long len = decode_hex(KATS[i].hex);
        int variant;
        if (len < 0) { printf("FAIL vector %u: bad hex\n", (unsigned)i); fails++; continue; }
        for (variant = 0; variant < 2; variant++) {
            const char *want = variant ? KATS[i].sha1 : KATS[i].sha0;
            if (sha01_hash(g_msg, (uint64_t)len,
                           variant ? SHA01_SHA1 : SHA01_SHA0, d) != 0) {
                printf("FAIL vector %u (%s): hash returned error\n",
                       (unsigned)i, variant ? "sha1" : "sha0");
                fails++;
                continue;
            }
            for (j = 0; j < SHA01_DIGEST_BYTES; j++)
                sprintf(got + 2 * j, "%02x", d[j]);
            if (strcmp(got, want) != 0) {
                printf("FAIL vector %u (%s)\n  want %s\n  got  %s\n",
                       (unsigned)i, variant ? "sha1" : "sha0", want, got);
                fails++;
            }
        }
    }

    /* The rotation really is the only difference: with it switched off, SHA-1
     * must reproduce SHA-0 exactly. This is checked here rather than only in
     * the shell tests so that `selftest` alone is meaningful. */
    {
        unsigned char d0[SHA01_DIGEST_BYTES], d1[SHA01_DIGEST_BYTES];
        long len = decode_hex("616263");
        if (len >= 0 &&
            sha01_hash(g_msg, (uint64_t)len, SHA01_SHA0, d0) == 0 &&
            sha01_hash(g_msg, (uint64_t)len, SHA01_SHA1, d1) == 0 &&
            memcmp(d0, d1, sizeof d0) == 0) {
            printf("FAIL: sha0 and sha1 agree, so the variant switch does nothing\n");
            fails++;
        }
    }

    if (fails == 0) {
        printf("ok %u\n", (unsigned)(sizeof KATS / sizeof KATS[0]) * 2u + 1u);
        return 0;
    }
    return 1;
}

static int cmd_hash(const char *vs, const char *hex, const char *rs) {
    sha01_variant v;
    unsigned char d[SHA01_DIGEST_BYTES];
    int rounds;
    long len;

    if (parse_variant(vs, &v) != 0) {
        fprintf(stderr, "sha01: variant must be sha0 or sha1, got '%s'\n", vs);
        return 2;
    }
    if (parse_rounds(rs, &rounds) != 0) {
        fprintf(stderr, "sha01: rounds must be 0..%d, got '%s'\n", SHA01_ROUNDS, rs);
        return 2;
    }
    len = decode_hex(hex);
    if (len < 0) {
        fprintf(stderr, "sha01: malformed hex, or message exceeds %u bytes\n", MSGMAX);
        return 2;
    }
    if (sha01_hash_ex(g_msg, (uint64_t)len, v, sha01_iv, rounds, d) != 0) {
        fprintf(stderr, "sha01: rounds must be 0..%d\n", SHA01_ROUNDS);
        return 2;
    }
    print_digest(d);
    return 0;
}

static int cmd_trace(const char *vs, const char *hex, const char *rs) {
    sha01_variant v;
    sha01_trace tr;
    uint32_t h[5];
    unsigned char block[64];
    int rounds, t;
    long len;

    if (parse_variant(vs, &v) != 0) {
        fprintf(stderr, "sha01: variant must be sha0 or sha1, got '%s'\n", vs);
        return 2;
    }
    if (parse_rounds(rs, &rounds) != 0) {
        fprintf(stderr, "sha01: rounds must be 0..%d, got '%s'\n", SHA01_ROUNDS, rs);
        return 2;
    }
    len = decode_hex(hex);
    if (len < 0 || len > 55) {
        fprintf(stderr, "sha01: trace takes a message that pads into one block "
                        "(at most 55 bytes)\n");
        return 2;
    }

    memset(block, 0, sizeof block);
    memcpy(block, g_msg, (size_t)len);
    block[len] = 0x80u;
    {
        uint64_t nbits = (uint64_t)len * 8u;
        int j;
        for (j = 0; j < 8; j++)
            block[56 + j] = (unsigned char)((nbits >> (8 * (7 - j))) & 0xFFu);
    }
    for (t = 0; t < 5; t++) h[t] = sha01_iv[t];
    if (sha01_compress(h, block, v, rounds, &tr) != 0) {
        fprintf(stderr, "sha01: rounds must be 0..%d\n", SHA01_ROUNDS);
        return 2;
    }

    for (t = 0; t < 5; t++) printf("HIN\t%d\t%08x\n", t, tr.h_in[t]);
    for (t = 0; t < SHA01_ROUNDS; t++) printf("W\t%d\t%08x\n", t, tr.W[t]);
    for (t = -1; t < tr.rounds; t++) printf("A\t%d\t%08x\n", t, sha01_a(&tr, t));
    for (t = -1; t < tr.rounds; t++) printf("B\t%d\t%08x\n", t, sha01_b(&tr, t));
    for (t = -1; t < tr.rounds; t++) printf("C\t%d\t%08x\n", t, sha01_c(&tr, t));
    for (t = -1; t < tr.rounds; t++) printf("D\t%d\t%08x\n", t, sha01_d(&tr, t));
    for (t = -1; t < tr.rounds; t++) printf("E\t%d\t%08x\n", t, sha01_e(&tr, t));
    for (t = 0; t < 5; t++) printf("HOUT\t%d\t%08x\n", t, tr.h_out[t]);
    return 0;
}

static void usage(void) {
    fputs("usage: sha01 hash  <sha0|sha1> <hex|-> [rounds]\n"
          "       sha01 trace <sha0|sha1> <hex|-> [rounds]\n"
          "       sha01 selftest\n",
          stderr);
}

int main(int argc, char **argv) {
    if (argc < 2) { usage(); return 2; }
    if (strcmp(argv[1], "hash") == 0 && argc >= 4) {
        return cmd_hash(argv[2], argv[3], argc >= 5 ? argv[4] : NULL);
    }
    if (strcmp(argv[1], "trace") == 0 && argc >= 4) {
        return cmd_trace(argv[2], argv[3], argc >= 5 ? argv[4] : NULL);
    }
    if (strcmp(argv[1], "selftest") == 0 && argc == 2) {
        return cmd_selftest();
    }
    usage();
    return 2;
}
