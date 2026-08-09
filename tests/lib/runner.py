#!/usr/bin/env python3
"""Drive one implementation (or one external oracle) over a list of inputs.

    runner.py --op hash|trace|stdin|calibrate --inputs F --out F
              [--shard N --nshard N] [--timeout SEC] [--tracedir DIR]
              -- COMMAND [ARG ...]

This exists in Python rather than as a shell loop for three reasons, all of
which turned out to matter:

  * Timeouts.  The seven implementations are under active development, and one
    of them hanging must not hang the suite.  Every invocation is bounded; a
    timeout is recorded as `timeout` in the rc column and surfaces in the
    comparator's `error` count, never as a pass and never as a silent skip.

  * Speed.  A shell `while read` loop forks per input; one Python process per
    shard forks only the implementation itself.

  * Faithful capture.  stdout is taken verbatim.  Nothing is normalised, so a
    capital hex digit or a missing newline reaches the comparator as the
    contract violation it is (spec/CLI.md).

Output for hash/stdin ops, one row per input:  key <TAB> rc <TAB> digest
where rc is the exit status as a string, or `timeout`, or `spawn-error`, and
digest is `-` when nothing usable came back.

For the trace op each trace is written to DIR/<tag>.<key> with DIR/<tag>.<key>.rc
holding the exit status, which is the shape tests/crosstest.sh compares.
"""

import argparse
import os
import subprocess
import sys
import time

HEXSET = set("0123456789abcdefABCDEF")


def read_inputs(path):
    rows = []
    with open(path) as fh:
        for line in fh:
            f = line.rstrip("\n").split("\t")
            if len(f) >= 3 and f[0]:
                rows.append(f)
    return rows


def run(cmd, timeout, stdin_bytes=None):
    """-> (rc_string, stdout_text)."""
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           input=stdin_bytes, timeout=timeout)
    except subprocess.TimeoutExpired:
        return "timeout", ""
    except OSError as e:
        return "spawn-error(%s)" % e.errno, ""
    return str(p.returncode), p.stdout.decode("utf-8", "replace")


def first_hex64(text):
    """Pull a 64-hex-digit token out of an oracle's first output line.

    openssl prints `SHA2-256(stdin)= <hex>`, shasum and sha256sum print
    `<hex>  -`.  Picking the token that looks like a digest handles all of them
    without a per-tool parser.
    """
    for line in text.split("\n")[:2]:
        for tok in line.replace("=", " ").split():
            if len(tok) == 64 and all(c in HEXSET for c in tok):
                return tok
    return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--op", required=True,
                    choices=("hash", "trace", "stdin", "calibrate"))
    ap.add_argument("--inputs")
    ap.add_argument("--out")
    ap.add_argument("--shard", type=int, default=0)
    ap.add_argument("--nshard", type=int, default=1)
    ap.add_argument("--timeout", type=float, default=60.0)
    ap.add_argument("--tracedir")
    ap.add_argument("--tag", default="impl")
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    args = ap.parse_args()

    cmd = args.cmd
    if cmd and cmd[0] == "--":
        cmd = cmd[1:]
    if not cmd:
        sys.exit("runner.py: no command given after --")

    # ------------------------------------------------------------ calibrate --
    if args.op == "calibrate":
        # Three one-block invocations give the fixed per-invocation cost; one
        # eight-block invocation gives the marginal cost of a block.  Both are
        # needed because they differ by orders of magnitude between languages.
        t0 = time.time()
        for _ in range(3):
            rc, _o = run(cmd + ["hash", "616263", "24"], args.timeout)
        t1 = time.time()
        run(cmd + ["hash", "ab" * 512, "4096"], args.timeout)
        t2 = time.time()
        base = max((t1 - t0) * 1000.0 / 3.0, 0.05)
        per = max(((t2 - t1) * 1000.0 - base) / 8.0, 0.0)
        print("%s\t%.3f\t%.3f" % (args.tag, base, per))
        return 0

    rows = read_inputs(args.inputs)
    rows = [r for i, r in enumerate(rows) if i % args.nshard == args.shard]

    if args.op == "trace":
        os.makedirs(args.tracedir, exist_ok=True)
        for f in rows:
            key, hx, nbits, blockidx = f[0], f[1], f[2], (f[3] if len(f) > 3 else "0")
            rc, out = run(cmd + ["trace", hx, nbits, blockidx], args.timeout)
            with open(os.path.join(args.tracedir, "%s.%s" % (args.tag, key)), "w") as fh:
                fh.write(out)
            with open(os.path.join(args.tracedir, "%s.%s.rc" % (args.tag, key)), "w") as fh:
                fh.write(rc + "\n")
        return 0

    with open(args.out, "w") as fh:
        for f in rows:
            key, nbits, hx = f[0], f[1], f[2]
            if args.op == "hash":
                rc, out = run(cmd + ["hash", hx, nbits], args.timeout)
                dig = out.split("\n")[0].strip()
            else:  # stdin: an external oracle, fed raw bytes
                raw = b"" if hx == "-" or nbits == "0" else bytes.fromhex(hx)
                rc, out = run(cmd, args.timeout, stdin_bytes=raw)
                dig = first_hex64(out)
            fh.write("%s\t%s\t%s\n" % (key, rc, dig or "-"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
