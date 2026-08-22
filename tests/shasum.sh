#!/bin/sh
#
# tests/shasum.sh — the `sha256sum` file-hashing convenience binary.
#
# `sha256sum` is Lean-only and outside the shared CLI contract of spec/CLI.md
# (see the header of lean/Sha256Sum.lean), so contract.sh and crosstest.sh
# never touch it. This phase gives it its own known-answer and behaviour
# checks:
#
#   * digests of the empty file, "abc", and the 256-byte 0x00..0xff ramp
#     match FIPS 180-4 known answers (independently: python3 hashlib agrees);
#   * the line format is exactly <64 lowercase hex><space><space><name>;
#   * stdin is hashed when there are no arguments, and when named as `-`;
#   * an unreadable file diagnoses on stderr, does not stop the remaining
#     arguments, and the exit code is 1.
#
# If the binary has not been built (no `lake build` yet), the phase is
# skipped with a warning rather than failed: the Lean toolchain is optional
# for the polyglot suite, and the other phases already treat it that way.
#
# Usage:
#   tests/shasum.sh          run the checks
set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
# lean/lakefile.toml sends build output to the disposable tree beside the
# repo (CLAUDE.md T2/T4), so the binary is not under lean/.lake.
BIN=$REPO/../_buildoutput/256-shavar/lean/bin/sha256sum

say() { printf '%s\n' "$*"; }
FAILURES=0

fail() { say "shasum: FAIL: $*"; FAILURES=$((FAILURES + 1)); }

if [ ! -x "$BIN" ]; then
  say "shasum: SKIP: $BIN not built (run: cd lean && lake build)"
  exit 0
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/shavar-shasum.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM

# The three known-answer files. Digests are FIPS 180-4 known answers,
# cross-checked against python3 hashlib when this phase was written.
: > "$WORK/empty.bin"
printf 'abc' > "$WORK/abc.bin"
i=0
while [ $i -lt 256 ]; do
  printf "\\$(printf '%03o' $i)" >> "$WORK/ramp.bin"
  i=$((i + 1))
done

D_EMPTY=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
D_ABC=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
D_RAMP=40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880

# Known answers and exact line format, in one invocation with several files.
GOT=$("$BIN" "$WORK/empty.bin" "$WORK/abc.bin" "$WORK/ramp.bin") || fail "multi-file run exited nonzero"
WANT="$D_EMPTY  $WORK/empty.bin
$D_ABC  $WORK/abc.bin
$D_RAMP  $WORK/ramp.bin"
[ "$GOT" = "$WANT" ] || fail "known-answer output mismatch:
--- got ---
$GOT
--- want ---
$WANT"

# stdin: bare invocation and the explicit `-` both hash standard input.
GOT=$(printf 'abc' | "$BIN") || fail "stdin run exited nonzero"
[ "$GOT" = "$D_ABC  -" ] || fail "bare stdin: got '$GOT'"
GOT=$(printf 'abc' | "$BIN" -) || fail "stdin('-') run exited nonzero"
[ "$GOT" = "$D_ABC  -" ] || fail "explicit '-': got '$GOT'"

# An unreadable file: stderr diagnostic, later arguments still hashed, exit 1.
OUT=$("$BIN" "$WORK/no-such-file" "$WORK/abc.bin" 2> "$WORK/err")
RC=$?
[ "$RC" = 1 ] || fail "missing file: exit code $RC, want 1"
[ "$OUT" = "$D_ABC  $WORK/abc.bin" ] || fail "missing file: later argument not hashed: '$OUT'"
grep -q "no-such-file" "$WORK/err" || fail "missing file: no stderr diagnostic naming the file"

# Independent oracle, when one is on the PATH (macOS shasum / coreutils).
if command -v shasum >/dev/null 2>&1; then
  GOT=$("$BIN" "$WORK/ramp.bin" | cut -d' ' -f1)
  WANT=$(shasum -a 256 "$WORK/ramp.bin" | cut -d' ' -f1)
  [ "$GOT" = "$WANT" ] || fail "disagrees with system shasum on ramp.bin: $GOT vs $WANT"
fi

if [ "$FAILURES" = 0 ]; then
  say "shasum: PASS"
  exit 0
else
  say "shasum: $FAILURES failure(s)"
  exit 1
fi
