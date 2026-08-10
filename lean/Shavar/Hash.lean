/-
# `Shavar.Hash` — padding on bytes, the Merkle–Damgård loop, and hex output

`Shavar/Pad.lean` proved things about padding as a bit string. This file does
the padding an implementation actually performs — on a byte buffer — and links
the two by proving that the concrete byte-level padding produces exactly the
length the abstract bit-level padding predicts (`padBytes_length`, which is V3
transported onto the running code).
-/
import Shavar.Compress
import Shavar.Pad

namespace Shavar

/-! ## Byte-level padding (SPEC.md §5) -/

/-- The bit length `L` as eight big-endian bytes — step 3 of SPEC.md §5.
`BitVec.ofNat 8` truncates to the low eight bits, which is what taking a byte
of a larger number means. -/
def lenBytesBE (L : Nat) : List (BitVec 8) :=
  (List.range 8).map (fun i => BitVec.ofNat 8 (L / 2 ^ (8 * (7 - i))))

@[simp] theorem lenBytesBE_length (L : Nat) : (lenBytesBE L).length = 8 := by
  simp [lenBytesBE]

/--
Pad a byte buffer holding an `L`-bit message.

The `1` bit of SPEC.md §5 step 1 lands at bit offset `L`, which §5.1 places at
bit `7 - (L mod 8)` of byte `⌊L/8⌋`. When `L` is a multiple of eight that is a
fresh `0x80` byte; otherwise it is set inside the existing final byte, which is
what `0x80 >>> (L % 8)` computes. Because the caller has already been checked
against `wellFormedB`, the bits this lands next to are known to be zero, so an
`|||` is exact rather than approximate.
-/
def padBytes (msg : List (BitVec 8)) (L : Nat) : List (BitVec 8) :=
  let withOne : List (BitVec 8) :=
    if L % 8 == 0 then msg ++ [0x80]
    else msg.dropLast ++ [(msg.getLast?.getD 0) ||| (0x80 >>> (L % 8))]
  (withOne ++ List.replicate (padLen L / 8 - (L / 8 + 1) - 8) 0) ++ lenBytesBE L

/-- The byte count of the buffer carrying the `1` bit: `⌊L/8⌋ + 1` in both
branches, which is the fact that makes the length arithmetic uniform. -/
theorem withOne_length (msg : List (BitVec 8)) (L : Nat) (hm : msg.length = (L + 7) / 8) :
    (if L % 8 == 0 then msg ++ [(0x80 : BitVec 8)]
     else msg.dropLast ++ [(msg.getLast?.getD 0) ||| (0x80 >>> (L % 8))]).length
      = L / 8 + 1 := by
  by_cases h : L % 8 == 0
  · simp only [h, if_pos, List.length_append, List.length_cons, List.length_nil, hm]
    simp only [beq_iff_eq] at h
    omega
  · simp only [h, Bool.false_eq_true, ite_false, List.length_append,
      List.length_cons, List.length_nil, List.length_dropLast, hm]
    simp only [beq_iff_eq] at h
    omega

/--
**V3, transported to the implementation.** The concrete byte-level padding of a
well-sized buffer produces exactly `padLen L / 8` bytes — that is, `padLen L`
bits, which `padLen_mod_512` already showed is a multiple of 512.

This is the bridge that makes V3 a statement about the running code rather than
only about a model of it. Without it, `padLen_mod_512` would be a true fact
about an arithmetic function that the hasher might or might not implement.
-/
theorem padBytes_length (msg : List (BitVec 8)) (L : Nat) (hm : msg.length = (L + 7) / 8) :
    (padBytes msg L).length * 8 = padLen L := by
  have hw := withOne_length msg L hm
  -- The zero-fill count is nonnegative: `padLen L / 8 ≥ L/8 + 9`.
  have hroom : padLen L / 8 ≥ L / 8 + 9 := by
    unfold padLen padZeros; omega
  unfold padBytes
  simp only [List.length_append, List.length_replicate, lenBytesBE_length, hw]
  have : padLen L % 8 = 0 := padLen_mod_8 L
  omega

/-- The padded buffer is a whole number of 64-byte blocks. -/
theorem padBytes_blocks (msg : List (BitVec 8)) (L : Nat) (hm : msg.length = (L + 7) / 8) :
    (padBytes msg L).length % 64 = 0 := by
  have h := padBytes_length msg L hm
  have h512 := padLen_mod_512 L
  omega

/-! ## Bytes to words

Four bytes make a word, most significant byte first (SPEC.md §1).

`b0 ++ b1` is `BitVec` concatenation: it produces a `BitVec 16` with `b0` in the
high half. The widths are checked by the compiler — `(b0 ++ b1) ++ (b2 ++ b3)`
is a `BitVec (8+8+(8+8))`, and Lean only accepts it as a `BitVec 32` because
those are the same number. Byte-order bugs of the "off by one shift" kind cannot
be written down in this style. -/

/-- Assemble four bytes into a big-endian 32-bit word. -/
def be32 (b0 b1 b2 b3 : BitVec 8) : BitVec 32 := (b0 ++ b1) ++ (b2 ++ b3)

/-- The sixteen words of block `blk` of a padded buffer. Indices past the end
read as zero; `padBytes_blocks` guarantees that never happens for a buffer this
function is actually called on. -/
def blockWords (bs : Array (BitVec 8)) (blk : Nat) : Vector (BitVec 32) 16 :=
  Vector.ofFn (fun i : Fin 16 =>
    let o := blk * 64 + i.val * 4
    be32 (bs.getD o 0) (bs.getD (o + 1) 0) (bs.getD (o + 2) 0) (bs.getD (o + 3) 0))

