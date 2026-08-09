/-
# `Shavar.Round` — the two ways of writing the SHA-256 round

This file writes down *both* forms of the compression round, independently and
honestly, so that `Shavar/Equiv.lean` can prove them equal. Nothing here refers
to the other form; neither definition is stated in terms of the other. If they
were, the equivalence theorem would be vacuous.

* `roundStd` is FIPS 180-4 / SPEC.md §2 — eight named registers `a…h`, six of
  whose eight assignments are copies.
* `round2D` is SPEC.md §3 — two coupled recurrences `A[t]`, `E[t]` with a
  lookback of four.

## What "equal" will mean

The claim of SPEC.md §3 is that the eight registers are two sliding windows of
width four. So the 2D state is exactly the eight words

    A[t-1] A[t-2] A[t-3] A[t-4]   E[t-1] E[t-2] E[t-3] E[t-4]

and the correspondence with the register names is the one written out in §3:

    a = A[t-1]   b = A[t-2]   c = A[t-3]   d = A[t-4]
    e = E[t-1]   f = E[t-2]   g = E[t-3]   h = E[t-4]

That correspondence is the function `Window.toRegs` below. The theorem in
`Equiv.lean` says that `toRegs` commutes with the two round functions: advancing
in the 2D world and then translating gives the same eight words as translating
and then advancing in the register world.
-/
import Shavar.Words

namespace Shavar

/-! ## The standard eight-register form (SPEC.md §2) -/

/-- The eight FIPS 180-4 working variables. A `structure` is a record; the
fields are named exactly as the standard names them. -/
structure Regs where
  a : BitVec 32
  b : BitVec 32
  c : BitVec 32
  d : BitVec 32
  e : BitVec 32
  f : BitVec 32
  g : BitVec 32
  h : BitVec 32
deriving Repr, DecidableEq, Inhabited

/-- One round of the standard form, transcribed line for line from SPEC.md §2:

```
T1 = h ⊞ Σ1(e) ⊞ Ch(e,f,g) ⊞ K[t] ⊞ W[t]
T2 = Σ0(a) ⊞ Maj(a,b,c)
h = g;  g = f;  f = e;  e = d ⊞ T1
d = c;  c = b;  b = a;  a = T1 ⊞ T2
```

In Lean the eight assignments become one record built from the *old* values, so
the sequencing subtlety of the imperative version (all right-hand sides read the
pre-round state) is automatic rather than something the reader has to check. -/
def roundStd (s : Regs) (kt wt : BitVec 32) : Regs :=
  let t1 := s.h + Sigma1 s.e + Ch s.e s.f s.g + kt + wt
  let t2 := Sigma0 s.a + Maj s.a s.b s.c
  { a := t1 + t2
    b := s.a
    c := s.b
    d := s.c
    e := s.d + t1
    f := s.e
    g := s.f
    h := s.g }

/-! ## The two-dimensional form (SPEC.md §3) -/

/-- The state of the order-4 recurrence: the last four values of each track.
Field `aN` is `A[t-N]` and field `eN` is `E[t-N]`, where `t` is the round about
to be computed. This is the whole state — there is nothing else to carry. -/
structure Window where
  a1 : BitVec 32   -- A[t-1]
  a2 : BitVec 32   -- A[t-2]
  a3 : BitVec 32   -- A[t-3]
  a4 : BitVec 32   -- A[t-4]
  e1 : BitVec 32   -- E[t-1]
  e2 : BitVec 32   -- E[t-2]
  e3 : BitVec 32   -- E[t-3]
  e4 : BitVec 32   -- E[t-4]
deriving Repr, DecidableEq, Inhabited

/-- `T1[t] = E[t-4] ⊞ Σ1(E[t-1]) ⊞ Ch(E[t-1], E[t-2], E[t-3]) ⊞ K[t] ⊞ W[t]`.

Kept as its own definition rather than inlined, because SPEC.md §7.1 asks that
`Ch`, `Maj` and each `⊞` stay separately addressable for cryptanalytic use, and
because the CLI's `trace` subcommand has to print `T1` per round. -/
def T1 (w : Window) (kt wt : BitVec 32) : BitVec 32 :=
  w.e4 + Sigma1 w.e1 + Ch w.e1 w.e2 w.e3 + kt + wt

/-- `T2[t] = Σ0(A[t-1]) ⊞ Maj(A[t-1], A[t-2], A[t-3])`. -/
def T2 (w : Window) : BitVec 32 :=
  Sigma0 w.a1 + Maj w.a1 w.a2 w.a3

/-- One step of the 2D recurrence:

```
E[t] = A[t-4] ⊞ T1[t]
A[t] = T1[t] ⊞ T2[t]
```

followed by sliding both windows. The "sliding" is the assignments
`a2 := w.a1` and so on; SPEC.md §3 observes that this is precisely what the six
copy-assignments of the standard form were doing. -/
def round2D (w : Window) (kt wt : BitVec 32) : Window :=
  let t1 := T1 w kt wt
  let t2 := T2 w
  { a1 := t1 + t2      -- A[t]
    a2 := w.a1         -- A[t-1] slides into the A[t-2] slot
    a3 := w.a2
    a4 := w.a3
    e1 := w.a4 + t1    -- E[t]
    e2 := w.e1
    e3 := w.e2
    e4 := w.e3 }

/-! ## The correspondence of SPEC.md §3 -/

/-- The window correspondence, verbatim from SPEC.md §3:
`a = A[t-1]`, `b = A[t-2]`, `c = A[t-3]`, `d = A[t-4]`,
`e = E[t-1]`, `f = E[t-2]`, `g = E[t-3]`, `h = E[t-4]`. -/
def Window.toRegs (w : Window) : Regs :=
  { a := w.a1, b := w.a2, c := w.a3, d := w.a4
    e := w.e1, f := w.e2, g := w.e3, h := w.e4 }

/-- The same correspondence read the other way. -/
def Regs.toWindow (s : Regs) : Window :=
  { a1 := s.a, a2 := s.b, a3 := s.c, a4 := s.d
    e1 := s.e, e2 := s.f, e3 := s.g, e4 := s.h }

/-! ## Running many rounds

Both forms are iterated over the *same* list of `(K[t], W[t])` pairs. Using a
list rather than a fixed count of 64 costs nothing and buys the reduced-round
variant that SPEC.md §6 requires for cryptanalysis: run `n` rounds by handing
over a list of length `n`. The equivalence theorem then holds for every round
count at once, with no extra work. -/

/-- Iterate the standard round over a list of `(K[t], W[t])` pairs. -/
def runStd (s : Regs) : List (BitVec 32 × BitVec 32) → Regs
  | [] => s
  | (kt, wt) :: rest => runStd (roundStd s kt wt) rest

/-- Iterate the 2D round over a list of `(K[t], W[t])` pairs. -/
def run2D (w : Window) : List (BitVec 32 × BitVec 32) → Window
  | [] => w
  | (kt, wt) :: rest => run2D (round2D w kt wt) rest

end Shavar
