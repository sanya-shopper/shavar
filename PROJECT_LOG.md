# shavar — Project Log

A running record of the project's context, decisions, and evolution. Newest
entries at the top. Each entry is committed so the history of thinking is
preserved alongside the history of code.

---

## 2026-08-09 — The C implementation as a CWEB literate program

`cweb/shavar-cweb.w` is a single Knuth/Levy CWEB file that `ctangle` turns into
the whole C program — `shavar-cweb.c`, `shavar.h` and `main.c`, via `@(file@>`
output sections — and that `cweave` turns into a 33-page typeset document,
`cweb/shavar-cweb.pdf`. It covers the library *and* the driver, and it explains
them in the order a reader should meet them: the 2D recurrence, the message
schedule, padding and the arbitrary-bit-length rule, then the compression
function and the plumbing. The prose absorbs the long comments that were in
`c/shavar.c` and adds three TikZ figures — the width-4 window over the two
tracks, the data dependence of one round, and the padded-message layout.

`c/` is untouched. This is a second presentation, not a replacement, and the
interesting question is therefore whether the tangled output is *the same
program*. `cweb/test_cweb.sh` answers it three ways:

- **Token identity.** Both sides through `cc -E -P` and then `cweb/ctokens.py`,
  which reduces the result to one token per line with string and character
  literals kept verbatim. The streams are identical — 3821 tokens for the
  library, 11778 for the driver. This is the leg that catches drift in code no
  test executes.
- **Observational identity.** Digests over 217 messages (189 not byte-aligned),
  full per-round traces record for record (344 records a block), reduced-round
  output at ten round counts including 0 and 64, and fourteen error paths
  compared on exit status, stdout *and* stderr.
- **The repository's own suite.** A four-line change to `tests/lib/common.sh`
  adds `SHAVAR_C_BIN`, which points the harness at a different build of the C
  implementation. With it set, `tests/nist.sh` runs the tangled binary against
  all 1154 NIST CAVP vectors and `tests/run.sh fast` runs it against the other
  six implementations, on digests and traces. Both pass.

The drift detector is itself tested: the script injects a one-digit change into
`K[0]` and requires the comparison to fail.

**Non-obvious things learned.**

- **CWEB was already installed.** `ctangle` and `cweave` ship with MacTeX and
  TeX Live (4.12.2 here), as does `cwebmac.tex`. Nothing needed installing on a
  machine that could already build `doc/shavar.pdf`.
- **A bare `|` in the TeX part of a section starts inline-code mode.** So the C
  bitwise-or operator cannot be written in prose — `|(x >> n) | (x << (32-n))|`
  silently becomes *code, prose, code* and swallows everything up to the next
  bar, which surfaced as `! Never defined: <Rotate right>` sixty lines away.
  TikZ's `|<->|` arrow syntax breaks the same way. Both diagnostics point
  nowhere near the cause.
- **A section name broken across a line** inside prose also yields a spurious
  `Never defined`.
- **CWEB has no way to cross-reference a starred (chapter) section.** It
  hyperlinks references to named *code* sections automatically, and that covers
  most of what one wants, but chapters have only the number `cweave` assigns.
  The limbo section now defines a `\slabel`/`\secref` pair — a 12-line plain-TeX
  reimplementation of LaTeX's `\label`/`\ref`, writing a `.lbl` file on pass one
  and reading it on pass two. An unresolved key renders as `??` deliberately,
  which is what makes the PDF test's `??` check mean anything: without a
  reference mechanism that check is vacuous. 49 chapter references resolve.
- **The `??` check found the document referring to itself.** The Testing chapter
  originally said the PDF "must contain no literal `??`" — and thereby contained
  one, and failed its own test. Rewritten to describe the pair without printing
  it.
- **The first draft of the round-dependence figure was wrong**, and only looking
  at the rendered page caught it: the heavy arrow for `A[t-4] → E[t]`, the one
  edge the figure exists to highlight, was drawn from `A[t-4]` to `E[t-4]`. A
  diagram is an assertion and can be false in exactly the way a sentence can.
