/-
# `Shavar.BitIdentities` — V2, the bit-level identities

**Obligation V2 (SPEC.md §8):** *the `Ch`/`Maj` identities used for
optimisation are sound.*

Real SHA-256 implementations do not write `Ch` and `Maj` the way FIPS 180-4
does. They use cheaper equivalent expressions — one fewer operation each, which
matters when the round body runs 64 times per block. This file proves the
substitutions are exact, for all 2⁹⁶ inputs.

## What `bv_decide` actually does

`bv_decide` is not a simplifier and not a sampler. Given a goal about bit
vectors it:

1. **Bit-blasts.** The goal is negated and compiled to a propositional formula
   over one Boolean variable per bit — an And-Inverter Graph, then CNF. A claim
   about three `BitVec 32` values becomes a SAT instance over 96 input
   variables plus internal ones.
2. **Calls a SAT solver.** CaDiCaL, bundled with the Lean toolchain, searches
   for a satisfying assignment of the negation. Finding one would be a
   counterexample and `bv_decide` reports it as such. Finding none means the
   original goal holds for every input.
3. **Checks the certificate.** Unsatisfiability is not taken on trust. CaDiCaL
   emits an LRAT proof — a machine-checkable log of the resolution steps — and
   Lean re-runs a verified LRAT checker over it. **The SAT solver is not in the
   trusted computing base.** A buggy or lying solver produces a certificate that
   fails to check, and the tactic fails.

The catch, stated plainly because SPEC.md §8 insists on it: step 3 runs the
checker by *compiled native evaluation*, not by kernel reduction, because
kernel-reducing a multi-thousand-step LRAT proof is impractical. The result is
sealed into a generated axiom of the form

    <theorem>._native.bv_decide.ax_N : verifyBVExpr <expr> <cert> = true

So the Lean **compiler** is in the trusted base for every `bv_decide` proof.
(SPEC.md §8 names this axiom `Lean.ofReduceBool`; on Lean 4.32.2 the mechanism
is the same but the axiom is generated per theorem under the name above. The
trust story is identical: compiled evaluation is believed.)

## …and why this file also proves everything twice

Because that caveat is avoidable here. `Ch` and `Maj` are *bitwise*: bit `i` of
the output depends only on bit `i` of the inputs (SPEC.md §7.2). So each
identity reduces to a claim about three Booleans, which is eight cases, which
the kernel can check directly.

So the two headline optimisations — the `Ch` rewrite and the `Maj` rewrite that
SPEC.md §8 names — are each proved **twice**, under two names:

* `…` (the primary form) — proved by extensionality plus an eight-way case
  split, trusting nothing beyond the kernel and Lean's standard axioms.
* `…_bv` — the identical statement proved by `bv_decide`, which additionally
  trusts the compiler.

Having the pair side by side is the point: `Shavar/Audit.lean` prints the axiom
list for both, so the cost of the automation is visible rather than argued
about. The remaining results in this file are proved only one way, and which
way is not arbitrary: claims about `Ch` and `Maj` alone take the kernel route
where the case split is available, while the `Σ`/`σ` identities at the end mix
bit positions, so the eight-case argument does not apply to them and SAT is
doing genuine work.
-/
import Shavar.Words

namespace Shavar

/-! ## Ch

`Ch(x,y,z) = (x ∧ y) ⊕ (¬x ∧ z)` is the spec form: three operations plus a
negation. The optimised form `z ⊕ (x ∧ (y ⊕ z))` is three operations and no
negation, and is what almost every production implementation actually emits. -/

/-- **V2.1.** The standard `Ch` optimisation:
`(x ∧ y) ⊕ (¬x ∧ z) = z ⊕ (x ∧ (y ⊕ z))`.

Read the proof script as: "two bit vectors are equal when they agree at every
index (`ext i`); push the index through the bitwise operations (`simp`); then
the goal is about three Booleans, so try all eight combinations". -/
theorem ch_eq_xor_form (x y z : BitVec 32) :
    Ch x y z = z ^^^ (x &&& (y ^^^ z)) := by
  unfold Ch
  ext i
  simp only [BitVec.getElem_xor, BitVec.getElem_and, BitVec.getElem_not]
  cases x[i] <;> cases y[i] <;> cases z[i] <;> rfl

/-- The same claim, discharged by SAT instead. Kept to exhibit the technique of
SPEC.md §8 and to be a reference point for the axiom comparison in the report. -/
theorem ch_eq_xor_form_bv (x y z : BitVec 32) :
    Ch x y z = z ^^^ (x &&& (y ^^^ z)) := by
  unfold Ch; bv_decide

/-- **V2.2.** `Ch` may equivalently be written with `∨` instead of `⊕`: the two
branches `(x ∧ y)` and `(¬x ∧ z)` are disjoint, so the exclusive or in the spec
could have been an inclusive or. Worth recording because some implementations
write it that way and a reader may wonder whether they are the same function. -/
theorem ch_eq_or_form (x y z : BitVec 32) :
    Ch x y z = (x &&& y) ||| ((~~~x) &&& z) := by
  unfold Ch
  ext i
  simp only [BitVec.getElem_xor, BitVec.getElem_and, BitVec.getElem_or,
    BitVec.getElem_not]
  cases x[i] <;> cases y[i] <;> cases z[i] <;> rfl

