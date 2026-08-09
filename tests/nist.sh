#!/bin/sh
#
# nist.sh — run every implementation against the NIST CAVP SHAVS known-answer
# vectors held in tests/vectors/.
#
# Discharges verification obligation V5 of spec/SPEC.md 8: "the implementations
# agree with FIPS 180-4".  This is the obligation that cross-testing cannot
# discharge, because seven implementations can share one misreading of the
# standard and agree with each other perfectly while all being wrong.
#
# Four files are used, all SHA-256:
#
#   vectors/byte/SHA256ShortMsg.rsp    65 vectors, 0..512 bits, byte-aligned
#   vectors/byte/SHA256LongMsg.rsp     64 vectors, 1304..51200 bits
#   vectors/bit/SHA256ShortMsg.rsp    513 vectors, 0..512 bits, 448 sub-byte
#   vectors/bit/SHA256LongMsg.rsp     512 vectors, 611..51200 bits, 448 sub-byte
#
# The BIT-oriented pair is the important one.  Arbitrary-bit-length hashing is
# the headline feature of this project (spec/SPEC.md 5), and these 1025 vectors
# are the only authoritative external reference for it that exists: no SHA-256
# program installed on this machine -- openssl, shasum, sha256sum -- can hash a
# message that is not a whole number of bytes.  896 of those 1025 vectors have
# a length that is not a multiple of 8.
#
# The vectors are committed to the repository, so this runs offline.  Refresh
# them with tests/fetch-vectors.sh, which records the source URLs.
#
# Usage:
#   tests/nist.sh [--mode fast|thorough] [--impls "c py ..."] [--jobs N] [--keep]

set -u
. "$(dirname "$0")/lib/common.sh"

MODE=fast
WANT_IMPLS=${SHAVAR_IMPLS:-}
KEEP=0
while [ $# -gt 0 ]; do
  case $1 in
    --mode)  MODE=$2; shift 2 ;;
    --impls) WANT_IMPLS=$2; shift 2 ;;
    --jobs)  JOBS=$2; shift 2 ;;
    --keep)  KEEP=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) err "unknown option: $1"; exit 2 ;;
  esac
done
case $MODE in fast|thorough) ;; *) err "--mode must be fast or thorough"; exit 2 ;; esac

mkdir -p "$WORK"
export SHAVAR_WORK="$WORK"
[ "$KEEP" = 1 ] || trap 'rm -rf "$WORK"' EXIT INT TERM

FAILED=0
SUMMARY="$WORK/summary.tsv"

hdr "shavar vs NIST CAVP SHAVS known-answer vectors"
say "mode     : $MODE"
say "vectors  : $VECTORS"
say "work dir : $WORK"

if [ ! -f "$VECTORS/bit/SHA256ShortMsg.rsp" ] || [ ! -f "$VECTORS/byte/SHA256ShortMsg.rsp" ]; then
  err "NIST vectors are not present under $VECTORS."
  err "Run tests/fetch-vectors.sh (needs network).  No expected digests are"
  err "invented in their absence: without the vectors, V5 is simply unchecked."
  exit 1
fi

# Confirm the committed vectors are the ones that were fetched.  A corrupted
# .rsp would otherwise show up as an implementation bug, which is exactly the
# wrong conclusion to draw.
if [ -f "$VECTORS/SHA256SUMS" ]; then
  if ( cd "$VECTORS" && shasum -a 256 -c SHA256SUMS ) >"$WORK/vecsum.log" 2>&1; then
    say "checksums: all 4 .rsp files match tests/vectors/SHA256SUMS"
  else
    err "tests/vectors/SHA256SUMS does not match the files on disk:"
    sed 's/^/  /' "$WORK/vecsum.log" >&2
    err "Refusing to report results against vectors of unknown provenance."
    exit 1
  fi
fi

