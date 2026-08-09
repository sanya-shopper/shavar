#!/usr/bin/env python3
"""Convert a NIST CAVP SHAVS .rsp file into harness inputs plus expectations.

Usage:
    nistload.py RSP --out-inputs INPUTS.tsv --out-expected EXPECTED.tsv
                    [--out-rejected REJECTED.tsv]

Reads the response file and writes

    INPUTS.tsv     key <TAB> nbits <TAB> hex        (spec/CLI.md encoding)
    EXPECTED.tsv   key <TAB> 0 <TAB> md             (same shape as an impl
                                                     result file, so the
                                                     comparator can treat NIST
                                                     as just another column)

Conventions in the .rsp files, which are easy to get wrong:

  * `Len` is in BITS, never bytes.
  * A `Len = 0` entry still carries a dummy `Msg = 00` line.  It means the
    EMPTY message, not the single zero byte.  Hashing `00` instead would give
    6e340b9c... rather than e3b0c442..., so this one line of special-casing is
    the difference between a passing suite and a silently wrong one.
  * In the bit-oriented files the message bits are left-justified in the final
    byte with the unused low bits zero, which is exactly the convention of
    spec/CLI.md 5.1 -- no transformation is needed, only verification.

Nothing is repaired here.  A vector whose final byte carries nonzero trailing
bits, or whose Msg length disagrees with ceil(Len/8), is written to the
rejected file with a reason and excluded, because feeding it to the
implementations would produce a failure that says nothing about them.  In
practice, at the time of writing, all 1154 SHA-256 vectors across the four
files pass this validation.
"""

import argparse
import sys


def parse(path):
    """Yield (len_bits, msg_hex, md_hex) triples in file order."""
    cur = {}
    with open(path, "r", encoding="ascii", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or line.startswith("["):
                continue
            if "=" not in line:
                continue
            k, v = line.split("=", 1)
            k = k.strip()
            v = v.strip()
            if k == "Len":
                cur = {"Len": int(v)}
            elif k == "Msg":
                cur["Msg"] = v
            elif k == "MD":
                cur["MD"] = v
                if "Len" in cur and "Msg" in cur:
                    yield cur["Len"], cur["Msg"], cur["MD"]
                cur = {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("rsp")
    ap.add_argument("--out-inputs", required=True)
    ap.add_argument("--out-expected", required=True)
    ap.add_argument("--out-rejected")
    args = ap.parse_args()

    inputs, expected, rejected = [], [], []
    key = 0
    for nbits, msg, md in parse(args.rsp):
        msg = msg.lower()
        md = md.lower()
        why = None
        if len(md) != 64 or any(c not in "0123456789abcdef" for c in md):
            why = "malformed MD"
        elif nbits == 0:
            # The dummy `Msg = 00` line: the message is empty.
            msg_out = "-"
        else:
            nbytes = (nbits + 7) // 8
            if len(msg) != 2 * nbytes:
                why = "Msg has %d hex digits, expected %d for Len=%d" % (
                    len(msg), 2 * nbytes, nbits)
            else:
                try:
                    raw = bytes.fromhex(msg)
                except ValueError:
                    why = "Msg is not hex"
                else:
                    rem = nbits % 8
                    if rem and (raw[-1] & ((1 << (8 - rem)) - 1)):
                        why = ("final byte %02x has nonzero trailing bits for "
                               "Len=%d; spec/CLI.md forbids this encoding" % (raw[-1], nbits))
                    else:
                        msg_out = msg
        if why:
            rejected.append((nbits, msg, md, why))
            continue
        inputs.append("%d\t%d\t%s\n" % (key, nbits, msg_out))
        expected.append("%d\t0\t%s\n" % (key, md))
        key += 1

    with open(args.out_inputs, "w") as fh:
        fh.writelines(inputs)
    with open(args.out_expected, "w") as fh:
        fh.writelines(expected)
    if args.out_rejected:
        with open(args.out_rejected, "w") as fh:
            for nbits, msg, md, why in rejected:
                fh.write("Len=%d\tMsg=%s\tMD=%s\t%s\n" % (nbits, msg[:64], md, why))

    sys.stderr.write("nistload: %s -> %d vectors, %d rejected\n"
                     % (args.rsp, len(inputs), len(rejected)))
    print(len(inputs))


if __name__ == "__main__":
    main()