/-- **V2.3.** `Ch` really does choose: where `x` is all ones it returns `y`. -/
theorem ch_allOnes (y z : BitVec 32) : Ch (BitVec.allOnes 32) y z = y := by
  unfold Ch
  ext i
  simp only [BitVec.getElem_xor, BitVec.getElem_and, BitVec.getElem_not,
    BitVec.getElem_allOnes]
  cases y[i] <;> cases z[i] <;> rfl

/-- **V2.4.** …and where `x` is all zeros it returns `z`. -/
theorem ch_zero (y z : BitVec 32) : Ch 0 y z = z := by
  -- Easiest from the optimised form: `z ⊕ (0 ∧ anything) = z ⊕ 0 = z`.
  rw [ch_eq_xor_form]
  simp

/-! ## Maj -/

/-- **V2.5.** The `Maj` optimisation named in SPEC.md §8:
`(x ∧ y) ⊕ (x ∧ z) ⊕ (y ∧ z) = (x ∧ y) ∨ (z ∧ (x ∨ y))`.

Five operations become four, and the right-hand side needs only one temporary.
This is the form used by OpenSSL and by essentially every optimised
implementation. -/
theorem maj_eq_or_form (x y z : BitVec 32) :
    Maj x y z = (x &&& y) ||| (z &&& (x ||| y)) := by
  unfold Maj
  ext i
  simp only [BitVec.getElem_xor, BitVec.getElem_and, BitVec.getElem_or]
  cases x[i] <;> cases y[i] <;> cases z[i] <;> rfl

/-- The same claim by SAT. -/
theorem maj_eq_or_form_bv (x y z : BitVec 32) :
    Maj x y z = (x &&& y) ||| (z &&& (x ||| y)) := by
  unfold Maj; bv_decide

/-- **V2.6.** The other common `Maj` rewrite, which keeps a running `x ⊕ y`
across rounds: `Maj(x,y,z) = ((x ⊕ y) ∧ (y ⊕ z)) ⊕ y`. -/
theorem maj_eq_xor_form (x y z : BitVec 32) :
    Maj x y z = ((x ^^^ y) &&& (y ^^^ z)) ^^^ y := by
  unfold Maj
  ext i
  simp only [BitVec.getElem_xor, BitVec.getElem_and]
  cases x[i] <;> cases y[i] <;> cases z[i] <;> rfl

/-- **V2.7.** `Maj` is genuinely a majority vote: two equal arguments decide
it. -/
theorem maj_self (x y : BitVec 32) : Maj x x y = x := by
  unfold Maj
  ext i
  simp only [BitVec.getElem_xor, BitVec.getElem_and]
  cases x[i] <;> cases y[i] <;> rfl

/-- **V2.8.** `Maj` is symmetric in its arguments — a fact SPEC.md relies on
implicitly by describing it as "majority" rather than by argument position.
Only two transpositions are needed since they generate the symmetric group. -/
theorem maj_comm_12 (x y z : BitVec 32) : Maj x y z = Maj y x z := by
  unfold Maj
  ext i
  simp only [BitVec.getElem_xor, BitVec.getElem_and]
  cases x[i] <;> cases y[i] <;> cases z[i] <;> rfl

theorem maj_comm_23 (x y z : BitVec 32) : Maj x y z = Maj x z y := by
  unfold Maj
  ext i
  simp only [BitVec.getElem_xor, BitVec.getElem_and]
  cases x[i] <;> cases y[i] <;> cases z[i] <;> rfl

/-! ## The Σ and σ functions

These mix bit positions, so the eight-case argument does not apply and
`bv_decide` is doing real work. The identities below are the ones an
implementation actually needs: every `ROTR` expanded into the shift-or pair
that C and JavaScript have to write, since neither language has a rotate
operator. Getting one of the shift amounts wrong (`32 - n` versus `n`) is a
classic transcription bug, and this is where it would be caught. -/

/-- `ROTR^n(x) = (x >>> n) ∨ (x <<< (32 - n))` at each of the eight rotation
amounts SHA-256 uses. Stated as separate theorems rather than one general claim
because `bv_decide` needs the shift amounts to be literals. -/
theorem rotr2 (x : BitVec 32) : rotr 2 x = (x >>> 2) ||| (x <<< 30) := by
  unfold rotr; bv_decide
theorem rotr6 (x : BitVec 32) : rotr 6 x = (x >>> 6) ||| (x <<< 26) := by
  unfold rotr; bv_decide
theorem rotr7 (x : BitVec 32) : rotr 7 x = (x >>> 7) ||| (x <<< 25) := by
  unfold rotr; bv_decide
theorem rotr11 (x : BitVec 32) : rotr 11 x = (x >>> 11) ||| (x <<< 21) := by
  unfold rotr; bv_decide
