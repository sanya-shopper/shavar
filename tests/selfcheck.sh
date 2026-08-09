#!/bin/sh
#
# selfcheck.sh — test the test harness.
#
# A harness that cannot fail is worth nothing, and "all green" is exactly the
# output you get both from eight correct implementations and from a comparator
# with a bug in it.  This script injects faults of each kind the harness claims
# to detect and asserts that it detects them, with the right verdict and a
# nonzero exit status.
#
# It uses no implementation and no network: the faults are synthetic result
# files and mutated copies of a real trace, so this runs in a couple of seconds
# and is meaningful even when every implementation is missing.
#
# Usage: tests/selfcheck.sh [--keep]

set -u
. "$(dirname "$0")/lib/common.sh"

KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

WORK=${SHAVAR_WORK:-${TMPDIR:-/tmp}}/shavar-selfcheck.$$
mkdir -p "$WORK"
[ "$KEEP" = 1 ] || trap 'rm -rf "$WORK"' EXIT INT TERM

hdr "harness self-check"
NPASS=0; NFAIL=0

ok()   { NPASS=$((NPASS + 1)); printf '  %sok%s   %s\n' "$C_GRN" "$C_OFF" "$1"; }
bad()  { NFAIL=$((NFAIL + 1)); printf '  %sFAIL%s %s\n' "$C_RED" "$C_OFF" "$1"; }

# expect_rc WANT DESC CMD...   -- run CMD, capture output in $OUT, check status
expect_rc() {
  _want=$1; _desc=$2; shift 2
  "$@" > "$WORK/out" 2>&1
  _rc=$?
  OUT=$(cat "$WORK/out")
  if [ "$_rc" = "$_want" ]; then return 0; fi
  bad "$_desc: exit $_rc, expected $_want"
  sed 's/^/      /' "$WORK/out" | head -12
  return 1
}

# expect_match DESC PATTERN  -- grep $WORK/out for PATTERN
expect_match() {
  if grep -q "$2" "$WORK/out"; then ok "$1"; else
    bad "$1: output did not contain /$2/"
    sed 's/^/      /' "$WORK/out" | head -12
  fi
}

A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# --------------------------------------------------------------- comparator --
printf '0\t8\taa\n1\t16\taabb\n2\t5\ta8\n' > "$WORK/in.tsv"

mk() { printf '0\t0\t%s\n1\t0\t%s\n2\t0\t%s\n' "$1" "$2" "$3" > "$WORK/$4"; }

# 1. everything agrees with the authority -> clean, exit 0
mk $A $A $A good1; mk $A $A $A good2; mk $A $A $A auth
if expect_rc 0 "comparator passes when all columns match the authority" \
    "$PYTHON" "$LIB/compare.py" --phase t1 --inputs "$WORK/in.tsv" \
      --col "x=$WORK/good1" --col "y=$WORK/good2" --col "NIST=$WORK/auth" \
      --authority NIST; then
  ok "comparator passes when all columns match the authority"
fi

# 2. one column disagrees with the authority -> FAIL, attributed, exit 1
mk $A $B $A wrong
if expect_rc 1 "comparator flags a disagreement with the authority" \
    "$PYTHON" "$LIB/compare.py" --phase t2 --inputs "$WORK/in.tsv" \
      --col "x=$WORK/good1" --col "y=$WORK/wrong" --col "NIST=$WORK/auth" \
      --authority NIST; then
  expect_match "comparator flags a disagreement with the authority" 'FAIL vs NIST'
  expect_match "  ... and names the offending input's bit length" 'nbits=16'
fi

# 3. peers split with no authority -> disputed, blame not assigned, exit 1
if expect_rc 1 "comparator reports a dispute when peers split with no authority" \
    "$PYTHON" "$LIB/compare.py" --phase t3 --inputs "$WORK/in.tsv" \
      --col "x=$WORK/good1" --col "y=$WORK/wrong"; then
  expect_match "comparator reports a dispute when peers split with no authority" 'DISAGREEMENT'
  expect_match "  ... and prints the groups rather than a majority verdict" "$B <- y"
