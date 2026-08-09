#!/usr/bin/env python3
"""Differential propagation through the SHA-256 compression function.

Takes two messages, runs the `trace` subcommand of any implementation on
each, and reports how their difference evolves round by round:

    dW[t] = W[t] ^ W'[t]        dA[t] = A[t] ^ A'[t]        dE[t] = E[t] ^ E'[t]

together with the Hamming weight of each, and the modular differences
A[t] - A'[t] (mod 2^32), which is how signed-difference paths are stated in
the literature and which diverges from the XOR difference exactly where
carries fire (spec/SPEC.md 7.3).

WHY THIS LIVES OUTSIDE THE IMPLEMENTATIONS
------------------------------------------
It works against ALL SEVEN implementations without any of them containing a
line of code for it, because spec/CLI.md fixes the trace format. That is the
payoff of having made the contract rigid: an analysis written once runs
everywhere, and if two implementations disagreed about a difference, that
would show up as a disagreement in the traces they emit rather than as a
disagreement between seven bespoke analysis routines.

This is tooling, not an implementation, so it uses the Python standard
library freely. The "core language only" rule constrains the seven
implementations under test.

USAGE
    research/avalanche.py <hexA> <hexB> <nbits> [--impl c] [--rounds 64]
                          [--block 0] [--bits] [--modular]

    # flip one bit of "abc" and watch it spread
    research/avalanche.py 616263 616261 24
"""

import argparse
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

JSC = ("/System/Library/Frameworks/JavaScriptCore.framework"
       "/Versions/A/Helpers/jsc")

# How to invoke each implementation. Same table as the test harness uses.
IMPLS = {
    "c":    ["./c/shavar"],
    "py":   ["python3", "py/shavar.py"],
    "pl":   ["perl", "pl/shavar.pl"],
    "scm":  ["chibi-scheme", "scm/shavar.scm"],
    "js":   ["./js/shavar-cli.js"],
    "sh":   ["bash", "sh/shavar.sh"],
    "lean": ["./lean/.lake/build/bin/shavar"],
}


def run_trace(impl, hexmsg, nbits, block, rounds):
    """Return {('A', 17): 0xdeadbeef, ...} parsed from a trace."""
    cmd = IMPLS[impl] + ["trace", hexmsg, str(nbits), str(block), str(rounds)]
    p = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"{impl} trace failed (exit {p.returncode}): {p.stderr.strip()}")
    out = {}
    for line in p.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            sys.exit(f"{impl}: malformed trace record: {line!r}")
        kind, idx, val = parts
        out[(kind, int(idx))] = int(val, 16)
    return out


def popcount(x):
    # Python 3.9 has no int.bit_count(), and this file targets the system
    # interpreter for the same reason py/shavar.py does.
    return bin(x).count("1")


def bar(weight, width=32, full=32):
    """A fixed-width bar. Same glyph scale everywhere so rounds compare."""
    n = 0 if full == 0 else int(round(weight * width / full))
    return "#" * n + "." * (width - n)


def main():
    ap = argparse.ArgumentParser(
        description="XOR/modular difference propagation, round by round.")
    ap.add_argument("hexa", help="first message, hex bytes or '-'")
    ap.add_argument("hexb", help="second message, hex bytes or '-'")
    ap.add_argument("nbits", type=int, help="bit length of BOTH messages")
    ap.add_argument("--impl", default="c", choices=sorted(IMPLS),
                    help="which implementation to trace through (default: c)")
    ap.add_argument("--rounds", type=int, default=64)
    ap.add_argument("--block", type=int, default=0)
    ap.add_argument("--bits", action="store_true",
                    help="show the 32-bit difference patterns, not just weights")
    ap.add_argument("--modular", action="store_true",
                    help="also show A-A' and E-E' mod 2^32")
    args = ap.parse_args()

    if not 0 <= args.rounds <= 64:
        sys.exit("rounds must be 0..64")

    ta = run_trace(args.impl, args.hexa, args.nbits, args.block, args.rounds)
    tb = run_trace(args.impl, args.hexb, args.nbits, args.block, args.rounds)

    print(f"# implementation : {args.impl}")
    print(f"# messages       : {args.hexa}  vs  {args.hexb}   ({args.nbits} bits)")
    print(f"# block {args.block}, {args.rounds} rounds\n")

    # Input difference, for context: how much difference we started with.
    dw_in = [ta[("W", t)] ^ tb[("W", t)] for t in range(16)]
    print(f"input difference: {sum(popcount(d) for d in dw_in)} bit(s) "
          f"across the 16 message words")

    dh = [ta[("HIN", i)] ^ tb[("HIN", i)] for i in range(8)]
    if any(dh):
        print(f"chaining-value difference: {sum(popcount(d) for d in dh)} bit(s)")
    print()

    hdr = f"{'t':>3}  {'|dW|':>4} {'|dA|':>4} {'|dE|':>4}   {'dA weight':<32}"
    print(hdr)
    print("-" * len(hdr))

    for t in range(args.rounds):
        dw = ta[("W", t)] ^ tb[("W", t)]
        da = ta[("A", t)] ^ tb[("A", t)]
        de = ta[("E", t)] ^ tb[("E", t)]
        print(f"{t:>3}  {popcount(dw):>4} {popcount(da):>4} {popcount(de):>4}   "
              f"{bar(popcount(da))}")
        if args.bits:
            print(f"      dW {dw:032b}")
            print(f"      dA {da:032b}")
            print(f"      dE {de:032b}")
        if args.modular:
            ma = (ta[("A", t)] - tb[("A", t)]) & 0xFFFFFFFF
            me = (ta[("E", t)] - tb[("E", t)]) & 0xFFFFFFFF
            # A signed reading: values near 2^32 are small negatives.
            sa = ma - (1 << 32) if ma > (1 << 31) else ma
            se = me - (1 << 32) if me > (1 << 31) else me
            print(f"      A-A' = {sa:+d}   E-E' = {se:+d}")

    dout = [ta[("HOUT", i)] ^ tb[("HOUT", i)] for i in range(8)]
    total = sum(popcount(d) for d in dout)
    print()
    print("output chaining value difference:")
    print("  " + " ".join(f"{d:08x}" for d in dout))
    print(f"  {total} of 256 bits differ "
          f"({100.0 * total / 256:.1f}%; a random pair would average 50%)")

    # A one-line honesty note, because a low weight late in the trace is the
    # interesting case and it is easy to over-read a single pair.
    if args.rounds == 64 and total:
        print("\nnote: one message pair is an observation, not a distinguisher.")


if __name__ == "__main__":
    main()
