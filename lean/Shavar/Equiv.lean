/-
# `Shavar.Equiv` — V1, the headline theorem

**Obligation V1 (SPEC.md §8):** *the 2D recurrence equals the 8-register form,
for one round and hence for 64.*

This file discharges it. Everything else in `lean/` is supporting material; this
is the theorem that justifies the whole framing of the project. If it were
false, every implementation in the repository would be computing something that
is not SHA-256.

## Reading the theorem statements without knowing Lean

A Lean theorem is a claim followed by a machine-checked justification. The claim
is everything between the theorem's name and the `:=`; the justification is the
`by …` script after it. The reader who does not know Lean can ignore the scripts
entirely and read only the claims — that is the point of the exercise. The
scripts are for the machine.

Two symbols carry the weight below:

* `=` between two `Regs` values means "these two eight-word records are equal,
  field by field". It is not approximate and not up to any convention.
* `∀ w kt wt, …` means "for every window `w` and every pair of round inputs".
  There is no sampling and no test corpus: the statement quantifies over all
  2³²ˣ⁸ windows and all 2³²ˣ² inputs simultaneously.

## Why this is not circular

`roundStd` and `round2D` are written out separately in `Shavar/Round.lean`.
Neither is defined in terms of the other, and neither mentions the translation
function. The translation `Window.toRegs` is the correspondence stated in
SPEC.md §3 and nothing more: it renames eight fields. So the theorem below has
real content — it says that this particular renaming turns one algorithm into
the other.
-/
import Shavar.Round

namespace Shavar

/-! ## One round -/

/--
**V1, one round.** Advancing the 2D recurrence and then reading off the eight
register names gives exactly the same eight words as reading off the register
names first and then advancing the standard round.

In the notation of SPEC.md §3: if at the top of round `t` we have
`a = A[t-1]`, `b = A[t-2]`, `c = A[t-3]`, `d = A[t-4]`, `e = E[t-1]`,
`f = E[t-2]`, `g = E[t-3]`, `h = E[t-4]`, then at the top of round `t+1` the
same correspondence holds, with the window shifted by one.

The proof is `rfl` — "these two expressions are the same expression once you
unfold the definitions". That is the strongest possible outcome: the two round
functions are not merely provably equal, they are *definitionally* equal, which
is Lean's way of confirming SPEC.md's claim that the register shuffle "was never
computation". The six copy-assignments and the six field-slides are literally
the same six words appearing in different slots of a record.
-/
theorem round2D_toRegs (w : Window) (kt wt : BitVec 32) :
    (round2D w kt wt).toRegs = roundStd w.toRegs kt wt := rfl

/-
An honest note on how *hard* the theorem above is. It is not hard: `rfl`
succeeds, so once `Window.toRegs` is unfolded the two sides are the same term.
A reader is entitled to ask whether that makes the claim empty.

It does not, but it is worth being precise about what it does and does not say.
What it says is that the correspondence SPEC.md §3 writes down — that particular
assignment of eight register names to eight window slots, and no other — turns
one round of §2 into one round of §3 exactly, with nothing left over. Had the
correspondence been off by one slot, or had `E[t] = A[t-4] ⊞ T1[t]` used
`A[t-3]`, `rfl` would fail and so would every other tactic, because the claim
would be false. The theorem is the check that the framing is right.

What it does *not* say is anything about the loop. That the correspondence is
*preserved* across a whole block is `run2D_toRegs` below, which needs an
induction and is not `rfl`: `run2D` and `runStd` are separate recursive
functions over a list of unknown length, and no amount of unfolding relates
them. The interesting content of V1 lives there.
-/

/-- The translation is a bijection: reading a window as registers and back is
the identity. Needed so that V1 can be stated starting from either side. -/
@[simp] theorem toWindow_toRegs (w : Window) : w.toRegs.toWindow = w := rfl

/-- …and in the other direction. -/
@[simp] theorem toRegs_toWindow (s : Regs) : s.toWindow.toRegs = s := rfl

