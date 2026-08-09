#!/usr/bin/env bash
#
# tests/pow.sh — the proof-of-work comparison, checked in every language.
#
# Discharges obligation V7 of spec/SPEC.md §8: that all seven implementations
# read the digest in the byte order §10.1 fixes, and agree with each other
# while doing it.
#
# WHY THIS SCRIPT EXISTS SEPARATELY FROM crosstest.sh
#
# The PoW comparison is deliberately library-only: it has no subcommand, so it
# is invisible to tests/crosstest.sh, which drives everything through the
# uniform command line of spec/CLI.md. Without this script the seven versions
# would be the only part of the repository whose mutual agreement nothing
# checked -- which is the property the whole project exists to demonstrate.
# So each implementation gets a small driver under pow-drivers/ that reads the
# shared vector file and prints a verdict per vector, and this script compares
# the columns.
#
# The drivers are marshalling shims and nothing else. No driver decides
# anything; every verdict comes from the implementation it loads.
#
# Two things are checked, and they are not the same check:
#
#   1. every implementation matches the EXPECTED verdict, which is anchored to
#      the Bitcoin genesis block rather than to this repository's own
#      arithmetic (SPEC.md §10.5);
#   2. every implementation matches every OTHER implementation, so a shared
#      misreading would still show up as a single column disagreeing if any
#      one of them got it right.
#
# Usage:
#   tests/pow.sh                 run every implementation that is present
#   tests/pow.sh --impls "c py"  restrict to a subset
#   tests/pow.sh --keep          keep the work directory
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
VECTORS=$REPO/tests/pow-vectors.tsv
DRIVERS=$REPO/tests/pow-drivers
ALL_IMPLS="c py pl scm js sh shz lean"
IMPLS=$ALL_IMPLS
KEEP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --impls) IMPLS=$2; shift 2 ;;
    --keep)  KEEP=1; shift ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) printf 'pow.sh: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/shavar-pow.XXXXXX") || exit 1
cleanup() { [ "$KEEP" -eq 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

say()  { printf '%s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
FAILURES=0

say "================================================================"
say " shavar proof-of-work comparison — SPEC.md §10, obligation V7"
say "================================================================"
say "repo     : $REPO"
say "vectors  : $VECTORS"
say "work dir : $WORK"
say ""

[ -r "$VECTORS" ] || { say "missing vector file: $VECTORS"; exit 1; }

# ---------------------------------------------------------------------------
# Expected verdicts, straight from the vector file.
# ---------------------------------------------------------------------------
awk -F'\t' '!/^#/ && NF >= 4 { print $1 "\t" $4 }' "$VECTORS" > "$WORK/expected"
NVEC=$(wc -l < "$WORK/expected" | tr -d ' ')
say "$NVEC vectors, of which:"
awk -F'\t' '{ c[$2]++ } END { for (k in c) printf "  %-8s %d\n", k, c[k] }' \
    "$WORK/expected" | sort
say ""

# ---------------------------------------------------------------------------
# Build the C driver. Absent tools are reported, never silently skipped.
# ---------------------------------------------------------------------------
CC=${CC:-cc}
if command -v "$CC" >/dev/null 2>&1; then
  if "$CC" -std=c99 -O1 -Wall -Wextra -Werror -I"$REPO/c" \
       "$DRIVERS/driver.c" "$REPO/c/shavar.c" -o "$WORK/driver-c" 2>"$WORK/cc.err"; then
    :
  else
    say "C driver failed to build:"
    sed 's/^/    /' "$WORK/cc.err"
    FAILURES=$((FAILURES + 1))
  fi
fi

# ---------------------------------------------------------------------------
# How to run each implementation. Empty command => absent.
# ---------------------------------------------------------------------------
runner_for() {
  case "$1" in
    c)   [ -x "$WORK/driver-c" ] && printf '%s' "$WORK/driver-c" ;;
    py)  command -v python3 >/dev/null 2>&1 && printf 'python3 %s' "$DRIVERS/driver.py" ;;
    pl)  command -v perl    >/dev/null 2>&1 && printf 'perl %s'    "$DRIVERS/driver.pl" ;;
    scm) command -v chibi-scheme >/dev/null 2>&1 &&
           printf 'env SHAVAR_LIB=1 SHAVAR_REPO=%s chibi-scheme %s' \
                  "$REPO" "$DRIVERS/driver.scm" ;;
    js)  if command -v jsc >/dev/null 2>&1; then
           printf 'jsc %s --' "$DRIVERS/driver.js"
         elif command -v node >/dev/null 2>&1; then
           printf 'node %s' "$DRIVERS/driver.js"
         fi ;;
    sh)  command -v bash >/dev/null 2>&1 && printf 'bash %s' "$DRIVERS/driver.sh" ;;
    shz) command -v zsh  >/dev/null 2>&1 && printf 'zsh %s'  "$DRIVERS/driver.sh" ;;
    lean) [ -x "$REPO/lean/.lake/build/bin/powdriver" ] &&
            printf '%s' "$REPO/lean/.lake/build/bin/powdriver" ;;
  esac
}

