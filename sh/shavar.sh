#!/usr/bin/env bash
#
# shavar — SHA-256 written as a two-dimensional order-4 recurrence.
# Pure-shell implementation. See ../spec/SPEC.md (algorithm) and
# ../spec/CLI.md (command line and output encoding).
#
# ============================================================================
# READ THIS FIRST IF YOU DO NOT WRITE SHELL
# ============================================================================
#
# This file is written for a reader who is fluent in C or Python and has never
# had a reason to learn shell. The shell constructs used here are few, and all
# of them are introduced below. There is no shell magic further down that is
# not explained at the point where it is first used.
#
#   $(( expr ))       ARITHMETIC EXPANSION. The text between the doubled
#                     parentheses is parsed as a C-like integer expression and
#                     the result is substituted as a decimal string. Inside it,
#                     bare words are variable names — you write `x + 1`, not
#                     `$x + 1`. Operators are C's: + - * / % << >> & | ^ ~ ! &&
#                     || ?: and the comma operator. There are no floats here
#                     (bash has no floating point at all).
#
#   (( expr ))        ARITHMETIC COMMAND. Same expression language, but used as
#                     a statement rather than for its textual value. Assignment
#                     works: (( x = y + 1 )). The comma operator lets one
#                     invocation do many assignments in sequence, which is the
#                     single most important performance lever in this file —
#                     see the note on cost below. Its exit status is 0 when the
#                     value is nonzero, so `(( x ))` reads as `if (x)` in C.
#
#   arr=(a b c)       ARRAY assignment. `${arr[i]}` reads element i, `arr[i]=v`
#                     writes it, `${#arr[@]}` is the length, `"${arr[@]}"` is
#                     all elements as separate words. Subscripts are arithmetic
#                     contexts, so `${arr[t+4]}` is legal and means what you
#                     expect. Arrays are one-dimensional and untyped: every
#                     element is a string, reinterpreted as a number whenever
#                     it lands in an arithmetic context.
#
#   ${var:off:len}    SUBSTRING. Zero-based offset, length in characters —
#                     Python's var[off:off+len]. `off` and `len` are arithmetic
#                     contexts too.
#
#   ${var%%pat}       Strip the longest suffix matching a glob pattern.
#   ${var#pat}        Strip the shortest prefix matching a glob pattern.
#   ${var##pat}       Strip the longest prefix. These four are the shell's
#                     entire string-slicing vocabulary and are used below to
#                     take apart the space-separated self-test vectors.
#
#   $( cmd )          COMMAND SUBSTITUTION. Runs `cmd` in a *subshell* — on a
#                     Unix system that is a fork(2), roughly 10^4 times the
#                     cost of an arithmetic evaluation. It appears nowhere in
#                     this file's hot path, and that is deliberate. Note the
#                     easy confusion: `$( )` forks, `$(( ))` does not. They are
#                     unrelated constructs that happen to look alike.
#
#   local x y         Function-scoped variables. Without it every variable is
#                     global, which in a 64-round loop is a good way to have
#                     the message schedule quietly overwrite the state.
#
# One thing this file deliberately does NOT do is touch IFS (the Internal Field
# Separator, the character set on which the shell splits unquoted expansions).
# IFS games are the classic source of shell bugs that appear only for certain
# inputs. Everything here that could have been done by word splitting is done
# instead with arrays and with the ${var%%pat} family, which are insensitive to
# IFS and behave identically under both shells.
#
# ============================================================================
# TWO SHELLS, ONE SCRIPT
# ============================================================================
#
# This script must run correctly under bash 3.2 (the version Apple ships in
# /bin/bash, frozen in 2007 for licensing reasons) and under zsh 5.9 (the
# default interactive shell on modern macOS). They are close, but not close
# enough to ignore:
#
#   * ARRAY INDEX ORIGIN. bash arrays are 0-based; native zsh arrays are
#     1-based. Every subscript in this file would be off by one under one of
#     the two shells. The fix is `emulate -L ksh`, which switches zsh into ksh
#     compatibility for the duration of the enclosing function — including any
#     function it calls, since shell options are dynamically scoped — and
#     restores the previous options when that function returns. Among other
#     things it sets KSH_ARRAYS, giving 0-based subscripts. It appears at the
#     top of every function below that touches an array, guarded by a test on
#     $ZSH_VERSION so that bash never sees it. (The six round functions and
#     shavar_is_uint do not index arrays and so do not need it.)
#
#     Note that the index origin affects *subscripting*, not storage: an array
#     built at file scope with `arr=(a b c)` is the same list of three items
#     either way, and reading `${arr[0]}` under KSH_ARRAYS yields `a`. That is
#     why the constant tables below can be defined at file scope. Explicit
#     indexed writes, however, must happen inside an emulated function, and
#     they all do.
#
#   * NO ASSOCIATIVE ARRAYS. bash gained `declare -A` in 4.0, so bash 3.2 has
#     none. Nothing here uses them.
#
#   * SPARSE ARRAYS COUNT DIFFERENTLY. Given `b=(); b[5]=1`, bash 3.2 reports
#     ${#b[@]} as 1 (elements set) and zsh reports 6 (highest index). This
#     script therefore never asks an array for its length unless it filled that
#     array densely from index 0.
#
#   * SUBSTRING OFFSETS NEED A `$`. `${h:i:2}` works in bash but zsh reads the
#     bare `i` as one of its history-style modifiers and dies with
#     "unrecognized modifier". `${h:$i:2}` is correct in both. See
#     shavar_parse_hex.
#
#   * `case` INSIDE `$( )`. bash 3.2 mis-parses a `case` statement inside a
#     command substitution, taking the pattern's closing ')' for the end of the
#     substitution. Not an issue for this file, which contains no command
#     substitutions at all, but shavar_test.sh has to work around it.
#
# There is no third behaviour to worry about: `$(( ))`, `${var:$off:len}`, the
# `${var%%pat}` family, `printf` (including `printf -v`), `case`, `local`,
# `read`, and `for ((;;))` were all checked to behave identically under both
# shells before this file was written.
#
# ============================================================================
# 32-BIT ARITHMETIC ON A 64-BIT SIGNED MACHINE
# ============================================================================
#
# The shell has exactly one numeric type: a 64-bit SIGNED integer. There is no
# unsigned type, no 32-bit type, and no way to ask for either. SHA-256 is
# defined on 32-bit unsigned words, so every value is represented as a
# non-negative 64-bit integer holding a 32-bit value, and the invariant
# `0 <= v <= 0xFFFFFFFF` is restored with `& 0xFFFFFFFF` (spelled $M below).
#
# Three consequences, each of which is a real bug if forgotten:
#
#   1. ADDITION must be masked. Five 32-bit addends reach at most 5*2^32 < 2^35
#      so the sum itself never overflows 64 bits; it is only the modular
#      reduction that has to be applied, and it may be applied once at the end
#      of a chain of additions rather than after each one. That is sound
#      because addition carries strictly upward: bits at position >= 32 of an
#      addend cannot influence bits < 32 of the sum.
#
#   2. The same argument covers XOR, AND and OR, which act bit-position-wise
#      (SPEC.md §7.2). So the rotations below are written as
#      `(x >> n) | (x << (32-n))` with NO mask on the left shift: the shifted-
#      out high bits land above bit 31, are ignored by every subsequent
#      addition and xor, and are cleared by the single mask at the end of the
#      expression. This saves a mask per rotation, which is 6 per round.
#
#   3. RIGHT SHIFT is arithmetic (sign-propagating) in the shell, as it is for
#      signed C. It is safe here only because every value that gets shifted
#      right has been masked and is therefore non-negative. The one place a
#      negative value is produced on purpose is `~x` inside Ch: `~x` has all
#      bits above 31 set, but it is immediately ANDed with a masked value, so
#      the result is non-negative and correct. No value is ever both negative
#      and right-shifted.
#
# The message bit length L is likewise carried in a signed 64-bit integer, so
# this implementation's real bound is L < 2^63 rather than the standard's
# L < 2^64 (SPEC.md §5). Documented rather than hidden; no message that large
# is going to be hashed by a shell script.
#
# ============================================================================
# CALLING CONVENTION
# ============================================================================
#
# Shell functions return an exit status (0-255), not a value. Returning
# anything larger means either printing it and capturing it with $( ) — a fork
# per call, unaffordable — or writing it to a global variable. This file uses
# global variables as out-parameters throughout, with a SHAVAR_ prefix, and
# says so at each function. It is the least pleasant thing about the code and
# it is not avoidable in this language.
#
#   SHAVAR_MSG[]    input  : message bytes, one integer 0..255 per element
#   SHAVAR_BLK[]    scratch: the 64 bytes of the block being compressed
#   SHAVAR_H[]      in/out : the 8-word chaining value
#   SHAVAR_HIN[]    output : copy of SHAVAR_H as it entered the last block
#   SHAVAR_W[]      output : message schedule W[0..63]
#   SHAVAR_A[]      output : the A track, SHAVAR_A[t+4] holds A[t], t = -4..63
#   SHAVAR_E[]      output : the E track, likewise offset by 4
#   SHAVAR_T1[]     output : T1[t]
#   SHAVAR_T2[]     output : T2[t]
#   SHAVAR_NBLOCKS  output : number of 512-bit blocks in the padded message
#   SHAVAR_IV_IN[]  input  : the chaining value to start from (free-start)
#
# Sourcing this file with SHAVAR_LIB set to a non-empty value defines all of
# the above without running the command line interface:
#
#   SHAVAR_LIB=1 . sh/shavar.sh
#
# ============================================================================
# PERFORMANCE
# ============================================================================
#
# Measured on an Apple-silicon Mac, one 512-bit block through the compression
# function — the schedule, 64 rounds, and the chaining update. The machine was
# shared while these were taken, so they are best-of-N and should be read as
# an order of magnitude, not a benchmark:
#
#   bash 3.2.57   4-6 ms/block      ~200 blocks/s    ~12 kB/s
#   zsh 5.9       1.1-1.6 ms/block  ~800 blocks/s    ~50 kB/s
#
# So: milliseconds per block, not seconds. No process is created per block —
# the cost is entirely the shell re-lexing arithmetic expression text and doing
# hash-table variable lookups. The two shells differ by a factor of four on
# identical source, which is worth knowing before drawing any conclusion from
# a single measurement of "the shell".
#
# What did NOT help, stated because the negative result is the more useful one:
#
#   * Collapsing each round from a dozen `(( ))` statements into ONE comma-
#     separated expression is worth nothing measurable in bash and nothing
#     measurable in zsh. Both forms were built and timed head to head. Shell
#     arithmetic cost is in the operators and the variable lookups, not in
#     statement dispatch, so the usual "fewer, bigger expressions" instinct
#     does not pay here. The single-expression form is kept because it reads
#     as the four lines of SPEC.md §3 rather than as twelve, not for speed.
#
#   * Generating padded blocks by region instead of by a per-byte four-way
#     conditional measured somewhere between 0% and 12% depending on machine
#     load — i.e. real but small. It is kept mainly because it says what
#     padding *is* more directly.
#
# What genuinely matters is cruder, and was measured head to head against the
# function-per-operation version that shavar_test.sh keeps around as a drift
# check: inlining the six round functions instead of calling them is worth
# 1.4x under bash and 2.5x under zsh. A shell function call costs far more
# than the handful of operators it would contain. And no `$( )` anywhere —
# a fork per round would have dwarfed every other consideration in this list.
#
# ============================================================================

