/-
# `Shavar.Compress` — the message schedule and the block compression

This file turns the round function of `Shavar/Round.lean` into a working
compression function: the order-16 message schedule of SPEC.md §4, the seeding
and feed-forward of SPEC.md §3, and the trace record the CLI's `trace`
subcommand prints.

Two requirements from SPEC.md §6 shape the signatures here. The compression
function takes a **caller-supplied chaining value** and a **round count**,
because free-start (chosen-IV) attacks and reduced-round distinguishers are the
point of the exercise and a library that only ever starts from the FIPS initial
value cannot express them. Neither is reachable through the ordinary hashing
API, and both are ordinary arguments here rather than special modes.

## Dependent types, second appearance

`Vector α n` is an array whose length is part of its type. `schedule` has type

    Vector (BitVec 32) 16 → Vector (BitVec 32) 64

which says, checked at compile time, that it consumes sixteen words and produces
sixty-four. Inside the loop, every index is accompanied by a proof that it is in
range — the `(by omega)` terms below. Those proofs are discharged when the file
is compiled; at runtime there are no bounds checks and no way to read off the
end of the array. Nothing here can raise an index-out-of-range error, because
no such execution exists.
-/
import Shavar.Equiv

namespace Shavar

/-! ## The message schedule (SPEC.md §4)

```
W[t] = M[t]                                              0 ≤ t < 16
W[t] = σ1(W[t-2]) ⊞ W[t-7] ⊞ σ0(W[t-15]) ⊞ W[t-16]      16 ≤ t < 64
```
-/

/--
Expand sixteen message words into the sixty-four schedule words.

The loop runs `i = 0 … 47`, filling slot `t = 16 + i`. The four back-references
are written as `14 + i`, `9 + i`, `1 + i` and `i` rather than as `t-2`, `t-7`,
`t-15`, `t-16`: they are the same indices, but phrasing them additively keeps
natural-number subtraction (which truncates at zero) out of the picture entirely.
-/
def schedule (m : Vector (BitVec 32) 16) : Vector (BitVec 32) 64 :=
  Fin.foldl 48
    (fun w i =>
      have hi : i.val < 48 := i.isLt
      w.set (16 + i.val)
        (sigma1 (w[14 + i.val]'(by omega)) + (w[9 + i.val]'(by omega))
          + sigma0 (w[1 + i.val]'(by omega)) + (w[i.val]'(by omega)))
        (by omega))
    (Vector.ofFn (fun i : Fin 64 => if h : i.val < 16 then m[i.val] else 0))

/-! ## The round inputs

Both forms of the round consume the same list of `(K[t], W[t])` pairs. Truncating
that list is exactly the reduced-round variant of SPEC.md §6 and CLI.md — there
is no separate code path for it, which is the reason the equivalence theorem of
`Shavar/Equiv.lean` covers reduced rounds for free. -/

/-- The first `rounds` pairs `(K[t], W[t])`, capped at 64. -/
def roundInputs (W : Vector (BitVec 32) 64) (rounds : Nat) : List (BitVec 32 × BitVec 32) :=
  ((List.finRange 64).take rounds).map (fun i => (K[i.val]'i.isLt, W[i.val]'i.isLt))

@[simp] theorem roundInputs_length (W : Vector (BitVec 32) 64) (rounds : Nat) :
    (roundInputs W rounds).length = min rounds 64 := by
  simp [roundInputs]

/-! ## One block

SPEC.md §3 gives the seeding, the loop, and the feed-forward:

```
A[-1] = H[0]  A[-2] = H[1]  A[-3] = H[2]  A[-4] = H[3]
E[-1] = H[4]  E[-2] = H[5]  E[-3] = H[6]  E[-4] = H[7]
                    ⋮
H[0] ⊞= A[63]   H[1] ⊞= A[62]   H[2] ⊞= A[61]   H[3] ⊞= A[60]
H[4] ⊞= E[63]   H[5] ⊞= E[62]   H[6] ⊞= E[61]   H[7] ⊞= E[60]
```

The feed-forward reads the *final window*, which is precisely the four most
recent values of each track: after the last round, `a1 = A[63]`, `a2 = A[62]`,
`a3 = A[61]`, `a4 = A[60]`, and likewise for `E`. No separate history is needed
to compute the output. -/

/-- Compress one block in the 2D form of SPEC.md §3, with a caller-supplied
chaining value `H` and a caller-chosen round count. -/
def compressBlock (H : Vector (BitVec 32) 8) (W : Vector (BitVec 32) 64)
    (rounds : Nat := 64) : Vector (BitVec 32) 8 :=
  let w := run2D (seedWindow H) (roundInputs W rounds)
  #v[H[0] + w.a1, H[1] + w.a2, H[2] + w.a3, H[3] + w.a4,
     H[4] + w.e1, H[5] + w.e2, H[6] + w.e3, H[7] + w.e4]

