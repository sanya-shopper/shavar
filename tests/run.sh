#!/bin/sh
#
# run.sh — the shavar test suite.
#
#   tests/run.sh              quick smoke, a few seconds
#   tests/run.sh fast         the same
#   tests/run.sh thorough     the long sweep, minutes
#
# Options:
#   --seed SEED     replay a previous run's random corpus exactly
#   --jobs N        shards per implementation (default 4); implementations also
#                   run concurrently with each other
#   --impls "a b"   restrict to a subset of implementations
#   --keep          keep the work directory for inspection
#   --skip-nist     skip the NIST known-answer phase
#   --skip-cross    skip the cross-implementation phase
#
# Exits nonzero if anything failed.  What it runs:
#
#   constants   recompute H and K from the primes; check spec/SPEC.md's tables
#               and each implementation's initial chaining value  (SPEC.md 9)
#   nist        NIST CAVP SHAVS known-answer vectors, byte- and bit-oriented,
#               plus each implementation's built-in selftest         (V5)
#   crosstest   swept and random bit lengths across every implementation, with
#               external-oracle validation on byte-aligned inputs and full
#               per-round trace diffs                                (V6, V5)

set -u
. "$(dirname "$0")/lib/common.sh"

MODE=fast
SEED=""
EXTRA=""
KEEP=0
DO_NIST=1
DO_CROSS=1

while [ $# -gt 0 ]; do
  case $1 in
    fast|thorough) MODE=$1; shift ;;
    --mode)        MODE=$2; shift 2 ;;
    --seed)        SEED=$2; shift 2 ;;
    --jobs)        JOBS=$2; EXTRA="$EXTRA --jobs $2"; shift 2 ;;
    --impls)       EXTRA="$EXTRA --impls"; IMPLSEL=$2; shift 2 ;;
    --keep)        KEEP=1; shift ;;
    --skip-nist)   DO_NIST=0; shift ;;
    --skip-cross)  DO_CROSS=0; shift ;;
    -h|--help)     sed -n '2,30p' "$0"; exit 0 ;;
    *) err "unknown option: $1"; exit 2 ;;
  esac
done
case $MODE in fast|thorough) ;; *) err "mode must be fast or thorough"; exit 2 ;; esac

if [ -z "$SEED" ]; then
  SEED=$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' \n')
  [ -n "$SEED" ] || SEED=$(date +%s)
fi

# One work directory for the whole run, so discovery happens once and every
# sub-script agrees about which implementations exist.
mkdir -p "$WORK"
export SHAVAR_WORK="$WORK"
[ "$KEEP" = 1 ] || trap 'rm -rf "$WORK"' EXIT INT TERM

START=$(date +%s)
printf '%s================================================================%s\n' "$C_BLD" "$C_OFF"
printf '%s shavar test suite — mode %s, seed %s%s\n' "$C_BLD" "$MODE" "$SEED" "$C_OFF"
printf '%s================================================================%s\n' "$C_BLD" "$C_OFF"
say "repo     : $ROOT"
say "work dir : $WORK"
say "replay   : tests/run.sh $MODE --seed $SEED"

RC=0
FAILED_PARTS=""

runpart() {
  _name=$1; shift
  if "$@"; then
    :
  else
    RC=1
    FAILED_PARTS="$FAILED_PARTS $_name"
  fi
}

# shellcheck disable=SC2086
if [ -n "${IMPLSEL:-}" ]; then SEL="--impls" ; else SEL="" ; fi

runpart constants sh "$TESTS_DIR/constants.sh" --keep ${SEL:+$SEL} ${IMPLSEL:-}

if [ "$DO_NIST" = 1 ]; then
  runpart nist sh "$TESTS_DIR/nist.sh" --mode "$MODE" --keep --jobs "$JOBS" \
      ${SEL:+$SEL} ${IMPLSEL:-}
else
  warn "NIST phase skipped by request: obligation V5 is unchecked in this run"
fi

if [ "$DO_CROSS" = 1 ]; then
  runpart crosstest sh "$TESTS_DIR/crosstest.sh" --mode "$MODE" --seed "$SEED" \
      --keep --jobs "$JOBS" ${SEL:+$SEL} ${IMPLSEL:-}
else
  warn "cross-test phase skipped by request: obligation V6 is unchecked in this run"
fi

"$PYTHON" "$LIB/summarize.py" --work "$WORK" || RC=1

END=$(date +%s)
say ""
say "  elapsed: $((END - START))s    seed: $SEED    mode: $MODE"
say "  replay : tests/run.sh $MODE --seed $SEED"

if [ "$RC" = 0 ]; then
  printf '\n%s  PASS  %s all phases green\n' "$C_GRN" "$C_OFF"
else
  printf '\n%s  FAIL  %s failing phases:%s\n' "$C_RED" "$C_OFF" "${FAILED_PARTS:- (see summary above)}"
fi
exit "$RC"
