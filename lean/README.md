# `lean/` — the formal-verification track

This directory holds the Lean 4 implementation of SHA-256 and the
machine-checked proofs of the verification obligations in `spec/SPEC.md` §8.

**You do not need to know Lean to read it.** Every file opens with a prose
header explaining what it claims and why, and every theorem carries a doc
comment stating in English what the formal sentence says. The proof scripts —
the `by …` parts — are for the machine; skipping them loses nothing.

## Building and running

```
cd lean
lake build                     # compiles the library, the proofs, and the tests
.lake/build/bin/shavar hash - 0
.lake/build/bin/shavar selftest
```

Requires Lean 4.32.2 (pinned in `lean-toolchain`; `elan` will fetch it). There
are **no external dependencies** — no Mathlib. Everything uses Lean's core
library and `Std`, which ship with the toolchain.

`lake build` does more than compile. It also

* runs the known-answer vectors (`Shavar/Tests.lean`) and fails the build if any
  digest is wrong;
* recomputes the initial value and the 64 round constants from the square and
  cube roots of the primes, in exact integer arithmetic, and fails the build if
  they disagree with the tables in `Shavar/Words.lean` (SPEC.md §9);
* prints the `#print axioms` report (`Shavar/Audit.lean`) — the ground truth for
  what has actually been proved and on what trust.

## What is in each file

| File | Contents |
| --- | --- |
| `Shavar/Words.lean` | `Ch`, `Maj`, `Σ0`, `Σ1`, `σ0`, `σ1`, the IV and `K` (SPEC.md §1.1, §9) |
| `Shavar/Round.lean` | The two round functions, written independently: `roundStd` (§2) and `round2D` (§3) |
| `Shavar/Equiv.lean` | **V1** — the proof that they agree, for one round and for any number of rounds |
| `Shavar/BitIdentities.lean` | **V2** — the `Ch`/`Maj` optimisations and the `Σ`/`σ` shift forms |
| `Shavar/Pad.lean` | **V3** and **V4** — padded length is a multiple of 512, and padding is injective |
| `Shavar/Compress.lean` | The message schedule (§4), block compression, and the trace record |
| `Shavar/Hash.lean` | Byte-level padding, the Merkle–Damgård loop, hex output |
| `Shavar/Cli.lean` | Argument decoding, the vector table, output shaping (CLI.md) |
| `Shavar/Tests.lean` | Checks that run during `lake build` |
| `Shavar/Audit.lean` | `#print axioms` for every headline theorem |
| `Main.lean` | The `shavar` executable |

## The three ideas a non-Lean reader needs

**A theorem is a checked claim.** `theorem foo : P := by tac` asserts `P` and
supplies a script that must convince the kernel. The file does not compile
otherwise. There is no way to state a theorem and leave it unjustified except by
writing `sorry`, which produces a loud warning and shows up in `#print axioms`
as `sorryAx`. There is no `sorry` anywhere in this directory.

**Quantifiers are not test corpora.** When `run2D_toRegs` says "for every window
and every list of round inputs", it means all 2²⁵⁶ starting states and every
round count, not a sample. This is the whole difference between the proofs here
and the (also valuable, also present) known-answer tests.

**Types carry information.** `BitVec 32` is the type of 32-bit vectors — the
width is part of the type, so a 32-bit value cannot be handed to something
expecting 64 bits. `Vector α n` is an array whose length is in its type, so
`schedule : Vector (BitVec 32) 16 → Vector (BitVec 32) 64` is checked at compile
time to consume sixteen words and produce sixty-four, and the loop that fills it
carries an in-range proof at every index. Whole categories of C bug — width
confusion, off-by-one indexing, reading past the end — are not merely absent
here; they are unwritable.

## What `bv_decide` does, and what it costs

`bv_decide` proves a bit-vector goal by negating it, bit-blasting to a SAT
instance, running the bundled CaDiCaL solver, and then **checking the returned
LRAT refutation certificate inside Lean**. The solver is not trusted: a bad
certificate fails the check. But the certificate check runs as compiled native
code, so the Lean compiler is in the trusted base for those proofs, and each one
introduces an axiom named `<theorem>._native.bv_decide.ax_N`.

Because `Ch` and `Maj` act bit-position-wise (SPEC.md §7.2), their identities can
also be proved by an eight-case argument the kernel checks directly.
`Shavar/BitIdentities.lean` therefore proves each of those twice — once each way
— so the trust difference is visible rather than argued about. The `Σ`/`σ`
identities mix bit positions and genuinely need SAT.

## Where the trust actually sits

`Shavar/Audit.lean` prints it. In summary:

* **V1** (all four levels: one round, many rounds, one block, whole hash) —
  kernel only, `[propext, Quot.sound]`.
* **V3, V4** — kernel only.
* **V2** — the `Ch`/`Maj` identities are available kernel-only; the `Σ`/`σ`
  identities carry a `bv_decide` native axiom.
* **V5** (agreement with FIPS 180-4) is a *test*, not a theorem: known answers,
  checked at build time.
* **V6** (agreement with the other implementations) belongs to the cross-testing
  harness, not to this directory.
