# shavar — CWEB literate build.
#
# One source file, shavar-cweb.w, and two programs that read it:
#
#   ctangle  extracts the C and writes it in the order a compiler needs
#   cweave   extracts the same material and typesets it in the order a reader
#            needs, with cross-references and an index
#
# Both ship with TeX Live and MacTeX, so there is nothing extra to install
# beyond a TeX distribution.
#
# The tangled sources are build outputs, not source: they are gitignored, and
# `make check` proves they are token-for-token the same program as the
# hand-written files in ../c.  Edit shavar-cweb.w, never the tangled files.
#
# See `make help`.

CC       ?= cc
STD      ?= c99
OPT      ?= -O2
WARN      = -Wall -Wextra -pedantic-errors -Wshadow -Wconversion -Wsign-conversion \
            -Wcast-qual -Wstrict-prototypes -Wmissing-prototypes -Wpointer-arith \
            -Wwrite-strings -Wredundant-decls -Wundef
CFLAGS   ?= -std=$(STD) $(OPT) $(WARN)

CTANGLE  ?= ctangle
CWEAVE   ?= cweave
TEX      ?= pdftex

WEB       = shavar-cweb.w
TANGLED   = shavar-cweb.c shavar.h main.c
PDF       = shavar-cweb.pdf

.PHONY: all tangle weave pdf check clean help

all: shavar $(PDF)

# ---- tangle ----------------------------------------------------------

# ctangle writes all three files in one pass; shavar-cweb.c is the unnamed
# section and the other two are @(...@> output-file sections.
$(TANGLED): $(WEB)
	$(CTANGLE) $(WEB)

tangle: $(TANGLED)

# The same strict warning set the hand-written build uses. If ctangle output
# provoked a warning that the original did not, that would itself be drift.
shavar: $(TANGLED)
	$(CC) $(CFLAGS) shavar-cweb.c main.c -o $@

# ---- weave -----------------------------------------------------------

shavar-cweb.tex: $(WEB)
	$(CWEAVE) $(WEB)

weave: shavar-cweb.tex

# Two TeX passes. The first writes the table of contents and the chapter
# label file; the second reads them back. A single pass leaves the contents
# page and every \secref unresolved, which is precisely the silent breakage
# test_cweb.sh exists to reject.
$(PDF): shavar-cweb.tex
	$(TEX) -interaction=nonstopmode shavar-cweb.tex >/dev/null
	$(TEX) -interaction=nonstopmode shavar-cweb.tex >/dev/null
	@echo "  woven document:  $(PDF)"

pdf: $(PDF)

# ---- checks ----------------------------------------------------------

check:
	sh ./test_cweb.sh

clean:
	rm -f $(TANGLED) shavar-cweb.tex shavar-cweb.idx shavar-cweb.scn \
	      shavar-cweb.toc shavar-cweb.log shavar-cweb.lbl shavar-cweb.pgf \
	      $(PDF) shavar

help:
	@echo "targets: all tangle weave pdf check clean"
	@echo "  make check   tangle, build, prove equivalence with ../c, weave, test the PDF"
