# shavar — Project Log

A running record of the project's context, decisions, and evolution. Newest
entries at the top. Each entry is committed so the history of thinking is
preserved alongside the history of code.

---

## 2026-08-10 — broken/: SHA-0, SHA-1, and a collision attack that runs

Asked which of the earlier SHAs was "fully broken". The answer is both, and
the interesting part is that they are the same function: SHA-1 rotates the
message-expansion feedback left by one bit and SHA-0 does not. NIST withdrew
SHA-0 in 1995 without explaining why. That rotation is why.

`broken/` implements both in C and Lean, implements the attack, and carries a
seven-page write-up, `sha-broken.pdf`.

**The rotation is worth measuring, and it measures enormous.** Feed a one-bit
difference through both expansions: under SHA-0 it stays in the single bit
column it started in (31 difference bits, 1 column) and under SHA-1 it spreads
over 23 columns (109 bits). That is the whole attack surface in one table.

**Lean proves what the C exhibits.** `sha0_expand_mask` says SHA-0's expansion
commutes with masking — for every message, mask and round — which is exactly
"it never moves information between bit positions".
`sha1_expand_not_mask` refutes the same statement for SHA-1 by explicit
counterexample. Kernel-only: `[propext, Quot.sound]`, no `Classical.choice`.
The distributivity lemma underneath is proved by eight-case truth table rather
than `bv_decide`, deliberately: bit-blasting to SAT would put the Lean
compiler in the trusted base for a fact a truth table settles.

**Real collisions, found, not quoted.** `collide search --rounds 25` produces
two distinct 64-byte messages with the same 25-round SHA-0 digest in about ten
milliseconds, re-verified through the CLI rather than trusted from the search.
Both are one block, so they pad identically and it is a hash collision, not
merely a compression-function one.

### Findings

- **The Parity rounds are not free, and I had written that they were.** The
  comment in `collide.c` said a linear `f` means "no condition"; the
  measurement it sat next to said 2^-3. Eight times cheaper than `Ch`/`Maj`,
  not free — the residual is carries, because the round adds mod 2^32 while
  the differential is stated in XOR. The measurement corrected the code's own
  documentation, which is the argument for measuring rather than asserting.
- **A disturbance vector is only usable if its five time-shifts are also
  codewords.** Fifteen extra linear conditions, cutting 65535 candidates to
  2047. Omitting it made every differential unmountable, and the first version
  of the search reported exactly that — `valid expansion: NO` for every round
  count. The bug announced itself correctly; what took the time was believing
  it rather than assuming the search was at fault.
- **A probe that cannot show it is working is not evidence.** The first survey
  of library-level behaviour across languages returned wrong digests for Perl
  and shell even in the control case, because it never handed them an initial
  chaining value. Those rows were nearly reported as findings about the
  implementations. Probes now assert the known answer in the control condition
  before any experimental row is believed.
- **Two of five references downloaded.** Chabaud–Joux 1998 came via the
  Internet Archive and SHAttered from `shattered.io`; both were confirmed
  against their own title pages before being cited, following the earlier
  incident recorded below where a guessed download turned out to be an
  unrelated paper. The IACR ePrint server returned 403 to every automated
  request and NIST no longer serves the withdrawn FIPS 180-1 PDF, so those
  entries say "no local copy" outright. No VirusTotal access was available;
  `refs.bib` states what was actually done instead of implying a scan.
- **SHA-0 has no oracle.** SHA-1 is checkable against three independent
  implementations on any machine; SHA-0 is implemented by nothing current.
  It therefore rests on published vectors plus the structural check that
  switching the rotation on turns each SHA-0 answer into the oracle-verified
  SHA-1 one, and on C and Lean — written separately — agreeing.

### Not delivered

Full SHA-0 (~2^39) and SHA-1 (~2^63) collisions are out of reach on one
machine and nothing claims otherwise. Message modification is not implemented,
which is why the search stops around 25 rounds. `sha-broken.pdf` §7 lists both
rather than leaving the reader to infer the boundary.

---

## 2026-08-10 — The round-count clamp: a fix applied where the bug was noticed

`SPEC.md` §6.1 now states that `rounds` is 0…64 at the **library** boundary and
that anything outside it must be rejected. All seven implementations were
changed to obey, and `tests/rounds.sh` checks that they do.