/-! ## The hash -/

/--
The full SHA-256 of an `L`-bit message held in `msg`.

`rounds` and `H0` are exposed as arguments because SPEC.md §6 requires it:
`H0` gives free-start / chosen-IV work, `rounds` gives reduced-round variants.
Both default to the FIPS values, so an ordinary caller writes
`hashBytes msg L` and gets SHA-256.
-/
def hashBytes (msg : List (BitVec 8)) (L : Nat)
    (rounds : Nat := 64) (H0 : Vector (BitVec 32) 8 := IV) : Vector (BitVec 32) 8 :=
  let padded := (padBytes msg L).toArray
  let nblocks := padded.size / 64
  (List.range nblocks).foldl
    (fun H i => compressBlock H (schedule (blockWords padded i)) rounds) H0

/-- The same, using the eight-register form of SPEC.md §2 for the compression.
Only used to state the top-level consequence of V1 below. -/
def hashBytesStd (msg : List (BitVec 8)) (L : Nat)
    (rounds : Nat := 64) (H0 : Vector (BitVec 32) 8 := IV) : Vector (BitVec 32) 8 :=
  let padded := (padBytes msg L).toArray
  let nblocks := padded.size / 64
  (List.range nblocks).foldl
    (fun H i => compressBlockStd H (schedule (blockWords padded i)) rounds) H0

/--
**V1 at the top level.** The hash function this repository ships, written in the
2D form of SPEC.md §3, computes the same digest as the same function written in
the eight-register form of FIPS 180-4 — for every message, every bit length,
every round count and every starting chaining value.

This is the end of the chain that begins with `round2D_toRegs` (one round),
passes through `run2D_toRegs` (any number of rounds) and
`compressBlock_eq_std` (one block including seeding and feed-forward), and
arrives here at the whole Merkle–Damgård iteration. It is the sentence
SPEC.md's opening paragraph asserts, made checkable.
-/
theorem hashBytes_eq_std (msg : List (BitVec 8)) (L rounds : Nat)
    (H0 : Vector (BitVec 32) 8) :
    hashBytes msg L rounds H0 = hashBytesStd msg L rounds H0 := by
  unfold hashBytes hashBytesStd
  -- The two folds differ only in the function applied at each block, and
  -- `compressBlock_eq_std` says those functions are equal.
  simp only [compressBlock_eq_std]

/-! ## Hexadecimal output (CLI.md)

CLI.md is strict: 64 lowercase hex digits and a single newline for `hash`, and
exactly eight zero-padded lowercase digits per word in `trace`. -/

/-- One lowercase hex digit. -/
def hexDigit (n : Nat) : Char :=
  if n < 10 then Char.ofNat (n + 48) else Char.ofNat (n + 87)

/-- A 32-bit word as exactly eight lowercase hex digits, zero-padded. -/
def hex8 (x : BitVec 32) : String :=
  String.ofList ((List.range 8).map (fun i => hexDigit ((x.toNat >>> (4 * (7 - i))) % 16)))

/-- A digest as 64 lowercase hex digits. -/
def digestHex (H : Vector (BitVec 32) 8) : String :=
  String.join (H.toList.map hex8)

/-- Convenience: hash and format. -/
def hashHex (msg : List (BitVec 8)) (L : Nat) (rounds : Nat := 64) : String :=
  digestHex (hashBytes msg L rounds)

/-! ## The valid range of `rounds` (SPEC.md §6.1)

`hashBytes` is a total function, so it has to do *something* when handed a
round count above 64. What it does is take the first `rounds` entries of a
64-element list via `roundInputs`, which silently yields all 64 — so asking
for 100 rounds returns genuine SHA-256 with no indication of trouble. That is
the failure mode SPEC.md §6.1 rules out.

`hashBytes?` below is therefore the checked entry point, and it is the one the
CLI and the test drivers use. `hashBytes` is kept unchecked because the proofs
in `Equiv.lean` and `hashBytes_eq_std` quantify over all round counts and want
a total function with no `Option` to thread through.

A note on what is claimed: the clamping behaviour described above is **stated,
not proved**. An attempt at `hashBytes msg L rounds = hashBytes msg L 64` for
`64 ≤ rounds` is true and provable in principle, but every route tried through
`List.take_of_length_le` on `List.finRange 64` sent elaboration into the
sixty-four concrete index terms and did not terminate in a usable time. It was
dropped rather than left half-finished or papered over with `native_decide`,
which would have added a compiler-trust axiom to a file that has none. The
range check itself is *tested*, in all eight builds, by `tests/rounds.sh`. The
repository keeps the proved/tested line sharp and this is on the tested side.

The same hazard existed in all seven implementations and was reachable in four
different ways — C and Lean clamped, Perl and shell ran off the end of `K`,
Scheme crashed. Only Python and JavaScript refused. See `tests/rounds.sh`. -/

/-- The checked entry point: `none` when `rounds` is outside 0…64.

Lean's `Nat` cannot be negative, so unlike the C, Perl and shell versions
there is no lower bound to test — 0 is legal and means feed-forward only. -/
def hashBytes? (msg : List (BitVec 8)) (L : Nat)
    (rounds : Nat := 64) (H0 : Vector (BitVec 32) 8 := IV) :
    Option (Vector (BitVec 32) 8) :=
  if rounds > 64 then none else some (hashBytes msg L rounds H0)

/-- `hashHex` with the same range check. -/
def hashHex? (msg : List (BitVec 8)) (L : Nat) (rounds : Nat := 64) :
    Option String :=
  (hashBytes? msg L rounds).map digestHex

end Shavar