- **pdfTeX packs link annotations into compressed object streams**, so
  `grep /GoTo` on the PDF finds nothing even when the links are there. The test
  inflates the streams before counting; there are 668.

## 2026-08-09 — Project defined: SHA-256 in seven languages, as a 2D recurrence

**What this is.** One algorithm — SHA-256 — implemented seven times, in C99,
Lean 4, Python 3, Perl 5, R7RS Scheme, JavaScript, and shell, so the
*implementations* can be compared for brevity, understandability, and research
readiness. Every implementation is core language only: no libraries, no
modules, no imports beyond what is needed to read `argv`. The one exception is
Lean, where verification tooling is in scope for the *proofs* but not for the
implementation.

**The framing that makes it worth doing.** The standard presentation of
SHA-256 keeps eight working registers `a…h` and shuffles them every round.
Six of those eight assignments are pure copies. Drop them and what is left is
two coupled recurrences with a lookback of four:

```
T1[t] = E[t-4] ⊞ Σ1(E[t-1]) ⊞ Ch(E[t-1],E[t-2],E[t-3]) ⊞ K[t] ⊞ W[t]
T2[t] = Σ0(A[t-1]) ⊞ Maj(A[t-1],A[t-2],A[t-3])
E[t]  = A[t-4] ⊞ T1[t]
A[t]  = T1[t] ⊞ T2[t]
```

The eight registers were never eight things; they are two sliding windows of
width four over the histories of `A` and `E`. The whole algorithm is then one
sentence: an order-16 recurrence (the message schedule) driving a nonlinear
order-4 recurrence in two tracks. `spec/SPEC.md` is the normative writeup and
`spec/CLI.md` fixes a uniform command-line contract so any implementation can
be diffed against any other.

**Why the 2D form, beyond elegance.** In this form the state *is* the history,
so retaining the full trajectory costs nothing — 136 words per block. That
makes every intermediate value addressable after the fact, which is what the
project actually needs, because the target audience is someone studying
differential or algebraic structure rather than someone hashing a file.

**Requirements accumulated during the session,** in the order they arrived:
arbitrary bit-length inputs (not just whole bytes); consider formal
verification; document for a reader who does not speak all seven languages;
add Python; no modules anywhere; add JavaScript running in local Safari; add
bash/zsh; implementations built in parallel; C packaged as both `.a` and
shared library with as much memory-cleanliness testing as the machine allows
and every locally available compiler; a harness testing random inputs at
random bit lengths, cross-checking implementations against each other and
against the preinstalled OpenSSL; and a brief PDF on where each language makes
this natural or hard.

**The Safari page is scoped as an interactive explorer**, not a demo: it does
round-by-round stepping forwards and backwards, draws the two tracks with the
order-4 window highlighted, renders words as individual bits, and has a diff
mode showing a one-bit input difference avalanching across 64 rounds. The
justification is the same one that motivates keeping the whole trace at all
(above) — the intended reader is studying the function, and the interior is
the thing worth seeing.

### Decisions taken

- **Uniform CLI across all seven** (`hash` / `trace` / `selftest`, tab-separated
  hex). Rigid to the byte, so cross-checking is `diff` rather than seven
  bespoke parsers — a parser per language would be seven more places for a bug
  to masquerade as a disagreement, or a disagreement as a formatting artefact.
- **Cross-check on traces, not just digests.** A digest mismatch says
  "something is wrong"; a trace mismatch says "`A[17]` is where it went
  wrong". That difference is most of the debugging value.
- **Reject, never mask, nonzero trailing bits** in a sub-byte final byte.
  Masking would map two distinct inputs to one digest and hide caller bugs.
  This also turns out to be the precondition that makes padding injectivity
  true at all.
- **Free-start (chosen IV) and reduced rounds are exposed everywhere.** Neither
  is reachable through a normal hashing API and both are prerequisites for the
  cryptanalytic work the repo is meant to support.
- **Lean uses `BitVec 32`, not `UInt32`**, because `bv_decide` reasons about
  `BitVec`. Confirmed working locally at Lean 4.32.2 — it discharged
  `Ch(x,y,z) = z ⊕ (x ∧ (y ⊕ z))` automatically on the first try.

