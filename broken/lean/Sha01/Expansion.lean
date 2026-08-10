/-
# `Sha01.Expansion` — the message expansion, and why SHA-0's is fatally weak

`../attack/expansion.c` *exhibits* the weakness: it feeds a one-bit difference
through both expansions and counts that SHA-0 keeps it in a single bit column
while SHA-1 spreads it over twenty-three. This file *proves* the underlying
statement, for every input and every column at once.

The property is stated as commutation with masking. Masking a word by `m`
keeps only the bit positions `m` selects, so

    expand (mask M) = mask (expand M)

says exactly "the expansion does not move information between bit positions":
whatever you delete before expanding, you could equally delete afterwards.
`sha0_expand_mask` proves that for SHA-0, and `sha1_expand_not_mask` exhibits
a concrete counterexample for SHA-1.

That is the whole difference between the two functions, in two theorems. The
attack in `../attack/` depends on it completely: it is what makes the possible
difference patterns in one column a 65536-element code that can be enumerated
outright, instead of a subspace of a 512-bit space that cannot.
-/
import Sha01.Basic

namespace Sha01

/-! ## The expansion

Written as a function of the round index rather than as an array fold, because
every proof below is an induction on that index and this is the shape the
induction wants. -/

/-- `W M rot t` is schedule word `t`, expanded from the sixteen message words
`M 0 … M 15` with feedback rotated left by `rot`.

`rot = 0` is SHA-0 and `rot = 1` is SHA-1. -/
def W (M : Nat → BitVec 32) (rot : Nat) : Nat → BitVec 32
  | t =>
    if t < 16 then M t
    else rotl rot (W M rot (t - 3) ^^^ W M rot (t - 8)
                   ^^^ W M rot (t - 14) ^^^ W M rot (t - 16))
  termination_by t => t
  decreasing_by all_goals omega

theorem W_lt (M : Nat → BitVec 32) (rot t : Nat) (h : t < 16) : W M rot t = M t := by
  rw [W]; simp [h]

theorem W_ge (M : Nat → BitVec 32) (rot t : Nat) (h : ¬ t < 16) :
    W M rot t = rotl rot (W M rot (t - 3) ^^^ W M rot (t - 8)
                          ^^^ W M rot (t - 14) ^^^ W M rot (t - 16)) := by
  rw [W]; simp [h]

/-! ## Masking distributes over the linear part -/

/-- Bitwise AND with a fixed mask distributes over XOR. This is the one
algebraic fact the whole argument rests on, and it is the reason SHA-0's
expansion — which is nothing but XOR — cannot mix bit positions. -/
theorem and_xor_distrib (a b m : BitVec 32) :
    (a ^^^ b) &&& m = (a &&& m) ^^^ (b &&& m) := by
  -- Bit by bit, then the eight cases of a three-variable Boolean identity.
  -- Deliberately not `bv_decide`: that would bit-blast to SAT and put the
  -- Lean compiler in the trusted base for a fact that a truth table settles.
  ext i
  simp only [BitVec.getElem_and, BitVec.getElem_xor]
  cases a[i] <;> cases b[i] <;> cases m[i] <;> rfl

/-! ## SHA-0: the expansion is thirty-two independent columns -/

/--
**SHA-0's expansion never moves a bit between positions.**

For every message, every mask and every round, masking before expanding gives
the same answer as masking after. Take `m` to be a single-bit mask and the
statement reads: bit `i` of every expanded word is a function of bit `i` of the
message words alone.

This is what makes the attack tractable. Difference patterns in one column
satisfy a scalar GF(2) recurrence with sixteen free bits, so there are 65536 of
them and `../attack/expansion.c` enumerates all of them in a tenth of a second.
Without column independence the same enumeration would be over 2⁵¹².
-/
theorem sha0_expand_mask (M : Nat → BitVec 32) (m : BitVec 32) :
    ∀ t, W M 0 t &&& m = W (fun k => M k &&& m) 0 t := by
  intro t
  induction t using Nat.strongRecOn with
  | _ t ih =>
    by_cases h : t < 16
    · rw [W_lt _ _ _ h, W_lt _ _ _ h]
    · rw [W_ge _ _ _ h, W_ge _ _ _ h, rotl_zero, rotl_zero]
      rw [← ih (t - 3) (by omega), ← ih (t - 8) (by omega),
          ← ih (t - 14) (by omega), ← ih (t - 16) (by omega)]
      rw [and_xor_distrib, and_xor_distrib, and_xor_distrib]

/-! ## SHA-1: it does not

One counterexample is enough, and a small one is more informative than a
general theorem here: it shows precisely *where* the coupling comes from.

Take a message whose only set bit is bit 0 of `M 0`, and mask down to bit 0.
Under SHA-1 the feedback into `W 16` is rotated left by one, so the bit lands
in position 1 — outside the mask. Masking first therefore gives a different
answer from masking last, and by exactly the bit the rotation moved. -/

/-- The message with bit 0 of word 0 set and nothing else. -/
def probe : Nat → BitVec 32 := fun k => if k = 0 then 1 else 0

/--
**SHA-1's expansion does move bits between positions.**

The same statement proved above for SHA-0 is false for SHA-1, and this is the
`ROTL¹` doing its job: it is the only difference between the two functions and
it is sufficient to destroy the property the attack needs.
-/
theorem sha1_expand_not_mask :
    ¬ (∀ (M : Nat → BitVec 32) (m : BitVec 32) (t : Nat),
        W M 1 t &&& m = W (fun k => M k &&& m) 1 t) := by
  intro h
  -- `W` is defined by well-founded recursion, so it does not reduce by
  -- computation; the two values are obtained from the equation lemmas
  -- instead. Round 16 reads rounds 13, 8, 2 and 0, all of them message words.
  have e16 : W probe 1 16 = 2#32 := by
    rw [W_ge _ _ _ (by omega), W_lt _ _ _ (by omega), W_lt _ _ _ (by omega),
        W_lt _ _ _ (by omega), W_lt _ _ _ (by omega)]
    simp only [probe, rotl]
    decide
  have e16' : W (fun k => probe k &&& 1#32) 1 16 = 2#32 := by
    rw [W_ge _ _ _ (by omega), W_lt _ _ _ (by omega), W_lt _ _ _ (by omega),
        W_lt _ _ _ (by omega), W_lt _ _ _ (by omega)]
    simp only [probe, rotl]
    decide
  have hc := h probe 1#32 16
  rw [e16, e16'] at hc
  -- 2 &&& 1 = 0, and 0 ≠ 2: the rotation moved the bit out of the mask.
  exact absurd hc (by decide)

end Sha01
