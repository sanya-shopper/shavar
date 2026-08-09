# shellcheck shell=sh
#
# common.sh — shared plumbing for the shavar cross-implementation test harness.
#
# Sourced by tests/crosstest.sh, tests/nist.sh, tests/constants.sh and
# tests/run.sh.  Deliberately POSIX-ish: macOS ships bash 3.2, so there are no
# associative arrays, no `local -n`, no ${var^^}.  Where real data structures
# are needed the work is handed to awk or python3 (the "no modules / core
# language only" rule constrains the seven implementations, not this harness).
#
# Terminology used throughout:
#
#   impl      one of the seven implementations under test, identified by a
#             short id: c, py, pl, scm, js, sh, shz, lean.
#   oracle    an independent, already-trusted SHA-256 program on this machine
#             (openssl, shasum, sha256sum).  Oracles can only hash whole
#             bytes, so they are silent on every sub-byte-length case.
#   authority a column whose value is taken as ground truth rather than as an
#             opinion: a NIST CAVP expected digest, or an oracle.
#   phase     a named body of test inputs (sweep, random, nist-bit-short, ...).

set -u

# ---------------------------------------------------------------- locations --

# tests/lib/common.sh -> tests/ -> repo root
COMMON_SH_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
case "$COMMON_SH_DIR" in
  */tests) TESTS_DIR=$COMMON_SH_DIR ;;
  */tests/lib) TESTS_DIR=$(dirname "$COMMON_SH_DIR") ;;
  *) TESTS_DIR=$COMMON_SH_DIR ;;
esac
ROOT=$(dirname "$TESTS_DIR")
LIB="$TESTS_DIR/lib"
VECTORS="$TESTS_DIR/vectors"

# Everything transient goes under one work directory so a run leaves no litter
# in the repository.  Override with SHAVAR_WORK to keep artefacts for inspection.
WORK=${SHAVAR_WORK:-${TMPDIR:-/tmp}/shavar-tests.$$}

# ------------------------------------------------------------------- config --

# Number of shards used per implementation.  Implementations are additionally
# run in parallel with each other, so real parallelism is JOBS * #impls.
JOBS=${SHAVAR_JOBS:-4}

# Interpreters / helper binaries, all overridable.
PYTHON=${SHAVAR_PYTHON:-python3}
PERL=${SHAVAR_PERL:-/usr/bin/perl}
CHIBI=${SHAVAR_CHIBI:-chibi-scheme}
JSC=${SHAVAR_JSC:-/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc}
BASH_BIN=${SHAVAR_BASH:-bash}
ZSH_BIN=${SHAVAR_ZSH:-zsh}
CC_BIN=${SHAVAR_CC:-clang}

# The full roster, in report order.  Missing ones are reported as skipped.
ALL_IMPLS="c py pl scm js sh shz lean"

# The external oracles.  Two of these are genuinely distinct codebases
# (LibreSSL vs OpenSSL 3.x); shasum is Perl's Digest::SHA and sha256sum is
# Apple's cctools/CommonCrypto front end, so there are three or four
# independent SHA-256 cores here depending on how you count.
ALL_ORACLES="ssl-libre ssl-openssl shasum sha256sum"

# ------------------------------------------------------------------ logging --

if [ -t 1 ] && [ "${SHAVAR_COLOR:-1}" = 1 ]; then
  C_RED=$(printf '\033[31m'); C_GRN=$(printf '\033[32m')
  C_YEL=$(printf '\033[33m'); C_BLD=$(printf '\033[1m'); C_OFF=$(printf '\033[0m')
