/-
# `Shavar.Audit` — what has actually been proved, and on what trust

## How to read `#print axioms`

Every Lean proof ultimately rests on some set of assumptions. `#print axioms T`
prints exactly which ones theorem `T` depends on, transitively through every
lemma it uses. It is not a summary written by a human; it is computed from the
proof term. If a proof secretly used `sorry`, `sorryAx` appears in this list, and
no amount of confident prose elsewhere can hide it. This file therefore is the
honest bottom line for the whole directory.

Three axiom names are Lean's own standard foundations and appear in ordinary
mathematics everywhere:

* `propext` — propositional extensionality: logically equivalent propositions
  are equal.
* `Classical.choice` — the axiom of choice, which in Lean also supplies
  excluded middle.
* `Quot.sound` — the defining property of quotient types.

A theorem depending on only these (or on none of them) is proved in the ordinary
sense: the Lean **kernel**, a small program whose job is to recheck proof terms,
has verified it end to end.

One further kind of name can appear here:

* `<theorem>._native.bv_decide.ax_N` — produced by `bv_decide`. It asserts
  `verifyBVExpr <bit-blasted goal> <LRAT certificate> = true`, established by
  running the verified LRAT checker as **compiled native code** rather than by
  kernel reduction. The SAT solver stays untrusted — a wrong certificate fails
  the check — but the Lean compiler and the native runtime are trusted. SPEC.md
  §8 flags this and names the axiom `Lean.ofReduceBool`; on Lean 4.32.2 the same
  mechanism appears under the per-theorem name above.

* `sorryAx` — an admitted, unproved statement. **There are none in this
  directory.** The build emits no `declaration uses 'sorry'` warnings, and no
  `#print axioms` output below mentions `sorryAx`.

## What each line below establishes

The four theorems printed first are the headline results. `hashBytes_eq_std` is
the one a sceptical reader should look at: it says the shipped hash function and
the FIPS 180-4 eight-register hash function agree, for every input.
-/
import Shavar

namespace Shavar

/-! ## V1 — the 2D recurrence equals the eight-register form -/

-- One round. Definitional equality; the strongest form the claim can take.
#print axioms round2D_toRegs

-- Any number of rounds, by induction. Covers 64 and every reduced count.
#print axioms run2D_toRegs

-- One whole block: seeding, rounds, feed-forward.
#print axioms compressBlock_eq_std

-- The whole hash function, over all messages, lengths, round counts and IVs.
#print axioms hashBytes_eq_std

/-! ## V2 — the bitwise identities

Each of these appears twice in `Shavar/BitIdentities.lean`. The primary name is
the kernel-only proof; the `_bv` name is the same statement via SAT. Printing
both side by side is the clearest possible statement of what `bv_decide` costs
in trust. -/

#print axioms ch_eq_xor_form      -- kernel only
#print axioms ch_eq_xor_form_bv   -- adds a native bv_decide axiom
#print axioms maj_eq_or_form      -- kernel only
#print axioms maj_eq_or_form_bv   -- adds a native bv_decide axiom

-- The remaining `Ch`/`Maj` facts are all kernel-only, by the same case split.
#print axioms ch_eq_or_form
#print axioms ch_allOnes
#print axioms ch_zero
#print axioms maj_eq_xor_form
#print axioms maj_self
#print axioms maj_comm_12
#print axioms maj_not_linear
#print axioms ch_not_linear

-- These genuinely need SAT: they mix bit positions, so the eight-case argument
-- that works for `Ch` and `Maj` does not apply.
#print axioms rotr2
#print axioms Sigma0_shift_form
#print axioms Sigma1_shift_form
#print axioms sigma0_shift_form
#print axioms sigma1_shift_form
#print axioms Sigma0_linear
#print axioms Sigma1_linear
#print axioms sigma0_linear
#print axioms sigma1_linear

/-! ## V3 — padding lands on a 512-bit multiple -/

#print axioms padLen_mod_512
#print axioms padBits_length_mod_512
#print axioms padBytes_length     -- the same fact about the running code

/-! ## V4 — padding is injective -/

#print axioms padBits_injective
#print axioms pad_injective_bytes

-- …and the reason the well-formedness side condition is not optional.
#print axioms not_wf_b4_5
#print axioms padBits_ne_of_wellFormed_ne

end Shavar
