#!/bin/sh
#
# constants.sh — check the SHA-256 initial value and round constants.
#
# spec/SPEC.md 9 asks tests/ to recompute H and K from the primes rather than
# trust the transcription, "because a mistyped constant is the classic way one
# of five implementations ends up subtly different from the other four, and it
# is cheap to rule out".  This is the cheap ruling-out.
#
# Two independent things are compared against the recomputation: the tables in
# spec/SPEC.md itself, and the initial chaining value each implementation
# actually holds, read out of the HIN records of `trace - 0 0`.
#
# Usage: tests/constants.sh [--impls "c py ..."] [--keep]

set -u
. "$(dirname "$0")/lib/common.sh"

WANT_IMPLS=""
KEEP=0
while [ $# -gt 0 ]; do
  case $1 in
    --impls) WANT_IMPLS=$2; shift 2 ;;
    --keep)  KEEP=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) err "unknown option: $1"; exit 2 ;;
  esac
done

mkdir -p "$WORK"
export SHAVAR_WORK="$WORK"
[ "$KEEP" = 1 ] || trap 'rm -rf "$WORK"' EXIT INT TERM

hdr "constants (spec/SPEC.md 9)"
ensure_discovered
IMPLS=$(impls_with_status ok)
if [ -n "$WANT_IMPLS" ]; then
  sel=""
  for w in $WANT_IMPLS; do for i in $IMPLS; do [ "$i" = "$w" ] && sel="$sel $i"; done; done
  IMPLS=$sel
fi

D="$WORK/constants"; mkdir -p "$D"
ARGS=""
for i in $IMPLS; do
  if impl_run "$i" trace - 0 0 > "$D/$i.trace" 2>"$D/$i.err"; then
    ARGS="$ARGS --hin $i=$D/$i.trace"
  else
    printf '  %sFAIL%s %-5s `trace - 0 0` exited nonzero: %s\n' "$C_RED" "$C_OFF" "$i" \
        "$(head -1 "$D/$i.err")"
    FAILED_TRACE=1
  fi
done

# shellcheck disable=SC2086
"$PYTHON" "$LIB/constants.py" --spec "$ROOT/spec/SPEC.md" $ARGS
rc=$?
[ "${FAILED_TRACE:-0}" = 1 ] && rc=1

if [ "$rc" = 0 ]; then
  printf '\n%sPASS%s constants\n' "$C_GRN" "$C_OFF"
else
  printf '\n%sFAIL%s constants\n' "$C_RED" "$C_OFF"
fi
exit "$rc"