# ---------------------------------------------------------------------------
# Constants (SPEC.md §9)
#
# Defined at file scope in list form only, which is index-origin agnostic (see
# the portability note above). They are written in hex for legibility and
# converted to decimal once, in shavar__init, so that the round loop is not
# re-parsing "0x428a2f98" sixty-four times per block.
# ---------------------------------------------------------------------------

# The FIPS 180-4 initial chaining value: the first 32 bits of the fractional
# parts of the square roots of the first eight primes.
SHAVAR_IV=(0x6a09e667 0xbb67ae85 0x3c6ef372 0xa54ff53a
           0x510e527f 0x9b05688c 0x1f83d9ab 0x5be0cd19)

# Round constants K[0..63]: the first 32 bits of the fractional parts of the
# cube roots of the first sixty-four primes.
SHAVAR_K=(
  0x428a2f98 0x71374491 0xb5c0fbcf 0xe9b5dba5 0x3956c25b 0x59f111f1 0x923f82a4 0xab1c5ed5
  0xd807aa98 0x12835b01 0x243185be 0x550c7dc3 0x72be5d74 0x80deb1fe 0x9bdc06a7 0xc19bf174
  0xe49b69c1 0xefbe4786 0x0fc19dc6 0x240ca1cc 0x2de92c6f 0x4a7484aa 0x5cb0a9dc 0x76f988da
  0x983e5152 0xa831c66d 0xb00327c8 0xbf597fc7 0xc6e00bf3 0xd5a79147 0x06ca6351 0x14292967
  0x27b70a85 0x2e1b2138 0x4d2c6dfc 0x53380d13 0x650a7354 0x766a0abb 0x81c2c92e 0x92722c85
  0xa2bfe8a1 0xa81a664b 0xc24b8b70 0xc76c51a3 0xd192e819 0xd6990624 0xf40e3585 0x106aa070
  0x19a4c116 0x1e376c08 0x2748774c 0x34b0bcb5 0x391c0cb3 0x4ed8aa4a 0x5b9cca4f 0x682e6ff3
  0x748f82ee 0x78a5636f 0x84c87814 0x8cc70208 0x90befffa 0xa4506ceb 0xbef9a3f7 0xc67178f2)

