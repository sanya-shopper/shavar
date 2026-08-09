#!/usr/bin/env python3
"""Generate the cross-test message corpus.

Emits TSV rows `key <TAB> nbits <TAB> hex` on stdout, where `hex` is the
message encoded exactly as spec/CLI.md requires:

  * 2 * ceil(nbits/8) hex digits, lowercase;
  * `-` when the message occupies zero bytes;
  * when nbits % 8 != 0, the final byte holds its nbits % 8 significant bits in
    the HIGH-order positions and the remaining low-order bits are ZERO.

That last point is not cosmetic.  SPEC.md 5.1 requires implementations to
*reject* a final byte with nonzero trailing bits rather than mask them, so a
generator that forgot to clear them would produce a corpus that every correct
implementation refuses, and the harness would report a phantom disagreement.
The clearing happens in one place, `encode()`, and `--selfcheck` asserts it.

The corpus is a deterministic function of (seed, mode).  Print the seed, keep
the seed, and any failure replays exactly.

Phases
------
sweep    Structurally interesting bit lengths, exhaustively.  Every length
         0..600 covers the one-block/two-block padding boundary (a message of
         L bits needs L + 1 + 64 <= 512, so L <= 447 fits in one block and
         L = 448 does not) and the 512-bit block boundary itself.  Three
         further bands cover the 2-block boundary at 959/960 and the 3-block
         boundary at 1471/1472, which the 0..600 sweep cannot reach.
random   Random lengths and random content, up to several thousand bits, with
         a long tail so that multi-block messages are exercised too.
"""

import argparse
import random
import sys

# Padding boundaries worth hitting exactly, derived from SPEC.md 5:
# a message of L bits needs L + 1 + k + 64 == 0 (mod 512), so the last L that
# still fits in n blocks is 512*n - 65.
BOUNDARIES = []
for _n in range(1, 12):
    _last = 512 * _n - 65          # 447, 959, 1471, ...
    BOUNDARIES += [_last - 1, _last, _last + 1, 512 * _n - 1, 512 * _n, 512 * _n + 1]
BOUNDARIES += [0, 1, 2, 7, 8, 9, 15, 16, 17, 31, 32, 33, 63, 64, 65]
BOUNDARIES = sorted(set(b for b in BOUNDARIES if b >= 0))


def encode(nbits, rng):
    """Random message of exactly `nbits` bits, encoded per spec/CLI.md."""
    nbytes = (nbits + 7) // 8
    if nbytes == 0:
        return "-"
    buf = bytearray(rng.getrandbits(8) for _ in range(nbytes))
    rem = nbits % 8
    if rem:
        # Clear the (8 - rem) low-order bits of the final byte.  SPEC.md 5.1.
        buf[-1] &= (0xFF << (8 - rem)) & 0xFF
    return buf.hex()


def lengths(mode):
    if mode == "thorough":
        sweep = list(range(0, 601))
        sweep += list(range(940, 1041))
        sweep += list(range(1450, 1551))
        sweep += BOUNDARIES
        nrandom = 400
        maxbits = 5000
        ntail = 24
        tailmax = 24000
    elif mode == "fast":
        sweep = list(range(0, 601, 7))
        sweep += BOUNDARIES
        nrandom = 40
        maxbits = 3000
        ntail = 4
        tailmax = 8000
    else:
        raise SystemExit("gen_corpus: mode must be fast or thorough")
    return sorted(set(x for x in sweep if x >= 0)), nrandom, maxbits, ntail, tailmax


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", required=True)
    ap.add_argument("--mode", default="fast")
    ap.add_argument("--phase", required=True, choices=("sweep", "random"))
    ap.add_argument("--selfcheck", action="store_true")
    args = ap.parse_args()

    sweep, nrandom, maxbits, ntail, tailmax = lengths(args.mode)

    # Distinct streams per phase so that changing one phase's size does not
    # shift the other phase's messages.
    rng = random.Random("shavar/%s/%s/%s" % (args.seed, args.mode, args.phase))

    rows = []
    if args.phase == "sweep":
        for n in sweep:
            rows.append((n, encode(n, rng)))
    else:
        for _ in range(nrandom):
            n = rng.randrange(0, maxbits + 1)
            rows.append((n, encode(n, rng)))
        for _ in range(ntail):
            n = rng.randrange(maxbits, tailmax + 1)
            rows.append((n, encode(n, rng)))
        rows.sort(key=lambda r: r[0])

    out = sys.stdout
    for key, (n, hx) in enumerate(rows):
        if args.selfcheck:
            nbytes = 0 if hx == "-" else len(hx) // 2
            assert nbytes == (n + 7) // 8, (n, hx)
            if n % 8:
                assert bytes.fromhex(hx)[-1] & ((1 << (8 - n % 8)) - 1) == 0, (n, hx)
        out.write("%d\t%d\t%s\n" % (key, n, hx))


if __name__ == "__main__":
    main()
