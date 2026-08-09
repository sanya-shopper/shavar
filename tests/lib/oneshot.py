#!/usr/bin/env python3
"""Run one command under a wall-clock timeout, passing stdout and stderr through.

    oneshot.py --timeout SEC --cmdfile ARGV0FILE -- ARG [ARG ...]

ARGV0FILE holds the invocation prefix as NUL-separated arguments (written by
write_argv_files in lib/common.sh); the arguments after `--` are appended.
Exits with the command's status, or 124 on timeout, matching timeout(1).

This is the one-off counterpart to lib/runner.py: used for the handful of
individual calls the harness makes outside a phase loop (the discovery smoke
test, `selftest`, and the single traces used by tests/constants.sh), all of
which must be bounded for the same reason -- an implementation being edited
underneath the harness can hang, and the suite has to survive that and report
it rather than stall.
"""

import argparse
import subprocess
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--timeout", type=float, default=120.0)
    ap.add_argument("--cmdfile", required=True)
    ap.add_argument("rest", nargs=argparse.REMAINDER)
    args = ap.parse_args()

    with open(args.cmdfile, "rb") as fh:
        prefix = [a for a in fh.read().split(b"\0") if a]
    if not prefix:
        sys.stderr.write("oneshot: empty command file %s\n" % args.cmdfile)
        return 127

    rest = args.rest
    if rest and rest[0] == "--":
        rest = rest[1:]
    cmd = [a.decode() for a in prefix] + rest

    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=args.timeout)
    except subprocess.TimeoutExpired:
        sys.stderr.write("oneshot: timed out after %gs: %s\n"
                         % (args.timeout, " ".join(cmd[:3])))
        return 124
    except OSError as e:
        sys.stderr.write("oneshot: cannot run %s: %s\n" % (cmd[0], e))
        return 127
    sys.stdout.buffer.write(p.stdout)
    sys.stdout.buffer.flush()
    sys.stderr.buffer.write(p.stderr)
    return p.returncode


if __name__ == "__main__":
    sys.exit(main())
