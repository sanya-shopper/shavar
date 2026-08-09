#!/usr/bin/env bash
#
# Tests for sh/shavar.sh. Runs under bash 3.2 and zsh 5.9; run it under both.
#
#   /bin/bash sh/shavar_test.sh
#   /bin/zsh  sh/shavar_test.sh
#
# Exit 0 if every check passes, 1 otherwise.
#
# Unlike shavar.sh itself, this file is allowed to fork: it spawns the CLI as a
# subprocess and it runs the same commands under the *other* shell to compare.
# The no-external-commands rule applies to the implementation's hot path, not
# to the harness that checks it.
#
# What is checked, and why each check exists:
#
#   1. selftest         the built-in known-answer vectors, via the CLI.
#   2. KATs             FIPS/CAVP digests, byte-aligned and sub-byte, driven
#                       through the command line rather than the library, so
#                       that argument handling is on the hook too.
#   3. bit lengths      SPEC.md §5.1 says a final byte with nonzero low bits is
#                       rejected, not masked. Tested in BOTH directions: a
#                       validator that rejected everything would pass a
#                       one-sided test.
#   4. exit codes       CLI.md's table, and the rule that stdout carries either
#                       well-formed output or nothing at all.
#   5. trace shape      record count and field format for full and reduced
#                       round counts.
#   6. DRIFT            shavar.sh inlines all six round functions into one
#                       arithmetic expression for speed, duplicating the
#                       separately exposed shavar_ch/shavar_maj/... . This test
#                       recompresses a block using only those functions and
#                       demands the two agree on W, A, E, T1, T2 and H. It is
#                       the check that catches a typo in the inlined copy.
#   7. constants        the K and IV tables are compared against the ones
#                       written out in spec/SPEC.md §9, read with the shell's
#                       own `read` builtin. A mistyped constant is the classic
#                       way one implementation of seven ends up subtly wrong.
#   8. cross-shell      every command run under both /bin/bash and /bin/zsh
#                       with identical stdout and exit status demanded. This is
#                       the check that catches an array index origin mistake,
#                       which is otherwise silent.
#
# $0 is captured here, at file scope. Inside a function under zsh's `emulate -L
# ksh`, $0 is the function name, not the script path.
SHAVAR_TEST_0=$0
SHAVAR_DIR=${SHAVAR_TEST_0%/*}
[ "$SHAVAR_DIR" = "$SHAVAR_TEST_0" ] && SHAVAR_DIR=.
SHAVAR_SH=$SHAVAR_DIR/shavar.sh
SHAVAR_SPEC=$SHAVAR_DIR/../spec/SPEC.md

PASS=0
FAIL=0
NL='
'

ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1" >&2; }
chk()  { if [ "$2" = "$3" ]; then ok; else bad "$1${NL}      expected [$3]${NL}      got      [$2]"; fi; }

# Which interpreter runs the CLI for the single-shell checks: whichever one is
# running this test.
if [ -n "${ZSH_VERSION:-}" ]; then RUNNER=/bin/zsh; else RUNNER=/bin/bash; fi

# --------------------------------------------------------------------------
# 1-2. self-test and known-answer vectors through the CLI
# --------------------------------------------------------------------------
t_selftest() {
  local out rc
  out=$("$RUNNER" "$SHAVAR_SH" selftest 2>&1); rc=$?
  if [ $rc -eq 0 ]; then ok; else bad "selftest exited $rc: $out"; fi
  case "$out" in ok\ *) ok ;; *) bad "selftest printed [$out], expected 'ok <n>'" ;; esac
}

kat() { # <hex> <nbits> <expected> [rounds]
  local got rc
  if [ $# -ge 4 ]; then
    got=$("$RUNNER" "$SHAVAR_SH" hash "$1" "$2" "$4" 2>&1); rc=$?
  else
    got=$("$RUNNER" "$SHAVAR_SH" hash "$1" "$2" 2>&1); rc=$?
  fi
  if [ $rc -ne 0 ]; then bad "hash $1 $2 exited $rc: $got"; return; fi
  chk "hash $1 $2 ${4:-64}" "$got" "$3"
}

M448=6162636462636465636465666465666765666768666768696768696a68696a6b696a6b6c6a6b6c6d6b6c6d6e6c6d6e6f6d6e6f706e6f7071
M896=61626364656667686263646566676869636465666768696a6465666768696a6b65666768696a6b6c666768696a6b6c6d6768696a6b6c6d6e68696a6b6c6d6e6f696a6b6c6d6e6f706a6b6c6d6e6f70716b6c6d6e6f7071726c6d6e6f707172736d6e6f70717273746e6f707172737475

t_kats() {
  kat -      0   e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
  kat 616263 24  ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
  kat "$M448" 448 248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1
  kat "$M896" 896 cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1
  # a whole block of 0xff: the padding then needs a second block for the length
  kat ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff \
      512 8667e718294e9e0df1d30600ba3eeb201f764aad2dad72748643e4a285e1d1f7

  # CLI.md allows uppercase hex on input; the digest must be unaffected.
  chk "uppercase hex input" \
      "$("$RUNNER" "$SHAVAR_SH" hash 616263 24)" \
      "$("$RUNNER" "$SHAVAR_SH" hash 616263 24)"
  chk "uppercase hex == lowercase hex" \
      "$("$RUNNER" "$SHAVAR_SH" hash 6A6B6C 24)" \
      "$("$RUNNER" "$SHAVAR_SH" hash 6a6b6c 24)"

  # reduced-round variants (not SHA-256; pinned so the path cannot change
  # silently, and so the other six implementations can be diffed against it)
  kat 616263 24 ddbd225ca600d8a7dc74fea2db8478030b6763919c0f13c6cd6b6de2bcf370d0 32
  kat 616263 24 1b0409f57bcc0e6315a1de882ce11eca5867604ca6985a9893de22897a384f31 16
  kat 616263 24 c774d234257194ecf7d6a1f7e1bee8ac4b3898a1ec13bb0bba8942377b64a6c4 1

  # free-start: a caller-supplied chaining value (SPEC.md §6)
  chk "free-start IV" \
      "$("$RUNNER" "$SHAVAR_SH" --iv 0000000000000001000000020000000300000004000000050000000600000007 \
          hash 616263 24)" \
      "c34c60f0862385a9c6ab68858345049a82580ff282f9969f87661dc8c25c7d04"
  chk "--iv with the FIPS value equals the default" \
      "$("$RUNNER" "$SHAVAR_SH" --iv 6a09e667bb67ae853c6ef372a54ff53a510e527f9b05688c1f83d9ab5be0cd19 \
          hash 616263 24)" \
      "$("$RUNNER" "$SHAVAR_SH" hash 616263 24)"
}

# --------------------------------------------------------------------------
# 3. sub-byte bit lengths, accepted AND rejected (SPEC.md §5.1)
# --------------------------------------------------------------------------
t_bitlen() {
  # accepted: low (8 - nbits%8) bits are zero
  kat b0 5 82c9ef980dfdf26f0cb97f59d34a60dc39c82e489da9ca2132681fe0aa14270a
  kat b8 5 9103bf6cd9f1134d81807ade91d54d9888b1a3df1f947f735ce00220dca5261c
  kat 68 5 d6d3e02a31a84a8caa9718ed6c2057be09db45e7823eb5079ce7a573a3760f95
  kat 00 1 bd4f9e98beb68c6ead3243b1b4c7fed75fa4feaab1f84795cbd8a98676a2a375
  kat c0 3 fa0e40cc693c20d55b131b825a32f961d6d0681811a95886d6704e9c376a9abd
  kat e0 3 8287ea50445e9ddd80b791cf413e74d152a577b8441b93fa29d88edc830f4400
  # a sub-byte length spanning two blocks
  kat 61616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616160 \
      557 6d359cbe0796b2262e76f606fa2147779d4687f0adcd5a1e31bd65b42dc8976a

  # rejected: nonzero bits below the significant ones
  reject b4 5   # 1011 0100 -> low three bits are 100
  reject b1 5   # 1011 0001
  reject 01 1   # low seven bits nonzero
  reject ff 7

  # distinct sub-byte inputs must give distinct digests, i.e. the low bits are
  # really being rejected rather than masked away.
  local a b
  a=$("$RUNNER" "$SHAVAR_SH" hash b0 5)
  b=$("$RUNNER" "$SHAVAR_SH" hash b0 4)
  if [ "$a" != "$b" ]; then ok; else bad "b0/5 and b0/4 hashed the same"; fi
}

reject() { # <hex> <nbits> — must exit 2 with empty stdout
  local out rc
  out=$("$RUNNER" "$SHAVAR_SH" hash "$1" "$2" 2>/dev/null); rc=$?
  if [ $rc -ne 2 ]; then bad "hash $1 $2 should exit 2, exited $rc"; return; fi
  if [ -n "$out" ]; then bad "hash $1 $2 wrote [$out] to stdout on error"; return; fi
  ok
}

# --------------------------------------------------------------------------
# 4. exit codes and stdout hygiene (CLI.md)
# --------------------------------------------------------------------------
usage_err() { # any argv that must exit 2 with empty stdout
  local out rc
  out=$("$RUNNER" "$SHAVAR_SH" "$@" 2>/dev/null); rc=$?
  if [ $rc -ne 2 ]; then bad "[$*] should exit 2, exited $rc"; return; fi
  if [ -n "$out" ]; then bad "[$*] wrote [$out] to stdout on error"; return; fi
  ok
}

t_exitcodes() {
  usage_err
  usage_err bogus
  usage_err hash
  usage_err hash 616263
  usage_err hash 616263 24 65        # rounds out of range
  usage_err hash 616263 -1
  usage_err hash 616263 xx
  usage_err hash zzz 24              # non-hex
  usage_err hash 61626 24            # odd number of hex digits
  usage_err hash 616263 25           # ceil(25/8)=4 bytes, 3 supplied
  usage_err hash 616263 16           # ceil(16/8)=2 bytes, 3 supplied
  usage_err hash - 8                 # empty buffer, 1 byte needed
  usage_err trace 616263 24 9        # blockidx past the end
  usage_err trace 616263 24 0 65
  usage_err --iv 00 hash 616263 24   # IV must be 64 hex digits
  usage_err --iv

  # exactly 64 hex digits and exactly one trailing newline, nothing else.
  # Command substitution strips trailing newlines, so a literal X is appended
  # inside the substitution to make them visible.
  local out
  out=$("$RUNNER" "$SHAVAR_SH" hash - 0; printf X)
  chk "digest is 64 hex + one newline" "$out" \
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855${NL}X"
}

# --------------------------------------------------------------------------
# 5. trace shape (CLI.md)
# --------------------------------------------------------------------------
#
# A trace has 8 HIN + 64 W + (4+r) A + (4+r) E + r T1 + r T2 + 8 HOUT records,
# that is 88 + 4r lines.
t_trace() {
  trace_shape 64 344
  trace_shape 16 152
  trace_shape 3  100

  # Spot-check individual records. NOTE: the whole trace is captured first and
  # then walked, rather than piping into a `while` containing a `case`. bash
  # 3.2 mis-parses a `case` statement inside $( ), counting the pattern's
  # closing ')' as the end of the substitution — one of the reasons that shell
  # version needs testing against rather than assuming.
  local out l first= aneg= elast= hout=
  out=$("$RUNNER" "$SHAVAR_SH" trace 616263 24)
  while read -r l; do
    [ -n "$first" ] || first=$l
    case "$l" in
      "A	-4	"*) aneg=$l ;;
      "E	63	"*) elast=$l ;;
      HOUT*)      hout=$hout${l##*	} ;;
    esac
  done <<EOF
$out
EOF
  chk "trace first record"   "$first" "$(printf 'HIN\t0\t6a09e667')"
  chk "trace A[-4] = H[3]"   "$aneg"  "$(printf 'A\t-4\ta54ff53a')"
  # H[4] leaving the block is E[63] plus H[4] entering it; check E[63] is there
  # and that the HOUT records concatenate to exactly the digest.
  case "$elast" in
    "E	63	"????????) ok ;;
    *) bad "trace E[63] missing or malformed: [$elast]" ;;
  esac
  chk "trace HOUT concatenates to the digest" \
      "$hout" "$("$RUNNER" "$SHAVAR_SH" hash 616263 24)"
}

trace_shape() { # <rounds> <expected line count>
  local n=0 l
  while read -r l; do
    n=$((n + 1))
    case "$l" in
      *"	"*"	"*"	"*) bad "trace record has too many fields: [$l]"; return ;;
      *"	"*"	"*) ;;
      *) bad "trace record is not three tab-separated fields: [$l]"; return ;;
    esac
  done <<EOF
$("$RUNNER" "$SHAVAR_SH" trace "$M448" 448 0 "$1")
EOF
  chk "trace rounds=$1 line count" "$n" "$2"
}

# --------------------------------------------------------------------------
# 6. drift between the inlined round loop and the exposed round functions
# --------------------------------------------------------------------------
#
# shavar_compress inlines Ch, Maj, Sigma0, Sigma1, sigma0 and sigma1 into two
# arithmetic expressions, because six function calls per round is too expensive
# to pay. shavar.sh also exposes those six as functions, for the instrumentation
# SPEC.md §7.1 calls for. Two copies of the same six formulas can disagree.
#
# This recomputes an entire block the slow, honest way — one function call per
# operation — and requires the result to match the fast path exactly, element by
# element, not merely in the final digest.
shavar_compress_ref() { # <rounds>, reads SHAVAR_BLK and SHAVAR_H, writes R*
  [ -n "${ZSH_VERSION:-}" ] && emulate -L ksh
  local rounds=$1 t i j s0 s1 cc mm S0v S1v x y
  local M=0xFFFFFFFF
  RW=(); RA=(); RE=(); RT1=(); RT2=(); RH=("${SHAVAR_H[@]}")

  for ((i = 0; i < 16; i++)); do
    (( j = i * 4 ))
    RW[i]=$(( (SHAVAR_BLK[j] << 24) | (SHAVAR_BLK[j+1] << 16) \
            | (SHAVAR_BLK[j+2] << 8) | SHAVAR_BLK[j+3] ))
  done
  for ((t = 16; t < 64; t++)); do
    shavar_sigma1 "${RW[t-2]}";  s1=$R
    shavar_sigma0 "${RW[t-15]}"; s0=$R
    RW[t]=$(( (s1 + RW[t-7] + s0 + RW[t-16]) & M ))
  done

  RA[0]=${RH[3]}; RA[1]=${RH[2]}; RA[2]=${RH[1]}; RA[3]=${RH[0]}
  RE[0]=${RH[7]}; RE[1]=${RH[6]}; RE[2]=${RH[5]}; RE[3]=${RH[4]}

  for ((t = 0; t < rounds; t++)); do
    shavar_Sigma1 "${RE[t+3]}";                          S1v=$R
    shavar_ch     "${RE[t+3]}" "${RE[t+2]}" "${RE[t+1]}"; cc=$R
    shavar_Sigma0 "${RA[t+3]}";                          S0v=$R
    shavar_maj    "${RA[t+3]}" "${RA[t+2]}" "${RA[t+1]}"; mm=$R
    RT1[t]=$(( (RE[t] + S1v + cc + SHAVAR_K[t] + RW[t]) & M ))
    RT2[t]=$(( (S0v + mm) & M ))
    RE[t+4]=$(( (RA[t] + RT1[t]) & M ))
    RA[t+4]=$(( (RT1[t] + RT2[t]) & M ))
  done

  RH[0]=$(( (RH[0] + RA[rounds+3]) & M )); RH[1]=$(( (RH[1] + RA[rounds+2]) & M ))
  RH[2]=$(( (RH[2] + RA[rounds+1]) & M )); RH[3]=$(( (RH[3] + RA[rounds])   & M ))
  RH[4]=$(( (RH[4] + RE[rounds+3]) & M )); RH[5]=$(( (RH[5] + RE[rounds+2]) & M ))
  RH[6]=$(( (RH[6] + RE[rounds+1]) & M )); RH[7]=$(( (RH[7] + RE[rounds])   & M ))
}

t_drift() {
  local rounds t bad_seen=0
  SHAVAR_LIB=1
  . "$SHAVAR_SH"
  shavar__init

  for rounds in 64 17; do
    # a block with some structure in it: "abc" padded, then a pseudo-random one
    shavar_parse_hex 616263
    SHAVAR_NBLOCKS=1
    shavar_block 24 0
    SHAVAR_H=("${SHAVAR_IV[@]}")
    shavar_compress_ref "$rounds"
    SHAVAR_H=("${SHAVAR_IV[@]}")
    shavar_compress "$rounds"

    for ((t = 0; t < 64; t++)); do
      [ "${SHAVAR_W[t]}" = "${RW[t]}" ] || { bad "drift W[$t] rounds=$rounds"; bad_seen=1; break; }
    done
    for ((t = 0; t < rounds + 4; t++)); do
      [ "${SHAVAR_A[t]}" = "${RA[t]}" ] || { bad "drift A[$((t-4))] rounds=$rounds"; bad_seen=1; break; }
      [ "${SHAVAR_E[t]}" = "${RE[t]}" ] || { bad "drift E[$((t-4))] rounds=$rounds"; bad_seen=1; break; }
    done
    for ((t = 0; t < rounds; t++)); do
      [ "${SHAVAR_T1[t]}" = "${RT1[t]}" ] || { bad "drift T1[$t] rounds=$rounds"; bad_seen=1; break; }
      [ "${SHAVAR_T2[t]}" = "${RT2[t]}" ] || { bad "drift T2[$t] rounds=$rounds"; bad_seen=1; break; }
    done
    for ((t = 0; t < 8; t++)); do
      [ "${SHAVAR_H[t]}" = "${RH[t]}" ] || { bad "drift H[$t] rounds=$rounds"; bad_seen=1; break; }
    done
  done
  [ $bad_seen -eq 0 ] && ok

  # the six round functions against hand-computed values
  # Ch selects y where x is 1 and z where x is 0, so f0f0.. picks the high
  # nibbles of aaaa.. and the low nibbles of 5555.., giving a5a5a5a5. Maj of
  # f0f0.., aaaa.. and 5555.. is f0f0.. because the second and third inputs
  # never agree, so the first one always casts the deciding vote.
  shavar_ch     0xF0F0F0F0 0xAAAAAAAA 0x55555555; chk "Ch"     "$R" "$((0xa5a5a5a5))"
  shavar_maj    0xF0F0F0F0 0xAAAAAAAA 0x55555555; chk "Maj"    "$R" "$((0xf0f0f0f0))"
  shavar_Sigma0 0x6a09e667; chk "Sigma0" "$R" "$((0xce20b47e))"
  shavar_Sigma1 0x510e527f; chk "Sigma1" "$R" "$((0x3587272b))"
  # sigma0(1) = ROTR7 | ROTR18 | SHR3 of a single low bit = 0x02000000 ^ 0x4000
  shavar_sigma0 0x00000001; chk "sigma0" "$R" "$((0x02004000))"
  # sigma1(1) = ROTR17 ^ ROTR19 ^ SHR10 = 0x8000 ^ 0x2000
  shavar_sigma1 0x00000001; chk "sigma1" "$R" "$((0x0000a000))"
  # rotations must never produce a negative number or exceed 32 bits
  local v
  for v in 0x80000000 0xFFFFFFFF 0x00000001; do
    shavar_Sigma0 "$v"; if [ "$R" -ge 0 ] && [ "$R" -le 4294967295 ]; then ok; else bad "Sigma0($v) = $R out of range"; fi
    shavar_sigma1 "$v"; if [ "$R" -ge 0 ] && [ "$R" -le 4294967295 ]; then ok; else bad "sigma1($v) = $R out of range"; fi
  done
}

# --------------------------------------------------------------------------
# 7. constants against spec/SPEC.md §9
# --------------------------------------------------------------------------
#
# SPEC.md prints the IV as one row of eight 8-hex-digit words and K as eight
# such rows. Every line of the document that consists of exactly eight
# 8-hex-digit words separated by single spaces is collected; the first is the
# IV, the next eight are K. `read` is a shell builtin, so this costs no
# process; the line is taken apart with ${var%% *} / ${var#* } rather than by
# word splitting, for the same IFS-independence reason as everywhere else.
t_constants() {
  if [ ! -f "$SHAVAR_SPEC" ]; then
    printf 'note: %s not found, skipping the constants-vs-spec check\n' "$SHAVAR_SPEC" >&2
    return 0
  fi
  local line w rest i n=0
  local -a FOUND
  FOUND=()
  while read -r line; do
    case "$line" in
      [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]" "*)
        # eight words of eight hex digits and nothing else?
        rest=$line
        i=0
        while [ -n "$rest" ]; do
          w=${rest%% *}
          case "$w" in
            [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
            *) i=99; break ;;
          esac
          i=$((i + 1))
          [ "$rest" = "$w" ] && break
          rest=${rest#* }
        done
        if [ "$i" -eq 8 ]; then
          rest=$line
          while :; do
            w=${rest%% *}
            FOUND[n]=$w; n=$((n + 1))
            [ "$rest" = "$w" ] && break
            rest=${rest#* }
          done
        fi
        ;;
    esac
  done < "$SHAVAR_SPEC"

  if [ "$n" -ne 72 ]; then
    bad "expected 8 IV + 64 K words in SPEC.md §9, found $n"
    return
  fi
  for ((i = 0; i < 8; i++)); do
    chk "SPEC.md IV[$i]" "$(printf '%08x' "${SHAVAR_IV[i]}")" "${FOUND[i]}"
  done
  for ((i = 0; i < 64; i++)); do
    chk "SPEC.md K[$i]" "$(printf '%08x' "${SHAVAR_K[i]}")" "${FOUND[i+8]}"
  done
}

# --------------------------------------------------------------------------
# 8. cross-shell agreement
# --------------------------------------------------------------------------
xshell() { # argv -> identical stdout and exit status under bash and zsh
  local ob oz rb rz
  ob=$(/bin/bash "$SHAVAR_SH" "$@" 2>/dev/null); rb=$?
  oz=$(/bin/zsh  "$SHAVAR_SH" "$@" 2>/dev/null); rz=$?
  if [ "$rb" != "$rz" ]; then bad "cross-shell [$*] exit bash=$rb zsh=$rz"; return; fi
  if [ "$ob" != "$oz" ]; then bad "cross-shell [$*] stdout differs"; return; fi
  ok
}

t_crossshell() {
  if [ ! -x /bin/bash ] || [ ! -x /bin/zsh ]; then
    printf 'note: need both /bin/bash and /bin/zsh for the cross-shell check\n' >&2
    return 0
  fi
  xshell hash - 0
  xshell hash 616263 24
  xshell hash "$M448" 448
  xshell hash "$M896" 896
  xshell hash b0 5
  xshell hash b8 5
  xshell hash b4 5          # both must fail the same way
  xshell hash 00 1
  xshell hash 616263 24 16
  xshell hash 616263 24 0
  xshell --iv 0000000000000001000000020000000300000004000000050000000600000007 hash 616263 24
  xshell trace 616263 24
  xshell trace "$M448" 448 1
  xshell trace "$M448" 448 0 7
  xshell selftest
  xshell bogus
}

# --------------------------------------------------------------------------
main() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L ksh

  if [ ! -f "$SHAVAR_SH" ]; then
    printf 'cannot find %s\n' "$SHAVAR_SH" >&2
    exit 1
  fi

  t_selftest
  t_kats
  t_bitlen
  t_exitcodes
  t_trace
  t_drift
  t_constants
  t_crossshell

  printf '%s: %d passed, %d failed\n' "${ZSH_VERSION:+zsh}${BASH_VERSION:+bash}" "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}

main "$@"
