#!/bin/sh
#
# crosstest.sh — cross-implementation testing for shavar.
#
# Discharges verification obligation V6 of spec/SPEC.md 8 ("the implementations
# agree with each other"), and the part of V5 that four independent external
# SHA-256 programs on this machine are able to witness.
#
# What it does, in order:
#
#   1. Discovers which builds are present -- the seven implementations, with
#      the shell one run under both bash and zsh, so eight ids in all.  They
#      are being written in parallel, so absence is normal and is reported, not
#      treated as a pass.  An implementation that is present but cannot answer
#      the CLI contract is reported as BROKEN and fails the run.
#
#   2. Builds a deterministic corpus from an explicit seed:
#        - sweep:  every bit length 0..600 (thorough), which straddles the
#                  one-block/two-block padding boundary at 447/448 and the
#                  512-bit block boundary, plus bands around the 2- and 3-block
#                  boundaries at 959/960 and 1471/1472;
#        - random: random content at random lengths up to several thousand
#                  bits, most of them not byte-aligned.
#
#   3. Hashes the whole corpus with every implementation, and with every
#      external oracle for the byte-aligned rows, and compares all columns.
#
#   4. Diffs FULL PER-ROUND TRACES between implementations on a sample of
#      inputs, so a disagreement is localised to a register and round index
#      rather than only to a digest.
#
# COVERAGE LIMIT, stated here and again at the end of every run: none of the
# four external oracles can hash a message that is not a whole number of bytes.
# For nbits % 8 != 0 the only external evidence is the NIST bit-oriented
# vectors (tests/nist.sh); within this script such rows rest on
# cross-implementation agreement alone.
#
# Usage:
#   tests/crosstest.sh [--mode fast|thorough] [--seed SEED] [--impls "c py ..."]
#                      [--jobs N] [--keep]
#
# Every failure prints the exact input (hex + nbits) and the seed, so any
# failure replays with:  tests/crosstest.sh --seed <SEED> --mode <MODE>

set -u
. "$(dirname "$0")/lib/common.sh"

MODE=fast
SEED=""
WANT_IMPLS=${SHAVAR_IMPLS:-}
KEEP=0

while [ $# -gt 0 ]; do
  case $1 in
    --mode)   MODE=$2; shift 2 ;;
    --seed)   SEED=$2; shift 2 ;;
    --impls)  WANT_IMPLS=$2; shift 2 ;;
    --jobs)   JOBS=$2; shift 2 ;;
    --keep)   KEEP=1; shift ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    *) err "unknown option: $1"; exit 2 ;;
  esac
done

case $MODE in fast|thorough) ;; *) err "--mode must be fast or thorough"; exit 2 ;; esac

# ------------------------------------------------------------------- seed --
# The seed is printed at the start of every run and accepted back as an
# argument, so a failure seen once is reproducible exactly.
if [ -z "$SEED" ]; then
  SEED=$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' \n')
  [ -n "$SEED" ] || SEED=$(date +%s)
fi

mkdir -p "$WORK"
export SHAVAR_WORK="$WORK"
[ "$KEEP" = 1 ] || trap 'rm -rf "$WORK"' EXIT INT TERM

FAILED=0
SUMMARY="$WORK/summary.tsv"

hdr "shavar cross-implementation test"
say "mode        : $MODE"
say "seed        : $SEED       <-- replay with: tests/crosstest.sh --seed $SEED --mode $MODE"
say "work dir    : $WORK"
say "parallelism : $JOBS shards per implementation, implementations run concurrently"

# -------------------------------------------------------------- discovery --
ensure_discovered

IMPLS=$(impls_with_status ok)
BROKEN=$(impls_with_status broken)
ABSENT=$(impls_with_status absent)

if [ -n "$WANT_IMPLS" ]; then
  sel=""
  for w in $WANT_IMPLS; do
    for i in $IMPLS; do [ "$i" = "$w" ] && sel="$sel $i"; done
  done
  IMPLS=$sel
fi

hdr "implementations"
for i in $ALL_IMPLS; do
  st=$(awk -F'\t' -v i="$i" '$1==i {print $2}' "$WORK/impls.tsv")
  rs=$(reason_for "$i")
  case $st in
    ok)     printf '  %s%-5s ok     %s%s\n' "$C_GRN" "$i" "$C_OFF" "$rs" ;;
    broken) printf '  %s%-5s BROKEN %s%s\n' "$C_RED" "$i" "$C_OFF" "$rs" ;;
    *)      printf '  %s%-5s absent%s %s\n' "$C_YEL" "$i" "$C_OFF" "$rs" ;;
  esac
done
[ -n "$BROKEN" ] && FAILED=1

hdr "external oracles (byte-aligned inputs only)"
while IFS='	' read -r oid ost odesc; do
  case $ost in
    ok) printf '  %s%-12s ok%s  %s\n' "$C_GRN" "$oid" "$C_OFF" "$odesc" ;;
    *)  printf '  %s%-12s absent%s %s\n' "$C_YEL" "$oid" "$C_OFF" "$odesc" ;;
  esac