else
  C_RED=; C_GRN=; C_YEL=; C_BLD=; C_OFF=
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s\n' "$*"; }
warn() { printf '%swarn:%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
err()  { printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
hdr()  { printf '\n%s== %s ==%s\n' "$C_BLD" "$*" "$C_OFF"; }

# ------------------------------------------------- implementation invocation --

# impl_desc ID -> one-line human description of how the impl is invoked.
impl_desc() {
  case $1 in
    c)    echo "$ROOT/c/shavar (C99, built with make/clang)" ;;
    py)   echo "$PYTHON $ROOT/py/shavar.py" ;;
    pl)   echo "$PERL $ROOT/pl/shavar.pl" ;;
    scm)  echo "$CHIBI $ROOT/scm/shavar.scm" ;;
    js)   echo "$JSC $ROOT/js/shavar-cli.js --" ;;
    sh)   echo "$BASH_BIN $ROOT/sh/shavar.sh" ;;
    shz)  echo "$ZSH_BIN $ROOT/sh/shavar.sh (same source, zsh)" ;;
    lean) echo "${SHAVAR_LEAN_BIN:-$ROOT/lean/.lake/build/bin/shavar}" ;;
    *)    echo "unknown impl $1" ;;
  esac
}

# impl_run ID ARGS... -> runs the implementation.  stdout is the impl's stdout.
impl_run() {
  _id=$1; shift
  case $_id in
    c)    "$ROOT/c/shavar" "$@" ;;
    py)   "$PYTHON" "$ROOT/py/shavar.py" "$@" ;;
    pl)   "$PERL" "$ROOT/pl/shavar.pl" "$@" ;;
    scm)  "$CHIBI" "$ROOT/scm/shavar.scm" "$@" ;;
    js)   "$JSC" "$ROOT/js/shavar-cli.js" -- "$@" ;;
    sh)   "$BASH_BIN" "$ROOT/sh/shavar.sh" "$@" ;;
    shz)  "$ZSH_BIN" "$ROOT/sh/shavar.sh" "$@" ;;
    lean) "${SHAVAR_LEAN_BIN:-$ROOT/lean/.lake/build/bin/shavar}" "$@" ;;
    *)    return 127 ;;
  esac
}

# now_ms — wall clock in milliseconds.  BSD date has no %N, so this goes
# through python3 rather than pretending `date +%s%N` is portable.
now_ms() { "$PYTHON" -c 'import time;print(int(time.time()*1000))'; }

# calibrate_impl ID — measure what this implementation costs, and write
#     id <TAB> base_ms <TAB> per_block_ms
# to $WORK/cost.tsv.
#
# Sampling rates are derived from this rather than hardcoded, because guessing
# which implementation is slow gets it wrong.  On the machine this was written
# on the shell implementation costs 9 ms plus 13 ms per 512-bit block while
# chibi-scheme costs 189 ms before it has hashed anything at all -- a 20x
# difference in the opposite direction to the obvious guess.  Measuring also
# means the harness keeps working as the implementations are optimised.
calibrate_impl() {
  _id=$1
  _big=$("$PYTHON" -c 'print("ab"*512)')     # 4096 bits = 8 blocks
  _t0=$(now_ms)
  impl_run "$_id" hash 616263 24 >/dev/null 2>&1
  impl_run "$_id" hash 616263 24 >/dev/null 2>&1
  impl_run "$_id" hash 616263 24 >/dev/null 2>&1
  _t1=$(now_ms)
  impl_run "$_id" hash "$_big" 4096 >/dev/null 2>&1
  _t2=$(now_ms)
  "$PYTHON" - "$_id" "$_t0" "$_t1" "$_t2" <<'EOF'
import sys
i, t0, t1, t2 = sys.argv[1], *map(int, sys.argv[2:5])
base = max((t1 - t0) / 3.0, 0.05)
per = max((t2 - t1 - base) / 8.0, 0.0)
print("%s\t%.3f\t%.3f" % (i, base, per))
EOF
}

calibrate_all() {
  : > "$WORK/cost.tsv"
  _pids=""
  for _i in $(impls_with_status ok); do
    ( calibrate_impl "$_i" > "$WORK/cost.$_i" ) &
    _pids="$_pids $!"
  done
  for _p in $_pids; do wait "$_p"; done
  cat "$WORK"/cost.* > "$WORK/cost.tsv" 2>/dev/null
  rm -f "$WORK"/cost.[a-z]*
}

