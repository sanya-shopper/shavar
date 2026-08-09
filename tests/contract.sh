#!/bin/sh
#
# contract.sh — check the command-line contract itself, not the arithmetic.
#
# spec/CLI.md fixes the encoding as tightly as spec/SPEC.md fixes the
# algorithm, and for a reason it states plainly: the cross-testing harness
# compares output byte-for-byte, so "a capital hex digit, a space instead of a
# tab, a missing trailing newline" has to register as a failure.  Everything
# checked here is normative text from that file.
#
# Two classes of check:
#
#   ACCEPT   inputs that must succeed, with output of exactly the right shape.
#            Note what is and is not asserted: that `hash - 0` prints 64
#            lowercase hex digits and one newline and nothing else is a CLI.md
#            requirement, so it is checked here; that the digest equals
#            e3b0c442... is a FIPS requirement, so it is checked in
#            tests/nist.sh against the NIST vector rather than hardcoded here.
#
#   REJECT   inputs that must fail with exit code 2 and an EMPTY stdout.  The
#            most important is a final byte with nonzero trailing bits:
#            SPEC.md 5.1 requires rejection rather than silent masking,
#            "because silently masking makes two distinct inputs hash the same
#            and would hide caller bugs".  An implementation that quietly
#            masks would pass every digest comparison in this harness -- the
#            corpus generator is careful to clear those bits -- and only this
#            check would catch it.
#
# Usage: tests/contract.sh [--impls "c py ..."] [--keep]

set -u
. "$(dirname "$0")/lib/common.sh"

WANT_IMPLS=${SHAVAR_IMPLS:-}
KEEP=0
while [ $# -gt 0 ]; do
  case $1 in
    --impls) WANT_IMPLS=$2; shift 2 ;;
    --keep)  KEEP=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) err "unknown option: $1"; exit 2 ;;
  esac
done

mkdir -p "$WORK"
export SHAVAR_WORK="$WORK"
[ "$KEEP" = 1 ] || trap 'rm -rf "$WORK"' EXIT INT TERM

hdr "CLI contract (spec/CLI.md)"
ensure_discovered
IMPLS=$(impls_with_status ok)
if [ -n "$WANT_IMPLS" ]; then
  sel=""
  for w in $WANT_IMPLS; do for i in $IMPLS; do [ "$i" = "$w" ] && sel="$sel $i"; done; done
  IMPLS=$sel
fi

D="$WORK/contract"; mkdir -p "$D"
FAILED=0
NPASS=0
NFAIL=0

# Each implementation is checked in its own subshell so that eight of them cost
# what the slowest one costs rather than the sum; the counters therefore live
# in files rather than in shell variables, which would not survive the fork.
fail() { printf '  %sFAIL%s %-5s %s\n' "$C_RED" "$C_OFF" "$1" "$2" >> "$LOG"; F=1; NF=$((NF + 1)); }
pass() { NP=$((NP + 1)); }

# ---- ACCEPT cases -----------------------------------------------------------
# name : hex nbits   -- must exit 0 and print one line of 64 lowercase hex.
#
# The padding boundaries here are the ones SPEC.md 5 makes interesting: 447
# bits is the largest message that still pads into a single block (447 + 1 + 64
# = 512), 448 is the smallest that needs two, and 449 crosses it with a
# one-significant-bit final byte.  For the non-byte-aligned lengths the final
# byte has its low bits cleared, as spec/CLI.md requires of any caller.
B48=00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff
accept_cases="
empty-message|- 0
sub-byte-5|b0 5
one-bit|80 1
abc-24|616263 24
boundary-447|${B48}0011223344556676 447
boundary-448|${B48}0011223344556677 448
boundary-449|${B48}001122334455667780 449
exact-block-512|${B48}00112233445566778899aabbccddeeff 512
two-block-513|${B48}00112233445566778899aabbccddeeff80 513
"

# ---- REJECT cases -----------------------------------------------------------
# Each must exit 2 (spec/CLI.md "Exit codes") with nothing on stdout.
reject_cases='
nonzero-trailing-bits|b1 5
nonzero-trailing-bits-1|01 1
odd-hex-digits|abc 12
non-hex-characters|zz 8
too-few-bytes-for-nbits|6162 24
too-many-bytes-for-nbits|61626364 24
negative-nbits|61 -8
'

