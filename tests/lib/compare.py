#!/usr/bin/env python3
"""Compare digest columns produced by implementations, oracles and NIST.

Usage:
    compare.py --phase NAME --inputs INPUTS.tsv
               --col name=RESULTS.tsv [--col ...]
               [--authority name[,name...]]
               [--summary SUMMARY.tsv] [--max-report N]

Every column file has the same shape, `key <TAB> rc <TAB> digest`, whether it
came from one of the seven implementations, from an external oracle, or from a
NIST .rsp expectation.  Unifying them is what lets one piece of code answer all
three of the questions the project cares about:

    V5  do the implementations match FIPS 180-4?     (authority = NIST)
    V5' do they match an independent codebase?       (authority = oracle)
    V6  do they match each other?                    (no authority; consensus)

Per-row verdicts, which the summary reports separately because they are
different kinds of evidence:

    pass       agreed with an authority (NIST digest, or external oracle)
    fail       disagreed with an authority -- this is a real, attributable bug
    agree      no authority for this row, two or more columns answered, and
               they all gave the same digest.  Evidence, but weaker: eight
               implementations can be wrong together.
    lone       no authority, and only one column answered -- so nothing was
               compared at all.  Kept separate from `agree` so the summary
               cannot count a digest as evidence for itself.
    disputed   no authority, and the columns split into groups.  Blame is NOT
               assigned by majority vote, because a majority of six agreeing
               transcriptions of the same misreading is exactly the failure
               mode V5 exists to catch.  Every participant is marked disputed
               and the groups are printed.
    error      the column produced no digest, a malformed digest, or a nonzero
               exit status.
    skipped    the column has no row for this key (subsampled away, or the
               input is not byte-aligned and the column is a byte-only oracle).

Exit status is 1 if there was any fail, dispute, error, or authority conflict.
"""

import argparse
import collections
import os
import sys

HEXSET = set("0123456789abcdef")


def load(path):
    out = {}
    if not path or not os.path.exists(path):
        return out
    with open(path) as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 3:
                continue
            try:
                key = int(parts[0])
            except ValueError:
                continue
            out[key] = (parts[1], parts[2])
    return out


def load_inputs(path):
    out = {}
    with open(path) as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 3:
                continue
            out[int(parts[0])] = (int(parts[1]), parts[2])
    return out


def valid(dig):
    return len(dig) == 64 and all(c in HEXSET for c in dig)


