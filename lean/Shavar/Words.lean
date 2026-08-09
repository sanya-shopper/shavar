/-
# `Shavar.Words` — the 32-bit word layer

This file defines the six auxiliary functions of SHA-256 (SPEC.md §1.1) and the
two constant tables (SPEC.md §9). Everything else in the project is built on top
of it.

## A note for readers who do not know Lean

Lean 4 is both a programming language and a proof assistant. The same text is
compiled to a running program *and* checked as mathematics. Three pieces of
syntax cover most of what appears below:

* `def name (arg : Type) : ResultType := body` introduces a definition. It is an
  ordinary function; there is nothing proof-specific about it.
* `theorem name : statement := by tactic` introduces a claim together with a
  proof script. The system will not accept the file unless the script really
  establishes the claim.
* `Vector α n` is an array whose length is part of its type.

We use `BitVec 32` — Lean's type of 32-bit vectors — rather than `UInt32`.
The two compute the same answers, but `BitVec` is the type the `bv_decide`
tactic understands, and `bv_decide` is how the bit-level obligations of
SPEC.md §8 (V2) are discharged. Choosing the representation that the automation
speaks is the single most consequential design decision in this directory.

`BitVec 32` is a *dependent type*: the width `32` is part of the type, not a
runtime property. Adding a `BitVec 32` to a `BitVec 64` is not a bug that shows
up in a test, it is a phrase the compiler refuses to parse. Width confusion —
a real source of defects in C SHA implementations — is therefore not a class of
error that can occur here at all.
-/
import Std.Tactic.BVDecide

namespace Shavar

/-! ## Rotations and shifts

Every signature below spells out `BitVec 32` rather than using a friendlier
alias such as `abbrev Word := BitVec 32`. That is deliberate and was learned the
hard way: an alias, even a fully-reducible one, survives in the *instance
arguments* of the elaborated term (`@HShiftRight.hShiftRight Word Nat …`), and
`bv_decide`'s bit-blaster matches those arguments syntactically. With the alias
in place it silently treats `x >>> 3` as an opaque unknown and then reports a
spurious counterexample. The verbose spelling is the price of keeping the
automation working. -/

/-- `ROTR^n(x)` of SPEC.md §1: circular right rotation by `n`. -/
def rotr (n : Nat) (x : BitVec 32) : BitVec 32 := x.rotateRight n

/-- `SHR^n(x)` of SPEC.md §1: logical right shift by `n`, zero-filled. -/
def shr (n : Nat) (x : BitVec 32) : BitVec 32 := x >>> n

/-! ## The six round functions (SPEC.md §1.1)

These are transcribed from the specification without any of the usual
"optimisations". Keeping them in spec form and proving the optimised forms
equal to them (see `Shavar/BitIdentities.lean`) is the point: the reader checks
the code against FIPS 180-4 by eye, and the machine checks the optimisation. -/

/-- `Ch(x,y,z) = (x ∧ y) ⊕ (¬x ∧ z)` — "choose": bit `i` of `x` picks between
bit `i` of `y` and bit `i` of `z`. -/
def Ch (x y z : BitVec 32) : BitVec 32 := (x &&& y) ^^^ ((~~~x) &&& z)

/-- `Maj(x,y,z) = (x ∧ y) ⊕ (x ∧ z) ⊕ (y ∧ z)` — "majority": bit `i` is
whichever value occurs at least twice among the three inputs. -/
def Maj (x y z : BitVec 32) : BitVec 32 := (x &&& y) ^^^ (x &&& z) ^^^ (y &&& z)

/-- `Σ0(x) = ROTR²(x) ⊕ ROTR¹³(x) ⊕ ROTR²²(x)`. Used on the `A` track. -/
def Sigma0 (x : BitVec 32) : BitVec 32 := rotr 2 x ^^^ rotr 13 x ^^^ rotr 22 x

/-- `Σ1(x) = ROTR⁶(x) ⊕ ROTR¹¹(x) ⊕ ROTR²⁵(x)`. Used on the `E` track. -/
def Sigma1 (x : BitVec 32) : BitVec 32 := rotr 6 x ^^^ rotr 11 x ^^^ rotr 25 x

/-- `σ0(x) = ROTR⁷(x) ⊕ ROTR¹⁸(x) ⊕ SHR³(x)`. Used on the message schedule. -/
def sigma0 (x : BitVec 32) : BitVec 32 := rotr 7 x ^^^ rotr 18 x ^^^ shr 3 x

/-- `σ1(x) = ROTR¹⁷(x) ⊕ ROTR¹⁹(x) ⊕ SHR¹⁰(x)`. Used on the message schedule. -/
def sigma1 (x : BitVec 32) : BitVec 32 := rotr 17 x ^^^ rotr 19 x ^^^ shr 10 x

/-! ## Constants (SPEC.md §9)

`Vector α n` is a length-indexed array: its *type* records that it holds
exactly `n` elements. Writing `K[t]` for `t : Fin 64` therefore needs no bounds
check and cannot fail — the well-formedness is discharged when the file is
compiled, not when the program runs. This is the second place dependent types
earn their keep here (the first was `BitVec 32`). -/

/-- Initial chaining value `H[0…7]`: the first 32 bits of the fractional parts
of the square roots of the first eight primes. -/
def IV : Vector (BitVec 32) 8 :=
  #v[0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
     0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]

/-- Round constants `K[0…63]`: the first 32 bits of the fractional parts of the
cube roots of the first sixty-four primes. -/
def K : Vector (BitVec 32) 64 :=
  #v[0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
     0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
     0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
     0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
     0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
     0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
     0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
     0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
     0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
     0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
     0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
     0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
     0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
     0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
     0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
     0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]

end Shavar