fi

# 4. authorities contradict each other -> reported as an oracle problem, exit 1
mk $A $B $A auth2
if expect_rc 1 "comparator reports authorities contradicting each other" \
    "$PYTHON" "$LIB/compare.py" --phase t4 --inputs "$WORK/in.tsv" \
      --col "x=$WORK/good1" --col "o1=$WORK/auth" --col "o2=$WORK/auth2" \
      --authority o1,o2; then
  expect_match "comparator reports authorities contradicting each other" 'AUTHORITIES DISAGREE'
fi

# 5. a nonzero exit status or empty digest is an error, never a silent skip
printf '0\t0\t%s\n1\t2\t-\n2\t0\t%s\n' "$A" "$A" > "$WORK/errcol"
if expect_rc 1 "comparator counts a nonzero exit / empty digest as an error" \
    "$PYTHON" "$LIB/compare.py" --phase t5 --inputs "$WORK/in.tsv" \
      --col "x=$WORK/errcol" --col "NIST=$WORK/auth" --authority NIST; then
  expect_match "comparator counts a nonzero exit / empty digest as an error" 'errored'
fi

# 6. a timeout is an error too (rc column is the word `timeout`)
printf '0\t0\t%s\n1\ttimeout\t-\n2\t0\t%s\n' "$A" "$A" > "$WORK/tocol"
if expect_rc 1 "comparator counts a timeout as an error" \
    "$PYTHON" "$LIB/compare.py" --phase t6 --inputs "$WORK/in.tsv" \
      --col "x=$WORK/tocol" --col "NIST=$WORK/auth" --authority NIST; then
  expect_match "comparator counts a timeout as an error" 'exit=timeout'
fi

# ---------------------------------------------------------------- tracediff --
# Build a synthetic but contract-shaped trace, then mutate single records.
"$PYTHON" - "$WORK/ref.trace" <<'EOF'
import sys
out = []
for i in range(8):   out.append("HIN\t%d\t%08x" % (i, 0x6a09e667 + i))
for t in range(64):  out.append("W\t%d\t%08x" % (t, 0x11110000 + t))
for t in range(-4, 64): out.append("A\t%d\t%08x" % (t, 0x22220000 + (t & 0xffff)))
for t in range(-4, 64): out.append("E\t%d\t%08x" % (t, 0x33330000 + (t & 0xffff)))
for t in range(64):  out.append("T1\t%d\t%08x" % (t, 0x44440000 + t))
for t in range(64):  out.append("T2\t%d\t%08x" % (t, 0x55550000 + t))
for i in range(8):   out.append("HOUT\t%d\t%08x" % (i, 0x66660000 + i))
open(sys.argv[1], "w").write("\n".join(out) + "\n")
EOF

mutate() {  # mutate LABEL IDX OUTFILE
  awk -F'\t' -v l="$1" -v i="$2" 'BEGIN{OFS="\t"}
      $1==l && $2==i { $3="deadbeef" } {print}' "$WORK/ref.trace" > "$3"
}

# 7. identical traces -> clean
if expect_rc 0 "tracediff accepts two identical, contract-shaped traces" \
    "$PYTHON" "$LIB/tracediff.py" c "$WORK/ref.trace" x "$WORK/ref.trace"; then
  ok "tracediff accepts two identical, contract-shaped traces"
fi

# 8. a single mutated schedule word is localised to exactly W[17]
mutate W 17 "$WORK/m1.trace"
if expect_rc 1 "tracediff localises a schedule fault to W[17]" \
    "$PYTHON" "$LIB/tracediff.py" c "$WORK/ref.trace" x "$WORK/m1.trace"; then
  expect_match "tracediff localises a schedule fault to W[17]" 'first at W\[17\]'