done < "$WORK/oracles.tsv"

NIMPL=0
for i in $IMPLS; do NIMPL=$((NIMPL + 1)); done
if [ "$NIMPL" -eq 0 ]; then
  err "no working implementation found; nothing can be cross-tested"
  exit 1
fi
if [ "$NIMPL" -eq 1 ] && [ -z "$(oracles_ok)" ]; then
  warn "only one working implementation and no oracle: cross-testing is vacuous"
fi

# --------------------------------------------------------- corpus + phases --
cols_for() {
  # emit --col arguments for every implementation and oracle result present
  _d=$1
  for _i in $IMPLS; do
    [ -f "$_d/$_i.tsv" ] && printf -- '--col\n%s=%s\n' "$_i" "$_d/$_i.tsv"
  done
  for _o in $(oracles_ok); do
    [ -f "$_d/$_o.tsv" ] && printf -- '--col\n%s=%s\n' "$_o" "$_d/$_o.tsv"
  done
}

run_and_compare() {
  _phase=$1
  _in="$WORK/$_phase.tsv"
  _d="$WORK/$_phase"
  _n=$(wc -l < "$_in" | tr -d ' ')
  hdr "phase $_phase ($_n inputs)"
  run_phase "$_phase" "$_in" "$MODE" $IMPLS
  run_oracles "$_phase" "$_in"
  say "  sampling (impl / budget / inputs run / measured cost base+perblock ms):"
  awk -F'\t' '{printf "    %-6s %-6s %-6s %s\n", $1, $2, $3, $4}' "$_d/budgets.tsv"
  _nb=$(awk -F'\t' '$2 % 8 == 0' "$_in" | wc -l | tr -d ' ')
  say "    oracles      all    $_nb  (byte-aligned rows only, of $_n)"
  say ""
  # Oracles are authorities: they are independent, already-validated codebases.
  _auth=$(oracles_ok | tr ' ' ',' | sed 's/,*$//')
  cols_for "$_d" | tr '\n' '\0' | xargs -0 "$PYTHON" "$LIB/compare.py" \
      --phase "$_phase" --inputs "$_in" \
      --authority "$_auth" --summary "$SUMMARY" || FAILED=1
}

"$PYTHON" "$LIB/gen_corpus.py" --seed "$SEED" --mode "$MODE" --phase sweep  --selfcheck > "$WORK/sweep.tsv"
"$PYTHON" "$LIB/gen_corpus.py" --seed "$SEED" --mode "$MODE" --phase random --selfcheck > "$WORK/random.tsv"

run_and_compare sweep
run_and_compare random

# --------------------------------------------------------- trace crosscheck --
#
# This is the part that makes the harness more useful than a digest diff.  Two
# implementations that disagree on a digest disagree on some earlier interior
# value; the trace pins down which one.
hdr "trace cross-check (per-round W / A / E / T1 / T2)"

REF=""
for cand in c py pl lean js scm sh shz; do
  for i in $IMPLS; do [ "$i" = "$cand" ] && [ -z "$REF" ] && REF=$i; done
done
say "  reference implementation: $REF"

# Trace samples: a few fixed structural cases plus a deterministic sample from
# the corpus, each at block 0 and at the final block of the padded message.
TSAMP="$WORK/trace-inputs.tsv"
: > "$TSAMP"
{
  printf -- '-\t0\n'          # empty message: pure padding block
  printf 'b0\t5\n'            # SPEC.md 5.2 worked example, sub-byte
  printf '616263\t24\n'       # "abc", the FIPS example
} > "$WORK/trace-fixed.tsv"

cat "$WORK/sweep.tsv" "$WORK/random.tsv" | awk -F'\t' '{print $3 "\t" $2}' > "$WORK/trace-pool.tsv"
TBUDGET=$(budget_for "$REF" trace "$MODE" "$WORK/sweep.tsv")
subsample "$WORK/trace-pool.tsv" "$WORK/trace-sample.tsv" "$TBUDGET"
cat "$WORK/trace-fixed.tsv" "$WORK/trace-sample.tsv" |
  awk -F'\t' '{
      nblocks = int(($2 + 64) / 512) + 1
      printf "%d\t%s\t%s\t%d\n", n++, $1, $2, 0
      if (nblocks > 1) printf "%d\t%s\t%s\t%d\n", n++, $1, $2, nblocks - 1
  }' > "$TSAMP"

NT=$(wc -l < "$TSAMP" | tr -d ' ')
say "  $NT candidate trace comparisons (input x block index); each implementation"
say "  runs as many of them as its measured cost budget allows"

TD="$WORK/traces"; mkdir -p "$TD"
tpids=""
for i in $IMPLS; do
  ( subsample "$TSAMP" "$TD/in-$i.tsv" "$(budget_for "$i" trace "$MODE")"
    "$PYTHON" "$LIB/runner.py" --op trace --tag "$i" --cmdfile "$WORK/argv.$i" \
        --inputs "$TD/in-$i.tsv" --tracedir "$TD" --timeout "$TIMEOUT" ) &
  tpids="$tpids $!"
