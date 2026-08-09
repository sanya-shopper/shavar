#!/bin/sh
# CLI-contract tests for the Scheme implementation.
#
# `shavar.scm selftest` checks the algorithm; this script checks the things a
# self-test cannot reach from inside the process: exit codes, the exact bytes
# on stdout, tab-separated trace shape, and that stdout stays empty when a
# diagnostic goes to stderr (../spec/CLI.md).
#
# It also rebuilds the program with the host bitwise libraries made invisible,
# so the R7RS-small arithmetic fallback is exercised end to end rather than
# merely being present in the file.
#
# Usage:  sh scm/test.sh [scheme-interpreter]      (default: chibi-scheme)

set -u

SCHEME=${1:-chibi-scheme}
HERE=$(dirname "$0")
PROG="$HERE/shavar.scm"

pass=0
fail=0

ok()   { pass=$((pass + 1)); }
bad()  { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }

# expect <name> <expected-stdout> <expected-rc> -- <args...>
expect() {
    name=$1; want=$2; want_rc=$3; shift 4
    got=$("$SCHEME" "$PROG" "$@" 2>/dev/null); got_rc=$?
    if [ "$got" = "$want" ] && [ "$got_rc" -eq "$want_rc" ]; then
        ok
    else
        bad "$name: rc=$got_rc (want $want_rc) out=[$got] want=[$want]"
    fi
}

# expect_rc <name> <expected-rc> -- <args...>: also requires stdout to be empty
expect_rc() {
    name=$1; want_rc=$2; shift 3
    got=$("$SCHEME" "$PROG" "$@" 2>/dev/null); got_rc=$?
    if [ "$got_rc" -eq "$want_rc" ] && [ -z "$got" ]; then
        ok
    else
        bad "$name: rc=$got_rc (want $want_rc) stdout=[$got] (want empty)"
    fi
}

M448=6162636462636465636465666465666765666768666768696768696a68696a6b696a6b6c6a6b6c6d6b6c6d6e6c6d6e6f6d6e6f706e6f7071

# ---- digests (FIPS 180-4 known answers) ------------------------------------
expect empty \
  e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 0 -- hash - 0
expect abc \
  ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad 0 -- hash 616263 24
expect 448bit \
  248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1 0 -- hash "$M448" 448

# ---- sub-byte bit lengths (SPEC.md 5.1): accept zero tails, reject nonzero --
expect accept-b0 \
  82c9ef980dfdf26f0cb97f59d34a60dc39c82e489da9ca2132681fe0aa14270a 0 -- hash b0 5
expect accept-b8 \
  9103bf6cd9f1134d81807ade91d54d9888b1a3df1f947f735ce00220dca5261c 0 -- hash b8 5
expect_rc reject-b4  2 -- hash b4 5
expect_rc reject-23bits 2 -- hash 616263 23

# ---- reduced rounds --------------------------------------------------------
expect abc-r32 \
  ddbd225ca600d8a7dc74fea2db8478030b6763919c0f13c6cd6b6de2bcf370d0 0 -- hash 616263 24 32

# ---- usage and malformed input all exit 2 with nothing on stdout -----------
expect_rc no-args        2 --
expect_rc bad-subcommand 2 -- frobnicate
expect_rc missing-nbits  2 -- hash 616263
expect_rc too-many-args  2 -- hash 616263 24 32 extra
expect_rc odd-hex        2 -- hash 61626 24
expect_rc non-hex        2 -- hash 6162zz 24
expect_rc short-buffer   2 -- hash - 8
expect_rc rounds-too-big 2 -- hash 616263 24 65
expect_rc block-oob      2 -- trace 616263 24 1
expect_rc selftest-args  2 -- selftest extra

# ---- digest is exactly 64 lowercase hex digits plus one newline ------------
out=$("$SCHEME" "$PROG" hash 616263 24 | od -An -c | tr -d ' \n')
case $out in
    *'\n') ok ;;
    *) bad "digest must end in exactly one newline (got [$out])" ;;
