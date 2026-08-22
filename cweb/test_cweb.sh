#!/usr/bin/env bash
#
# test_cweb.sh — treat the literate version as a tested artefact, both halves
# of it.
#
# A literate program has two failure modes an ordinary one does not.  The
# tangled C can drift away from the hand-written C it is supposed to reproduce,
# and the woven document can build "successfully" while rendering an unresolved
# reference as `??`.  Neither is caught by reading.  Everything below exists to
# catch one of them.
#
# The equivalence argument has three independent legs, and none of them
# subsumes the others:
#
#   1. token identity      both sides preprocessed and tokenised; the streams
#                          must be equal.  Catches drift in code no test
#                          executes.  Would pass if both were identically wrong.
#   2. observational        the two binaries must agree on digests, on full
#      identity             per-round traces, on reduced-round output, and on
#                          the error paths.  Catches anything the corpus reaches.
#   3. the real suite       the tangled binary is substituted for the C
#                          implementation in tests/ and run against the NIST
#                          CAVP vectors and the other six implementations.
#
# Usage:
#   cweb/test_cweb.sh              everything
#   cweb/test_cweb.sh --quick      skip `tests/run.sh fast` (the slowest leg)

set -uo pipefail
cd "$(dirname "$0")" || exit 1
HERE=$(pwd)
ROOT=$(dirname "$HERE")

# Compiled build output lives in the disposable tree beside the repository
# (CLAUDE.md T2); BUILD_TARGET_PREFIX overrides the prefix, matching c/Makefile
# and tests/lib/common.sh.
BUILD_DIR=${BUILD_TARGET_PREFIX:-$(dirname "$ROOT")}/_buildoutput/256-shavar

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