SHAVAR_ROUNDS=64          # full SHA-256
SHAVAR_M=0xFFFFFFFF       # the 32-bit mask, written $M in hot code
SHAVAR__READY=            # set by shavar__init once the tables are normalised

# shavar__init — normalise the constant tables to decimal. Idempotent.
#
# Must run inside a function because it performs indexed writes, which need
# zsh's ksh array emulation to agree with bash about where index 0 is.
shavar__init() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L ksh
  [ -n "$SHAVAR__READY" ] && return 0
  local i
  for ((i = 0; i < 64; i++)); do (( SHAVAR_K[i] = SHAVAR_K[i] )); done
  for ((i = 0; i < 8;  i++)); do (( SHAVAR_IV[i] = SHAVAR_IV[i] )); done
  SHAVAR_IV_IN=("${SHAVAR_IV[@]}")
  SHAVAR__READY=1
}

# ---------------------------------------------------------------------------
# The six round functions (SPEC.md §1.1), exposed individually
#
# SPEC.md §7.1 turns on which of these are GF(2)-linear, so research code needs
# to substitute or instrument them one at a time; the C header keeps them
# separate for the same reason. Each writes its result to the global $R.
#
# These are NOT used by the compression loop. A shell function call is not a
# fork, but it is still an order of magnitude more expensive than an arithmetic
# operator, and six calls per round times 64 rounds times one block is enough
# to matter. The loop therefore inlines all six by hand. That duplication is a
# genuine correctness risk — the inline copy and the function copy can drift —
# and it is guarded in shavar_test.sh, which recomputes a whole block through
# these functions and diffs it against the inlined loop.
# ---------------------------------------------------------------------------

shavar_ch()     { R=$(( ($1 & $2) ^ (~$1 & $3) )); }
shavar_maj()    { R=$(( ($1 & $2) ^ ($1 & $3) ^ ($2 & $3) )); }
shavar_Sigma0() { R=$(( ((($1 >> 2)  | ($1 << 30)) ^ (($1 >> 13) | ($1 << 19)) ^ (($1 >> 22) | ($1 << 10))) & 0xFFFFFFFF )); }
shavar_Sigma1() { R=$(( ((($1 >> 6)  | ($1 << 26)) ^ (($1 >> 11) | ($1 << 21)) ^ (($1 >> 25) | ($1 << 7)))  & 0xFFFFFFFF )); }
shavar_sigma0() { R=$(( ((($1 >> 7)  | ($1 << 25)) ^ (($1 >> 18) | ($1 << 14)) ^  ($1 >> 3))               & 0xFFFFFFFF )); }
shavar_sigma1() { R=$(( ((($1 >> 17) | ($1 << 15)) ^ (($1 >> 19) | ($1 << 13)) ^  ($1 >> 10))              & 0xFFFFFFFF )); }

