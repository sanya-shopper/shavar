# shavar

SHA-256 implemented seven times — in **C99, Lean 4, Python, Perl, Scheme,
JavaScript and shell** — written not as the usual eight shuffling registers
but as **two coupled recurrences with a lookback of four**.

Three things at once: a comparison of how seven languages express the same
algorithm, an instrument for studying the function's interior, and a
step-debugger you can open in a browser.

```
T1[t] = E[t-4] ⊞ Σ1(E[t-1]) ⊞ Ch(E[t-1],E[t-2],E[t-3]) ⊞ K[t] ⊞ W[t]
T2[t] = Σ0(A[t-1]) ⊞ Maj(A[t-1],A[t-2],A[t-3])
E[t]  = A[t-4] ⊞ T1[t]
A[t]  = T1[t] ⊞ T2[t]
```

That is the whole compression function. The standard presentation keeps eight
variables `a…h`, but six of its eight assignments are pure copies: the
registers are two sliding windows of width four over the histories of `A` and
`E`. Removing the copies leaves the four lines above. `lean/` proves the two
forms equivalent, and for a single round the equivalence is *definitional* —
the formal statement of "the register shuffle was never computation".

## Quick start

```sh
make -C c                                  # build the reference
./c/shavar hash 616263 24                  # "abc"
./c/shavar hash b0 5                       # a FIVE-BIT message
./c/shavar trace 616263 24 | head          # every intermediate value

open js/index.html                         # the interactive step-debugger
bash tests/run.sh fast                     # cross-check all implementations
python3 research/avalanche.py 616263 616262 24   # watch one bit avalanche
```

## Why this formulation

- **Smaller.** Four lines per round with no permutation to get wrong.
- **The state *is* the history**, so keeping the full trajectory costs nothing
  (136 words per block) and every intermediate value stays addressable.
- **It is the object cryptanalysis reasons about** — differential work talks
  about the sequences `A[t]` and `E[t]`, not about register names.

One structural fact the picture makes obvious and the algebra hides: `A[t]`
reads the `E` history at four points, but `E[t]` reads the `A` history at
exactly one, `A[t-4]`. That single edge is the *only* path from the `A` track
to the `E` track.

## Layout

| Path | What it is |
| --- | --- |
| `spec/SPEC.md` | the normative specification — read this first |
| `spec/CLI.md` | the uniform command-line contract all seven obey |
| `c/` | C99 reference: `.a` + shared library, zero allocations |
| `lean/` | Lean 4 implementation **and machine-checked proofs** |
| `py/ pl/ scm/ js/ sh/` | the other implementations, one directory each |
| `js/index.html` | interactive step-debugger, runs from `file://` in Safari |
| `tests/` | cross-testing harness + 1154 NIST CAVP vectors |
| `research/` | differential propagation tooling |
| `doc/shavar.pdf` | comparative write-up: what each language makes hard |

## Ground rules

Every implementation is **core language only** — no libraries, no modules, no
imports beyond reading `argv`. That constraint is the point: it is what
exposes the difference between a language that has a 32-bit unsigned integer
and one that has to simulate it. (Exactly two have one. The rest spend their
idiom budget on it, and that choice shapes everything else in the file.)

Test tooling is exempt and uses whatever it likes.

All seven support **arbitrary bit lengths**, not just whole bytes; a
**caller-supplied chaining value**; and **reduced round counts** — the last two
unreachable from a normal hashing API and both prerequisites for free-start
and reduced-round analysis.

## Correctness

Verified in CI on every push (44 jobs):

- **1154 NIST CAVP vectors, 896 of them not byte-aligned.** Committed, so the
  suite runs offline.
- **All seven agree byte-for-byte on the full per-round trace** — `W`, `A`,
  `E`, `T1`, `T2` — not merely on digests. A disagreement therefore names the
  round and register where it happened.
- **valgrind: 0 errors, no leaks possible.** ASan, MSan, UBSan clean.
- **Big-endian verified**, not assumed: cross-compiled to s390x and run under
  QEMU, digests identical.
- 36 compiler configurations; Lean build fails on any `sorry`.

**What is proved, versus tested.** The equivalence of the two forms, and the
padding length and injectivity theorems, are *proved* in Lean with kernel-only
axioms. Everything else is *tested*. The repository keeps that line sharp, and
so does the harness: its summary separates `verified` (matched NIST or an
external oracle) from `agreed` (only other implementations answered), and
never adds them together.

One limit worth stating plainly: `openssl`, `shasum` and `sha256sum` can only
hash whole bytes, so for sub-byte lengths outside the NIST bit-oriented set,
the evidence is cross-implementation agreement alone. That is a strong
instrument and a weak oracle, and the tooling says so on every run.

## Reading order

1. `spec/SPEC.md` — the mathematics, and why this formulation
2. `doc/shavar.pdf` — the comparison, and the surprises
3. `c/shavar.c` — the shortest and most direct implementation
4. `lean/Shavar/Equiv.lean` — the proof that all of this is still SHA-256
5. `PROJECT_LOG.md` — how it was built, including what went wrong

## Licence

Not yet chosen. Treat as all-rights-reserved until one is added.
