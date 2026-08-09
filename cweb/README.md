# cweb — the C implementation as a literate program

This directory holds `shavar-cweb.w`, a [CWEB](https://www-cs-faculty.stanford.edu/~knuth/cweb.html)
literate program: **one file that is both the documentation and the source** of
the C implementation. Two programs read it.

| Tool | Reads | Writes | Purpose |
| --- | --- | --- | --- |
| `ctangle` | `shavar-cweb.w` | `shavar-cweb.c`, `shavar.h`, `main.c` | the C the compiler needs, in the order it needs it |
| `cweave` | `shavar-cweb.w` | `shavar-cweb.tex` → `shavar-cweb.pdf` | the same material typeset in the order a reader needs, with cross-references and an index |

The two orders are different, and separating them is the point. The document
presents the algorithm as a human should learn it — the two-dimensional
recurrence, the message schedule, padding for arbitrary bit lengths, then the
compression function and the plumbing — while the tangled output is in
declaration order.

## This is a parallel presentation, not a replacement

`c/shavar.c`, `c/shavar.h` and `c/main.c` are still the sources the rest of the
project builds against. Nothing was deleted or moved. What this directory adds
is a second presentation of the same program, and with it an obligation: the
tangled output must **be** that program, not merely resemble it.

`test_cweb.sh` discharges that obligation three ways, and none of the three
subsumes the others:

1. **Token identity.** Both sides are run through the C preprocessor (`cc -E -P`,
   which expands macros and removes comments and `#line` markers) and then
   through `ctokens.py`, which reduces what is left to one token per line with
   string and character literals preserved verbatim. The two streams must be
   *identical* — currently 3821 tokens for the library and 11778 for the driver.
   This catches drift in code that no test happens to execute. It would pass if
   both programs were identically wrong.
2. **Observational identity.** The tangled binary and `c/shavar` must agree on
   digests over 217 messages (189 of them not byte-aligned), on **full
   per-round traces** record for record, on reduced-round output at ten round
   counts including 0 and 64, and on the exit status, stdout and stderr of
   fourteen error paths. This catches anything the corpus reaches.
3. **The repository's own suite.** `SHAVAR_C_BIN` points `tests/` at the
   tangled binary, which is then run against the 1154 NIST CAVP known-answer
   vectors and against the other six implementations on digests and traces.

The drift detector is itself tested: the script injects a one-digit change into
a round constant and requires the comparison to fail.

## Building

```sh
make -C cweb            # tangle, compile, weave, typeset
make -C cweb check      # everything above plus the full test suite
open cweb/shavar-cweb.pdf
```

Requirements: a C compiler, `python3`, and a TeX distribution. `ctangle`,
`cweave` and `cwebmac.tex` ship with **TeX Live and MacTeX**, so on a machine
that can already build `doc/shavar.pdf` there is nothing extra to install. On
Debian and Ubuntu the binaries are in the `cweb` package and the macros in
`texlive-plain-generic`; the diagrams additionally need `texlive-pictures` for
PGF/TikZ.

`test_cweb.sh --quick` skips the cross-implementation leg, which is the slow one.

## What is source and what is not

Committed as source: `shavar-cweb.w`, `ctokens.py`, `Makefile`, `test_cweb.sh`.

Committed as a tested build output: `shavar-cweb.pdf`, so the document can be
read without a TeX installation — the same convention `doc/shavar.pdf` follows.

Gitignored: everything else here. In particular **do not edit the tangled
`shavar-cweb.c`, `shavar.h` or `main.c` in this directory** — they are
regenerated on every build and any edit is lost. Edit `shavar-cweb.w`.

## Notes on the CWEB source

A few things are worth knowing before editing `shavar-cweb.w`.

* **A bare `|` in a TeX (prose) part starts inline-code mode.** The C bitwise-or
  operator therefore cannot appear literally in prose, and TikZ's `|<->|` arrow
  syntax cannot be used either. Both mistakes produce a confusing cascade of
  errors far from the actual line, so they are worth recognising.
* **A section name split across a line break** inside prose confuses `cweave`
  and is reported as `Never defined`. Keep `|@<Name of section@>|` on one line.
* **CWEB has no way to refer to a starred (chapter) section.** It hyperlinks
  references to *named code* sections automatically, but chapters have only a
  number that `cweave` assigns. The limbo section of `shavar-cweb.w` therefore
  defines a small `\slabel` / `\secref` pair — the plain-TeX equivalent of
  LaTeX's `\label` and `\ref`, writing a `.lbl` file on the first pass and
  reading it back on the second. An unresolved key deliberately renders as
  `??`, which is what `test_cweb.sh` looks for in the finished PDF.
* **Two TeX passes are required**, one to write the table of contents and the
  label file and one to read them back. The `Makefile` does both.
* Diagrams use PGF/TikZ through its plain-TeX interface: `\input tikz.tex`, and
  `\tikzpicture … \endtikzpicture` rather than `\begin{tikzpicture}`.