**How it was found.** Not by a test — nothing in the repository could reach it.
It came out of measuring line and branch coverage for the first time, which had
never been done here. `c/shavar.c` was at 90.48% branch coverage, and two of the
four uncovered branches were the round-count clamp. They were uncovered
*because* the CLI had been taught to reject out-of-range counts, so nothing
driving the program through its command line could ever reach them. Dead from
the CLI, live from the library: the coverage gap was the earlier fix's own
shadow.

**What the bug was.** `shavar_compress` clamped silently, and `shavar_hash_ex`
passed `rounds` straight through. A caller linking against `libshavar` and
asking for 100 rounds got a genuine SHA-256 digest and a success status, in
answer to a request that denotes no function. This is the same defect
`d845127` fixed at the CLI layer, described in the entry below in exactly those
terms — "a confidently wrong answer beats an error message only in the sense
that it is harder to notice". The fix went where the bug had been *observed*
rather than where it *lived*, and every other path to it stayed open.

**Probing the other six turned up worse, and four-way disagreement.** With
`rounds = 100` at the library boundary:

| | behaviour |
| --- | --- |
| Python, JavaScript | rejected — correct, and they always had been |
| C, Lean | silently clamped to 64, returning real SHA-256 |
| Perl, shell | ran the loop past the end of `K` — every missing constant reading as `undef` or the empty string, so both produced the *same* garbage digest `6723435a…` and Perl additionally sprayed uninitialized-value warnings |
| Scheme | crashed with an interpreter backtrace |

Seven implementations, four behaviours, none of it visible to `crosstest.sh`
because that harness drives everything through the CLI and the CLI rejects the
input before the library sees it. That Perl and shell agreed *with each other*
on the garbage is the nastiest part: two columns matching looks like evidence.

**A methodological note on the probe itself.** The first survey script produced
wrong digests for Perl and shell even at `rounds = 64`, because it failed to
hand them an initial chaining value — Perl's `@IV` is a file-scoped `my`, and
the shell needs `shavar__init`. Those rows were artifacts of the harness, not
findings about the implementations, and were nearly reported as findings. The
fix was to make the probe assert the known SHA-256("abc") digest at
`rounds = 64` before any out-of-range row is believed. A measurement that
cannot demonstrate it is measuring correctly is not evidence.

**What changed.** `shavar_compress` now returns `int` rather than `void` — it
had no way to refuse otherwise — and `shavar_hash_ex` propagates. That is an
API break, taken deliberately: the alternative was a library that cannot say
no. Perl and Scheme raise, the shell returns 1, and Lean gained `hashBytes?`
and `hashHex?` as checked entry points, `Nat` having no negative case to test.

**One thing not delivered.** `hashBytes_clamps` — a Lean theorem stating that
above 64 the total function silently behaves as 64 — is true and provable in
principle but was dropped. Every route tried through `List.take_of_length_le`
on `List.finRange 64` sent elaboration into sixty-four concrete index terms and
did not terminate in usable time; the file builds in 4 seconds without it and
hung past 10 minutes with it. It was removed rather than left half-proved or
forced through with `native_decide`, which would have put a compiler-trust
axiom into a file that has none. The Lean doc comment says so explicitly. The
range check is on the *tested* side of the proved/tested line, in all eight
builds.

### Findings

- **A check enforced at one layer is not a property of the system.** The CLI
  fix was correct and complete for the CLI. It was mistaken for a fix to the
  program. The general shape — "we validate that at the boundary" — is worth
  distrusting whenever there is more than one boundary.
- **Coverage measurement was worth doing and had never been done.** No
  instrumentation existed anywhere in the repo; every use of the word
  "coverage" in the codebase meant input-space coverage. The first run found a
  real bug, and it found it in the branches that were uncovered *for a reason*.
- **`tests/rounds.sh` puts the clamp back** into a copy of `c/shavar.c` and
  requires the contract check to catch it. 4 of the 9 counts do. Same
  discipline as `selfcheck.sh` and the mutation phase of `pow.sh`.

---

## 2026-08-09 — Proof-of-work comparison, in all seven languages

`SPEC.md` §10 specifies a proof-of-work (PoW) comparison — decode a compact
Bitcoin `nBits` target and decide whether a digest meets it — and all seven
implementations now have it, along with the CWEB literate version.

