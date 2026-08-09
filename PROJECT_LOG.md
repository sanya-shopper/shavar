# shavar — Project Log

A running record of the project's context, decisions, and evolution. Newest
entries at the top. Each entry is committed so the history of thinking is
preserved alongside the history of code.

---

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

**The unifying image the user offered**, which is a good one and worth
designing toward: *a blend between a debugger and a video game for SHA-256
nerds*. The Safari page is where that lands — round-by-round stepping, the two
tracks with the order-4 window highlighted, bit-level rendering, and a diff
mode that shows a one-bit input difference avalanching across 64 rounds.

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