# ---------------------------------------------------------------------------
# shavar_compress <rounds>
#
# Compress SHAVAR_BLK[0..63] into SHAVAR_H[0..7], recording the entire interior
# of the compression into SHAVAR_W / SHAVAR_A / SHAVAR_E / SHAVAR_T1 /
# SHAVAR_T2. `rounds` may be anything in 0..64; SHAVAR_H may be any chaining
# value, not only the FIPS initial one. Both are prerequisites for the
# free-start and reduced-round analyses of SPEC.md §6, and neither is reachable
# through a normal hashing API.
#
# The trace is always recorded rather than being optional. Retaining it costs
# two array writes per round and 544 bytes; making it conditional would cost a
# branch per round and a second copy of the loop.
#
# INDEX OFFSET. The spec indexes A and E from t = -4. Shell arrays have no
# negative indices, so SHAVAR_A[t+4] holds A[t]. The +4 is written out at every
# use rather than hidden behind an accessor function, because an accessor would
# be a function call in the innermost loop. Read `SHAVAR_A[t+3]` as `A[t-1]`.
# ---------------------------------------------------------------------------
shavar_compress() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L ksh
  local rounds=$1
  local t i j x y a1 a2 a3 a4 e1 e2 e3 e4 t1 t2
  local M=0xFFFFFFFF

  SHAVAR_HIN=("${SHAVAR_H[@]}")

  # -- message schedule, W[0..15]: the block's bytes as big-endian words -----
  # (( )) with a comma operator does the index arithmetic and the four byte
  # placements in one evaluation.
  for ((i = 0; i < 16; i++)); do
    (( j = i << 2,
       SHAVAR_W[i] = (SHAVAR_BLK[j]   << 24) | (SHAVAR_BLK[j+1] << 16)
                   | (SHAVAR_BLK[j+2] <<  8) |  SHAVAR_BLK[j+3] ))
  done

  # -- message schedule, W[16..63] (SPEC.md §4) -----------------------------
  #   W[t] = sigma1(W[t-2]) + W[t-7] + sigma0(W[t-15]) + W[t-16]
  # sigma0 and sigma1 are inlined. Only the final sum is masked; see the
  # arithmetic note at the top of the file for why the intermediate rotations
  # may be left dirty above bit 31.
  #
  # W is computed for all 64 entries even when `rounds` is smaller, because the
  # schedule does not depend on the round count and CLI.md requires `trace` to
  # print all 64 regardless.
  for ((t = 16; t < 64; t++)); do
    (( x = SHAVAR_W[t-15],
       y = SHAVAR_W[t-2],
       SHAVAR_W[t] = ( (((x >>  7) | (x << 25)) ^ ((x >> 18) | (x << 14)) ^ (x >>  3))
                     + (((y >> 17) | (y << 15)) ^ ((y >> 19) | (y << 13)) ^ (y >> 10))
                     + SHAVAR_W[t-7] + SHAVAR_W[t-16] ) & M ))
  done

  # -- seed the two tracks from the incoming chaining value (SPEC.md §3) ----
  #   A[-1]=H0 A[-2]=H1 A[-3]=H2 A[-4]=H3      E[-1]=H4 ... E[-4]=H7
  # which after the +4 offset is simply H reversed into the first four slots.
  SHAVAR_A[0]=${SHAVAR_H[3]}; SHAVAR_A[1]=${SHAVAR_H[2]}
  SHAVAR_A[2]=${SHAVAR_H[1]}; SHAVAR_A[3]=${SHAVAR_H[0]}
  SHAVAR_E[0]=${SHAVAR_H[7]}; SHAVAR_E[1]=${SHAVAR_H[6]}
  SHAVAR_E[2]=${SHAVAR_H[5]}; SHAVAR_E[3]=${SHAVAR_H[4]}

  # -- the round loop (SPEC.md §3) ------------------------------------------
  #
  #   T1[t] = E[t-4] + Sigma1(E[t-1]) + Ch(E[t-1],E[t-2],E[t-3]) + K[t] + W[t]
  #   T2[t] = Sigma0(A[t-1]) + Maj(A[t-1],A[t-2],A[t-3])
  #   E[t]  = A[t-4] + T1[t]
  #   A[t]  = T1[t] + T2[t]
  #
  # The whole round is a single arithmetic evaluation, sequenced with the comma
  # operator. This was expected to be faster than one (( )) per assignment and
  # measurably is not — both forms were built and timed, and the difference is
  # inside the noise under bash and under zsh. It is kept because it puts the
  # four lines of the spec on screen as four lines of code, which is the only
  # place in this file where the shell lets the algorithm show through.
  #
  # a1..a4 are A[t-1]..A[t-4] and e1..e4 are E[t-1]..E[t-4]. Naming them keeps
  # the round body legible and avoids re-evaluating `SHAVAR_A[t+3]` for each of
  # the five places a1 appears.
  for ((t = 0; t < rounds; t++)); do
    (( a1 = SHAVAR_A[t+3], a2 = SHAVAR_A[t+2], a3 = SHAVAR_A[t+1], a4 = SHAVAR_A[t],
       e1 = SHAVAR_E[t+3], e2 = SHAVAR_E[t+2], e3 = SHAVAR_E[t+1], e4 = SHAVAR_E[t],

       t1 = ( e4
            + ((((e1 >>  6) | (e1 << 26)) ^ ((e1 >> 11) | (e1 << 21)) ^ ((e1 >> 25) | (e1 << 7))))
            + ((e1 & e2) ^ (~e1 & e3))
            + SHAVAR_K[t] + SHAVAR_W[t] ) & M,

       t2 = ( ((((a1 >>  2) | (a1 << 30)) ^ ((a1 >> 13) | (a1 << 19)) ^ ((a1 >> 22) | (a1 << 10))))
            + ((a1 & a2) ^ (a1 & a3) ^ (a2 & a3)) ) & M,

       SHAVAR_T1[t] = t1,
       SHAVAR_T2[t] = t2,
       SHAVAR_E[t+4] = (a4 + t1) & M,
       SHAVAR_A[t+4] = (t1 + t2) & M ))
  done

  # -- outgoing chaining value ----------------------------------------------
  #   H[0..3] += A[n-1..n-4]      H[4..7] += E[n-1..n-4]      n = rounds
  # For n < 4 the indices reach back into the seeded region, which is exactly
  # what the recurrence says should happen and needs no special case: with the
  # +4 offset, A[n-1] is SHAVAR_A[n+3] whatever the sign of n-1.
  (( SHAVAR_H[0] = (SHAVAR_H[0] + SHAVAR_A[rounds+3]) & M,
     SHAVAR_H[1] = (SHAVAR_H[1] + SHAVAR_A[rounds+2]) & M,
     SHAVAR_H[2] = (SHAVAR_H[2] + SHAVAR_A[rounds+1]) & M,
     SHAVAR_H[3] = (SHAVAR_H[3] + SHAVAR_A[rounds])   & M,
     SHAVAR_H[4] = (SHAVAR_H[4] + SHAVAR_E[rounds+3]) & M,
     SHAVAR_H[5] = (SHAVAR_H[5] + SHAVAR_E[rounds+2]) & M,
     SHAVAR_H[6] = (SHAVAR_H[6] + SHAVAR_E[rounds+1]) & M,
     SHAVAR_H[7] = (SHAVAR_H[7] + SHAVAR_E[rounds])   & M ))
}