### Findings so far

- **A bad test case of my own**, caught by the C self-test failing: I had told
  all six implementation agents that `hash b8 5` must be rejected. It must not.
  `0xb8` is `1011 1000`; for a 5-bit message the low three bits are already
  zero, so it is valid. The genuine rejection case is `0xb4` (`1011 0100`).
  All agents were corrected mid-flight. Worth recording because the failure
  mode is instructive: a one-sided test ("does it reject?") would have been
  passed by an implementation that rejects everything, so the suite now checks
  both directions.
- **The C code has no undefined behaviour.** `-fsanitize=undefined` is clean.
  The only sanitizer finding was `unsigned-shift-base` on the rotation, which
  is *not* UB — C99 6.5.7p4 defines unsigned left shift as reduction mod 2³²,
  and discarding bits is what a rotation is for. Rather than suppress the
  check, `rotr` now masks the low bits before shifting them up, which passes
  the strictest setting and — verified in the disassembly — still compiles to
  a single `ror` instruction. No suppressions anywhere in the matrix.
- **valgrind does not exist on arm64 macOS**, and MemorySanitizer is
  unsupported on this target. Recorded so the omission reads as a platform
  fact rather than an oversight. ASan, UBSan, Apple's `leaks`, and the clang
  static analyzer cover what they can.
- **Only one C compiler is installed.** `gcc` and `cc` are both symlinks to
  Apple clang 17; there is no Homebrew GCC. Compiler diversity therefore comes
  from clang's own axes — four language standards, six optimisation levels,
  and an x86_64 cross-build for a second code generator.
- **Three implementations already agree byte-for-byte on the full 344-line
  trace** for `"abc"`, and on digests across sub-byte lengths 0, 5, 8, 9, 13,
  24. C, Python, and Perl were written independently against the spec, so this
  is real evidence rather than a shared-code tautology.
- **AddressSanitizer does not work on this machine at all**, and the way that
  was established is worth recording. It first looked like a performance
  problem in my own code: the million-'a' vector ran for five minutes under
  ASan, and the obvious suspect was `shavar_compress` building a 1.1 KB trace
  on the stack for each of 15 625 blocks. That theory was wrong. Bisecting the
  input showed the short vectors hung too; then the *usage message* hung, with
  no hashing at all; then a do-nothing `int main(void){return 0;}` hung as
  well, inside and outside the shell sandbox. `ASAN_OPTIONS=verbosity=1` stops
  after "libc interceptors initialized", so it stalls in runtime init before
  reaching `main`. It is an incompatibility between the shipped ASan runtime
  and this OS build. The lesson is the ordinary one: the first plausible
  explanation was about my code, and it survived exactly until it was tested.
- **Everything else in the C matrix is clean.** UBSan with
  `-fno-sanitize-recover=all` passes; the clang static analyzer reports
  nothing; Apple's `leaks` reports "0 leaks for 0 total leaked bytes", which
  is expected given the library never calls an allocator; four language
  standards and six optimisation levels all agree; the x86_64 cross-build
  compiles, though Rosetta 2 is not installed so it cannot be executed here.

### CI closed every gap the laptop could not reach

Pushed to `github.com/sanya-shopper/shavar` and wired up GitHub Actions. The
point was never redundancy with local testing; it was to reach what a
macOS/arm64 machine physically cannot. **44 jobs, all green**, and three
results are worth recording specifically:

- **valgrind: 0 errors from 0 contexts**, on the hashing, tracing and
  rejection paths, with "All heap blocks were freed — no leaks are possible".
  This tool does not exist on Apple Silicon, so it had never run before.
- **Big-endian is now verified rather than asserted.** `shavar.c` claims
  endian independence because it never casts a byte pointer to `uint32_t` and
  does every conversion with explicit shifts. CI cross-compiles to s390x and
  runs it under QEMU: `ELF 64-bit MSB executable, IBM S/390` → `ok 5`, and the
  `"abc"` digest matches the little-endian one exactly. A claim like that is
  worth little until something big-endian has actually executed it.
