#!/usr/bin/env python3
"""Localise a disagreement between two `trace` outputs to a round and register.

Usage:
    tracediff.py REF_NAME REF_FILE OTHER_NAME OTHER_FILE [--context N]

A digest diff tells you that two implementations disagree.  A trace diff tells
you *where*: "pl diverges from c first at W[17]" points at one line of one
source file, and the distinction between a W divergence and an A divergence is
the distinction between a broken message schedule and a broken round function.

Ordering matters for that to be useful.  spec/CLI.md fixes the emission order
as HIN, W, A, E, T1, T2, HOUT, so a plain `diff` would report the first
differing *line*, which groups all 64 A values before the first T1 value and
would blame A[3] for a fault whose origin is T1[3].  This tool instead sorts
records into causal order -- for each round t, W[t] is computed first, then
T1[t] and T2[t], then A[t] and E[t] -- so the reported divergence is the
earliest quantity that actually went wrong.

It also validates the record shape itself (8 lowercase hex digits, tab
separated, the full index ranges from CLI.md), because a formatting deviation
is a contract violation in its own right and must not be silently tolerated
into looking like a value mismatch.
"""

import argparse
import re
import sys

LABELS = ("HIN", "W", "A", "E", "T1", "T2", "HOUT")

# Causal rank within one round.  W is the schedule (independent of the round
# function), then the two temporaries, then the two tracks they feed.
RANK = {"W": 0, "T1": 1, "T2": 2, "A": 3, "E": 4}

LINE_RE = re.compile(r"^(HIN|W|A|E|T1|T2|HOUT)\t(-?\d+)\t([0-9a-f]{8})$")


def parse(path, name):
    """Return (records, problems).  records maps (label, idx) -> hex8."""
    recs = {}
    problems = []
    try:
        with open(path) as fh:
            raw = fh.read()
    except OSError as e:
        return recs, ["%s: cannot read trace: %s" % (name, e)]
    if raw and not raw.endswith("\n"):
        problems.append("%s: trace does not end with a newline" % name)
    for lineno, line in enumerate(raw.split("\n"), 1):
        if line == "":
            continue
        m = LINE_RE.match(line)
        if not m:
            if len(problems) < 8:
                problems.append("%s: line %d does not match the CLI.md record "
                                "format `LABEL\\t<int>\\t<8 lowercase hex>`: %r"
                                % (name, lineno, line[:120]))
            continue
        label, idx, val = m.group(1), int(m.group(2)), m.group(3)
        if (label, idx) in recs and recs[(label, idx)] != val:
            problems.append("%s: duplicate record %s[%d] with differing values"
                            % (name, label, idx))
        recs[(label, idx)] = val
    return recs, problems


def expected_keys(rounds=64):
    keys = [("HIN", i) for i in range(8)]
    keys += [("W", t) for t in range(64)]
    keys += [("A", t) for t in range(-4, rounds)]
    keys += [("E", t) for t in range(-4, rounds)]
    keys += [("T1", t) for t in range(rounds)]
    keys += [("T2", t) for t in range(rounds)]
    keys += [("HOUT", i) for i in range(8)]
    return keys


def causal_order(keys):
    def sort_key(k):
        label, idx = k
        if label == "HIN":
            return (-2, 0, idx)
        if label == "HOUT":
            return (10 ** 6, 0, idx)
        return (idx, RANK[label], 0)
    return sorted(keys, key=sort_key)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ref_name")
    ap.add_argument("ref_file")
    ap.add_argument("other_name")
    ap.add_argument("other_file")
    ap.add_argument("--context", type=int, default=4)
    ap.add_argument("--rounds", type=int, default=64)
    args = ap.parse_args()

    a, pa = parse(args.ref_file, args.ref_name)
    b, pb = parse(args.other_file, args.other_name)

    problems = pa + pb
    rc = 0

    # Completeness against the contract.
    want = expected_keys(args.rounds)
    for recs, name in ((a, args.ref_name), (b, args.other_name)):
        missing = [k for k in want if k not in recs]
        extra = [k for k in recs if k not in set(want)]
        if missing:
            problems.append("%s: trace is missing %d required records, first: %s"
                            % (name, len(missing),
                               ", ".join("%s[%d]" % k for k in missing[:6])))
        if extra:
            problems.append("%s: trace has %d records outside the contract, first: %s"
                            % (name, len(extra),
                               ", ".join("%s[%d]" % k for k in sorted(extra)[:6])))

    common = [k for k in causal_order(set(a) & set(b))]
    diffs = [k for k in common if a[k] != b[k]]

    if problems:
        rc = 1
        for p in problems:
            print("    contract problem: %s" % p)

    if not diffs:
        if not problems:
            print("    %s == %s over %d trace records" % (args.other_name,
                                                          args.ref_name, len(common)))
        return rc

    first = diffs[0]
    print("    impl %s diverges from %s first at %s[%d]  (%s=%s, %s=%s)"
          % (args.other_name, args.ref_name, first[0], first[1],
             args.ref_name, a[first], args.other_name, b[first]))
    print("    %d of %d common records differ" % (len(diffs), len(common)))
    shown = 0
    for k in diffs[1:]:
        if shown >= args.context:
            break
        print("      then %s[%d]: %s=%s %s=%s"
              % (k[0], k[1], args.ref_name, a[k], args.other_name, b[k]))
        shown += 1
    if len(diffs) > shown + 1:
        print("      ... and %d more" % (len(diffs) - shown - 1))
    return 1


if __name__ == "__main__":
    sys.exit(main())