fi

# 9. causal ordering: W[17] and A[3] both wrong -> A[3] is the earlier fault,
#    even though every W record is emitted before every A record (CLI.md).
mutate W 17 "$WORK/m2a.trace"
awk -F'\t' 'BEGIN{OFS="\t"} $1=="A" && $2==3 { $3="deadbeef" } {print}' \
    "$WORK/m2a.trace" > "$WORK/m2.trace"
if expect_rc 1 "tracediff prefers the causally earlier fault over the file order" \
    "$PYTHON" "$LIB/tracediff.py" c "$WORK/ref.trace" x "$WORK/m2.trace"; then
  expect_match "tracediff prefers the causally earlier fault over the file order" 'first at A\[3\]'
fi

# 10. within one round, T1[5] precedes A[5]
awk -F'\t' 'BEGIN{OFS="\t"} ($1=="T1" || $1=="A") && $2==5 { $3="deadbeef" } {print}' \
    "$WORK/ref.trace" > "$WORK/m3.trace"
if expect_rc 1 "tracediff orders T1[t] before A[t] within a round" \
    "$PYTHON" "$LIB/tracediff.py" c "$WORK/ref.trace" x "$WORK/m3.trace"; then
  expect_match "tracediff orders T1[t] before A[t] within a round" 'first at T1\[5\]'
fi

# 11. a formatting deviation is a contract violation in its own right
sed 's/^W\t20\t.*/W\t20\tDEADBEEF/' "$WORK/ref.trace" > "$WORK/m4.trace"
if expect_rc 1 "tracediff rejects an uppercase hex record" \
    "$PYTHON" "$LIB/tracediff.py" c "$WORK/ref.trace" x "$WORK/m4.trace"; then
  expect_match "tracediff rejects an uppercase hex record" 'contract problem'
fi

# 12. a truncated trace is caught as missing records, not as agreement
grep -v '^T2	6[0-3]	' "$WORK/ref.trace" > "$WORK/m5.trace"
if expect_rc 1 "tracediff catches a truncated trace" \
    "$PYTHON" "$LIB/tracediff.py" c "$WORK/ref.trace" x "$WORK/m5.trace"; then
  expect_match "tracediff catches a truncated trace" 'missing'
fi

# ------------------------------------------------------------ corpus + rsp --
# 13. the generator never emits a final byte with nonzero trailing bits
if expect_rc 0 "corpus generator self-check passes (SPEC.md 5.1 encoding)" \
    "$PYTHON" "$LIB/gen_corpus.py" --seed selfcheck --mode fast --phase random --selfcheck; then
  ok "corpus generator self-check passes (SPEC.md 5.1 encoding)"
fi

# 14. ... and an independent re-verification of the same property
"$PYTHON" "$LIB/gen_corpus.py" --seed selfcheck --mode thorough --phase sweep > "$WORK/c.tsv"
if "$PYTHON" - "$WORK/c.tsv" <<'EOF'
import sys
bad = 0
for line in open(sys.argv[1]):
    _k, n, hx = line.rstrip("\n").split("\t")
    n = int(n)
    nby = 0 if hx == "-" else len(hx) // 2
    if nby != (n + 7) // 8: bad += 1; continue
    if n % 8 and bytes.fromhex(hx)[-1] & ((1 << (8 - n % 8)) - 1): bad += 1
sys.exit(1 if bad else 0)
EOF
then ok "every generated message is correctly encoded (independent re-check)"
else bad "generated corpus violates the encoding rule"; fi

# 15. the corpus reaches the padding boundaries it claims to
for want in 447 448 449 511 512 513 959 960 961 1471 1472; do
  if ! awk -F'\t' -v w="$want" '$2 == w {found=1} END {exit !found}' "$WORK/c.tsv"; then
    bad "thorough sweep is missing bit length $want"
    continue
  fi
