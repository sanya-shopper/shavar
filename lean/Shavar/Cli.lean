/-
# `Shavar.Cli` — argument parsing, the known-answer vectors, and output shaping

CLI.md fixes the encoding down to the character: lowercase hex, single tabs, one
trailing newline, diagnostics on stderr only. This file implements that contract;
`Main.lean` is a three-line wrapper around it.

The pieces that matter for correctness rather than formatting are:

* `parseHex`, which rejects malformed input rather than guessing, and
* the well-formedness check, which is `Shavar.wellFormedB` from
  `Shavar/Pad.lean` — the *same* predicate that appears as a hypothesis of the
  injectivity theorem `pad_injective_bytes`. The runtime check and the proof
  obligation are one function, so the theorem is about this program and not
  about an idealisation of it.
-/
import Shavar.Hash

namespace Shavar

/-! ## Hex input -/

/-- The value of a single hex digit, or `none` if the character is not one. -/
def hexVal (c : Char) : Option Nat :=
  if '0' ≤ c && c ≤ '9' then some (c.toNat - 48)
  else if 'a' ≤ c && c ≤ 'f' then some (c.toNat - 87)
  else if 'A' ≤ c && c ≤ 'F' then some (c.toNat - 55)
  else none

/-- Parse a list of hex characters, two at a time, into bytes. -/
def hexChars : List Char → Option (List (BitVec 8))
  | [] => some []
  | a :: b :: rest => do
      let x ← hexVal a
      let y ← hexVal b
      let t ← hexChars rest
      pure (BitVec.ofNat 8 (16 * x + y) :: t)
  | _ => none

/-- Parse the `<hex>` argument. CLI.md: the single character `-` denotes a
zero-byte message; otherwise an even number of hex digits, either case. -/
def parseHex (s : String) : Option (List (BitVec 8)) :=
  if s == "-" then some [] else hexChars s.toList

/-! ## Diagnostics

CLI.md exit codes: 0 success, 1 a failing `selftest` vector, 2 bad usage,
malformed hex, or nonzero trailing bits. -/

inductive CliError where
  | usage (msg : String)
  | badHex
  | wrongByteCount (got expected : Nat)
  | trailingBits
deriving Repr

def CliError.message : CliError → String
  | .usage m => m
  | .badHex => "malformed hex"
  | .wrongByteCount got expected =>
      s!"hex holds {got} bytes but nbits requires {expected}"
  | .trailingBits =>
      "final byte has nonzero bits below the message length; \
       SPEC.md 5.1 requires them to be zero"

/-- Decode and validate a `<hex> <nbits>` pair into a checked message.

Both halves of the well-formedness rule of SPEC.md §5.1 are enforced here, and
`hash b0 5` / `hash b8 5` pass while `hash b4 5` does not. The check is a call
to `wellFormedB`, so there is no second, possibly-divergent copy of the rule. -/
def decodeMessage (hex : String) (nbits : Nat) : Except CliError (List (BitVec 8)) := do
  let bytes ← match parseHex hex with
    | none => throw .badHex
    | some b => pure b
  if bytes.length ≠ (nbits + 7) / 8 then
    throw (.wrongByteCount bytes.length ((nbits + 7) / 8))
  if !wellFormedB bytes nbits then
    throw .trailingBits
  pure bytes

/-! ## Known-answer vectors (V5 in the small)

These are the built-in vectors `selftest` runs. The byte-aligned ones are
standard FIPS 180-4 / CAVP values. The sub-byte ones exercise SPEC.md §5.1, the
part of the standard that hobby implementations usually get wrong, and include
both `b0` and `b8` at five bits — a validator that rejected everything would
pass a one-sided test, so both an accepted `0`-low-bit case and an accepted
set-bit-inside-the-message case are present. Whether `b4 5` is correctly
*rejected* is checked in `Shavar/Pad.lean` as the theorem `not_wf_b4_5`. -/

/-- `(hex, nbits, expected digest)`. -/
def vectors : List (String × Nat × String) :=
  [ ("-", 0,
     "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
    ("616263", 24,
     "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
    ("6162636462636465636465666465666765666768666768696768696a68696a6b696a6b6c6a6b6c6d6b6c6d6e6c6d6e6f6d6e6f706e6f7071",
     448,
     "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
    -- exactly one block after padding is impossible at 512 bits: this is two.
    ("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f",
     512,
     "fdeab9acf3710362bd2658cdc9a29e8f9c757fcf9811603a8c447cd1d9151108"),
    -- Sub-byte lengths (SPEC.md §5.1, §5.2).
    ("00", 1, "bd4f9e98beb68c6ead3243b1b4c7fed75fa4feaab1f84795cbd8a98676a2a375"),
    ("80", 1, "b9debf7d52f36e6468a54817c1fa071166c3a63d384850e1575b42f702dc5aa1"),
    ("c0", 3, "fa0e40cc693c20d55b131b825a32f961d6d0681811a95886d6704e9c376a9abd"),
    ("b0", 5, "82c9ef980dfdf26f0cb97f59d34a60dc39c82e489da9ca2132681fe0aa14270a"),
    ("b8", 5, "9103bf6cd9f1134d81807ade91d54d9888b1a3df1f947f735ce00220dca5261c"),
    ("5a", 7, "5f03e13f82779fad1f19ac74f53aa9f93c0e4ce000a0a99f8c25cb536e774658") ]

/-! ## Output shaping -/

/-- One tab-separated trace record: `TAG<tab>index<tab>eight-hex-digits`. -/
def record (tag : String) (idx : Int) (v : BitVec 32) : String :=
  tag ++ "\t" ++ toString idx ++ "\t" ++ hex8 v

/-- Number a list of words from `start`, emitting one record each. -/
def records (tag : String) (start : Int) (vs : List (BitVec 32)) : List String :=
  vs.zipIdx.map (fun (v, i) => record tag (start + (i : Int)) v)

/-- The chaining value entering block `blk`, and that block's schedule. -/
def blockContext (msg : List (BitVec 8)) (L blk rounds : Nat) :
    Option (Vector (BitVec 32) 8 × Vector (BitVec 32) 64) :=
  let padded := (padBytes msg L).toArray
  let nblocks := padded.size / 64
  if blk ≥ nblocks then none
  else
    let H := (List.range blk).foldl
      (fun H i => compressBlock H (schedule (blockWords padded i)) rounds) IV
    some (H, schedule (blockWords padded blk))

/-- The full `trace` output for one block, in the order CLI.md prescribes. -/
def traceLines (msg : List (BitVec 8)) (L blk rounds : Nat) : Option (List String) :=
  match blockContext msg L blk rounds with
  | none => none
  | some (H, W) =>
      let tr := traceBlock H W rounds
      some <|
        records "HIN" 0 H.toList
        ++ records "W" 0 W.toList
        ++ records "A" (-4) tr.as
        ++ records "E" (-4) tr.es
        ++ records "T1" 0 tr.t1s
        ++ records "T2" 0 tr.t2s
        ++ records "HOUT" 0 tr.hout.toList

end Shavar