esac
n=$("$SCHEME" "$PROG" hash 616263 24 | wc -c | tr -d ' ')
[ "$n" = 65 ] && ok || bad "digest line must be 65 bytes, got $n"
if "$SCHEME" "$PROG" hash 616263 24 | grep -q '[A-Z]'; then
    bad "digest must be lowercase"
else
    ok
fi

# ---- trace shape -----------------------------------------------------------
# 8 HIN + 64 W + 68 A + 68 E + 64 T1 + 64 T2 + 8 HOUT = 344 records
n=$("$SCHEME" "$PROG" trace 616263 24 | wc -l | tr -d ' ')
[ "$n" = 344 ] && ok || bad "full trace must be 344 lines, got $n"
# reduced rounds: W stays at 64, A/E become rounds+4, T1/T2 become rounds
n=$("$SCHEME" "$PROG" trace 616263 24 0 20 | wc -l | tr -d ' ')
[ "$n" = 168 ] && ok || bad "20-round trace must be 168 lines, got $n"
# every record is exactly three tab-separated fields
n=$("$SCHEME" "$PROG" trace 616263 24 | awk -F'\t' 'NF!=3' | wc -l | tr -d ' ')
[ "$n" = 0 ] && ok || bad "$n trace records are not 3 tab-separated fields"
# The lookback window is seeded A[-1]=H[0] .. A[-4]=H[3], E[-1]=H[4] ..
# E[-4]=H[7] (SPEC.md 3).  Note the reversal: A[-4] is H[3], not H[0].  (The
# example in CLI.md's formatting note shows `A -4 6a09e667`; that is H[0], and
# it illustrates the escaping of a negative index rather than the seed order,
# which SPEC.md 3 fixes and which any other choice would get wrong digests for.)
seeds=$("$SCHEME" "$PROG" trace 616263 24 |
        awk -F'\t' '($1=="A"||$1=="E") && ($2=="-1"||$2=="-4") {print $1 $2 "=" $3}' |
        tr '\n' ' ')
[ "$seeds" = "A-4=a54ff53a A-1=6a09e667 E-4=5be0cd19 E-1=510e527f " ] \
    && ok || bad "lookback seeding wrong: $seeds"
last=$("$SCHEME" "$PROG" trace 616263 24 | tail -1 | cut -f1)
[ "$last" = HOUT ] && ok || bad "trace must end with HOUT, got $last"

# ---- the built-in vectors --------------------------------------------------
if "$SCHEME" "$PROG" selftest 2>/dev/null | grep -q '^ok '; then ok
else bad "selftest did not report ok"; fi
"$SCHEME" "$PROG" selftest >/dev/null 2>&1 && ok || bad "selftest exit status"

# ---- the same program with no host bitwise library available ---------------
# Rewriting the two `(library ...)` feature requirements to names that cannot
# exist forces `cond-expand` into its `else` clause, so the program runs on
# nothing but R7RS-small arithmetic.
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
sed -e 's/(library (srfi 151))/(library (shavar no such library a))/g' \
    -e 's/(library (scheme bitwise))/(library (shavar no such library b))/g' \
    "$PROG" > "$tmp/portable-only.scm"
if "$SCHEME" "$tmp/portable-only.scm" selftest 2>&1 | grep -q 'none (portable)'; then ok
else bad "portable-only build did not take the fallback branch"; fi
got=$("$SCHEME" "$tmp/portable-only.scm" hash 616263 24 2>/dev/null)
[ "$got" = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad ] \
    && ok || bad "portable-only digest wrong: $got"
"$SCHEME" "$tmp/portable-only.scm" selftest >/dev/null 2>&1 \
    && ok || bad "portable-only selftest failed"

printf '%s: %d passed, %d failed\n' "$0" "$pass" "$fail"
[ "$fail" -eq 0 ]
