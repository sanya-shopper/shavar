/-
# `Shavar.Pow` — the proof-of-work comparison, and a proof that it reads the
# digest in the right byte order

`spec/SPEC.md` §10 is normative. The short version: a digest is compared
against a *target* by reading its 32 bytes as one 256-bit integer, and the
order they are read in is a convention rather than a fact about the digest.
This repository implements Bitcoin's convention, in which the digest is read
**little-endian** — byte 0, the first byte the hash function emitted, is the
*least* significant — and the comparison is `≤` rather than `<`.

That convention is the only thing here that is easy to get wrong, and getting
it wrong is silent: the code still compiles, still runs, and still returns a
plausible verdict. The other six implementations pin it with test vectors
(`tests/pow.sh`). Lean can do better, so this file does the comparison the
same byte-at-a-time way they do and then *proves* that the result agrees with
the ordering of the two numbers those bytes denote — `powCheck_iff` at the
end. A byte-order bug would make that theorem false rather than merely make a
test fail.
-/
import Shavar.Words

namespace Shavar

/-! ## Big-endian numerals

`beValue bs` is the number whose base-256 digits are `bs`, most significant
first. Defined by recursion rather than with `foldl` because every proof below
is an induction on the list, and this shape is the one the induction wants.
-/

/-- The value of a big-endian list of bytes: `beValue [1, 2] = 258`. -/
def beValue : List (BitVec 8) → Nat
  | [] => 0
  | b :: bs => b.toNat * 256 ^ bs.length + beValue bs

/-- A little-endian reading is the big-endian reading of the reversed bytes.
This one line is the entire byte-order convention of SPEC.md §10.1. -/
def leValue (bs : List (BitVec 8)) : Nat := beValue bs.reverse

/-- An `n`-byte numeral is below `256 ^ n`. Needed because the comparison
below decides an ordering from the first differing byte alone, which is only
valid because everything after it is too small to overturn the decision. -/
theorem beValue_lt (bs : List (BitVec 8)) : beValue bs < 256 ^ bs.length := by
  induction bs with
  | nil => simp [beValue]
  | cons b bs ih =>
    have hb : b.toNat < 256 := by simpa using b.isLt
    -- b ≤ 255, and the tail is below one place value, so the whole is below
    -- 255·256^n + 256^n = 256^(n+1).
    have h1 : b.toNat * 256 ^ bs.length ≤ 255 * 256 ^ bs.length :=
      Nat.mul_le_mul (by omega) (Nat.le_refl _)
    have hstep : 256 ^ (bs.length + 1) = 256 ^ bs.length * 256 := Nat.pow_succ ..
    simp only [beValue, List.length_cons]
    -- Linear in the atoms `256 ^ bs.length`, `b.toNat * 256 ^ bs.length` and
    -- `beValue bs`, which is all omega needs.
    omega

/-! ## The comparison

`cmpBE` walks two equal-length big-endian numerals most significant byte first
and stops at the first difference. It is exactly the loop the C, Python, Perl,
Scheme, JavaScript and shell versions run, written out as a recursion.
-/

/-- Compare two big-endian byte strings, most significant byte first. -/
def cmpBE : List (BitVec 8) → List (BitVec 8) → Ordering
  | [], [] => .eq
  | a :: as, b :: bs =>
      if a.toNat < b.toNat then .lt
      else if b.toNat < a.toNat then .gt
      else cmpBE as bs
  | [], _ :: _ => .lt
  | _ :: _, [] => .gt

/-- **The comparison is the ordering.** For equal-length byte strings, the
byte-at-a-time walk answers "at most" exactly when the numbers it is comparing
stand in that relation. Everything in this file that could be a byte-order bug
would falsify this statement. -/
theorem cmpBE_ne_gt_iff :
    ∀ (as bs : List (BitVec 8)), as.length = bs.length →
      (cmpBE as bs ≠ .gt ↔ beValue as ≤ beValue bs) := by
  intro as
  induction as with
  | nil =>
    intro bs h
    cases bs with
    | nil => simp [cmpBE, beValue]
    | cons _ _ => simp at h
  | cons a as ih =>
    intro bs h
    cases bs with
    | nil => simp at h
    | cons b bs =>
      have hlen : as.length = bs.length := by simpa using h
      have hpa : beValue as < 256 ^ as.length := beValue_lt as
      have hpb : beValue bs < 256 ^ bs.length := beValue_lt bs
      rw [hlen] at hpa
      simp only [cmpBE, beValue, hlen]
      by_cases hab : a.toNat < b.toNat
      · -- Strictly smaller leading byte. The tail cannot overturn it: the tail
        -- is below one place value and the leading gap is at least one.
        have e1 : (a.toNat + 1) * 256 ^ bs.length
            = a.toNat * 256 ^ bs.length + 256 ^ bs.length := Nat.succ_mul ..
        have e2 : (a.toNat + 1) * 256 ^ bs.length ≤ b.toNat * 256 ^ bs.length :=
          Nat.mul_le_mul (by omega) (Nat.le_refl _)
        simp only [if_pos hab]
        constructor
        · intro _; omega
        · intro _; simp
      · by_cases hba : b.toNat < a.toNat
        · -- Symmetric: strictly larger leading byte, so the answer is "no".
          have e1 : (b.toNat + 1) * 256 ^ bs.length
              = b.toNat * 256 ^ bs.length + 256 ^ bs.length := Nat.succ_mul ..
          have e2 : (b.toNat + 1) * 256 ^ bs.length ≤ a.toNat * 256 ^ bs.length :=
            Nat.mul_le_mul (by omega) (Nat.le_refl _)
          simp only [if_neg hab, if_pos hba]
          constructor
          · intro hcon; exact absurd rfl hcon
          · intro hle; omega
        · -- Equal leading bytes: the place-value terms cancel, so recurse.
          have hEq : a.toNat = b.toNat := by omega
          rw [if_neg hab, if_neg hba, hEq, Nat.add_le_add_iff_left]
          exact ih bs hlen

