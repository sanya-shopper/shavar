#!/usr/bin/env bash
#
# tests/rounds.sh — the library-level round-count contract, in every language.
#
# Discharges obligation V8 of spec/SPEC.md §8: that every implementation
# rejects a round count outside 0..64 at the LIBRARY boundary, and that all of
# them agree on the digest for the counts that are legal.
#
# WHY THIS PHASE EXISTS
#
# spec/CLI.md already fixed the range for command-line callers, and every
# implementation obeyed it there. That turned out to constrain the library not
# at all, and nothing in the repository could see the difference, because
# crosstest.sh drives everything through the CLI and the CLI rejects an
# out-of-range count before the library is ever reached.
#
# Underneath that blind spot the seven implementations had diverged four ways
# on the same call:
#
#   python, javascript   rejected                          (correct)
#   c, lean              silently clamped to 64 and returned real SHA-256
#   perl, shell          ran the loop past the end of K, returning a digest
#                        that is not any reduced-round variant of anything
#   scheme               crashed with an interpreter backtrace
#
# The clamp is the worst of the four: a correct-looking answer, with a success
# status, to a request that denotes no function. See PROJECT_LOG.md, which
# records this being fixed once already -- at the CLI layer, which is where it
# had been noticed rather than where it lived.
#
# Usage:
#   tests/rounds.sh                 every implementation that is present
#   tests/rounds.sh --impls "c py"  a subset
#   tests/rounds.sh --keep          keep the work directory
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
VECTORS=$REPO/tests/rounds-vectors.tsv
DRIVERS=$REPO/tests/rounds-drivers
ALL_IMPLS="c py pl scm js sh shz lean"
IMPLS=$ALL_IMPLS
KEEP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --impls) IMPLS=$2; shift 2 ;;
    --keep)  KEEP=1; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) printf 'rounds.sh: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/shavar-rounds.XXXXXX") || exit 1
cleanup() { [ "$KEEP" -eq 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

say() { printf '%s\n' "$*"; }
FAILURES=0
TAB=$(printf '\t')

say "================================================================"
say " shavar library round-count contract — SPEC.md §6.1, obligation V8"
say "================================================================"
say "repo     : $REPO"
say "vectors  : $VECTORS"
say "work dir : $WORK"
say ""

[ -r "$VECTORS" ] || { say "missing vector file: $VECTORS"; exit 1; }

awk -F'\t' '!/^#/ && NF >= 2 { print $1 "\t" $2 }' "$VECTORS" > "$WORK/expected"
NVEC=$(wc -l < "$WORK/expected" | tr -d ' ')
say "$NVEC round counts under test:"
awk -F'\t' '{ printf "  %-6s expect %s\n", $1, $2 }' "$WORK/expected"
say ""

CC=${CC:-cc}
if command -v "$CC" >/dev/null 2>&1; then
  "$CC" -std=c99 -O1 -Wall -Wextra -Werror -I"$REPO/c" \
      "$DRIVERS/driver.c" "$REPO/c/shavar.c" -o "$WORK/driver-c" 2>"$WORK/cc.err" || {
    say "C driver failed to build:"; sed 's/^/    /' "$WORK/cc.err"
    FAILURES=$((FAILURES + 1)); }
fi

runner_for() {
  case "$1" in
    c)   [ -x "$WORK/driver-c" ] && printf '%s' "$WORK/driver-c" ;;
    py)  command -v python3 >/dev/null 2>&1 && printf 'python3 %s' "$DRIVERS/driver.py" ;;
    pl)  command -v perl    >/dev/null 2>&1 && printf 'perl %s'    "$DRIVERS/driver.pl" ;;
    scm) command -v chibi-scheme >/dev/null 2>&1 &&
           printf 'env SHAVAR_LIB=1 SHAVAR_REPO=%s chibi-scheme %s' "$REPO" "$DRIVERS/driver.scm" ;;
    js)  if command -v jsc >/dev/null 2>&1; then printf 'jsc %s --' "$DRIVERS/driver.js"
         elif command -v node >/dev/null 2>&1; then printf 'node %s' "$DRIVERS/driver.js"; fi ;;
    sh)  command -v bash >/dev/null 2>&1 && printf 'bash %s' "$DRIVERS/driver.sh" ;;
    shz) command -v zsh  >/dev/null 2>&1 && printf 'zsh %s'  "$DRIVERS/driver.sh" ;;
    lean) [ -x "$REPO/lean/.lake/build/bin/roundsdriver" ] &&
            printf '%s' "$REPO/lean/.lake/build/bin/roundsdriver" ;;
  esac
}