# ---------------------------------------------------------------------------
# Run them.
# ---------------------------------------------------------------------------
say "== implementations =="
PRESENT=""
for id in $IMPLS; do
  cmd=$(runner_for "$id")
  if [ -z "$cmd" ]; then
    printf '  %-5s absent   (interpreter or build missing)\n' "$id"
    continue
  fi
  # jsc needs the repo as cwd because driver.js load()s a relative path.
  if ( cd "$REPO" && $cmd "$VECTORS" > "$WORK/out.$id" 2> "$WORK/err.$id" ); then
    got=$(wc -l < "$WORK/out.$id" | tr -d ' ')
    if [ "$got" -ne "$NVEC" ]; then
      printf '  %-5s BROKEN   produced %s lines, expected %s\n' "$id" "$got" "$NVEC"
      sed 's/^/      /' "$WORK/err.$id" | head -5
      FAILURES=$((FAILURES + 1))
      continue
    fi
    printf '  %-5s ok\n' "$id"
    PRESENT="$PRESENT $id"
  else
    printf '  %-5s BROKEN   driver exited nonzero\n' "$id"
    sed 's/^/      /' "$WORK/err.$id" | head -8
    FAILURES=$((FAILURES + 1))
  fi
done
say ""

if [ -z "$PRESENT" ]; then
  say "no implementation ran: nothing was checked"
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Each implementation against the expected verdicts.
# ---------------------------------------------------------------------------
say "== against the expected verdicts (external anchor: SPEC.md §10.5) =="
for id in $PRESENT; do
  if diff -q "$WORK/expected" "$WORK/out.$id" >/dev/null 2>&1; then
    printf '  %-5s all %s vectors match\n' "$id" "$NVEC"
  else
    printf '  %-5s DISAGREES with the expected verdicts:\n' "$id"
    join -t"$(printf '\t')" "$WORK/expected" "$WORK/out.$id" |
      awk -F'\t' '$2 != $3 { printf "      %-18s expected %-8s got %s\n", $1, $2, $3 }'
    FAILURES=$((FAILURES + 1))
  fi
done
say ""

# ---------------------------------------------------------------------------
# 2. Every implementation against every other.
# ---------------------------------------------------------------------------
say "== against each other (V7: mutual agreement) =="
REF=$(printf '%s' "$PRESENT" | awk '{ print $1 }')
DISAGREE=0
for id in $PRESENT; do
  [ "$id" = "$REF" ] && continue
  if ! diff -q "$WORK/out.$REF" "$WORK/out.$id" >/dev/null 2>&1; then
    printf '  %s and %s disagree:\n' "$REF" "$id"
    join -t"$(printf '\t')" "$WORK/out.$REF" "$WORK/out.$id" |
      awk -F'\t' -v a="$REF" -v b="$id" \
        '$2 != $3 { printf "      %-18s %s=%-8s %s=%s\n", $1, a, $2, b, $3 }'
    DISAGREE=1
    FAILURES=$((FAILURES + 1))
  fi