/-! ## Decoding a compact target

`nbits` here is Bitcoin's compact target encoding — an 8-bit exponent above a
23-bit mantissa — and has nothing to do with the message bit length called
`nbits` elsewhere in this development. The collision of names is inherited from
both conventions.

Lean has arbitrary-precision `Nat`, so unlike the six sibling implementations
it can form the target as a number and read its bytes off. That difference is
worth being explicit about: the others build a 32-byte array because they have
no bignum available, and `targetBytes` below is proved-by-construction to be
the same thing by `beValue_targetBytes`.
-/

/-- The exponent byte of a compact target. -/
def powExponent (nbits : UInt32) : Nat := (nbits >>> 24).toNat

/-- The 23-bit mantissa of a compact target. -/
def powMantissa (nbits : UInt32) : Nat := (nbits &&& 0x007FFFFF).toNat

/-- The target as a number, before validity is considered. -/
def powTargetValue (nbits : UInt32) : Nat :=
  let e := powExponent nbits
  let m := powMantissa nbits
  if e ≤ 3 then m / 256 ^ (3 - e) else m * 256 ^ (e - 3)

/-- Is the encoding usable? Negative, overflowing and zero targets are all
errors rather than verdicts: nothing can be at or below zero, so answering
"not met" to such a request would dress a malformed input as an opinion.
The three overflow tests are conditioned on a nonzero mantissa, matching
Bitcoin's `SetCompact` exactly. -/
def powValid (nbits : UInt32) : Bool :=
  let e := powExponent nbits
  let m := powMantissa nbits
  let negative := m != 0 && (nbits &&& 0x00800000) != 0
  let overflow := m != 0 && (e > 34 || (m > 0xFF && e > 33) || (m > 0xFFFF && e > 32))
  !negative && !overflow && powTargetValue nbits != 0

/-- The target as 32 bytes, **big**-endian: index 0 is the most significant. -/
def targetBytes (nbits : UInt32) : List (BitVec 8) :=
  (List.range 32).map fun i =>
    BitVec.ofNat 8 (powTargetValue nbits / 256 ^ (31 - i) % 256)

theorem targetBytes_length (nbits : UInt32) : (targetBytes nbits).length = 32 := by
  simp [targetBytes]

/-! ## The comparison itself -/

/-- Does `digest` meet the target encoded by `nbits`?

`digest` is 32 bytes in **emission order** — the order the hash function
produced them, the order `hashHex` prints. `none` means the encoding was
invalid.

The `.reverse` is the whole convention: the digest is read little-endian, so
the walk must see byte 31 first. Deleting it is the classic byte-order bug,
and `powCheck_iff` below is what makes deleting it fail loudly. -/
def powCheck (digest : List (BitVec 8)) (nbits : UInt32) : Option Bool :=
  if digest.length != 32 then none
  else if !powValid nbits then none
  else some (cmpBE digest.reverse (targetBytes nbits) != Ordering.gt)

/-- **The byte order is correct.** For a well-formed request, `powCheck`
answers "met" exactly when the little-endian reading of the digest is at most
the target it was asked about.

The statement mentions no bytes at all: it is about the two *numbers*, so it
is exactly the claim SPEC.md §10 makes in prose, and the byte-level walk in
`cmpBE` together with the `.reverse` in `powCheck` are what discharge it. -/
theorem powCheck_iff (digest : List (BitVec 8)) (nbits : UInt32)
    (hd : digest.length = 32) (hv : powValid nbits = true) :
    powCheck digest nbits = some true ↔
      leValue digest ≤ beValue (targetBytes nbits) := by
  have hlen : digest.reverse.length = (targetBytes nbits).length := by
    simp [hd, targetBytes_length]
  have key := cmpBE_ne_gt_iff digest.reverse (targetBytes nbits) hlen
  unfold powCheck leValue
  rw [if_neg (by simp [hd]), if_neg (by simp [hv]), Option.some.injEq, bne_iff_ne]
  exact key

end Shavar
