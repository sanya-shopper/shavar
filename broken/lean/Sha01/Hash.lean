/-
# `Sha01.Hash` — the executable side

`Sha01.Expansion` defines the schedule as a recursive function of the round
index, which is the shape the proofs want and a terrible shape to evaluate:
each word calls itself four times, so computing round 79 that way is
exponential. This file carries a second, linear-time schedule built by
iteration, and the two are checked against each other by `#guard` over the
range where the recursive one is still cheap to run.

That check is a **test, not a proof**, and the distinction is the repository's
usual one: `sha0_expand_mask` is proved about the recursive definition, and the
executable path here is evidence-by-agreement — with `sched`, with the C
implementation in `../../c/`, and through it with three external SHA-1 oracles.
-/
import Sha01.Expansion

namespace Sha01

/-! ## A linear-time schedule -/

/-- The expanded schedule, `n` words, built by iteration rather than by
recursion on the index. Same recurrence as `W`; see the note above. -/
def sched (M : Nat → BitVec 32) (rot n : Nat) : Array (BitVec 32) :=
  (List.range n).foldl
    (fun acc t =>
      if t < 16 then acc.push (M t)
      else acc.push (rotl rot (acc[t - 3]! ^^^ acc[t - 8]!
                               ^^^ acc[t - 14]! ^^^ acc[t - 16]!)))
    (Array.emptyWithCapacity n)

/-- Schedule word `t`, evaluated efficiently. -/
def schedAt (M : Nat → BitVec 32) (rot t : Nat) : BitVec 32 :=
  (sched M rot (t + 1))[t]!

/-! ## Compression (FIPS 180-1 §7) -/

/-- The five working registers. -/
structure St where
  a : BitVec 32
  b : BitVec 32
  c : BitVec 32
  d : BitVec 32
  e : BitVec 32
  deriving Repr, DecidableEq

/-- One round. The rotation by 30 in the middle is what stops SHA-1 from
collapsing into a pair of clean recurrences the way SHA-256 does. -/
def step (t : Nat) (Wt : BitVec 32) (s : St) : St :=
  let temp := rotl 5 s.a + f t s.b s.c s.d + s.e + Wt + K t
  { a := temp, b := s.a, c := rotl 30 s.b, d := s.c, e := s.d }

/-- Compress one block, given its sixteen words. -/
def compress (h : Vector (BitVec 32) 5) (M : Nat → BitVec 32)
    (v : Variant) (rounds : Nat) : Vector (BitVec 32) 5 :=
  let Ws := sched M v.rot (max rounds 16)
  let s0 : St := { a := h[0], b := h[1], c := h[2], d := h[3], e := h[4] }
  let s := (List.range rounds).foldl (fun s t => step t (Ws[t]!) s) s0
  #v[h[0] + s.a, h[1] + s.b, h[2] + s.c, h[3] + s.d, h[4] + s.e]

/-! ## Padding (FIPS 180 §4)

Identical in both functions, and the same construction `../../spec/SPEC.md` §5
describes for SHA-256 apart from the digest size: a `1` bit, zeros, then the
length in **bits** as a 64-bit big-endian integer. -/

def lenBytesBE (n : Nat) : List (BitVec 8) :=
  (List.range 8).map (fun i => BitVec.ofNat 8 (n / 2 ^ (8 * (7 - i))))

def padBytes (msg : List (BitVec 8)) : List (BitVec 8) :=
  let len := msg.length
  let k := (56 + 64 - ((len + 1) % 64)) % 64
  msg ++ [0x80] ++ List.replicate k 0 ++ lenBytesBE (len * 8)

def be32 (b0 b1 b2 b3 : BitVec 8) : BitVec 32 := (b0 ++ b1) ++ (b2 ++ b3)

/-- The sixteen words of block `blk`. -/
def blockWords (bs : Array (BitVec 8)) (blk : Nat) : Nat → BitVec 32 :=
  fun i =>
    let o := blk * 64 + i * 4
    be32 (bs[o]!) (bs[o + 1]!) (bs[o + 2]!) (bs[o + 3]!)

/-- The digest of a byte message, as five words. -/
def hashBytes (msg : List (BitVec 8)) (v : Variant) (rounds : Nat := 80) :
    Vector (BitVec 32) 5 :=
  let p := (padBytes msg).toArray
  let nblocks := p.size / 64
  (List.range nblocks).foldl (fun h i => compress h (blockWords p i) v rounds) IV

/-! ## Hex -/

def hexDigit (n : Nat) : Char :=
  if n < 10 then Char.ofNat (n + 48) else Char.ofNat (n + 87)

def hex8 (x : BitVec 32) : String :=
  String.ofList ((List.range 8).map (fun i => hexDigit ((x.toNat >>> (4 * (7 - i))) % 16)))

def digestHex (H : Vector (BitVec 32) 5) : String :=
  String.join (H.toList.map hex8)

def hashHex (msg : List (BitVec 8)) (v : Variant) (rounds : Nat := 80) : String :=
  digestHex (hashBytes msg v rounds)

/-! ## Checks run at build time

The two schedules must agree. `W` is exponential in the round index, so this
is checked over the range where it is still cheap — enough to catch a
transcription slip between the two definitions, not a proof that they agree
everywhere. -/

def probeMsg : Nat → BitVec 32 := fun k => BitVec.ofNat 32 (k * 0x01234567 + 89)

#guard (List.range 20).all (fun t => schedAt probeMsg 0 t == W probeMsg 0 t)
#guard (List.range 20).all (fun t => schedAt probeMsg 1 t == W probeMsg 1 t)

/-- "abc" -/
def abc : List (BitVec 8) := [0x61, 0x62, 0x63]

-- SHA-1("abc") is checkable against any SHA-1 in the world; SHA-0("abc") is
-- the published value, and `../../tests/run.sh` pins it by the structural
-- route as well.
#guard hashHex abc .sha1 == "a9993e364706816aba3e25717850c26c9cd0d89d"
#guard hashHex abc .sha0 == "0164b8a914cd2a5e74c4f7ff082c4d97f1edf880"
#guard hashHex [] .sha1 == "da39a3ee5e6b4b0d3255bfef95601890afd80709"
#guard hashHex [] .sha0 == "f96cea198ad1dd5617ac084a3d92c6107708c0ef"

end Sha01