# cost_base ID / cost_block ID — measured costs in ms, with safe fallbacks.
cost_base()  { awk -F'\t' -v i="$1" '$1==i {print $2; f=1} END{if(!f) print 20}' "$WORK/cost.tsv"; }
cost_block() { awk -F'\t' -v i="$1" '$1==i {print $3; f=1} END{if(!f) print 5}' "$WORK/cost.tsv"; }

# ------------------------------------------------------- oracle invocation --

# oracle_path ID -> absolute path, or empty if not installed.
oracle_path() {
  case $1 in
    ssl-libre)   echo "${SHAVAR_SSL_LIBRE:-/usr/bin/openssl}" ;;
    ssl-openssl) echo "${SHAVAR_SSL_OPENSSL:-/opt/homebrew/bin/openssl}" ;;
    shasum)      echo "${SHAVAR_SHASUM:-/usr/bin/shasum}" ;;
    sha256sum)   echo "${SHAVAR_SHA256SUM:-/sbin/sha256sum}" ;;
    *)           echo "" ;;
  esac
}

# oracle_desc ID -> human description including the version string, so the
# report records exactly which codebase produced the reference digests.
oracle_desc() {
  _p=$(oracle_path "$1")
  case $1 in
    ssl-libre|ssl-openssl) echo "$_p dgst -sha256 [$("$_p" version 2>/dev/null | head -1)]" ;;
    shasum)                echo "$_p -a 256 [$("$_p" -v 2>/dev/null | head -1)]" ;;
    sha256sum)             echo "$_p [$("$_p" --version 2>/dev/null | head -1)]" ;;
    *)                     echo "$_p" ;;
  esac
}

# oracle_hash ID  < raw-bytes-on-stdin  -> 64 lowercase hex on stdout.
oracle_hash() {
  _p=$(oracle_path "$1")
  case $1 in
    ssl-libre|ssl-openssl) "$_p" dgst -sha256 2>/dev/null | awk '{print $NF}' ;;
    shasum)                "$_p" -a 256 2>/dev/null | awk '{print $1}' ;;
    sha256sum)             "$_p" 2>/dev/null | awk '{print $1}' ;;
    *)                     return 127 ;;
  esac
}

# --------------------------------------------------------------- discovery --