theorem rotr13 (x : BitVec 32) : rotr 13 x = (x >>> 13) ||| (x <<< 19) := by
  unfold rotr; bv_decide
theorem rotr17 (x : BitVec 32) : rotr 17 x = (x >>> 17) ||| (x <<< 15) := by
  unfold rotr; bv_decide
theorem rotr18 (x : BitVec 32) : rotr 18 x = (x >>> 18) ||| (x <<< 14) := by
  unfold rotr; bv_decide
theorem rotr19 (x : BitVec 32) : rotr 19 x = (x >>> 19) ||| (x <<< 13) := by
  unfold rotr; bv_decide
theorem rotr22 (x : BitVec 32) : rotr 22 x = (x >>> 22) ||| (x <<< 10) := by
  unfold rotr; bv_decide
theorem rotr25 (x : BitVec 32) : rotr 25 x = (x >>> 25) ||| (x <<< 7) := by
  unfold rotr; bv_decide

/-- **V2.9.** `Σ0` written purely in shifts and ors, as a C implementation must
write it. -/
theorem Sigma0_shift_form (x : BitVec 32) :
    Sigma0 x = ((x >>> 2) ||| (x <<< 30)) ^^^ ((x >>> 13) ||| (x <<< 19))
                 ^^^ ((x >>> 22) ||| (x <<< 10)) := by
  unfold Sigma0 rotr; bv_decide

/-- **V2.10.** `Σ1` likewise. -/
theorem Sigma1_shift_form (x : BitVec 32) :
    Sigma1 x = ((x >>> 6) ||| (x <<< 26)) ^^^ ((x >>> 11) ||| (x <<< 21))
                 ^^^ ((x >>> 25) ||| (x <<< 7)) := by
  unfold Sigma1 rotr; bv_decide

/-- **V2.11.** `σ0` likewise. Note the third term is a plain shift, not a
rotation — the asymmetry that makes `σ` different from `Σ`. -/
theorem sigma0_shift_form (x : BitVec 32) :
    sigma0 x = ((x >>> 7) ||| (x <<< 25)) ^^^ ((x >>> 18) ||| (x <<< 14))
                 ^^^ (x >>> 3) := by
  unfold sigma0 rotr shr; bv_decide

/-- **V2.12.** `σ1` likewise. -/
theorem sigma1_shift_form (x : BitVec 32) :
    sigma1 x = ((x >>> 17) ||| (x <<< 15)) ^^^ ((x >>> 19) ||| (x <<< 13))
                 ^^^ (x >>> 10) := by
  unfold sigma1 rotr shr; bv_decide

/-! ## The GF(2)-linearity claim of SPEC.md §7.1

SPEC.md §7.1 asserts that `Σ0`, `Σ1`, `σ0`, `σ1` are linear over `GF(2)` — that
is, additive with respect to `⊕` — and that this is why the message schedule is
"linear apart from its three additions". That claim is load-bearing for the
cryptanalytic discussion, so it is worth checking rather than asserting. -/

/-- **V2.13.** `Σ0(x ⊕ y) = Σ0(x) ⊕ Σ0(y)`. -/
theorem Sigma0_linear (x y : BitVec 32) : Sigma0 (x ^^^ y) = Sigma0 x ^^^ Sigma0 y := by
  unfold Sigma0 rotr; bv_decide

/-- **V2.14.** `Σ1(x ⊕ y) = Σ1(x) ⊕ Σ1(y)`. -/
theorem Sigma1_linear (x y : BitVec 32) : Sigma1 (x ^^^ y) = Sigma1 x ^^^ Sigma1 y := by
  unfold Sigma1 rotr; bv_decide

/-- **V2.15.** `σ0(x ⊕ y) = σ0(x) ⊕ σ0(y)`. -/
theorem sigma0_linear (x y : BitVec 32) : sigma0 (x ^^^ y) = sigma0 x ^^^ sigma0 y := by
  unfold sigma0 rotr shr; bv_decide

/-- **V2.16.** `σ1(x ⊕ y) = σ1(x) ⊕ σ1(y)`. -/
theorem sigma1_linear (x y : BitVec 32) : sigma1 (x ^^^ y) = sigma1 x ^^^ sigma1 y := by
  unfold sigma1 rotr shr; bv_decide

/-- **V2.17.** `Ch` and `Maj`, by contrast, are *not* `GF(2)`-linear — this is
the other half of the SPEC.md §7.1 table, and the half that carries the
security argument. Stated as a concrete counterexample: linearity in the first
argument fails.

`decide` here is a finite computation on two specific words, checked by the
kernel; no SAT solver is involved. -/
theorem maj_not_linear :
    Maj ((1 : BitVec 32) ^^^ 2) 1 1 ≠ Maj 1 1 1 ^^^ Maj 2 1 1 := by
  decide

/-- **V2.18.** …and `Ch` likewise is not linear in its selector argument. -/
theorem ch_not_linear :
    Ch ((1 : BitVec 32) ^^^ 2) 0 1 ≠ Ch 1 0 1 ^^^ Ch 2 0 1 := by
  decide

end Shavar
