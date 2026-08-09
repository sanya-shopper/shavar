#!/usr/bin/env python3
"""PoW driver for py/shavar.py. See tests/pow.sh.

Reads the vector file named on the command line and writes one
`id <TAB> met|unmet|invalid` line per vector to stdout. It is a marshalling
shim only: every decision comes from py/shavar.py.
"""
import os
import sys

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "py"))
import shavar  # noqa: E402


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: driver.py VECTORS.tsv\n")
        return 2
    with open(argv[1]) as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            vid, dhex, nbhex = line.rstrip("\n").split("\t")[:3]
            digest = bytes.fromhex(dhex)
            nbits = int(nbhex, 16)
            try:
                verdict = "met" if shavar.pow_check(digest, nbits) else "unmet"
            except shavar.ShavarError:
                verdict = "invalid"
            sys.stdout.write("%s\t%s\n" % (vid, verdict))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