# discover_impls writes "$WORK/impls.tsv" with one row per implementation:
#     id <TAB> status <TAB> reason
# status is one of:
#     ok       present and answering the CLI contract in well-formed shape
#     absent   the source file / interpreter is not there yet (not a failure:
#              the seven implementations are written in parallel)
#     broken   present but does not answer `hash 616263 24` with 64 hex digits
#              (this IS a failure and is reported as one)
#
# Note what the smoke test does *not* do: it never compares against a known
# digest.  Whether an implementation is correct is what the suite exists to
# find out; discovery only establishes whether it can be spoken to at all.
discover_impls() {
  : > "$WORK/impls.tsv"
  for id in $ALL_IMPLS; do
    _reason=""
    _src=""
    case $id in
      c)    _src="$ROOT/c/shavar.c" ;;
      py)   _src="$ROOT/py/shavar.py" ;;
      pl)   _src="$ROOT/pl/shavar.pl" ;;
      scm)  _src="$ROOT/scm/shavar.scm" ;;
      js)   _src="$ROOT/js/shavar-cli.js" ;;
      sh|shz) _src="$ROOT/sh/shavar.sh" ;;
      lean) _src="$ROOT/lean/lakefile.toml" ;;
    esac

    if [ ! -e "$_src" ]; then
      printf '%s\tabsent\tsource not present: %s\n' "$id" "$_src" >> "$WORK/impls.tsv"
      continue
    fi

    # Interpreter / build prerequisites.
    case $id in
      c)
        if ! build_c; then
          printf '%s\tbroken\tbuild failed (see %s)\n' "$id" "$WORK/build-c.log" >> "$WORK/impls.tsv"
          continue
        fi ;;
      py)   command -v "$PYTHON" >/dev/null 2>&1 || _reason="interpreter not found: $PYTHON" ;;
      pl)   [ -x "$PERL" ] || _reason="interpreter not found: $PERL" ;;
      scm)  command -v "$CHIBI" >/dev/null 2>&1 || _reason="interpreter not found: $CHIBI" ;;
      js)   [ -x "$JSC" ] || _reason="jsc helper not found: $JSC" ;;
      sh)   command -v "$BASH_BIN" >/dev/null 2>&1 || _reason="shell not found: $BASH_BIN" ;;
      shz)  command -v "$ZSH_BIN" >/dev/null 2>&1 || _reason="shell not found: $ZSH_BIN" ;;
      lean) find_lean_bin || _reason="lake executable not built (run 'lake build' in lean/, or set SHAVAR_LEAN_BIN)" ;;
    esac
    if [ -n "$_reason" ]; then
      printf '%s\tabsent\t%s\n' "$id" "$_reason" >> "$WORK/impls.tsv"
      continue
    fi

    # Shape-only smoke test.
    _out=$(impl_run "$id" hash 616263 24 2>"$WORK/smoke-$id.err")
    _rc=$?
    if [ "$_rc" -ne 0 ]; then
      _e=$(head -1 "$WORK/smoke-$id.err" 2>/dev/null)
      printf '%s\tbroken\t`hash 616263 24` exited %s: %s\n' "$id" "$_rc" "$_e" >> "$WORK/impls.tsv"
    elif ! printf '%s' "$_out" | grep -Eq '^[0-9a-f]{64}$'; then
      _shown=$(printf '%s' "$_out" | head -c 80 | tr -d '\n')
      printf '%s\tbroken\t`hash 616263 24` did not print 64 lowercase hex digits (got %s)\n' \
             "$id" "${_shown:-<empty stdout>}" >> "$WORK/impls.tsv"
    else
      printf '%s\tok\t%s\n' "$id" "$(impl_desc "$id")" >> "$WORK/impls.tsv"
    fi
  done
}

# build_c — build the C implementation into $ROOT/c/shavar.  Uses the repo's
# Makefile when there is one, otherwise the documented clang line.
build_c() {
  if [ -f "$ROOT/c/Makefile" ]; then
    ( cd "$ROOT/c" && make ) >"$WORK/build-c.log" 2>&1 && [ -x "$ROOT/c/shavar" ] && return 0
  fi
  ( cd "$ROOT/c" && "$CC_BIN" -std=c99 -O2 shavar.c main.c -o shavar ) >>"$WORK/build-c.log" 2>&1
  [ -x "$ROOT/c/shavar" ]
}