done
ok "thorough sweep covers the 1-, 2- and 3-block padding boundaries"

# 16. the .rsp loader maps `Len = 0, Msg = 00` to the EMPTY message, not to 0x00
if [ -f "$VECTORS/bit/SHA256ShortMsg.rsp" ]; then
  "$PYTHON" "$LIB/nistload.py" "$VECTORS/bit/SHA256ShortMsg.rsp" \
      --out-inputs "$WORK/n.in" --out-expected "$WORK/n.exp" >/dev/null 2>&1
  first=$(head -1 "$WORK/n.in")
  case $first in
    *"	0	-") ok "nistload maps Len=0 / Msg=00 to the empty message" ;;
    *) bad "nistload mishandled the Len=0 dummy Msg line: got '$first'" ;;
  esac
  # and the count matches the number of MD lines in the file
  want=$(grep -c '^MD = ' "$VECTORS/bit/SHA256ShortMsg.rsp")
  got=$(wc -l < "$WORK/n.in" | tr -d ' ')
  if [ "$want" = "$got" ]; then ok "nistload read all $got vectors from the file"
  else bad "nistload read $got vectors but the file has $want MD lines"; fi
else
  printf '  %sskip%s NIST vector checks: %s not present\n' "$C_YEL" "$C_OFF" "$VECTORS"
fi

# ---------------------------------------------------------------- sampling --
# 17. subsampling keeps the first and last row, and is deterministic
seq 1 500 | awk '{print $1 "\t" ($1 * 8) "\tab"}' > "$WORK/s.tsv"
sfail=0
for b in 1 2 3 7 24 130; do
  subsample "$WORK/s.tsv" "$WORK/s1.out" "$b"
  subsample "$WORK/s.tsv" "$WORK/s2.out" "$b"
  cmp -s "$WORK/s1.out" "$WORK/s2.out" || { bad "subsample at budget $b is not deterministic"; sfail=1; }
  n=$(wc -l < "$WORK/s1.out" | tr -d ' ')
  [ "$n" = "$b" ] || { bad "subsample at budget $b returned $n rows"; sfail=1; }
  if [ "$b" -gt 1 ]; then
    [ "$(head -1 "$WORK/s1.out" | cut -f1)" = 1 ]   || { bad "subsample at budget $b dropped the first row"; sfail=1; }
    [ "$(tail -1 "$WORK/s1.out" | cut -f1)" = 500 ] || { bad "subsample at budget $b dropped the last row"; sfail=1; }
  fi
done
[ "$sfail" = 0 ] && ok "subsampling is deterministic and keeps the first and last row"

# 18. the timeout really fires rather than hanging the suite
cat > "$WORK/hang.sh" <<'EOF'
#!/bin/sh
sleep 300
EOF
chmod +x "$WORK/hang.sh"
printf '%s\0' "$WORK/hang.sh" > "$WORK/argv.hang"
printf '0\t8\taa\n' > "$WORK/hin.tsv"
"$PYTHON" "$LIB/runner.py" --op hash --cmdfile "$WORK/argv.hang" \
    --inputs "$WORK/hin.tsv" --out "$WORK/hout.tsv" --timeout 2 >/dev/null 2>&1
if grep -q 'timeout' "$WORK/hout.tsv" 2>/dev/null; then
  ok "a hanging implementation is killed and recorded as a timeout"
else
  bad "the per-invocation timeout did not fire: $(cat "$WORK/hout.tsv" 2>/dev/null)"
fi

# --------------------------------------------------------------------- done --
say ""
say "  $NPASS self-checks passed, $NFAIL failed"
if [ "$NFAIL" = 0 ]; then
  printf '\n%sPASS%s selfcheck\n' "$C_GRN" "$C_OFF"
  exit 0
else
  printf '\n%sFAIL%s selfcheck — the harness cannot be trusted until this is green\n' "$C_RED" "$C_OFF"
  exit 1
fi
