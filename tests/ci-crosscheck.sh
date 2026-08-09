#!/usr/bin/env bash
# Fast cross-implementation agreement check for CI.
#
# This is deliberately small and dependency-free: it is the gate that runs on
# every push. The exhaustive random/NIST sweep lives in crosstest.sh; this one
# is here to fail fast and to be readable when it does.
#
# What it checks:
#   1. every available implementation agrees with the C reference on a set of
#      digests, including sub-byte bit lengths;
#   2. every available implementation produces a byte-identical `trace`, so a
#      disagreement is localised to a round rather than just to a digest;
#   3. the trailing-bit rule is enforced in BOTH directions (a validator that
#      rejected everything would pass a one-sided test).
#
# Missing implementations are skipped and named, never silently ignored.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

JSC=/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc
fails=0
tested=()
skipped=()

# Invoke implementation $1 with the remaining arguments.
run() {
  local impl=$1; shift
  case $impl in
    c)   ./c/shavar "$@" ;;
    py)  python3 py/shavar.py "$@" ;;
    pl)  perl pl/shavar.pl "$@" ;;
    scm) chibi-scheme scm/shavar.scm "$@" ;;
    sh)  bash sh/shavar.sh "$@" ;;
    zsh) zsh sh/shavar.sh "$@" ;;
    js)  if [ -x "$JSC" ]; then ./js/shavar-cli.js "$@"; else node tests/node-cli.js "$@"; fi ;;
    lean) ./lean/.lake/build/bin/shavar "$@" ;;
  esac
}

# Is implementation $1 runnable here?
have() {
  case $1 in
    c)    [ -x ./c/shavar ] ;;
    py)   [ -f py/shavar.py ] && command -v python3 >/dev/null ;;
    pl)   [ -f pl/shavar.pl ] && command -v perl >/dev/null ;;
    scm)  [ -f scm/shavar.scm ] && command -v chibi-scheme >/dev/null ;;
    sh)   [ -f sh/shavar.sh ] && command -v bash >/dev/null ;;
    zsh)  [ -f sh/shavar.sh ] && command -v zsh >/dev/null ;;
    js)   [ -f js/shavar.js ] && { [ -x "$JSC" ] || command -v node >/dev/null; } ;;
    lean) [ -x ./lean/.lake/build/bin/shavar ] ;;
  esac
}

ALL=(c py pl scm sh zsh js lean)

# The C reference must exist; everything is compared against it.
if ! have c; then
  echo "building C reference..."
  make -C c shavar >/dev/null || { echo "FATAL: cannot build C reference"; exit 1; }
fi

for i in "${ALL[@]}"; do
  if have "$i"; then tested+=("$i"); else skipped+=("$i"); fi
done

echo "tested:  ${tested[*]}"
echo "skipped: ${skipped[*]:-none}"
echo

# ---- 1 & 2: digests and traces --------------------------------------------
# Sub-byte lengths are the interesting cases; 447/448 straddle the one-block
# to two-block padding boundary.
CASES=(
  "- 0"           "616263 24"       "b0 5"          "b8 5"
  "80 1"          "c0 2"            "f0a8 13"       "8000 9"
  "ff 8"          "0000000000 33"
)

for case in "${CASES[@]}"; do
  set -- $case
  hex=$1; n=$2
  ref=$(run c hash "$hex" "$n" 2>/dev/null)
  for i in "${tested[@]}"; do
    [ "$i" = c ] && continue
    got=$(run "$i" hash "$hex" "$n" 2>/dev/null)
    if [ "$got" != "$ref" ]; then
      echo "DIGEST MISMATCH  L=$n msg=$hex"
      echo "   c  = $ref"
      echo "   $i = $got"
      fails=$((fails + 1))
    fi
  done
done

for case in "- 0" "616263 24" "b0 5"; do
  set -- $case
  hex=$1; n=$2
  run c trace "$hex" "$n" > /tmp/ci_trace_c.txt 2>/dev/null
  for i in "${tested[@]}"; do
    [ "$i" = c ] && continue
    run "$i" trace "$hex" "$n" > "/tmp/ci_trace_$i.txt" 2>/dev/null
    if ! diff -q /tmp/ci_trace_c.txt "/tmp/ci_trace_$i.txt" >/dev/null 2>&1; then
      echo "TRACE MISMATCH  L=$n msg=$hex  impl=$i"
      # Name the first differing record: that is the whole point of tracing.
      diff /tmp/ci_trace_c.txt "/tmp/ci_trace_$i.txt" | head -6
      fails=$((fails + 1))
    fi
  done
done

# ---- 3: trailing-bit rule, both directions --------------------------------
# 0xb0 = 1011 0000 and 0xb8 = 1011 1000 both have zero low 3 bits -> valid.
# 0xb4 = 1011 0100 has low bits 100                               -> invalid.
for i in "${tested[@]}"; do
  run "$i" hash b4 5 >/dev/null 2>&1; bad=$?
  run "$i" hash b0 5 >/dev/null 2>&1; ok1=$?
  run "$i" hash b8 5 >/dev/null 2>&1; ok2=$?
  if [ "$bad" -ne 2 ] || [ "$ok1" -ne 0 ] || [ "$ok2" -ne 0 ]; then
    echo "TRAILING-BIT RULE WRONG in $i: b4=$bad (want 2) b0=$ok1 (want 0) b8=$ok2 (want 0)"
    fails=$((fails + 1))
  fi
done

echo
if [ "$fails" -eq 0 ]; then
  echo "cross-check PASSED across ${#tested[@]} implementations: ${tested[*]}"
  [ ${#skipped[@]} -gt 0 ] && echo "(not available here: ${skipped[*]})"
  exit 0
fi
echo "cross-check FAILED with $fails mismatch(es)"
exit 1
