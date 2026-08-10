/-
# `Sha01.Basic` — SHA-0 and SHA-1 in Lean 4

Both functions, from FIPS 180 (1993) and FIPS 180-1 (1995). They differ in one
place only: SHA-1 rotates the message-expansion feedback left by one bit and
SHA-0 does not, which is carried here as a single `rot` parameter.

Neither is safe to use. This exists so that `Sha01.Expansion` can *prove* the
structural property the collision attacks exploit, rather than only exhibit it
the way `../attack/expansion.c` does.

`BitVec 32` rather than `UInt32`, for the same reason `../../lean/` uses it:
the bitvector tactics reason about `BitVec`.
-/

namespace Sha01

/-! ## Words -/

/-- Rotate left. `BitVec.rotateLeft` already means this; the wrapper exists so
that the expansion below can take the rotation amount as a parameter and so
that `rotl 0` is visibly the identity. -/
def rotl (n : Nat) (x : BitVec 32) : BitVec 32 := x.rotateLeft n

@[simp] theorem rotl_zero (x : BitVec 32) : rotl 0 x = x := by
  simp only [rotl, BitVec.rotateLeft, BitVec.rotateLeftAux, Nat.sub_zero]
  ext i
  simp

/-- Which of the two functions. The value *is* the rotation amount, which is
the entire difference between them. -/
inductive Variant where
  | sha0 : Variant
  | sha1 : Variant
  deriving DecidableEq, Repr

def Variant.rot : Variant → Nat
  | .sha0 => 0
  | .sha1 => 1

/-! ## The three round functions (FIPS 180-1 §5)

`parity` is GF(2)-linear and the other two are not, which is why an attacker's
disturbance vector wants its weight in rounds 20–39 and 60–79. -/

def ch     (b c d : BitVec 32) : BitVec 32 := (b &&& c) ^^^ (~~~b &&& d)
def parity (b c d : BitVec 32) : BitVec 32 := b ^^^ c ^^^ d
def maj    (b c d : BitVec 32) : BitVec 32 := (b &&& c) ^^^ (b &&& d) ^^^ (c &&& d)

def f (t : Nat) (b c d : BitVec 32) : BitVec 32 :=
  if t < 20 then ch b c d
  else if t < 40 then parity b c d
  else if t < 60 then maj b c d
  else parity b c d

/-- One constant per twenty rounds: ⌊2³⁰√2⌋, ⌊2³⁰√3⌋, ⌊2³⁰√5⌋, ⌊2³⁰√10⌋. -/
def K (t : Nat) : BitVec 32 :=
  if t < 20 then 0x5A827999
  else if t < 40 then 0x6ED9EBA1
  else if t < 60 then 0x8F1BBCDC
  else 0xCA62C1D6

/-- The FIPS 180 initial chaining value, shared by both functions. -/
def IV : Vector (BitVec 32) 5 :=
  #v[0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]

end Sha01