say "== implementations =="
PRESENT=""
for id in $IMPLS; do
  cmd=$(runner_for "$id")
  if [ -z "$cmd" ]; then
    printf '  %-5s absent   (interpreter or build missing)\n' "$id"; continue
  fi
  if ( cd "$REPO" && $cmd "$VECTORS" > "$WORK/out.$id" 2> "$WORK/err.$id" ); then
    got=$(wc -l < "$WORK/out.$id" | tr -d ' ')
    if [ "$got" -ne "$NVEC" ]; then
      printf '  %-5s BROKEN   produced %s lines, expected %s\n' "$id" "$got" "$NVEC"
      sed 's/^/      /' "$WORK/err.$id" | head -5
      FAILURES=$((FAILURES + 1)); continue
    fi
    printf '  %-5s ok\n' "$id"; PRESENT="$PRESENT $id"
  else
    printf '  %-5s BROKEN   driver exited nonzero\n' "$id"
    sed 's/^/      /' "$WORK/err.$id" | head -8
    FAILURES=$((FAILURES + 1))
  fi
done
say ""

[ -n "$PRESENT" ] || { say "no implementation ran: nothing was checked"; exit 1; }

# ---------------------------------------------------------------------------
# 1. The accept/reject contract.
# ---------------------------------------------------------------------------
say "== the contract: which counts are accepted =="
for id in $PRESENT; do
  bad=$(join -t"$TAB" "$WORK/expected" "$WORK/out.$id" |
        awk -F'\t' '{
          split($2, allowed, "|"); ok = 0
          for (k in allowed) if (allowed[k] == $3) ok = 1
          if (!ok) printf "      rounds=%-6s expected %-26s got %s\n", $1, $2, $3
        }')
  if [ -z "$bad" ]; then
    printf '  %-5s all %s counts as specified\n' "$id" "$NVEC"
  else
    printf '  %-5s VIOLATES the contract:\n' "$id"; printf '%s\n' "$bad"
    FAILURES=$((FAILURES + 1))
  fi
done
say ""

# ---------------------------------------------------------------------------
# 2. Digest agreement on the counts that are legal. A reduced-round digest is
#    not covered by NIST, so this is mutual agreement only -- but a divergence
#    here would mean two implementations disagree about what "12 rounds" is.
# ---------------------------------------------------------------------------
say "== digests agree on the accepted counts =="
REF=$(printf '%s' "$PRESENT" | awk '{ print $1 }')
agree=1
for id in $PRESENT; do
  [ "$id" = "$REF" ] && continue
  diffs=$(join -t"$TAB" "$WORK/out.$REF" "$WORK/out.$id" |
          awk -F'\t' -v a="$REF" -v b="$id" '
            $2 == "accepted" && $4 == "accepted" && $3 != $5 {
              printf "      rounds=%-6s %s=%s  %s=%s\n", $1, a, $3, b, $5 }')
  if [ -n "$diffs" ]; then
    printf '  %s and %s disagree:\n' "$REF" "$id"; printf '%s\n' "$diffs"
    agree=0; FAILURES=$((FAILURES + 1))
  fi
done
[ "$agree" -eq 1 ] && say "  all of[$PRESENT ] agree, count for count"
say ""

# ---------------------------------------------------------------------------
# 3. Self-check. "All green" is also what a harness that never looked prints,
#    so a copy of c/shavar.c is put back the way it was -- rejecting replaced
#    by the old silent clamp -- and the contract check is required to catch it.
#    Nothing in the repository is touched; the mutant is built from a copy.
# ---------------------------------------------------------------------------
say "== self-check: restoring the old clamp must FAIL the contract =="
if [ -x "$WORK/driver-c" ]; then
  # '#' as the delimiter: the pattern contains '||', which would end a
  # '|'-delimited s/// in the middle of the condition.
  sed 's#if (rounds < 0 || rounds > SHAVAR_ROUNDS) return -1;#if (rounds < 0) rounds = 0; if (rounds > SHAVAR_ROUNDS) rounds = SHAVAR_ROUNDS;#' \
      "$REPO/c/shavar.c" > "$WORK/mutant.c"
  if cmp -s "$REPO/c/shavar.c" "$WORK/mutant.c"; then
    say "  could not inject the mutation: the expected source line was not found"
    say "  (the self-check is therefore vacuous, which is itself a failure)"
    FAILURES=$((FAILURES + 1))
  elif "$CC" -std=c99 -O1 -I"$REPO/c" "$DRIVERS/driver.c" "$WORK/mutant.c" \
         -o "$WORK/driver-mutant" 2>/dev/null; then
    "$WORK/driver-mutant" "$VECTORS" > "$WORK/out.mutant" 2>/dev/null
    n=$(join -t"$TAB" "$WORK/expected" "$WORK/out.mutant" |
        awk -F'\t' '{ split($2,a,"|"); ok=0; for (k in a) if (a[k]==$3) ok=1; if (!ok) c++ }
                    END { print c+0 }')
    if [ "$n" -eq 0 ]; then
      say "  MUTANT PASSED — these counts do not distinguish clamping from"
      say "  rejecting, so a green run above would have meant nothing"
      FAILURES=$((FAILURES + 1))
    else
      printf '  clamping mutant caught on %s of %s counts — the check has teeth\n' \
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
  say "PASS  rounds: $NVEC counts x$(printf '%s' "$PRESENT" | wc -w | tr -d ' ') implementations, contract held"
  exit 0
fi
say "FAIL  rounds: $FAILURES problem(s)"
exit 1