# find_lean_bin — locate the `lake exe` output.  The name is not fixed by the
# CLI contract, so search the standard build directory for an executable.
find_lean_bin() {
  if [ -n "${SHAVAR_LEAN_BIN:-}" ] && [ -x "${SHAVAR_LEAN_BIN}" ]; then
    export SHAVAR_LEAN_BIN; return 0
  fi
  for cand in "$ROOT"/lean/.lake/build/bin/*; do
    [ -f "$cand" ] && [ -x "$cand" ] || continue
    case $cand in *.hash|*.trace|*.rsp|*.olean|*.c|*.o) continue ;; esac
    SHAVAR_LEAN_BIN=$cand; export SHAVAR_LEAN_BIN; return 0
  done
  return 1
}

# ensure_discovered — run discovery once per $WORK, so that crosstest.sh and
# nist.sh can each be run standalone but do not repeat the work (and, more
# importantly, do not disagree about the roster) when driven by run.sh.
ensure_discovered() {
  mkdir -p "$WORK"
  export SHAVAR_WORK="$WORK"
  if [ ! -s "$WORK/impls.tsv" ]; then discover_impls; fi
  if [ ! -s "$WORK/oracles.tsv" ]; then discover_oracles; fi
  if [ ! -s "$WORK/cost.tsv" ]; then calibrate_all; fi
}

# impls_with_status STATUS -> space separated ids
impls_with_status() {
  awk -F'\t' -v s="$1" '$2==s {printf "%s ", $1}' "$WORK/impls.tsv"
}

# reason_for ID
reason_for() {
  awk -F'\t' -v i="$1" '$1==i {print $3}' "$WORK/impls.tsv"
}

# discover_oracles writes "$WORK/oracles.tsv": id <TAB> status <TAB> desc
discover_oracles() {
  : > "$WORK/oracles.tsv"
  for id in $ALL_ORACLES; do
    p=$(oracle_path "$id")
    if [ -x "$p" ] && printf '' | oracle_hash "$id" 2>/dev/null | grep -Eq '^[0-9a-f]{64}$'; then
      printf '%s\tok\t%s\n' "$id" "$(oracle_desc "$id")" >> "$WORK/oracles.tsv"
    else
      printf '%s\tabsent\tnot executable or not answering: %s\n' "$id" "$p" >> "$WORK/oracles.tsv"
    fi
  done
}

oracles_ok() { awk -F'\t' '$2=="ok" {printf "%s ", $1}' "$WORK/oracles.tsv"; }

# ------------------------------------------------------------------ budgets --

# time_budget_ms MODE PHASE -> how much CPU time one implementation is allowed
# to spend on one phase.  This is the master sampling knob; everything else is
# derived from it and from the measured per-implementation cost.
time_budget_ms() {
  case $2 in
    trace) [ "$1" = thorough ] && echo "${SHAVAR_TIME_TRACE_MS:-10000}" \
                               || echo "${SHAVAR_TIME_TRACE_MS:-1500}" ;;
    *)     [ "$1" = thorough ] && echo "${SHAVAR_TIME_BUDGET_MS:-90000}" \
                               || echo "${SHAVAR_TIME_BUDGET_MS:-2500}" ;;
  esac
}

# budget_for IMPL PHASE MODE [INPUTS] -> maximum number of inputs from that
# phase to hand to that implementation, or the literal word `all`.
#
# Derived from the measured cost of the implementation (calibrate_impl) and the
# mean number of 512-bit blocks in the phase's inputs, so a phase of 100-block
# NIST LongMsg vectors is automatically sampled far more sparsely than a phase
# of 1-block sweep inputs, for every implementation, in proportion to what that
# implementation actually costs.
#
# The result is snapped to a fixed ladder so that ordinary timing jitter does
# not change which rows get selected: two runs on the same machine pick the
# same subset, and a failure found at budget 200 reproduces at budget 200.
#
# Overrides, in order of precedence:
#   SHAVAR_BUDGET_<IMPL>_<PHASE>   exact row count, or `all`   (e.g. ..._SCM_SWEEP=12)
#   SHAVAR_TIME_BUDGET_MS          ms per implementation per phase
budget_for() {
  _i=$1; _p=$2; _m=$3; _f=${4:-}
  _iu=$(printf '%s' "$_i" | tr 'a-z-' 'A-Z_')
  _pu=$(printf '%s' "$_p" | tr 'a-z-' 'A-Z_')
  _ov=$(eval "printf '%s' \"\${SHAVAR_BUDGET_${_iu}_${_pu}:-}\"")
  if [ -n "$_ov" ]; then printf '%s' "$_ov"; return; fi

  _ms=$(time_budget_ms "$_m" "$_p")
  _mb=1
  if [ -n "$_f" ] && [ -s "$_f" ]; then
    # mean blocks per input:  a message of L bits pads into
    # floor((L + 64) / 512) + 1 blocks  (spec/SPEC.md 5)
    _mb=$(awk -F'\t' '{s += int(($2 + 64) / 512) + 1; n++} END {print (n ? s / n : 1)}' "$_f")
  fi
  awk -v base="$(cost_base "$_i")" -v per="$(cost_block "$_i")" \
      -v blocks="$_mb" -v ms="$_ms" '
    BEGIN {
      cost = base + per * blocks
      if (cost <= 0) { print "all"; exit }
      n = int(ms / cost)
      split("1 2 3 5 8 12 20 30 50 80 130 200 350 600 1000 1700 3000", L, " ")
      best = 1
      for (j = 1; j in L; j++) if (L[j] <= n) best = L[j]
      if (n >= 3000) print "all"; else print best
    }'
}

# subsample IN OUT BUDGET — keep an evenly spaced BUDGET-sized subset of IN,
# always including the first and last line.  Deterministic: the same budget
# always selects the same rows, so a failure found at budget 24 reproduces.
subsample() {
  _in=$1; _out=$2; _b=$3
  if [ "$_b" = all ]; then cp "$_in" "$_out"; return 0; fi
  if [ "$_b" -le 0 ] 2>/dev/null; then : > "$_out"; return 0; fi
  awk -v b="$_b" '
    NR == FNR { n++; next }
    { if (n <= b)  { print; next }
      if (b <= 1)  { if (FNR == 1) print; next }
      # Nearest of the b evenly spaced slots, then the canonical row for that
      # slot.  Selecting the slot representative rather than the first row that
      # maps to it is what makes the first and last rows always chosen.
      k   = int((FNR - 1) * (b - 1) / (n - 1) + 0.5)
      pos = int(k * (n - 1) / (b - 1) + 0.5) + 1
      if (FNR == pos) print
    }' "$_in" "$_in" > "$_out"
}

# ------------------------------------------------------------ run one phase --
#
# run_phase PHASE INPUTS MODE IMPLS...
#
# INPUTS is a TSV of `key <TAB> nbits <TAB> hex`.  For each implementation this
# subsamples according to its budget, shards the work JOBS ways, runs all
# implementations concurrently, and leaves `$WORK/<phase>/<impl>.tsv` holding
# `key <TAB> rc <TAB> digest-or-dash` sorted by key.
run_phase() {
  _phase=$1; _inputs=$2; _mode=$3; shift 3
  _d="$WORK/$_phase"; mkdir -p "$_d"
  _pids=""
  for _i in "$@"; do
    _b=$(budget_for "$_i" "$_phase" "$_mode" "$_inputs")
    subsample "$_inputs" "$_d/in-$_i.tsv" "$_b"
    printf '%s\t%s\t%s\t%s+%s\n' "$_i" "$_b" \
        "$(wc -l < "$_d/in-$_i.tsv" | tr -d ' ')" \
        "$(cost_base "$_i")" "$(cost_block "$_i")" >> "$_d/budgets.tsv"
    [ -s "$_d/in-$_i.tsv" ] || { : > "$_d/$_i.tsv"; continue; }
    (
      _jp=""
      _n=$JOBS
      _s=0
      while [ "$_s" -lt "$_n" ]; do
        "$LIB/runhash.sh" "$_i" "$_d/in-$_i.tsv" "$_d/$_i.part$_s" "$_s" "$_n" &
        _jp="$_jp $!"
        _s=$((_s + 1))
      done
      for _p in $_jp; do wait "$_p"; done
      cat "$_d/$_i".part* 2>/dev/null | sort -n -k1,1 > "$_d/$_i.tsv"
      rm -f "$_d/$_i".part*
    ) &
    _pids="$_pids $!"
  done
  for _p in $_pids; do wait "$_p"; done
}

# run_oracles PHASE INPUTS — same shape, but only byte-aligned rows are fed to
# the oracles, because no oracle on this machine can hash a partial byte.
run_oracles() {
  _phase=$1; _inputs=$2
  _d="$WORK/$_phase"; mkdir -p "$_d"
  awk -F'\t' '$2 % 8 == 0' "$_inputs" > "$_d/in-oracles.tsv"
  _pids=""
  for _o in $(oracles_ok); do
    [ -s "$_d/in-oracles.tsv" ] || { : > "$_d/$_o.tsv"; continue; }
    ( "$LIB/runoracle.sh" "$_o" "$_d/in-oracles.tsv" "$_d/$_o.tsv" ) &
    _pids="$_pids $!"
  done
  for _p in $_pids; do wait "$_p"; done
}
