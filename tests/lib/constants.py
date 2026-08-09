#!/usr/bin/env python3
"""Recompute the SHA-256 constants from first principles and check them.

spec/SPEC.md 9 states that tests/ recomputes H and K from the primes rather
than trusting the transcription in the specification, on the grounds that a
mistyped constant is the classic way one of several implementations ends up
subtly different from the others.  This is that recomputation.

H[0..7] are the first 32 bits of the fractional parts of the square roots of
the first eight primes; K[0..63] are the first 32 bits of the fractional parts
of the cube roots of the first sixty-four primes.  Both are computed here with
exact integer arithmetic -- no floating point, whose 53-bit mantissa is enough
for these particular values but would be an unnecessary thing to have to argue
about.

Three things are then checked:

  1. the recomputed values against the tables printed in spec/SPEC.md, so a
     typo in the normative document itself is caught;
  2. the recomputed H against the HIN records of each implementation's
     `trace` output for block 0 of the empty message, which is by definition
     the FIPS initial chaining value -- this tests the constant as the
     implementation actually holds it;
  3. nothing about K directly, because K is not separately observable through
     the CLI; a mistyped K[t] shows up as a trace divergence at T1[t], which
     tests/crosstest.sh reports precisely.

Usage:
    constants.py --spec spec/SPEC.md [--hin FILE ...]
where each --hin FILE is `name=path-to-a-trace-output`.
"""

import argparse
import re
import sys


def nth_primes(n):
    primes, cand = [], 2
    while len(primes) < n:
        if all(cand % p for p in primes if p * p <= cand):
            primes.append(cand)
        cand += 1
    return primes


def frac_root(p, root, bits=32):
    """First `bits` bits of the fractional part of p ** (1/root), exactly.

    Find the integer r with r**root <= p * 2**(root*bits) < (r+1)**root; then
    r mod 2**bits is the answer, since floor(p**(1/root) * 2**bits) = r.
    """
    target = p << (root * bits)
    lo, hi = 0, 1 << (bits + 8)
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if mid ** root <= target:
            lo = mid
        else:
            hi = mid - 1
    return lo & ((1 << bits) - 1)


def compute():
    primes = nth_primes(64)
    h = [frac_root(p, 2) for p in primes[:8]]
    k = [frac_root(p, 3) for p in primes]
    return h, k


def scrape_spec(path):
    """Pull the H and K tables out of spec/SPEC.md section 9."""
    text = open(path).read()
    tail = text.split("## 9. Constants", 1)
    if len(tail) < 2:
        return None, None
    tail = tail[1]
    blocks = re.findall(r"```\n(.*?)```", tail, re.S)
    words = [re.findall(r"\b[0-9a-f]{8}\b", b) for b in blocks]
    h = next((w for w in words if len(w) == 8), None)
    k = next((w for w in words if len(w) == 64), None)
    return h, k


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--spec")
    ap.add_argument("--hin", action="append", default=[])
    args = ap.parse_args()

    h, k = compute()
    print("  recomputed H[0..7] from sqrt of the first 8 primes:")
    print("    " + " ".join("%08x" % x for x in h))
    print("  recomputed K[0..63] from cbrt of the first 64 primes: "
          "%08x ... %08x" % (k[0], k[63]))

    rc = 0
    if args.spec:
        sh, sk = scrape_spec(args.spec)
        if sh is None or sk is None:
            print("  FAIL could not find the constant tables in %s" % args.spec)
            rc = 1
        else:
            got = ["%08x" % x for x in h]
            if got != sh:
                print("  FAIL spec/SPEC.md H table disagrees with recomputation")
                for i, (a, b) in enumerate(zip(got, sh)):
                    if a != b:
                        print("       H[%d]: computed %s, spec says %s" % (i, a, b))
                rc = 1
            else:
                print("  ok   spec/SPEC.md H[0..7] matches the recomputation")
            got = ["%08x" % x for x in k]
            if got != sk:
                print("  FAIL spec/SPEC.md K table disagrees with recomputation")
                for i, (a, b) in enumerate(zip(got, sk)):
                    if a != b:
                        print("       K[%d]: computed %s, spec says %s" % (i, a, b))
                rc = 1
            else:
                print("  ok   spec/SPEC.md K[0..63] matches the recomputation")

    for spec in args.hin:
        name, _, path = spec.partition("=")
        try:
            body = open(path).read()
        except OSError as e:
            print("  FAIL %-5s cannot read trace: %s" % (name, e))
            rc = 1
            continue
        hin = {}
        for line in body.split("\n"):
            f = line.split("\t")
            if len(f) == 3 and f[0] == "HIN":
                hin[int(f[1])] = f[2]
        got = [hin.get(i) for i in range(8)]
        want = ["%08x" % x for x in h]
        if got == want:
            print("  ok   %-5s initial chaining value matches (HIN of block 0)" % name)
        else:
            print("  FAIL %-5s initial chaining value is wrong" % name)
            for i in range(8):
                if got[i] != want[i]:
                    print("       H[%d]: expected %s, impl reports %s"
                          % (i, want[i], got[i]))
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