check_impl() {
  i=$1
  LOG="$D/$i.log"; : > "$LOG"
  NP=0; NF=0; F=0
  bad=0
  # ---- accept
  OLDIFS=$IFS; IFS='
'
  for case in $accept_cases; do
    [ -n "$case" ] || continue
    name=${case%%|*}; rest=${case#*|}
    hx=${rest%% *}; nb=${rest##* }
    IFS=$OLDIFS
    impl_run "$i" hash "$hx" "$nb" > "$D/$i.$name.out" 2>"$D/$i.$name.err"
    rc=$?
    if [ "$rc" != 0 ]; then
      fail "$i" "accept/$name: exit $rc, expected 0  ($(head -1 "$D/$i.$name.err"))"; bad=1
    elif ! grep -Eq '^[0-9a-f]{64}$' "$D/$i.$name.out"; then
      fail "$i" "accept/$name: stdout is not 64 lowercase hex digits: $(head -c 90 "$D/$i.$name.out")"; bad=1
    elif [ "$(wc -c < "$D/$i.$name.out" | tr -d ' ')" != 65 ]; then
      fail "$i" "accept/$name: stdout is $(wc -c < "$D/$i.$name.out" | tr -d ' ') bytes, expected 65 (64 hex + one newline)"; bad=1
    else
      pass
    fi
    IFS='
'
  done
  # ---- reject
  for case in $reject_cases; do
    [ -n "$case" ] || continue
    name=${case%%|*}; rest=${case#*|}
    hx=${rest%% *}; nb=${rest##* }
    IFS=$OLDIFS
    impl_run "$i" hash "$hx" "$nb" > "$D/$i.$name.out" 2>"$D/$i.$name.err"
    rc=$?
    if [ "$rc" != 2 ]; then
      got=$(head -c 70 "$D/$i.$name.out" | tr -d '\n')
      fail "$i" "reject/$name (\`hash $hx $nb\`): exit $rc, expected 2${got:+; stdout was $got}"; bad=1
    elif [ -s "$D/$i.$name.out" ]; then
      fail "$i" "reject/$name: exited 2 but wrote to stdout, which spec/CLI.md reserves for well-formed output: $(head -c 70 "$D/$i.$name.out")"; bad=1
    else
      pass
    fi
    IFS='
'
  done
  IFS=$OLDIFS

  # ---- trace shape, checked against the record grammar of spec/CLI.md
  impl_run "$i" trace 616263 24 0 > "$D/$i.trace" 2>/dev/null
  if [ $? != 0 ] || [ ! -s "$D/$i.trace" ]; then
    fail "$i" "trace 616263 24 0 produced no output"; bad=1
  else
    out=$("$PYTHON" "$LIB/tracediff.py" "$i" "$D/$i.trace" "$i" "$D/$i.trace" 2>&1)
    if printf '%s' "$out" | grep -q 'contract problem'; then
      fail "$i" "trace violates the spec/CLI.md record format:"
      printf '%s\n' "$out" | grep 'contract problem' | head -4 | sed 's/^/      /'
      bad=1
    else
      pass
    fi
  fi

  [ "$bad" = 0 ] && printf '  %s%-5s ok%s   all accept/reject/trace-shape cases\n' "$C_GRN" "$i" "$C_OFF" >> "$LOG"
  printf '%s\t%s\t%s\n' "$NP" "$NF" "$F" > "$D/$i.cnt"
}

pids=""
for i in $IMPLS; do
  check_impl "$i" &
  pids="$pids $!"
done
for p in $pids; do wait "$p"; done

# Replay the per-implementation logs in roster order, so the output is
# deterministic even though the work was not.
for i in $ALL_IMPLS; do
  [ -f "$D/$i.log" ] && cat "$D/$i.log"
  if [ -f "$D/$i.cnt" ]; then
    np=$(cut -f1 "$D/$i.cnt"); nf=$(cut -f2 "$D/$i.cnt"); f=$(cut -f3 "$D/$i.cnt")
    NPASS=$((NPASS + np)); NFAIL=$((NFAIL + nf))
    [ "$f" = 1 ] && FAILED=1
  fi
done

say ""
say "  $NPASS checks passed, $NFAIL failed"
if [ "$FAILED" = 0 ]; then
  printf '\n%sPASS%s contract\n' "$C_GRN" "$C_OFF"
else
  printf '\n%sFAIL%s contract\n' "$C_RED" "$C_OFF"
fi
exit "$FAILED"