/-- **V1, one round, stated from the register side.** Same content as
`round2D_toRegs`, phrased for a reader who thinks of the eight registers as
primary: one standard round is the 2D step performed on the corresponding
window. -/
theorem roundStd_toWindow (s : Regs) (kt wt : BitVec 32) :
    roundStd s kt wt = (round2D s.toWindow kt wt).toRegs := rfl

/-! ## All rounds -/

/--
**V1, the full theorem.** For *any* sequence of round inputs `ks` — of any
length, so in particular the 64 pairs `(K[t], W[t])` of a real SHA-256 block,
and equally the reduced-round variants SPEC.md §6 requires — running the 2D
recurrence and translating agrees with translating and running the standard
eight-register loop.

`ks : List (BitVec 32 × BitVec 32)` is the list of `(K[t], W[t])` pairs. `ks.length = 64`
is the standard case; nothing in the proof depends on that number.

The proof is induction on the list. The base case (`nil`, zero rounds) is
`rfl`. The inductive step (`cons`) does one round with `round2D_toRegs` above
and appeals to the induction hypothesis for the rest. `generalizing w` is what
makes the induction hypothesis apply to the *advanced* window rather than only
to the starting one — the standard shape for a proof about a loop with
changing state.
-/
theorem run2D_toRegs (w : Window) (ks : List (BitVec 32 × BitVec 32)) :
    (run2D w ks).toRegs = runStd w.toRegs ks := by
  induction ks generalizing w with
  | nil => rfl
  | cons p rest ih =>
      obtain ⟨kt, wt⟩ := p
      -- One round on each side, then the induction hypothesis.
      simp only [run2D, runStd, ← round2D_toRegs, ih]

/-- **V1, the full theorem, from the register side.** -/
theorem runStd_toWindow (s : Regs) (ks : List (BitVec 32 × BitVec 32)) :
    runStd s ks = (run2D s.toWindow ks).toRegs := by
  rw [run2D_toRegs, toRegs_toWindow]

/-! ## The 64-round instance, spelled out

`run2D_toRegs` already covers 64 rounds, but SPEC.md §8 phrases V1 as "for one
round and hence for 64", so we state that instance separately rather than
leaving the reader to instantiate it. -/

/-- **V1 at exactly 64 rounds.** -/
theorem run2D_toRegs_64 (w : Window) (ks : List (BitVec 32 × BitVec 32)) (_h : ks.length = 64) :
    (run2D w ks).toRegs = runStd w.toRegs ks :=
  run2D_toRegs w ks

/-! ## The seeding and the feed-forward

V1 as stated is about the *loop*. A complete SHA-256 block also seeds the loop
from the incoming chaining value and adds the result back in (the
Merkle–Damgård feed-forward). SPEC.md §3 gives the 2D seeding as

    A[-1] = H[0]  A[-2] = H[1]  A[-3] = H[2]  A[-4] = H[3]
    E[-1] = H[4]  E[-2] = H[5]  E[-3] = H[6]  E[-4] = H[7]

and the output as `H[0] ⊞= A[63]`, `H[1] ⊞= A[62]`, … The standard form seeds
`a…h := H[0…7]` and adds back `a…h`. Under `Window.toRegs` those are the same
two operations, which the next two lemmas record so that the block-level
equivalence in `Shavar/Compress.lean` is a one-liner. -/

/-- Seeding: the 2D seeding of SPEC.md §3 and the register seeding
`a…h := H[0…7]` describe the same eight words. -/
def seedWindow (H : Vector (BitVec 32) 8) : Window :=
  { a1 := H[0], a2 := H[1], a3 := H[2], a4 := H[3]
    e1 := H[4], e2 := H[5], e3 := H[6], e4 := H[7] }

/-- The register-form seeding. -/
def seedRegs (H : Vector (BitVec 32) 8) : Regs :=
  { a := H[0], b := H[1], c := H[2], d := H[3]
    e := H[4], f := H[5], g := H[6], h := H[7] }

/-- The two seedings agree under the §3 correspondence. -/
@[simp] theorem seedWindow_toRegs (H : Vector (BitVec 32) 8) :
    (seedWindow H).toRegs = seedRegs H := rfl

end Shavar