**The specification was written before any of the code**, which for this
feature is not ceremony. The digest has to be read as one 256-bit integer, and
the byte order that requires is a *convention*: Bitcoin reads it
little-endian, so `digest[0]`, the first byte the hash function emitted, is
the least significant. Reading it the other way is silent — it compiles, it
runs, and it returns a plausible verdict — and this repository's own record
already says that every place seven independent implementations diverged was a
place the specification was silent. So the order was fixed on paper first, in
a section with a worked example and a figure, and only then implemented.

**Scoped library-only, on request, with the consequence handled rather than
accepted.** There is no CLI verb, which means `crosstest.sh` — which drives
everything through `spec/CLI.md` — cannot see the new code at all. Left there,
the PoW comparison would have been the only part of the repository whose
seven-way agreement nothing checked, which is the property the project exists
to demonstrate. `tests/pow.sh` closes that: one small marshalling driver per
language under `tests/pow-drivers/`, deciding nothing themselves, and the
columns compared both against expected verdicts and against each other.

**The vectors are anchored outside this repository.** Two of the eighteen are
the same 32 bytes in opposite orders: the Bitcoin genesis block's doubled
SHA-256 as emitted, and its reverse. They disagree, and no other vector
separates the two readings as sharply — an implementation reading the digest
big-endian swaps both verdicts and stays perfectly self-consistent. The
genesis header was hashed to confirm it reproduces the published block hash
before any of it was written down, rather than transcribing a value and hoping.

**The harness is required to fail.** The last phase of `pow.sh` mutates a copy
of `c/shavar.c` to read the digest big-endian and asserts the comparison
rejects it; 5 of 18 vectors catch it. Nothing in the repository is touched.
Without that step, "all green" would have been equally consistent with a
harness that never looked — the same reasoning that produced `selfcheck.sh`.

**Lean does better than test it.** `lean/Shavar/Pow.lean` runs the same
byte-at-a-time walk the other six do and then proves `powCheck_iff`: the walk
answers "met" exactly when the little-endian reading of the digest is at most
the target. The statement quantifies over the two *numbers* and mentions no
byte index at all, so a big-endian version could not satisfy it. Kernel-only —
`[propext, Classical.choice, Quot.sound]`, no `bv_decide` native axiom, no
`sorry`.

### Findings

- **Scheme needed a modulino guard.** `scm/shavar.scm` ran its CLI on load, so
  a test driver could not reach its procedures. It now checks `SHAVAR_LIB`
  through `get-environment-variable`, which is already in the
  `(scheme process-context)` import it had — no new dependency, and the same
  spelling `sh/shavar.sh` had been using all along. Perl already had the idiom.
- **A too-broad `guard` nearly turned a broken driver into a verdict.** The
  Scheme driver wraps `pow-check` in `guard` to turn an invalid `nBits` into
  the verdict "invalid". On its first run it printed "invalid" for all
  eighteen vectors — not because the implementation was wrong but because the
  driver had never loaded it, and the guard swallowed the unbound-variable
  error. `pow.sh` caught it as a disagreement, but the failure mode is worth
  recording: an exception handler wide enough to catch "this is malformed" is
  usually also wide enough to catch "this is broken", and the two must not
  produce the same output. There is now a canary outside the guard.
- **A second Lean executable broke implementation discovery.** `find_lean_bin`
  in `tests/lib/common.sh` scanned `lean/.lake/build/bin/` and took the first
  executable it found, which was fine while there was exactly one. Adding
  `powdriver` put it ahead of `shavar` in glob order, and every Lean row in
  `nist.sh` and `crosstest.sh` became `BROKEN: usage: powdriver VECTORS.tsv`.
  The harness failed loudly and named the cause, which is it working properly;
  the lesson is about the assumption underneath — "there is exactly one
  binary" was never stated anywhere, so nothing protected it. Discovery now
  prefers the conventional name and treats the scan as a fallback.
- **No `ring`, no `positivity`.** `lean/` deliberately has no Mathlib
  dependency, so the arithmetic in the proofs is core `Nat` lemmas and `omega`
  over abstracted nonlinear atoms. Worth knowing before reaching for a tactic.
- **JavaScript's bitwise operators are signed.** `nBits >>> 24` rather than
  `>> 24`, and an explicit `>>> 0` on entry, because a target with its top bit
  set would otherwise decode as a negative number.
- **Difficulty as a float is deliberately absent.** The conventional
  `difficulty_1_target ÷ target` ratio is not computed anywhere: the shell
  implementation has no floating-point arithmetic at all, and seven
  independently rounded approximations of one ratio is exactly the unstated
  boundary this project keeps finding at the root of divergence.

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