# ---------------------------------------------------------------------------
# Padding (SPEC.md §5)
#
# shavar_padded_blocks <nbits> — how many 512-bit blocks the padded message
# occupies, into SHAVAR_NBLOCKS.
#
#   L + 1 + k = 448 (mod 512), then 64 more bits, so the padded length is the
#   next multiple of 512 at or above L + 65. Integer division does it:
#   floor((L + 64) / 512) + 1. L = 447 gives 1; L = 448 gives 2.
# ---------------------------------------------------------------------------
shavar_padded_blocks() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L ksh
  (( SHAVAR_NBLOCKS = ($1 + 64) / 512 + 1 ))
}

# shavar_block <nbits> <idx> — materialise block `idx` of the padded message
# into SHAVAR_BLK[0..63]. Requires SHAVAR_NBLOCKS to be current.
#
# The padded stream is never built in full; each block is generated on demand
# from the message bytes plus the position. A padded block is made of at most
# four regions, and they are written in that order rather than being selected
# byte by byte:
#
#   [0, nfull-base)     whole message bytes
#   nfull-base          the byte carrying the appended 1 bit. When L is not a
#                       multiple of 8 this byte also carries the message's
#                       final L mod 8 bits in its high-order positions, and the
#                       1 bit goes at bit 7 - (L mod 8): that is 0x80 >> rem.
#                       When L IS a multiple of 8 the same expression gives
#                       plain 0x80 with no message bits, so there is no special
#                       case. (SPEC.md §5.1, §5.2.)
#   56..63 of the last  the eight big-endian length bytes
#   everything else     zero
#
# The 1-bit position and the length field can never coincide, because padding
# always appends at least 1 + 64 bits.
#
# PERFORMANCE. The obvious way to write this is one loop over j = 0..63 with a
# four-way branch inside. Measured, that cost more than the entire 64-round
# compression it feeds: 64 conditionals plus 64 indexed writes, per block. The
# version below zeroes the block with a single whole-array assignment — one
# operation regardless of length — and then writes only the regions that are
# not zero. It is also arguably the clearer statement of what padding is.
SHAVAR__ZERO64=(0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
                0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)

shavar_block() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L ksh
  local L=$1 idx=$2
  local nfull rem total base j hi
  (( nfull = L / 8, rem = L % 8, total = SHAVAR_NBLOCKS * 64, base = idx * 64 ))

  SHAVAR_BLK=("${SHAVAR__ZERO64[@]}")

  # message bytes falling in this block
  (( hi = nfull - base ))
  (( hi > 64 )) && hi=64
  for ((j = 0; j < hi; j++)); do SHAVAR_BLK[j]=${SHAVAR_MSG[base+j]}; done

  # the byte holding the appended 1 bit, if it lands here
  (( j = nfull - base ))
  (( j >= 0 && j < 64 )) && (( SHAVAR_BLK[j] = (rem ? SHAVAR_MSG[nfull] : 0) | (0x80 >> rem) ))

  # the 64-bit big-endian length, always the last eight bytes of the last block
  if (( base + 64 == total )); then
    for ((j = 56; j < 64; j++)); do (( SHAVAR_BLK[j] = (L >> (8 * (63 - j))) & 0xFF )); done
  fi
  return 0
}

# ---------------------------------------------------------------------------
# shavar_hash_ex <nbits> <rounds>
#
# Hash SHAVAR_MSG[] starting from SHAVAR_IV_IN[] with the given round count,
# leaving the digest in SHAVAR_H[0..7]. The caller has already validated the
# message (shavar_check_msg).
# ---------------------------------------------------------------------------
shavar_hash_ex() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L ksh
  local L=$1 rounds=$2 b
  shavar_padded_blocks "$L"
  SHAVAR_H=("${SHAVAR_IV_IN[@]}")
  for ((b = 0; b < SHAVAR_NBLOCKS; b++)); do
    shavar_block "$L" "$b"
    shavar_compress "$rounds"
  done
}

# ---------------------------------------------------------------------------
# Proof-of-work comparison (SPEC.md §10)
# ---------------------------------------------------------------------------
#
# The argument called <nbits> in this section is Bitcoin's compact *target*
# encoding, an 8-bit exponent above a 23-bit mantissa. It has nothing to do
# with the message bit length called L or nbits elsewhere in this file; the
# collision of names is inherited from both conventions.
#
# It is passed as a shell integer, so a caller holding the usual hex spelling
# writes  shavar_pow_target $((16#1d00ffff)).

# shavar_pow_target <nbits> — decode into SHAVAR_POW_TARGET[0..31], BIG-endian:
# index 0 is the most significant byte. Returns 1 on an encoding that is
# negative, overflows 256 bits, or denotes zero.
#
# The target is built byte by byte. Shell arithmetic is 64-bit, so a 256-bit
# value has no representation here at all — which is the same constraint the
# six sibling implementations work under, and why they can be expected to
# agree.
shavar_pow_target() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L ksh
  local nb=$1 exponent mantissa shift i v
  (( exponent = (nb >> 24) & 0xFF ))
  (( mantissa = nb & 0x007FFFFF ))

  # The sign bit. A target is an unsigned magnitude, so a set sign bit is an
  # error rather than something to mask away. Guarded on a nonzero mantissa to
  # match Bitcoin's SetCompact exactly.
  if (( mantissa != 0 && (nb & 0x00800000) != 0 )); then
    return 1
  fi
  if (( mantissa != 0 && (exponent > 34 || \
        (mantissa > 0xFF && exponent > 33) || \
        (mantissa > 0xFFFF && exponent > 32)) )); then
    return 1
  fi

  SHAVAR_POW_TARGET=()
  for ((i = 0; i < 32; i++)); do SHAVAR_POW_TARGET[i]=0; done

  if (( exponent <= 3 )); then
    # The mantissa shifts down and may vanish entirely.
    (( v = mantissa >> (8 * (3 - exponent)) ))
    (( SHAVAR_POW_TARGET[31] = v & 0xFF ))
    (( SHAVAR_POW_TARGET[30] = (v >> 8) & 0xFF ))
    (( SHAVAR_POW_TARGET[29] = (v >> 16) & 0xFF ))
  else
    # `shift` is the byte offset of the mantissa's low byte from the least
    # significant end, so in a big-endian array it lands at index 31 - shift.
    # The overflow test above guarantees no nonzero byte lands below index 0.
    (( shift = exponent - 3 ))
    (( 31 - shift >= 0 )) && (( SHAVAR_POW_TARGET[31 - shift] = mantissa & 0xFF ))
    (( 30 - shift >= 0 )) && (( SHAVAR_POW_TARGET[30 - shift] = (mantissa >> 8) & 0xFF ))
    (( 29 - shift >= 0 )) && (( SHAVAR_POW_TARGET[29 - shift] = (mantissa >> 16) & 0xFF ))
  fi

  # A zero target is unsatisfiable, so it is a malformed request rather than a
  # verdict of "no" against every possible digest.
  for ((i = 0; i < 32; i++)); do
    (( SHAVAR_POW_TARGET[i] != 0 )) && return 0
  done
  return 1
}