done
[ "$DISAGREE" -eq 0 ] &&
  say "  all of[$PRESENT ] agree, vector for vector"
say ""

# ---------------------------------------------------------------------------
# The byte-order pair, called out because it is the point of the exercise.
# ---------------------------------------------------------------------------
say "== the byte-order pair =="
say "  genesis-le and genesis-be are the same 32 bytes in opposite orders."
say "  An implementation that read the digest big-endian would swap both"
say "  verdicts and still look self-consistent, so this pair is what"
say "  distinguishes a correct reading from a plausible one."
for id in $PRESENT; do
  le=$(awk -F'\t' '$1 == "genesis-le" { print $2 }' "$WORK/out.$id")
  be=$(awk -F'\t' '$1 == "genesis-be" { print $2 }' "$WORK/out.$id")
  if [ "$le" = "met" ] && [ "$be" = "unmet" ]; then
    printf '  %-5s little-endian=met  big-endian-reading=unmet   correct\n' "$id"
  else
    printf '  %-5s genesis-le=%s genesis-be=%s   WRONG BYTE ORDER\n' "$id" "$le" "$be"
    FAILURES=$((FAILURES + 1))
  fi
done
say ""

# ---------------------------------------------------------------------------
# Self-check: does this script actually catch the bug it exists to catch?
#
# "All green" is the output both of a correct implementation and of a harness
# that never looks. So a copy of c/shavar.c is mutated to read the digest
# big-endian -- the one-character error the whole section is about -- and the
# comparison is required to reject it. Nothing in the repository is touched:
# the mutant is built in the work directory from a copy.
# ---------------------------------------------------------------------------
say "== self-check: a deliberately byte-reversed implementation must FAIL =="
if [ -x "$WORK/driver-c" ]; then
  sed 's/digest\[SHAVAR_DIGEST_BYTES - 1 - i\]/digest[i]/' \
      "$REPO/c/shavar.c" > "$WORK/mutant.c"
  if cmp -s "$REPO/c/shavar.c" "$WORK/mutant.c"; then
    say "  could not inject the mutation: the expected source line was not found"
    say "  (the self-check is therefore vacuous, which is itself a failure)"
    FAILURES=$((FAILURES + 1))
  elif "$CC" -std=c99 -O1 -I"$REPO/c" "$DRIVERS/driver.c" "$WORK/mutant.c" \
         -o "$WORK/driver-mutant" 2>/dev/null; then
    "$WORK/driver-mutant" "$VECTORS" > "$WORK/out.mutant" 2>/dev/null
    if diff -q "$WORK/expected" "$WORK/out.mutant" >/dev/null 2>&1; then
      say "  MUTANT PASSED — these vectors do not distinguish the byte orders,"
      say "  so a green run above would have meant nothing"
      FAILURES=$((FAILURES + 1))
    else
      n=$(join -t"$(printf '\t')" "$WORK/expected" "$WORK/out.mutant" |
            awk -F'\t' '$2 != $3' | wc -l | tr -d ' ')
      printf '  mutant rejected on %s of %s vectors — the check has teeth\n' \
             "$n" "$NVEC"
    fi
  else
    say "  mutant failed to build; self-check skipped"
    FAILURES=$((FAILURES + 1))
  fi
else
  say "  skipped: no C driver to mutate"
fi
say ""

say "=============================================================="
if [ "$FAILURES" -eq 0 ]; then
  say "PASS  pow: $NVEC vectors x$(printf '%s' "$PRESENT" | wc -w | tr -d ' ') implementations, no disagreement"
  exit 0
fi
say "FAIL  pow: $FAILURES problem(s)"
exit 1