ensure_discovered
IMPLS=$(impls_with_status ok)
BROKEN=$(impls_with_status broken)
if [ -n "$WANT_IMPLS" ]; then
  sel=""
  for w in $WANT_IMPLS; do for i in $IMPLS; do [ "$i" = "$w" ] && sel="$sel $i"; done; done
  IMPLS=$sel
fi
[ -n "$BROKEN" ] && FAILED=1

hdr "implementations"
for i in $ALL_IMPLS; do
  st=$(awk -F'\t' -v i="$i" '$1==i {print $2}' "$WORK/impls.tsv")
  printf '  %-5s %-7s %s\n' "$i" "${st:-absent}" "$(reason_for "$i")"
done
[ -n "$(printf '%s' "$IMPLS" | tr -d ' ')" ] || { err "no working implementation"; exit 1; }

run_rsp() {
  _phase=$1; _rsp=$2
  _in="$WORK/$_phase.tsv"; _exp="$WORK/$_phase.expected"; _rej="$WORK/$_phase.rejected"
  _n=$("$PYTHON" "$LIB/nistload.py" "$_rsp" --out-inputs "$_in" \
        --out-expected "$_exp" --out-rejected "$_rej" 2>/dev/null)
  hdr "phase $_phase — $_rsp ($_n vectors)"
  if [ -s "$_rej" ]; then
    warn "$(wc -l < "$_rej" | tr -d ' ') vectors in this file were rejected as unusable:"
    head -5 "$_rej" | sed 's/^/    /'
    FAILED=1
  fi
  _sub=$(awk -F'\t' '$2 % 8 != 0' "$_in" | wc -l | tr -d ' ')
  say "  $_sub of $_n vectors have a bit length that is not a multiple of 8"

  _d="$WORK/$_phase"
  run_phase "$_phase" "$_in" "$MODE" $IMPLS
  say "  sampling (impl / budget / vectors run / measured cost base+perblock ms):"
  awk -F'\t' '{printf "    %-6s %-6s %-6s %s\n", $1, $2, $3, $4}' "$_d/budgets.tsv"
  say ""

  _args=""
  for _i in $IMPLS; do
    [ -f "$_d/$_i.tsv" ] && _args="$_args --col $_i=$_d/$_i.tsv"
  done
  # NIST is the authority: its digests are ground truth, not one more opinion.
  # shellcheck disable=SC2086
  "$PYTHON" "$LIB/compare.py" --phase "$_phase" --inputs "$_in" \
      $_args --col "NIST=$_exp" --authority NIST --summary "$SUMMARY" || FAILED=1
}

run_rsp nist-byte-short "$VECTORS/byte/SHA256ShortMsg.rsp"
run_rsp nist-byte-long  "$VECTORS/byte/SHA256LongMsg.rsp"
run_rsp nist-bit-short  "$VECTORS/bit/SHA256ShortMsg.rsp"
run_rsp nist-bit-long   "$VECTORS/bit/SHA256LongMsg.rsp"

# ------------------------------------------------------- built-in selftests --
hdr 'built-in selftest (the selftest subcommand of spec/CLI.md)'
for i in $IMPLS; do
  out=$(impl_run "$i" selftest 2>&1); rc=$?
  if [ "$rc" = 0 ] && printf '%s' "$out" | grep -Eq '^ok [0-9]+'; then
    printf '  %s%-5s ok%s   %s\n' "$C_GRN" "$i" "$C_OFF" "$(printf '%s' "$out" | head -1)"
  else
    printf '  %s%-5s FAIL%s exit=%s: %s\n' "$C_RED" "$i" "$C_OFF" "$rc" \
        "$(printf '%s' "$out" | head -3 | tr '\n' ' ')"
    FAILED=1
  fi
done

hdr "NIST result"
if [ "$FAILED" = 0 ]; then
  printf '%sPASS%s nist\n' "$C_GRN" "$C_OFF"
else
  printf '%sFAIL%s nist\n' "$C_RED" "$C_OFF"
fi
exit "$FAILED"