fails=0
note() { printf '%-58s %s\n' "$1" "$2"; }
fail() { note "$1" "FAIL"; fails=$((fails + 1)); }
pass() { note "$1" "ok"; }
skip() { note "$1" "skipped ($2)"; }
hdr()  { printf '\n== %s ==\n' "$1"; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/shavar-cweb.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

CC_BIN=${CC:-cc}
WARN="-Wall -Wextra -pedantic-errors -Wshadow -Wconversion -Wsign-conversion
      -Wcast-qual -Wstrict-prototypes -Wmissing-prototypes -Wpointer-arith
      -Wwrite-strings -Wredundant-decls -Wundef"

# ===========================================================================
hdr "toolchain"
# ===========================================================================

have_tangle=1
command -v ctangle >/dev/null || have_tangle=0
have_weave=1
command -v cweave >/dev/null || have_weave=0
command -v pdftex >/dev/null || have_weave=0
if [ "$have_weave" = 1 ] && ! kpsewhich cwebmac.tex >/dev/null 2>&1; then
  have_weave=0
fi

if [ "$have_tangle" = 1 ]; then pass "ctangle present: $(command -v ctangle)"
else skip "ctangle present" "not installed"; fi
if [ "$have_weave" = 1 ]; then pass "cweave + pdftex + cwebmac.tex present"
else skip "cweave + pdftex + cwebmac.tex present" "not installed"; fi

if [ "$have_tangle" = 0 ] && [ "$have_weave" = 0 ]; then
  echo
  echo "CWEB is not installed; nothing to test.  It ships with TeX Live and"
  echo "MacTeX (binaries ctangle and cweave), or as the Debian package 'cweb'."
  exit 0
fi

# ===========================================================================
if [ "$have_tangle" = 1 ]; then
hdr "tangle: does ctangle produce the same program as ../c ?"
# ===========================================================================

# Both ctangle and cweave report a problem in two ways: a nonzero exit and a
# line beginning with `!`.  Neither the banner nor the cheerful
# "(No errors were found.)" can be relied on -- CWEB 4.8 as packaged for
# Debian prints nothing at all when its output is not a terminal, while 4.12
# from MacTeX prints both -- so the check is on the exit status and on the
# absence of complaints, which every version agrees about.
web_ran_clean() { # web_ran_clean LABEL RC LOGFILE
  if [ "$2" = 0 ] && ! grep -qE '^!|Pardon me' "$3"; then
    pass "$1"
  else
    fail "$1"
    if [ -s "$3" ]; then sed 's/^/    /' "$3" | head -20
    else echo "    (exit $2, no diagnostic output)"; fi
  fi
}

rm -f shavar-cweb.c shavar.h main.c
ctangle shavar-cweb.w > "$TMP/ctangle.log" 2>&1
web_ran_clean "ctangle runs clean" "$?" "$TMP/ctangle.log"

for f in shavar-cweb.c shavar.h main.c; do
  if [ -s "$f" ]; then pass "tangled $f"; else fail "tangled $f"; fi
done

# The tangled sources must survive the same warning set as the hand-written
# ones, with -Werror.  A warning here that ../c does not provoke would be a
# difference in the program even if the token check somehow passed.
# shellcheck disable=SC2086
if $CC_BIN -std=c99 -O2 $WARN -Werror shavar-cweb.c main.c -o "$TMP/shavar-cweb" \
     > "$TMP/cc.log" 2>&1; then
  pass "tangled sources compile warning-free (-Werror)"
else
  fail "tangled sources compile warning-free (-Werror)"
  head -20 "$TMP/cc.log" | sed 's/^/    /'
fi

# ---- leg 1: token identity ------------------------------------------------
#
# `cc -E -P` expands macros and drops comments and #line markers; ctokens.py
# then reduces what is left to one token per line, keeping string and
# character literals verbatim.  Formatting differences vanish; anything else
# survives.

toks() { # toks SOURCE OUT
  $CC_BIN -std=c99 -E -P "$1" 2>/dev/null | python3 "$HERE/ctokens.py" > "$2"
}

cmp_tokens() { # cmp_tokens LABEL HANDWRITTEN TANGLED
  toks "$2" "$TMP/tok.a" || { fail "$1"; return; }
  toks "$3" "$TMP/tok.b" || { fail "$1"; return; }
  if [ ! -s "$TMP/tok.a" ] || [ ! -s "$TMP/tok.b" ]; then
    fail "$1"
    echo "    one of the token streams is empty (preprocessing failed?)"
    return
  fi
  if diff -u "$TMP/tok.a" "$TMP/tok.b" > "$TMP/tok.diff"; then
    pass "$1 ($(wc -l < "$TMP/tok.a" | tr -d ' ') tokens)"
  else
    fail "$1"
    echo "    the tangled program has DRIFTED from the hand-written one:"
    head -20 "$TMP/tok.diff" | sed 's/^/    /'
  fi
}

cmp_tokens "token-identical: shavar.c + shavar.h" "$ROOT/c/shavar.c" "$HERE/shavar-cweb.c"
cmp_tokens "token-identical: main.c"              "$ROOT/c/main.c"   "$HERE/main.c"

# The drift detector is only worth anything if it detects drift.  Perturb one
# round constant in a copy of the tangled library and require a failure.
mkdir -p "$TMP/inject"
sed 's/0x428a2f98u/0x428a2f99u/' shavar-cweb.c > "$TMP/inject/shavar-cweb.c"
cp shavar.h "$TMP/inject/shavar.h"
$CC_BIN -std=c99 -E -P -I"$TMP/inject" "$TMP/inject/shavar-cweb.c" 2>/dev/null \
  | python3 "$HERE/ctokens.py" > "$TMP/inject/tok"
toks "$ROOT/c/shavar.c" "$TMP/tok.ref"
if diff -q "$TMP/tok.ref" "$TMP/inject/tok" >/dev/null 2>&1; then
  fail "the drift detector detects an injected drift"
else
  pass "the drift detector detects an injected drift"
fi

# ---- leg 2: observational identity ----------------------------------------

REF="$BUILD_DIR/c/shavar"
if [ ! -x "$REF" ]; then
  ( cd "$ROOT/c" && make shavar ) > "$TMP/refbuild.log" 2>&1
fi
NEW="$TMP/shavar-cweb"

if [ -x "$REF" ] && [ -x "$NEW" ]; then
  pass "both binaries built"

  # Deterministic corpus: every bit length 0..80, the padding boundaries, and
  # a pseudo-random tail.  Most of these are not byte-aligned, which is the
  # case no external oracle can witness and therefore the case most worth
  # comparing build against build.
  python3 - "$TMP/corpus.tsv" <<'PY'
import random, sys
out = open(sys.argv[1], "w")
rnd = random.Random(20260809)
lens = list(range(0, 81))
lens += list(range(440, 460)) + list(range(504, 522)) + list(range(952, 970))
lens += [rnd.randrange(0, 4096) for _ in range(80)]
for L in lens:
    nb = (L + 7) // 8
    b = bytearray(rnd.randrange(256) for _ in range(nb))
    if L % 8:                      # clear the unused low bits of the last byte
        b[-1] &= (0xFF << (8 - L % 8)) & 0xFF
    out.write("%s\t%d\n" % (b.hex() if nb else "-", L))
out.close()
PY
  n=0; bad=0
  while IFS=$(printf '\t') read -r hex bits; do
    n=$((n + 1))
    a=$("$REF" hash "$hex" "$bits" 2>&1); ra=$?
    b=$("$NEW" hash "$hex" "$bits" 2>&1); rb=$?
    if [ "$a" != "$b" ] || [ "$ra" != "$rb" ]; then
      bad=$((bad + 1))
      [ "$bad" -le 3 ] && printf '    hash %s %s: c=%s(%s) cweb=%s(%s)\n' \
          "$(printf '%.40s' "$hex")" "$bits" "$a" "$ra" "$b" "$rb"
    fi
  done < "$TMP/corpus.tsv"
  sub=$(awk -F'\t' '$2 % 8 != 0' "$TMP/corpus.tsv" | wc -l | tr -d ' ')
  if [ "$bad" = 0 ]; then
    pass "digests agree on $n messages ($sub sub-byte lengths)"
  else
    fail "digests agree on $n messages ($sub sub-byte lengths)"
    echo "    $bad disagreement(s)"
  fi

  # Reduced rounds, including both ends of the legal range and the values
  # where the feed-forward window reaches back into the seeds.
  bad=0; n=0
  for r in 0 1 2 3 4 5 16 32 63 64; do
    for m in "616263 24" "- 0" "b0 5" "ff 8" "0102030405060708090a0b0c0d0e0f10 128"; do
      # shellcheck disable=SC2086
      set -- $m
      n=$((n + 1))
      a=$("$REF" hash "$1" "$2" "$r" 2>&1); ra=$?
      b=$("$NEW" hash "$1" "$2" "$r" 2>&1); rb=$?
      [ "$a" = "$b" ] && [ "$ra" = "$rb" ] || { bad=$((bad + 1)); \
        printf '    rounds=%s hash %s %s: c=%s cweb=%s\n' "$r" "$1" "$2" "$a" "$b"; }
    done
  done
  if [ "$bad" = 0 ]; then pass "reduced-round digests agree ($n cases)"
  else fail "reduced-round digests agree ($n cases)"; fi

  # Full traces.  A digest comparison says the two agree on the answer; a
  # trace comparison says they agree on every intermediate word of every
  # round, which is a far stronger statement.
  bad=0; n=0
  for m in "616263 24 0" "- 0 0" "b0 5 0" "b0 5 0" "$(printf 'ab%.0s' $(seq 1 80)) 640 1"; do
    # shellcheck disable=SC2086
    set -- $m
    n=$((n + 1))
    "$REF" trace "$1" "$2" "$3" > "$TMP/tr.a" 2>&1; ra=$?
    "$NEW" trace "$1" "$2" "$3" > "$TMP/tr.b" 2>&1; rb=$?
    if ! diff -q "$TMP/tr.a" "$TMP/tr.b" >/dev/null || [ "$ra" != "$rb" ]; then
      bad=$((bad + 1))
      diff "$TMP/tr.a" "$TMP/tr.b" | head -5 | sed 's/^/    /'
    fi
  done
  # A trace is 344 lines for a full-round block; report the size so the
  # comparison cannot silently become a comparison of two empty files.
  lines=$(wc -l < "$TMP/tr.a" | tr -d ' ')
  if [ "$bad" = 0 ] && [ "$lines" -gt 300 ]; then
    pass "full per-round traces agree ($n blocks, $lines records each)"
  else
    fail "full per-round traces agree ($n blocks)"
  fi

  # Error paths: exit status, stdout and stderr must all match.  spec/CLI.md
  # requires stdout to be empty on every one of these.
  bad=0; n=0
  while IFS= read -r args; do
    [ -n "$args" ] || continue
    n=$((n + 1))
    # shellcheck disable=SC2086
    ao=$("$REF" $args 2>"$TMP/e.a"); ra=$?
    # shellcheck disable=SC2086
    bo=$("$NEW" $args 2>"$TMP/e.b"); rb=$?
    if [ "$ao" != "$bo" ] || [ "$ra" != "$rb" ] || ! diff -q "$TMP/e.a" "$TMP/e.b" >/dev/null; then
      bad=$((bad + 1))
      printf '    `%s`: c=(%s)%s cweb=(%s)%s\n' "$args" "$ra" "$ao" "$rb" "$bo"
    fi
    if [ -n "$ao" ] && [ "$ra" != 0 ]; then
      bad=$((bad + 1)); printf '    `%s` wrote to stdout on failure\n' "$args"
    fi
  done <<'EOF'
hash b4 5
hash b8 4
hash 616263 25
hash 616263 23
hash zz 8
hash 616 24
hash 616263 24 65
hash 616263 24 -1
hash 616263 24 x
hash 616263 abc
trace 616263 24 9
trace b4 5 0
selftest extra
bogus
EOF
  if [ "$bad" = 0 ]; then pass "error paths agree ($n cases, stdout empty)"
  else fail "error paths agree ($n cases, stdout empty)"; fi

  # The built-in self-test, which covers the million-character vector.
  if out=$("$NEW" selftest 2>&1) && printf '%s' "$out" | grep -Eq '^ok [0-9]+'; then
    pass "tangled binary passes its own selftest ($out)"
  else
    fail "tangled binary passes its own selftest"
    printf '%s\n' "$out" | head -5 | sed 's/^/    /'
  fi
else
  fail "both binaries built"
fi

# ---- leg 3: the repository's own test suite -------------------------------

hdr "the tangled binary under the repository test suite"

export SHAVAR_C_BIN="$NEW"
if [ -x "$NEW" ]; then
  if sh "$ROOT/tests/nist.sh" --impls c > "$TMP/nist.log" 2>&1; then
    pass "tests/nist.sh --impls c (NIST CAVP known-answer vectors)"
    grep -E '^ *(nist-|  c )' "$TMP/nist.log" | head -8 | sed 's/^/    /'
  else
    fail "tests/nist.sh --impls c (NIST CAVP known-answer vectors)"
    tail -30 "$TMP/nist.log" | sed 's/^/    /'
  fi

  if [ "$QUICK" = 1 ]; then
    skip "tests/run.sh fast (cross-implementation)" "--quick"
  elif sh "$ROOT/tests/run.sh" fast > "$TMP/suite.log" 2>&1; then
    pass "tests/run.sh fast (cross-implementation, with cweb as 'c')"
    grep -E '^  (impl|c) ' "$TMP/suite.log" | head -4 | sed 's/^/    /'
  else
    fail "tests/run.sh fast (cross-implementation, with cweb as 'c')"
    tail -40 "$TMP/suite.log" | sed 's/^/    /'
  fi
fi
unset SHAVAR_C_BIN

fi  # have_tangle

# ===========================================================================
if [ "$have_weave" = 1 ]; then
hdr "weave: is the document sound?"
# ===========================================================================

rm -f shavar-cweb.tex shavar-cweb.idx shavar-cweb.scn shavar-cweb.toc \
      shavar-cweb.lbl shavar-cweb.pdf

cweave shavar-cweb.w > "$TMP/cweave.log" 2>&1
web_ran_clean "cweave runs clean" "$?" "$TMP/cweave.log"

# cweave reports a section that is referenced but never defined, or defined
# and never used, as a warning rather than as a nonzero exit.  Those are the
# CWEB equivalents of an unresolved cross-reference and must fail the build.
if grep -qiE 'never defined|never used' "$TMP/cweave.log"; then
  fail "no dangling section names"
  grep -iE 'never defined|never used' "$TMP/cweave.log" | head -10 | sed 's/^/    /'
else
  pass "no dangling section names"
fi

# Two passes: the first writes the contents file and the chapter labels, the
# second reads them back.
pdftex -interaction=nonstopmode shavar-cweb.tex > "$TMP/tex1.log" 2>&1
pdftex -interaction=nonstopmode shavar-cweb.tex > "$TMP/tex2.log" 2>&1
if grep -qE '^! ' "$TMP/tex2.log"; then
  fail "TeX runs without an error"
  grep -A2 -E '^! ' "$TMP/tex2.log" | head -20 | sed 's/^/    /'
else
  pass "TeX runs without an error"
fi

if [ -f shavar-cweb.pdf ]; then
  pass "shavar-cweb.pdf produced ($(wc -c < shavar-cweb.pdf | tr -d ' ') bytes)"
else
  fail "shavar-cweb.pdf produced"
fi

# Project convention: no generic main.pdf; the document is named after what it
# is.  ctangle's default output would have been shavar-cweb.c, so the .w file
# is named for the document and the library file follows from it.
if [ -f shavar-cweb.pdf ] && [ ! -f main.pdf ]; then
  pass "pdf named non-generically"
else
  fail "pdf named non-generically"
fi

if [ -f shavar-cweb.pdf ] && command -v pdftotext >/dev/null; then
  pdftotext -q shavar-cweb.pdf "$TMP/pdf.txt" 2>/dev/null

  # An unresolved \secref renders as "??", exactly as an unresolved \ref does
  # in LaTeX, and TeX exits successfully either way.  This is the check that
  # stops a quietly broken document from shipping.
  if grep -q '??' "$TMP/pdf.txt"; then
    fail "no unresolved references ('??') in the rendered text"
    grep -n '??' "$TMP/pdf.txt" | head -5 | sed 's/^/    /'
  else
    pass "no unresolved references ('??') in the rendered text"
  fi

  # ...and the positive half: the references must actually be there.  A
  # document with no \secref at all would trivially pass the check above.
  nref=$(grep -oE '§[0-9]+' "$TMP/pdf.txt" | wc -l | tr -d ' ')
  if [ "$nref" -ge 15 ]; then
    pass "chapter cross-references resolved ($nref of them)"
  else
    fail "chapter cross-references resolved (found only $nref)"
  fi

  # "Section Page" is the header cwebmac puts on the table of contents; it is
  # written on the last pass and is the usual casualty of a one-pass build.
  for want in "Introduction" "The two-dimensional form" "The compression function" \
              "Padding" "Index" "Section Page"; do
    if grep -qi "$want" "$TMP/pdf.txt"; then
      pass "rendered: $want"
    else
      fail "rendered: $want"
    fi
  done

  # cweave generates the index and the list of section names from the code, so
  # they cannot rot; but they can be empty if something went wrong upstream.
  if [ -s shavar-cweb.idx ] && [ -s shavar-cweb.scn ]; then
    pass "index and section list generated ($(wc -l < shavar-cweb.idx | tr -d ' ') index entries)"
  else
    fail "index and section list generated"
  fi
  # The identifier index and the list of section names are two separate
  # generated pages.  pdftotext drops the underscore out of the typewriter
  # font, hence the wildcard.
  if grep -qE 'shavar.compress *:' "$TMP/pdf.txt"; then
    pass "identifier index reached the page"
  else
    fail "identifier index reached the page"
  fi
  if grep -qE 'Cited in section' "$TMP/pdf.txt"; then
    pass "list of section names reached the page"
  else
    fail "list of section names reached the page"
  fi
else
  skip "rendered-text checks" "no pdftotext"
fi

# Internal hyperlinks: cwebmac emits a GoTo annotation for every section
# cross-reference when running under pdftex, and \secref adds one per chapter
# reference.  A document with none means the links silently degraded to plain
# text -- the document would still look right on paper and be much less useful
# on screen.  pdftex packs the annotation dictionaries into compressed object
# streams, so they have to be inflated before they can be counted.
if [ -f shavar-cweb.pdf ]; then
  nlink=$(python3 - shavar-cweb.pdf <<'PY'
import re, sys, zlib
data = open(sys.argv[1], "rb").read()
n = data.count(b"/GoTo")
for m in re.finditer(rb"stream\r?\n", data):
    start = m.end()
    end = data.find(b"endstream", start)
    try:
        n += zlib.decompress(data[start:end]).count(b"/GoTo")
    except Exception:
        pass
print(n)
PY
)
  if [ "${nlink:-0}" -ge 50 ]; then
    pass "internal hyperlinks present ($nlink GoTo destinations)"
  else
    fail "internal hyperlinks present (found ${nlink:-0} GoTo destinations)"
  fi
fi

fi  # have_weave

# ===========================================================================
echo
if [ "$fails" -eq 0 ]; then
  echo "cweb tests passed"
  exit 0
fi
echo "$fails cweb test(s) FAILED"
exit 1