# shavar_pow_check <digest-hex> <nbits> — exit status 0 if the digest meets the
# target, 1 if it does not, 2 if <nbits> is invalid. <digest-hex> is 64 hex
# characters in EMISSION order: exactly what `hash` prints.
#
# THE BYTE ORDER, the only thing here that is easy to get wrong: the digest is
# read LITTLE-endian. Byte 0 — the first byte the hash function emitted, the
# leftmost pair of the hex string — is the LEAST significant byte of the
# 256-bit value, and byte 31 is the MOST significant. That is the reverse of
# the order the bytes are written in, and it is why a Bitcoin block hash is
# displayed reversed relative to the digest actually computed. SPEC.md §10.1.
#
# The comparison is "at most", not "strictly less".
shavar_pow_check() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L ksh
  local h=$1 nb=$2 i a b
  case "$h" in
    *[!0-9a-fA-F]*) return 2 ;;
  esac
  [ ${#h} -eq 64 ] || return 2
  shavar_pow_target "$nb" || return 2

  # Both values walked most significant byte first. SHAVAR_POW_TARGET is
  # already in that order; the digest is not, so it is indexed backwards.
  # `31 - i` is the whole convention — using `i` there is the classic
  # byte-order bug, and it is silent.
  for ((i = 0; i < 32; i++)); do
    (( a = 16#${h:$(( (31 - i) * 2 )):2} ))
    (( b = SHAVAR_POW_TARGET[i] ))
    (( a < b )) && return 0
    (( a > b )) && return 1
  done
  return 0   # every byte equal: value == target, and the relation is <=
}

# ---------------------------------------------------------------------------
# Input handling
# ---------------------------------------------------------------------------

# shavar_parse_hex <hexstring> — decode into SHAVAR_MSG[] as integers.
# Returns 1 on a malformed string. `-` means the empty message.
#
# `case` with a glob pattern is the shell's regex-shaped tool. The pattern
# *[!0-9a-fA-F]* matches any string containing at least one character outside
# the bracket set, so the first branch fires exactly on malformed input. This
# check must come before the conversion below, because $(( 16#zz )) is a fatal
# arithmetic error rather than a recoverable one.
#
# $(( 16#XY )) is base-16 input in arithmetic expansion. Both shells accept
# upper and lower case letters interchangeably for bases up to 36.
#
# PORTABILITY TRAP. The substring offset is written `${h:$i:2}` with an
# explicit `$`, not `${h:i:2}`. bash accepts either, but zsh parses a bare
# identifier after the colon as one of its history-style modifiers and fails
# with "unrecognized modifier `i'". The `$` disambiguates in both shells.
shavar_parse_hex() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L ksh
  local h=$1 n i
  SHAVAR_MSG=()
  [ "$h" = "-" ] && return 0
  case "$h" in
    '' | *[!0-9a-fA-F]*) return 1 ;;
  esac
  n=${#h}
  (( n % 2 )) && return 1
  for ((i = 0; i < n; i += 2)); do
    (( SHAVAR_MSG[i >> 1] = 16#${h:$i:2} ))
  done
  return 0
}

# shavar_check_msg <nbits> <nbytes-supplied> — enforce CLI.md's message
# encoding rules. Returns 1 with a diagnostic on stderr if violated.
#
#   * ceil(nbits/8) must equal the number of hex bytes supplied;
#   * when nbits % 8 != 0, the low 8 - (nbits % 8) bits of the final byte must
#     be zero. SPEC.md §5.1: rejecting rather than masking is deliberate, since
#     masking would map two distinct inputs to one digest.
shavar_check_msg() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L ksh
  local L=$1 have=$2 want rem
  (( want = (L + 7) / 8 ))
  if (( have != want )); then
    printf 'shavar: %s bits needs %s hex bytes, got %s\n' "$L" "$want" "$have" >&2
    return 1
  fi
  (( rem = L % 8 )) || return 0
  if (( SHAVAR_MSG[L / 8] & ((1 << (8 - rem)) - 1) )); then
    printf 'shavar: final byte has nonzero bits below the %s significant ones\n' "$rem" >&2
    return 1
  fi
  return 0
}

# shavar_is_uint <string> — a decimal non-negative integer and nothing else.
# The '' alternative rejects the empty string, which the glob alone would let
# through (it has no character outside the set because it has no characters).
shavar_is_uint() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
  esac
  return 0
}

# shavar_set_iv <64 hex digits> — free-start support: replace the initial
# chaining value. Returns 1 on a malformed argument.
shavar_set_iv() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L ksh
  local s=$1 i off
  case "$s" in
    *[!0-9a-fA-F]*) return 1 ;;
  esac
  [ ${#s} -eq 64 ] || return 1
  for ((i = 0; i < 8; i++)); do
    (( off = 8 * i ))
    (( SHAVAR_IV_IN[i] = 16#${s:$off:8} ))
  done
  return 0
}

# ---------------------------------------------------------------------------
# Output (CLI.md)
# ---------------------------------------------------------------------------

# printf here is the SHELL BUILTIN, not /usr/bin/printf: no process is created.
# A format string is reused until its arguments run out, so one call with eight
# arguments emits eight fields. "${SHAVAR_H[@]}" expands to the eight words as
# eight separate arguments.
shavar_print_digest() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L ksh
  printf '%08x' "${SHAVAR_H[@]}"
  printf '\n'
}

# shavar_print_trace <rounds> — CLI.md's tab-separated record format.
# `\t` is interpreted by printf, and %d prints negative t with its leading '-'
# as required.
shavar_print_trace() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L ksh
  local rounds=$1 i t
  for ((i = 0; i < 8; i++));       do printf 'HIN\t%d\t%08x\n'  "$i" "${SHAVAR_HIN[i]}"; done
  for ((t = 0; t < 64; t++));      do printf 'W\t%d\t%08x\n'    "$t" "${SHAVAR_W[t]}";   done
  for ((t = -4; t < rounds; t++)); do printf 'A\t%d\t%08x\n'    "$t" "${SHAVAR_A[t+4]}"; done
  for ((t = -4; t < rounds; t++)); do printf 'E\t%d\t%08x\n'    "$t" "${SHAVAR_E[t+4]}"; done
  for ((t = 0; t < rounds; t++));  do printf 'T1\t%d\t%08x\n'   "$t" "${SHAVAR_T1[t]}";  done
  for ((t = 0; t < rounds; t++));  do printf 'T2\t%d\t%08x\n'   "$t" "${SHAVAR_T2[t]}";  done
  for ((i = 0; i < 8; i++));       do printf 'HOUT\t%d\t%08x\n' "$i" "${SHAVAR_H[i]}";   done
}

# ---------------------------------------------------------------------------
# Self-test vectors
#
# Each record is "hex nbits rounds expected". They are taken apart with the
# ${var%%pat} / ${var#pat} family rather than by word splitting, so that no
# assumption about IFS or about zsh's SH_WORD_SPLIT option leaks in:
#
#   ${rec%% *}   everything before the first space   (strip longest " *" suffix)
#   ${rec#* }    everything after the first space    (strip shortest "* " prefix)
#
# Coverage, deliberately chosen so that a failure localises:
#   1-4   FIPS/CAVP byte-aligned vectors: empty, one block, the 448-bit
#         boundary case, and a two-block message.
#   5-7   sub-byte lengths (SPEC.md §5): the spec's own worked example of
#         L = 5, the NIST bit-oriented L = 5 vector, and L = 1.
#   8     a sub-byte length that also spans two blocks (L = 557).
#   9     a whole block of 0xff, which puts the length field alone in block 2.
#   10-12 reduced-round variants of "abc" at 32, 16 and 1 rounds. These are not
#         SHA-256 and have no external authority; they were produced by an
#         independent implementation of SPEC.md §3 and exist to pin the
#         reduced-round path against silent change, and to be cross-checked
#         against the other six implementations (SPEC.md §8, V6).
# ---------------------------------------------------------------------------
SHAVAR_VECTORS=(
"- 0 64 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
"616263 24 64 ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
"6162636462636465636465666465666765666768666768696768696a68696a6b696a6b6c6a6b6c6d6b6c6d6e6c6d6e6f6d6e6f706e6f7071 448 64 248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
"61626364656667686263646566676869636465666768696a6465666768696a6b65666768696a6b6c666768696a6b6c6d6768696a6b6c6d6e68696a6b6c6d6e6f696a6b6c6d6e6f706a6b6c6d6e6f70716b6c6d6e6f7071726c6d6e6f707172736d6e6f70717273746e6f707172737475 896 64 cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"
"b0 5 64 82c9ef980dfdf26f0cb97f59d34a60dc39c82e489da9ca2132681fe0aa14270a"
"68 5 64 d6d3e02a31a84a8caa9718ed6c2057be09db45e7823eb5079ce7a573a3760f95"
"00 1 64 bd4f9e98beb68c6ead3243b1b4c7fed75fa4feaab1f84795cbd8a98676a2a375"
"61616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616160 557 64 6d359cbe0796b2262e76f606fa2147779d4687f0adcd5a1e31bd65b42dc8976a"
"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff 512 64 8667e718294e9e0df1d30600ba3eeb201f764aad2dad72748643e4a285e1d1f7"
"616263 24 32 ddbd225ca600d8a7dc74fea2db8478030b6763919c0f13c6cd6b6de2bcf370d0"
"616263 24 16 1b0409f57bcc0e6315a1de882ce11eca5867604ca6985a9893de22897a384f31"
"616263 24 1 c774d234257194ecf7d6a1f7e1bee8ac4b3898a1ec13bb0bba8942377b64a6c4"
)

shavar_selftest() {
  [ -n "${ZSH_VERSION:-}" ] && emulate -L ksh
  shavar__init
  local n=0 bad=0 rec hx rest nb rd want got

  for rec in "${SHAVAR_VECTORS[@]}"; do
    hx=${rec%% *};   rest=${rec#* }
    nb=${rest%% *};  rest=${rest#* }
    rd=${rest%% *};  want=${rest##* }

    # Validate the vector itself, through exactly the path the CLI uses. This
    # is not ceremony: an earlier draft of this table carried a 97-byte hex
    # string labelled 512 bits, and because the extra bytes were beyond the one
    # block that 512 bits occupies, the digest still matched and the self-test
    # still passed. A self-test that does not check its own inputs is testing
    # less than it claims to.
    if ! shavar_parse_hex "$hx"; then
      bad=$((bad + 1)); n=$((n + 1))
      printf 'FAIL\t%s\t%s\tmalformed hex in vector\n' "$hx" "$nb" >&2
      continue
    fi
    if ! shavar_check_msg "$nb" "${#SHAVAR_MSG[@]}"; then
      bad=$((bad + 1)); n=$((n + 1))
      printf 'FAIL\t%s\t%s\tvector violates the message encoding rules\n' "$hx" "$nb" >&2
      continue
    fi
    SHAVAR_IV_IN=("${SHAVAR_IV[@]}")
    shavar_hash_ex "$nb" "$rd"
    # A digest is eight words; build the 64-character string without forking.
    # printf -v assigns to a variable instead of writing to stdout, so no $( )
    # and no subshell. It is supported by bash 3.1+ and by zsh 5.x.
    printf -v got '%08x%08x%08x%08x%08x%08x%08x%08x' "${SHAVAR_H[@]}"
    n=$((n + 1))
    if [ "$got" != "$want" ]; then
      bad=$((bad + 1))
      printf 'FAIL\t%s\t%s\trounds=%s\n\texpected %s\n\tgot      %s\n' \
             "$hx" "$nb" "$rd" "$want" "$got" >&2
    fi
  done

  if (( bad )); then
    printf 'FAIL %d of %d vectors\n' "$bad" "$n" >&2
    return 1
  fi
  printf 'ok %d\n' "$n"
  return 0
}

# ---------------------------------------------------------------------------
# Command line (CLI.md)
#
# Exit codes: 0 success, 1 a self-test vector failed, 2 bad usage / malformed
# hex / nonzero trailing bits. Diagnostics go to stderr so that stdout is
# always either well-formed output or empty.
# ---------------------------------------------------------------------------

shavar_usage() {
  printf 'usage: shavar.sh [--iv <64hex>] <command>\n' >&2
  printf '  hash  <hex> <nbits> [rounds]\n' >&2
  printf '  trace <hex> <nbits> [blockidx] [rounds]\n' >&2
  printf '  selftest\n' >&2
  printf '\n' >&2
  printf '  <hex> is 2*ceil(nbits/8) hex digits, or - for the empty message.\n' >&2
  printf '  --iv supplies a free-start chaining value; it is an extension\n' >&2
  printf '  beyond the fixed contract in spec/CLI.md and defaults to the\n' >&2
  printf '  FIPS 180-4 initial value.\n' >&2
}

shavar_main() {
  # This is the one place the zsh/bash array-origin difference is resolved for
  # the whole program: `emulate -L ksh` here covers every function this one
  # calls, because shell options are dynamically scoped, and unwinds when
  # shavar_main returns.
  [ -n "${ZSH_VERSION:-}" ] && emulate -L ksh
  shavar__init

  SHAVAR_IV_IN=("${SHAVAR_IV[@]}")

  while [ $# -gt 0 ]; do
    case "$1" in
      --iv)
        [ $# -ge 2 ] || { printf 'shavar: --iv needs an argument\n' >&2; return 2; }
        shavar_set_iv "$2" || { printf 'shavar: --iv wants 64 hex digits\n' >&2; return 2; }
        shift 2
        ;;
      -h | --help) shavar_usage; return 2 ;;
      *) break ;;
    esac
  done

  [ $# -ge 1 ] || { shavar_usage; return 2; }

  local cmd=$1; shift
  local rounds=64 blockidx=0 nbytes b

  case "$cmd" in
    hash)
      [ $# -eq 2 ] || [ $# -eq 3 ] || { shavar_usage; return 2; }
      shavar_is_uint "$2" || { printf 'shavar: nbits must be a non-negative integer\n' >&2; return 2; }
      if [ $# -eq 3 ]; then
        shavar_is_uint "$3" || { printf 'shavar: rounds must be a non-negative integer\n' >&2; return 2; }
        rounds=$3
        (( rounds <= 64 )) || { printf 'shavar: rounds must be 0..64\n' >&2; return 2; }
      fi
      shavar_parse_hex "$1" || { printf 'shavar: malformed hex\n' >&2; return 2; }
      # SHAVAR_MSG was filled densely from index 0, so ${#SHAVAR_MSG[@]} is
      # trustworthy here — see the note on sparse arrays at the top.
      nbytes=${#SHAVAR_MSG[@]}
      shavar_check_msg "$2" "$nbytes" || return 2
      shavar_hash_ex "$2" "$rounds"
      shavar_print_digest
      return 0
      ;;

    trace)
      [ $# -ge 2 ] && [ $# -le 4 ] || { shavar_usage; return 2; }
      shavar_is_uint "$2" || { printf 'shavar: nbits must be a non-negative integer\n' >&2; return 2; }
      if [ $# -ge 3 ]; then
        shavar_is_uint "$3" || { printf 'shavar: blockidx must be a non-negative integer\n' >&2; return 2; }
        blockidx=$3
      fi
      if [ $# -ge 4 ]; then
        shavar_is_uint "$4" || { printf 'shavar: rounds must be a non-negative integer\n' >&2; return 2; }
        rounds=$4
        (( rounds <= 64 )) || { printf 'shavar: rounds must be 0..64\n' >&2; return 2; }
      fi
      shavar_parse_hex "$1" || { printf 'shavar: malformed hex\n' >&2; return 2; }
      nbytes=${#SHAVAR_MSG[@]}
      shavar_check_msg "$2" "$nbytes" || return 2
      shavar_padded_blocks "$2"
      (( blockidx < SHAVAR_NBLOCKS )) || {
        printf 'shavar: blockidx %s out of range, padded message has %s blocks\n' \
               "$blockidx" "$SHAVAR_NBLOCKS" >&2
        return 2
      }
      # Run the preceding blocks to obtain the chaining value entering the one
      # being traced; the trace arrays are then overwritten by the last call.
      SHAVAR_H=("${SHAVAR_IV_IN[@]}")
      for ((b = 0; b <= blockidx; b++)); do
        shavar_block "$2" "$b"
        shavar_compress "$rounds"
      done
      shavar_print_trace "$rounds"
      return 0
      ;;

    selftest)
      [ $# -eq 0 ] || { shavar_usage; return 2; }
      shavar_selftest
      return $?
      ;;

    *)
      printf 'shavar: unknown command %s\n' "$cmd" >&2
      shavar_usage
      return 2
      ;;
  esac
}

# Run the CLI unless the file was sourced as a library. There is no portable
# way to detect sourcing that works in both bash and zsh, so the caller says
# so explicitly:  SHAVAR_LIB=1 . sh/shavar.sh
if [ -z "${SHAVAR_LIB:-}" ]; then
  shavar_main "$@"
  exit $?
fi
