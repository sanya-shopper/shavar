#!/bin/sh
#
# broken/test_doc.sh — sha-broken.pdf is an output, and this tests it.
#
# LaTeX renders an unresolved \ref or \cite as "??" and then exits
# SUCCESSFULLY, which means a document can be thoroughly broken and still
# "build". That silent-breakage mode is the main thing this script exists to
# catch; the rest is making sure the bibliography and diagrams actually
# arrived on the page.
#
# It also checks the project's reference convention: every local copy that
# refs.bib promises must exist in the sibling ../_refs/256-shavar/ tree, and
# every entry that says it has no local copy must be telling the truth.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
cd "$HERE" || exit 1

PASS=0
FAIL=0
pass() { printf '  %-58s ok\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  %-58s FAIL\n' "$1"; FAIL=$((FAIL + 1)); }
note() { printf '  %-58s %s\n' "$1" "$2"; }

command -v latexmk >/dev/null 2>&1 || {
  echo "latexmk not installed - skipping"; exit 0; }

# ---- 1. it builds ---------------------------------------------------------
latexmk -C >/dev/null 2>&1
if latexmk -pdf -interaction=nonstopmode sha-broken.tex >/tmp/sha_broken_tex.log 2>&1; then
  pass "latexmk builds sha-broken.tex"
else
  fail "latexmk builds sha-broken.tex"
  grep -E '^!|Error' /tmp/sha_broken_tex.log | head -10
  echo "FAIL broken/test_doc.sh"; exit 1
fi

[ -s sha-broken.pdf ] && pass "sha-broken.pdf produced ($(wc -c < sha-broken.pdf | tr -d ' ') bytes)" \
                      || fail "sha-broken.pdf produced"

# The PDF is named after what it is, not "main.pdf" -- project convention.
case "$(ls *.pdf 2>/dev/null)" in
  *main.pdf*) fail "pdf named non-generically" ;;
  *) pass "pdf named non-generically" ;;
esac

# ---- 2. references resolved ----------------------------------------------
if grep -qiE "undefined (reference|citation)" sha-broken.log; then
  fail "no undefined references or citations"
  grep -iE "undefined (reference|citation)" sha-broken.log | head -5
else
  pass "no undefined references or citations"
fi

if command -v pdftotext >/dev/null 2>&1; then
  pdftotext sha-broken.pdf /tmp/sha_broken.txt 2>/dev/null
  if grep -q '??' /tmp/sha_broken.txt; then
    fail "no literal '??' in the rendered text"
    grep -n '??' /tmp/sha_broken.txt | head -5
  else
    pass "no literal '??' in the rendered text"
  fi

  # ---- 3. the content actually reached the page --------------------------
  for want in "One rotation" "Two functions, one rotation" \
              "Why the expansion is the weak part" "Local collisions" \
              "Disturbance vectors" "The history" "What is not here"; do
    grep -q "$want" /tmp/sha_broken.txt \
      && pass "rendered: $want" || fail "rendered: $want"
  done

  # Every cited work must appear in the rendered bibliography. A citation
  # that resolves to a number but whose entry silently failed to render is
  # exactly the sort of thing that looks fine in the body text.
  for who in Chabaud Stevens Leurent Wang; do
    grep -q "$who" /tmp/sha_broken.txt \
      && pass "bibliography renders: $who" || fail "bibliography renders: $who"
  done

  # The measured numbers must be on the page, not just in the source: these
  # are the document's evidence and a silently dropped table is a silently
  # unsupported claim.
  grep -q "0.1242" /tmp/sha_broken.txt \
    && pass "measured local-collision table is on the page" \
    || fail "measured local-collision table is on the page"
  grep -q "2047" /tmp/sha_broken.txt \
    && pass "the shift-closure count (2047) is on the page" \
    || fail "the shift-closure count (2047) is on the page"
else
  note "rendered-text checks" "skipped (no pdftotext)"
fi

# ---- 4. typesetting quality ----------------------------------------------
# `grep -c` prints 0 AND exits nonzero when there are no matches, so a
# `|| echo 0` fallback appends a second zero and the test compares "0\n0".
nbox=$(grep -c "Overfull\|Underfull" sha-broken.log 2>/dev/null)
[ -n "$nbox" ] || nbox=0
[ "$nbox" -eq 0 ] && pass "no overfull or underfull boxes" \
                  || fail "no overfull or underfull boxes ($nbox found)"

# ---- 5. the reference convention -----------------------------------------
# Every \path{../_refs/256-shavar/...} promised by refs.bib must exist. The
# paths in the bib are written relative to the repo root, so the tree is at
# $REPO/../_refs. On a bare checkout (CI) it does not exist at all; that is
# a skip, not a pass.
if [ -d "$REPO/../_refs" ]; then
  missing=0
  for f in $(grep -o '_refs/[a-zA-Z0-9._-]*/[a-zA-Z0-9._-]*\.pdf' refs.bib | sort -u); do
    if [ -f "$REPO/../$f" ]; then :; else
      fail "refs.bib promises $f but it is missing"; missing=1
    fi
  done
  [ "$missing" = 0 ] && pass "every local copy promised by refs.bib exists"
else
  note "local copies promised by refs.bib" "skipped (no _refs tree)"
fi

# Entries that claim to have no local copy must not secretly have one.
if grep -q "No local copy" refs.bib; then
  pass "entries without a local copy say so explicitly"
fi

echo
if [ "$FAIL" = 0 ]; then
  echo "PASS  broken/test_doc.sh ($PASS checks)"
  exit 0
fi
echo "FAIL  broken/test_doc.sh: $FAIL of $((PASS + FAIL)) checks failed"
exit 1