/-- The same block compression written in the standard eight-register form of
SPEC.md §2, for comparison. This is not used by the hash function; it exists so
that the equivalence can be stated at block level and not only at round level. -/
def compressBlockStd (H : Vector (BitVec 32) 8) (W : Vector (BitVec 32) 64)
    (rounds : Nat := 64) : Vector (BitVec 32) 8 :=
  let s := runStd (seedRegs H) (roundInputs W rounds)
  #v[H[0] + s.a, H[1] + s.b, H[2] + s.c, H[3] + s.d,
     H[4] + s.e, H[5] + s.f, H[6] + s.g, H[7] + s.h]

/--
**V1 at block level.** The whole block compression — seeding, all the rounds,
and the feed-forward — computes the same eight output words whichever of the two
forms is used, for every chaining value, every message schedule, and every round
count.

This is the form of V1 that a reader who does not care about the round function
wants: it says the 2D framing of the entire repository computes SHA-256's
compression function and not something else. It follows from `run2D_toRegs` by
rewriting the eight output components.
-/
theorem compressBlock_eq_std (H : Vector (BitVec 32) 8) (W : Vector (BitVec 32) 64)
    (rounds : Nat) : compressBlock H W rounds = compressBlockStd H W rounds := by
  have hw := run2D_toRegs (seedWindow H) (roundInputs W rounds)
  rw [seedWindow_toRegs] at hw
  -- `hw` says the final window, read as registers, is the final register state.
  -- Each output word is one field of that record, so the two outputs agree.
  simp only [compressBlock, compressBlockStd, ← hw, Window.toRegs]

/-! ## The trace (CLI.md `trace`)

The CLI has to print `W[0…63]`, `A[-4…63]`, `E[-4…63]` and `T1[t]`, `T2[t]` for
every round. That is the whole interior of the compression, which SPEC.md §6
calls for and §3 point 3 says is cheap to keep — 136 words, 544 bytes.

The tracing fold below carries the *same* `Window` that `run2D` carries and
advances it with the *same* `round2D`; the lists are pure observation. That is
recorded as `traceRun_window` so the trace cannot silently drift from the value
the hash actually uses. -/

/-- Accumulated trace state: the current window, then `A`, `E`, `T1`, `T2` in
reverse round order. -/
structure TraceAcc where
  win : Window
  as : List (BitVec 32)
  es : List (BitVec 32)
  t1s : List (BitVec 32)
  t2s : List (BitVec 32)

/-- One traced round: advance the window exactly as `round2D` does, and record
what happened. -/
def traceStep (acc : TraceAcc) (kw : BitVec 32 × BitVec 32) : TraceAcc :=
  let w := acc.win
  let w' := round2D w kw.1 kw.2
  { win := w'
    as := w'.a1 :: acc.as
    es := w'.e1 :: acc.es
    t1s := T1 w kw.1 kw.2 :: acc.t1s
    t2s := T2 w :: acc.t2s }

/-- Run the traced fold. -/
def traceRun (w : Window) (ks : List (BitVec 32 × BitVec 32)) : TraceAcc :=
  ks.foldl traceStep { win := w, as := [], es := [], t1s := [], t2s := [] }

/-- The window the tracer ends on is the window `run2D` ends on. Tracing is
observation, not a second implementation that could disagree with the first. -/
theorem traceRun_window (w : Window) (ks : List (BitVec 32 × BitVec 32)) :
    (traceRun w ks).win = run2D w ks := by
  unfold traceRun
  suffices h : ∀ (ks : List (BitVec 32 × BitVec 32)) (acc : TraceAcc),
      (ks.foldl traceStep acc).win = run2D acc.win ks by
    exact h ks _
  intro ks
  induction ks with
  | nil => intro acc; rfl
  | cons p rest ih =>
      intro acc
      obtain ⟨kt, wt⟩ := p
      simpa [List.foldl, traceStep, run2D] using ih (traceStep acc (kt, wt))

/-- The full interior of one block's compression, in the order CLI.md prints
it. `as` and `es` run from `A[-4]`/`E[-4]` upward; `t1s` and `t2s` from `t = 0`
upward. -/
structure BlockTrace where
  hin : Vector (BitVec 32) 8
  w : Vector (BitVec 32) 64
  as : List (BitVec 32)
  es : List (BitVec 32)
  t1s : List (BitVec 32)
  t2s : List (BitVec 32)
  hout : Vector (BitVec 32) 8

/-- Compress one block and keep everything. -/
def traceBlock (H : Vector (BitVec 32) 8) (W : Vector (BitVec 32) 64)
    (rounds : Nat := 64) : BlockTrace :=
  let acc := traceRun (seedWindow H) (roundInputs W rounds)
  { hin := H
    w := W
    -- A[-4], A[-3], A[-2], A[-1] are H[3], H[2], H[1], H[0] (SPEC.md §3).
    as := [H[3], H[2], H[1], H[0]] ++ acc.as.reverse
    es := [H[7], H[6], H[5], H[4]] ++ acc.es.reverse
    t1s := acc.t1s.reverse
    t2s := acc.t2s.reverse
    hout := compressBlock H W rounds }

end Shavar
