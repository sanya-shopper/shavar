#!/usr/bin/env python3
"""Rounds-contract driver for py/shavar.py. See tests/rounds.sh.

Prints `<rounds> <TAB> accepted|rejected <TAB> <digest|->` per row.
Marshalling only: every verdict comes from py/shavar.py.
"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "py"))
import shavar  # noqa: E402

for line in open(sys.argv[1]):
    if line.startswith("#") or not line.strip():
        continue
    r = int(line.split("\t")[0])
    try:
        print("%d\taccepted\t%s" % (r, shavar.hexdigest(b"abc", 24, rounds=r)))
    except shavar.ShavarError:
        print("%d\trejected\t-" % r)