- **AddressSanitizer and MemorySanitizer both run clean on Linux**, including
  `detect_leaks` and `detect_stack_use_after_return` — the checks that are
  unavailable or broken locally. So the local ASan hang really was a host
  defect and not a latent bug in the code.

Also covered: 36 compiler configurations (gcc-13, gcc-14, clang-18 × c99/c11/c17
× four optimisation levels), static and shared library packaging with a runtime
link check, the Lean build with a hard failure on any `sorry`, all seven
implementations' self-tests, an eight-way cross-check, and the PDF build with
an unresolved-reference gate.

### The comparative PDF

`doc/shavar.tex` → `doc/shavar.pdf`, seven pages, built by `latexmk` with
`biber`. `doc/test_doc.sh` treats it as a tested artefact: it fails if the
build breaks, if any reference resolves to `??` (LaTeX renders those and exits
*successfully*, which is exactly the silent-breakage mode this project refuses
to ship), if a bibliography entry fails to render, or if a local reference copy
promised by `refs.bib` is missing from `refs/`.

Three references are mirrored in `refs/` with provenance and retrieval dates.
One near-miss worth recording: I downloaded what I believed was the
`bv_decide` paper from a guessed arXiv ID and checked it before citing — it
turned out to be an unrelated paper on multimodal LLM benchmarks. Deleted, and
the correct reference (Böving et al., OOPSLA 2025) is cited with its DOI and
an explicit "no local copy" note. A guessed citation that happens to resolve
to *something* is worse than no citation, because it looks checked.

### The harness found what agreement alone could not

The cross-testing harness landed with the NIST CAVP vectors: **1154 known
answers, 896 of them not byte-aligned**, checksummed and committed so the
suite runs offline. That materially improves an earlier, gloomier assessment
recorded above. It is true that no *live* oracle on this machine can hash a
partial byte -- openssl, LibreSSL, `shasum` and `sha256sum` are all
byte-only -- but the NIST bit-oriented files are an external authority, and
they downloaded. Sub-byte hashing is therefore externally validated after all,
for 896 lengths. Only sub-byte lengths *outside* that set rest on
cross-implementation agreement alone.

The harness keeps that distinction in its output rather than in a footnote:
`verified` (matched NIST or an oracle), `agreed` (only other implementations
answered), and `lone` (nothing to compare against) are three separate columns
and are never summed. Disputes with no authority present do not pick a winner
by majority; every participant is marked disputed and the groups printed.

**A real divergence, found by testing a feature nothing had tested.** The
harness noted that reduced-round mode was exposed but unexercised. Testing it
turned up two disagreements at the boundaries, both traceable to `spec/CLI.md`
never stating the valid range of `rounds`:

- `rounds = 0` was accepted by six implementations and rejected by JavaScript.
- `rounds > 64` was rejected by six -- and **silently clamped to 64 by C**, so
  `hash <msg> <n> 100` printed a correct-looking SHA-256 digest in answer to a
  request that means nothing.

The C behaviour was mine, and it is the worse of the two: a confidently wrong
answer beats an error message only in the sense that it is harder to notice.
Fixed by specifying the range (0..64, with 0 the legal feed-forward-only
case), rejecting anything above it, and correcting both implementations. All
seven now agree on every round count from 0 to 64 and all reject 65 and 100
with exit 2.

The general lesson is worth keeping: every place these seven independent
implementations diverged turned out to be a place the specification was silent,
not a place someone made a mistake. Unstated boundaries are where independent
readings separate.

### Notes on method

Six implementations were written concurrently by separate agents, each owning
one directory, against a spec frozen before any of them started. That is the
right shape for this particular job: the value of the comparison depends on
the implementations being genuinely independent, and a spec written first is
what makes seven-way agreement evidence of correctness rather than evidence of
copy-paste.

---

## 2026-08-09 — Repository created

Empty repository initialized on `main`, with this log and a `.gitignore` for
macOS and editor cruft. Nothing else exists yet.

**Open: what the project is.** The name `shavar` is all that has been recorded
so far. The next entry should be a "Project defined" one, stating the goal, the
constraints, and what a finished version looks like — written before code, so
that later entries can be read against the original intent rather than against
a reconstruction of it.