done
for p in $tpids; do wait "$p"; done

TRACE_BAD=0
TRACE_OK=0
while IFS='	' read -r k hx nb bi; do
  [ -f "$TD/$REF.$k" ] || continue
  refrc=$(cat "$TD/$REF.$k.rc" 2>/dev/null || echo 1)
  if [ "$refrc" != 0 ] || [ ! -s "$TD/$REF.$k" ]; then
    printf '  %sreference %s failed to trace%s nbits=%s block=%s msg=%s (exit %s)\n' \
        "$C_RED" "$REF" "$C_OFF" "$nb" "$bi" "$(printf '%.40s' "$hx")" "$refrc"
    head -2 "$TD/$REF.$k.err" 2>/dev/null | sed 's/^/    /'
    TRACE_BAD=$((TRACE_BAD + 1)); FAILED=1
    continue
  fi
  for i in $IMPLS; do
    [ "$i" = "$REF" ] && continue
    [ -f "$TD/$i.$k.rc" ] || continue     # subsampled away for a slow impl
    rc=$(cat "$TD/$i.$k.rc")
    if [ "$rc" != 0 ]; then
      printf '  %sFAIL%s %s trace exited %s  nbits=%s block=%s msg=%s\n' \
          "$C_RED" "$C_OFF" "$i" "$rc" "$nb" "$bi" "$(printf '%.40s' "$hx")"
      head -2 "$TD/$i.$k.err" 2>/dev/null | sed 's/^/    /'
      TRACE_BAD=$((TRACE_BAD + 1)); FAILED=1
      continue
    fi
    if cmp -s "$TD/$REF.$k" "$TD/$i.$k"; then
      TRACE_OK=$((TRACE_OK + 1))
      continue
    fi
    printf '  %sFAIL%s trace mismatch  nbits=%s block=%s\n    msg = %s\n' \
        "$C_RED" "$C_OFF" "$nb" "$bi" "$hx"
    "$PYTHON" "$LIB/tracediff.py" "$REF" "$TD/$REF.$k" "$i" "$TD/$i.$k"
    TRACE_BAD=$((TRACE_BAD + 1)); FAILED=1
  done
done < "$TSAMP"

# Even when every trace matches byte-for-byte, check the reference trace itself
# against the contract: a shared formatting deviation would otherwise pass.
if [ "$TRACE_BAD" = 0 ]; then
  firstk=$(head -1 "$TSAMP" | cut -f1)
  if [ -n "${firstk:-}" ] && [ -s "$TD/$REF.$firstk" ]; then
    "$PYTHON" "$LIB/tracediff.py" "$REF" "$TD/$REF.$firstk" "$REF" "$TD/$REF.$firstk" \
        >"$WORK/trace-contract.txt" 2>&1 || FAILED=1
    grep -q 'contract problem' "$WORK/trace-contract.txt" && {
      printf '  %sFAIL%s reference trace violates spec/CLI.md:\n' "$C_RED" "$C_OFF"
      cat "$WORK/trace-contract.txt"
    }
  fi
fi
say "  trace comparisons: $TRACE_OK identical, $TRACE_BAD mismatched"

# ------------------------------------------------------------------ wrap up --
hdr "crosstest result"
say "seed $SEED (mode $MODE) — rerun with: tests/crosstest.sh --seed $SEED --mode $MODE"
say ""
say "Coverage note, so this run is not read as saying more than it checked:"
NONBYTE=$(cat "$WORK/sweep.tsv" "$WORK/random.tsv" | awk -F'\t' '$2 % 8 != 0' | wc -l | tr -d ' ')
TOTALIN=$(cat "$WORK/sweep.tsv" "$WORK/random.tsv" | wc -l | tr -d ' ')
say "  * $NONBYTE of $TOTALIN corpus inputs are NOT byte-aligned.  No external"
say "    oracle on this machine can hash a partial byte, so for those inputs the"
say "    evidence here is cross-implementation agreement only.  Independent"
say "    confirmation for sub-byte lengths comes from the NIST bit-oriented"
say "    vectors: run tests/nist.sh."
say "  * Agreement between implementations is not correctness.  V5 (NIST) and"
say "    V6 (this script) are separate obligations; see spec/SPEC.md 8."
if [ -n "$BROKEN" ]; then
  say "  * present but non-functional, counted as failures:$BROKEN"
fi
if [ -n "$ABSENT" ]; then
  say "  * not yet present, untested:$ABSENT"
fi

if [ "$FAILED" = 0 ]; then
  printf '\n%sPASS%s crosstest\n' "$C_GRN" "$C_OFF"
else
  printf '\n%sFAIL%s crosstest\n' "$C_RED" "$C_OFF"
fi
exit "$FAILED"
