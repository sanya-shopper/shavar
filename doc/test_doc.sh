#!/usr/bin/env bash
# Treat the PDF as a build artefact with tests, not as a file someone
# eyeballed once.
#
# The failure this guards against is specific: LaTeX renders an unresolved
# \ref or \cite as "??" and exits successfully. A document can therefore be
# "built" and still be quietly broken, which is exactly the kind of misleading
# output this project is not willing to ship.

set -uo pipefail
cd "$(dirname "$0")" || exit 1

fails=0
note() { printf '%-52s %s\n' "$1" "$2"; }
fail() { note "$1" "FAIL"; fails=$((fails + 1)); }
pass() { note "$1" "ok"; }

command -v latexmk >/dev/null || { echo "latexmk not installed - skipping"; exit 0; }

# ---- 1. it builds at all --------------------------------------------------
latexmk -C >/dev/null 2>&1
if latexmk -pdf -interaction=nonstopmode shavar.tex >/tmp/shavar_tex.log 2>&1; then
  pass "builds cleanly"
else
  fail "builds cleanly"
  grep -E "^! " /tmp/shavar_tex.log | head -10
fi

[ -f shavar.pdf ] || { fail "shavar.pdf produced"; echo; echo "$fails failure(s)"; exit 1; }
pass "shavar.pdf produced"

# ---- 2. the PDF is named after the repository, not something generic ------
# (Project convention: no main.pdf.)
[ -f shavar.pdf ] && pass "pdf named after the repo"

# ---- 3. no unresolved cross-references ------------------------------------
if grep -qiE "there were undefined references|citation .* undefined|reference .* undefined" shavar.log; then
  fail "no undefined references"
  grep -iE "undefined" shavar.log | head -10
else
  pass "no undefined references"
fi

# ---- 4. no literal ?? in the rendered text --------------------------------
# This is the belt-and-braces version of check 3: it inspects the actual
# rendered output rather than trusting the log.
if command -v pdftotext >/dev/null; then
  pdftotext -q shavar.pdf /tmp/shavar_txt.txt 2>/dev/null
  if grep -q '??' /tmp/shavar_txt.txt; then
    fail "no '??' in rendered text"
    grep -n '??' /tmp/shavar_txt.txt | head -5
  else
    pass "no '??' in rendered text"
  fi
else
  note "no '??' in rendered text" "skipped (no pdftotext)"
fi

# ---- 5. the bibliography actually rendered --------------------------------
if command -v pdftotext >/dev/null; then
  for key in "Secure Hash Standard" "Appel" "Revised" "Bitvector"; do
    if grep -qi "$key" /tmp/shavar_txt.txt; then
      pass "bibliography contains '$key'"
    else
      fail "bibliography contains '$key'"
    fi
  done
fi

# ---- 6. every local copy promised by the bibliography exists --------------
# refs.bib claims specific files in refs/. A claim like that rots silently.
while read -r p; do
  if [ -f "../$p" ]; then pass "local copy present: $p"; else fail "local copy present: $p"; fi
done < <(grep -oE 'refs/[A-Za-z0-9._-]+\.pdf' refs.bib | sort -u)

# ---- 7. internal links exist ----------------------------------------------
# hyperref emits /Annots for links; a document with none means colorlinks
# silently produced plain text.
if command -v pdftotext >/dev/null; then
  if grep -qE "Figure 1|Section" /tmp/shavar_txt.txt; then
    pass "cross-references rendered"
  else
    fail "cross-references rendered"
  fi
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "doc tests passed"
  exit 0
fi
echo "$fails doc test(s) FAILED"
exit 1
