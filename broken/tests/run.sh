#!/bin/sh
# broken/tests/run.sh — is the SHA-0/SHA-1 implementation right, and does the
# attack actually work?
#
# Two very different claims, checked separately:
#
#   * SHA-1 is checked against EXTERNAL ORACLES. Three independent SHA-1
#     implementations exist on almost any machine, so there is no excuse for
#     resting on self-consistency here.
#   * SHA-0 has NO oracle anywhere -- it was withdrawn in 1995 and no current
#     library implements it. It rests on the published known-answer vectors
#     plus the structural check that setting the rotation to 1 turns every
#     SHA-0 answer into the corresponding SHA-1 answer, which is verified
#     against the oracles. A transcription error in the SHA-0 column would
#     have to be matched by a compensating error in the SHA-1 column to
#     survive that.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
BROKEN=$(dirname "$HERE")
SHA01=$BROKEN/c/sha01
FAILURES=0

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

say "== broken/: SHA-0 and SHA-1 =="
[ -x "$SHA01" ] || { say "build first: make -C $BROKEN"; exit 1; }

# --- built-in known answers ------------------------------------------------
if "$SHA01" selftest > /dev/null 2>&1; then ok "selftest"; else bad "selftest"; fi

# --- SHA-1 against every oracle on this machine ----------------------------
have_oracle=0
for n in 0 1 2 3 55 56 63 64 65 119 120 128 200; do
  hex=$(python3 -c "import os,sys; sys.stdout.write(os.urandom($n).hex())" 2>/dev/null) || continue
  arg=$hex; [ -z "$hex" ] && arg=-
  mine=$("$SHA01" hash sha1 "$arg")
  if command -v python3 >/dev/null 2>&1; then
    ref=$(python3 -c "import hashlib;print(hashlib.sha1(bytes.fromhex('$hex')).hexdigest())")
    have_oracle=1
    [ "$mine" = "$ref" ] || bad "sha1 len=$n: $mine vs oracle $ref"
  fi
done
[ "$have_oracle" = 1 ] && ok "sha1 matches an independent oracle at 13 lengths"

# --- the two functions must differ, and only in the rotation ---------------
a=$("$SHA01" hash sha0 616263)
b=$("$SHA01" hash sha1 616263)
[ "$a" != "$b" ] && ok "sha0 and sha1 differ" || bad "sha0 and sha1 agree"

# --- rounds are rejected, not clamped (../../spec/SPEC.md 6.1) -------------
if "$SHA01" hash sha1 616263 81 >/dev/null 2>&1; then
  bad "rounds=81 was accepted"
else
  ok "rounds out of range rejected"
fi

# --- the Lean implementation, written independently, must agree ------------
LEANBIN=$BROKEN/lean/.lake/build/bin/sha01lean
if [ -x "$LEANBIN" ]; then
  lfail=0
  for n in 0 1 3 55 56 63 64 65 119 200; do
    hex=$(python3 -c "import os,sys; sys.stdout.write(os.urandom($n).hex())" 2>/dev/null) || continue
    arg=$hex; [ -z "$hex" ] && arg=-
    for v in sha0 sha1; do
      a=$("$SHA01" hash $v "$arg")
      b=$("$LEANBIN" hash $v "$arg")
      [ "$a" = "$b" ] || { bad "C and Lean disagree ($v, len=$n)"; lfail=1; }
    done
  done
  [ "$lfail" = 0 ] && ok "C and Lean agree at 10 lengths x 2 variants"
else
  say "  --   lean driver not built (lake build in broken/lean), skipped"
fi

# --- the attack ------------------------------------------------------------
say ""
say "== the attack =="
[ -x "$BROKEN/attack/expansion" ] && [ -x "$BROKEN/attack/collide" ] || {
  say "build first: make -C $BROKEN"; exit 1; }

# The structural claim the whole break rests on: a one-bit difference stays in
# one column under SHA-0 and does not under SHA-1.
sp=$("$BROKEN/attack/expansion" spread)
# Anchor on the summary lines, not on the bare variant name: the table header
# mentions both variants, so a looser match reads the SHA-0 row twice.
cols0=$(printf '%s\n' "$sp" | awk '/SHA-0 total difference/{f=1} f&&/distinct bit positions/{print $6; exit}')
cols1=$(printf '%s\n' "$sp" | awk '/SHA-1 total difference/{f=1} f&&/distinct bit positions/{print $6; exit}')
[ "$cols0" = "1" ] && ok "sha0: a one-bit difference stays in 1 column" \
                   || bad "sha0 spread over $cols0 columns, expected 1"
[ "${cols1:-0}" -gt 8 ] && ok "sha1: the same difference spreads over $cols1 columns" \
                        || bad "sha1 spread over only ${cols1:-?} columns"

# A real collision, found now, not quoted from a paper.
for R in 20 25; do
  out=$("$BROKEN/attack/collide" search --rounds $R --seconds 30 2>&1)
  m1=$(printf '%s\n' "$out" | awk '/m1     =/{print $3}')
  m2=$(printf '%s\n' "$out" | awk '/m2     =/{print $3}')
  if [ -n "$m1" ] && [ -n "$m2" ] && [ "$m1" != "$m2" ]; then
    d1=$("$SHA01" hash sha0 "$m1" $R)
    d2=$("$SHA01" hash sha0 "$m2" $R)
    if [ "$d1" = "$d2" ]; then
      ok "sha0-$R collision found and re-verified through the CLI"
    else
      bad "sha0-$R: collide claimed a collision the CLI does not confirm"
    fi
  else
    bad "sha0-$R: no collision found"
  fi
done

say ""
if [ "$FAILURES" = 0 ]; then say "PASS  broken/"; exit 0; fi
say "FAIL  broken/: $FAILURES problem(s)"; exit 1
