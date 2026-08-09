#!/usr/bin/env python3
"""Print the final summary table for a whole test run.

Reads the per-phase rows appended by compare.py to summary.tsv, together with
the discovery records, and answers the three questions the run has to answer
plainly:

    which implementations were tested,
    how many vectors each passed,
    which were skipped and why.

Columns:
    verified   digests that matched an authority -- a NIST CAVP expected value
               or an external oracle.  This is the number that means "checked
               against something outside this repository".
    agreed     digests with no authority available (sub-byte lengths outside
               the NIST files) where two or more implementations answered and
               all gave the same answer.  Real evidence, but weaker: it cannot
               catch a shared misreading of FIPS 180-4.
    lone       no authority, and only this implementation ran the row -- so
               nothing was compared.  Kept out of `agreed` deliberately: it is
               coverage of the input, not evidence of correctness.
    FAILED     disagreed with an authority.
    disputed   implementations disagreed among themselves with no authority to
               settle it.  Blame is not assigned by majority vote.
    error      no digest, malformed digest, or nonzero exit.
    skipped    not run for this row: subsampled away (slow implementations get
               a smaller budget), or the row is not byte-aligned and the column
               is a byte-only oracle.

Usage: summarize.py --work DIR [--phases-run "a b c"]
"""

import argparse
import collections
import os
import sys


def read_tsv(path):
    if not os.path.exists(path):
        return []
    with open(path) as fh:
        return [ln.rstrip("\n").split("\t") for ln in fh if ln.strip()]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", required=True)
    args = ap.parse_args()

    impls = collections.OrderedDict()
    for row in read_tsv(os.path.join(args.work, "impls.tsv")):
        if len(row) >= 3:
            impls[row[0]] = (row[1], row[2])
    oracles = collections.OrderedDict()
    for row in read_tsv(os.path.join(args.work, "oracles.tsv")):
        if len(row) >= 3:
            oracles[row[0]] = (row[1], row[2])

    agg = collections.defaultdict(collections.Counter)
    phases = []
    for row in read_tsv(os.path.join(args.work, "summary.tsv")):
        if len(row) != 11:
            continue
        phase, name, is_auth, p, a, f, d, e, s, o, lo = row
        if phase not in phases:
            phases.append(phase)
        c = agg[name]
        c["verified"] += int(p)
        c["agreed"] += int(a)
        c["failed"] += int(f)
        c["disputed"] += int(d)
        c["error"] += int(e)
        c["skipped"] += int(s)
        c["offered"] += int(o)
        c["lone"] += int(lo)
        if int(is_auth):
            c["authority"] = 1

    print()
    print("=" * 78)
    print("FINAL SUMMARY")
    print("=" * 78)
    print("phases run: %s" % (", ".join(phases) if phases else "(none)"))
    print()

    fmt = "  %-12s %-8s %9s %8s %7s %8s %9s %7s %8s"
    print(fmt % ("impl", "status", "verified", "agreed", "lone", "FAILED",
                 "disputed", "error", "skipped"))
    print("  " + "-" * 78)

    bad = 0
    tested = []
    skipped = []
    for name, (status, reason) in impls.items():
        c = agg.get(name)
        if status == "ok" and c:
            tested.append(name)
            print(fmt % (name, "ok", c["verified"], c["agreed"], c["lone"],
                         c["failed"], c["disputed"], c["error"], c["skipped"]))
            bad += c["failed"] + c["disputed"] + c["error"]
        elif status == "ok":
            tested.append(name)
            print(fmt % (name, "ok", 0, 0, 0, 0, 0, 0, 0))
        elif status == "broken":
            skipped.append((name, "BROKEN", reason))
            print(fmt % (name, "BROKEN", *(["-"] * 7)))
            bad += 1
        else:
            skipped.append((name, "absent", reason))
            print(fmt % (name, "absent", *(["-"] * 7)))

    print()
    print("  authorities — the yardsticks, not competitors.  'offered' is how")
    print("  many rows each supplied a ground-truth digest for.")
    print("  " + "-" * 74)
    afmt = "  %-12s %-8s %9s %8s %7s %8s %9s %7s %8s"
    print(afmt % ("authority", "status", "offered", "", "", "FAILED", "",
                  "error", "skipped"))
    for name, (status, desc) in list(oracles.items()) + \
            ([("NIST", ("ok", "tests/vectors"))] if agg.get("NIST") else []):
        c = agg.get(name)
        if status == "ok" and c:
            print(afmt % (name, "ok", c["offered"], "", "", c["failed"], "",
                          c["error"], c["skipped"]))
            bad += c["failed"] + c["error"]
        else:
            print(afmt % (name, status, "-", "", "", "-", "", "-", "-"))

    if skipped:
        print()
        print("  not tested, and why:")
        for name, status, reason in skipped:
            print("    %-6s %-7s %s" % (name, status, reason))

    print()
    print("  tested: %s" % (" ".join(tested) if tested else "(none)"))
    print("  NOTE ON WHAT 'verified' MEANS: only NIST vectors and the external")
    print("  oracles are authorities.  The oracles cannot hash a partial byte,")
    print("  so for sub-byte lengths outside the NIST bit-oriented files the")
    print("  evidence is the 'agreed' column -- mutual consistency, not proof.")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