def short(hx, n=48):
    return hx if len(hx) <= n else "%s...(%d hex digits)" % (hx[:n], len(hx))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--phase", required=True)
    ap.add_argument("--inputs", required=True)
    ap.add_argument("--col", action="append", default=[])
    ap.add_argument("--authority", default="")
    ap.add_argument("--summary")
    ap.add_argument("--max-report", type=int, default=12)
    args = ap.parse_args()

    inputs = load_inputs(args.inputs)
    cols = collections.OrderedDict()
    for spec in args.col:
        name, _, path = spec.partition("=")
        cols[name] = load(path)
    authorities = [a for a in args.authority.split(",") if a and a in cols]

    stat = collections.OrderedDict(
        (c, collections.Counter()) for c in cols)
    reports = []
    conflicts = []
    n_rows_checked = 0
    n_rows_bad = 0

    for key in sorted(inputs):
        nbits, hx = inputs[key]

        answers = {}       # name -> digest, only well-formed ones
        for name, data in cols.items():
            if key not in data:
                stat[name]["skipped"] += 1
                continue
            rc, dig = data[key]
            if rc != "0" or not valid(dig):
                stat[name]["error"] += 1
                if len(reports) < args.max_report:
                    reports.append(
                        "  [%s] key=%d nbits=%d: column %s errored "
                        "(exit=%s, stdout=%r)\n    msg = %s"
                        % (args.phase, key, nbits, name, rc, dig, short(hx)))
                n_rows_bad += 1
                continue
            answers[name] = dig

        if not answers:
            continue

        # Authority handling.  If two authorities disagree with each other we
        # have no ground truth for this row and say so rather than picking one.
        auth_vals = set(answers[a] for a in authorities if a in answers)
        ref = None
        if len(auth_vals) == 1:
            ref = auth_vals.pop()
        elif len(auth_vals) > 1:
            detail = ", ".join("%s=%s" % (a, answers[a])
                               for a in authorities if a in answers)
            conflicts.append("  [%s] key=%d nbits=%d: AUTHORITIES DISAGREE: %s"
                             % (args.phase, key, nbits, detail))
            n_rows_bad += 1

        n_rows_checked += 1

        if ref is not None:
            bad = []
            for name, dig in answers.items():
                if name in authorities:
                    # An authority is the yardstick, not a competitor.  Counting
                    # it as "passing against itself" would inflate the summary
                    # with a number that means nothing; count rows offered.
                    stat[name]["offered"] += 1
                elif dig == ref:
                    stat[name]["pass"] += 1
                else:
                    stat[name]["fail"] += 1
                    bad.append(name)
            if bad:
                n_rows_bad += 1
                if len(reports) < args.max_report:
                    reports.append(
                        "  [%s] key=%d nbits=%d FAIL vs %s\n"
                        "    msg      = %s\n"
                        "    expected = %s\n"
                        "%s"
                        % (args.phase, key, nbits, "/".join(authorities), short(hx), ref,
                           "\n".join("    %-9s= %s" % (n, answers[n]) for n in bad)))
        else:
            groups = collections.OrderedDict()
            for name, dig in answers.items():
                groups.setdefault(dig, []).append(name)
            if len(answers) == 1:
                # Exactly one column answered and there is no authority, so
                # nothing was actually compared.  Counting this as agreement
                # would be counting a digest as evidence for itself, which is
                # how a summary ends up overstating its own coverage.
                for name in answers:
                    stat[name]["lone"] += 1
            elif len(groups) == 1:
                for name in answers:
                    stat[name]["agree"] += 1
            else:
                n_rows_bad += 1
                for name in answers:
                    stat[name]["disputed"] += 1
                if len(reports) < args.max_report:
                    lines = ["  [%s] key=%d nbits=%d DISAGREEMENT between "
                             "implementations (no external authority for this row)"
                             % (args.phase, key, nbits),
                             "    msg = %s" % short(hx)]
                    for dig, names in groups.items():
                        lines.append("    %-40s <- %s" % (dig, " ".join(sorted(names))))
                    reports.append("\n".join(lines))

    # ------------------------------------------------------------- output --
    width = max([len(c) for c in cols] + [6])
    print("phase %s: %d input rows, %d compared, %d rows with a problem"
          % (args.phase, len(inputs), n_rows_checked, n_rows_bad))
    hdr = ("  %-*s %8s %8s %8s %8s %8s %8s %8s %8s"
           % (width, "column", "pass", "agree", "lone", "fail", "disputed",
              "error", "skipped", "offered"))
    print(hdr)
    print("  " + "-" * (len(hdr) - 2))
    for name in cols:
        s = stat[name]
        tag = " (authority)" if name in authorities else ""
        print("  %-*s %8d %8d %8d %8d %8d %8d %8d %8d%s"
              % (width, name, s["pass"], s["agree"], s["lone"], s["fail"],
                 s["disputed"], s["error"], s["skipped"], s["offered"], tag))

    if conflicts:
        print("\n  EXTERNAL AUTHORITIES DISAGREED WITH EACH OTHER "
              "(this is a problem with the oracles, not necessarily with shavar):")
        for c in conflicts[:args.max_report]:
            print(c)
    if reports:
        print("\n  first %d problem rows:" % len(reports))
        for r in reports:
            print(r)

    if args.summary:
        with open(args.summary, "a") as fh:
            for name in cols:
                s = stat[name]
                fh.write("%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n"
                         % (args.phase, name, 1 if name in authorities else 0,
                            s["pass"], s["agree"], s["fail"], s["disputed"],
                            s["error"], s["skipped"], s["offered"], s["lone"]))

    bad = sum(stat[c]["fail"] + stat[c]["disputed"] + stat[c]["error"] for c in cols)
    return 1 if (bad or conflicts) else 0


if __name__ == "__main__":
    sys.exit(main())
