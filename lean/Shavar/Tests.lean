/-
# `Shavar.Tests` — checks that run as part of `lake build`

Everything here is executed when the file is compiled. `#eval` runs a compiled
`IO` action at elaboration time; if the action throws, the build fails. So these
are not documentation of intent — a broken one stops the build.

These are *tests*, not proofs. They check particular inputs, whereas the
theorems in `Shavar/Equiv.lean`, `Shavar/BitIdentities.lean` and
`Shavar/Pad.lean` quantify over all of them. Both are needed: the theorems say
the 2D form is the eight-register form and that padding behaves, but no theorem
here says the constant table was typed correctly or that the result matches
FIPS 180-4. That is what obligation V5 is for, and it is answered by known
answers, not by deduction.
-/
import Shavar.Cli

namespace Shavar
namespace Tests

/-- Fail the build with a message. -/
def check (name : String) (ok : Bool) (detail : String := "") : IO Unit :=
  if ok then pure () else throw (IO.userError s!"{name} FAILED {detail}")

/-! ## SPEC.md §9: recomputing the constants from the primes

SPEC.md §9 says a mistyped constant is the classic way one implementation ends
up subtly different from the others, and that the derivations are cheap to
check. So rather than trusting the transcription in `Shavar/Words.lean`, we
recompute both tables from their definitions:

* `H[i]` is the first 32 bits of the fractional part of `√pᵢ` for the first
  eight primes, which equals `⌊√(pᵢ · 2⁶⁴)⌋ mod 2³²`.
* `K[i]` is the same for `∛pᵢ` over the first sixty-four primes, which equals
  `⌊∛(pᵢ · 2⁹⁶)⌋ mod 2³²`.

Both are exact integer computations — no floating point is involved, so there
is no rounding question. -/

def isPrime (n : Nat) : Bool :=
  n ≥ 2 && (List.range n).all (fun d => d < 2 || n % d != 0)

/-- The first `k` primes. The 64th is 311, so searching below 400 suffices. -/
def firstPrimes (k : Nat) : List Nat := ((List.range 400).filter isPrime).take k

/-- Integer cube root: the largest `r` with `r³ ≤ n`. Binary search; the `fuel`
argument makes termination obvious to the compiler. -/
def icbrt (n : Nat) : Nat :=
  let rec go (fuel lo hi : Nat) : Nat :=
    match fuel with
    | 0 => lo
    | f + 1 =>
      if hi ≤ lo then lo
      else
        let mid := (lo + hi + 1) / 2
        if mid ^ 3 ≤ n then go f mid hi else go f lo (mid - 1)
  go 256 0 (n + 1)

def ivFromPrimes : List (BitVec 32) :=
  (firstPrimes 8).map (fun p => BitVec.ofNat 32 (Nat.sqrt (p * 2 ^ 64)))

def kFromPrimes : List (BitVec 32) :=
  (firstPrimes 64).map (fun p => BitVec.ofNat 32 (icbrt (p * 2 ^ 96)))

#eval do
  check "firstPrimes" ((firstPrimes 64).getLast? == some 311)
    s!"64th prime came out as {(firstPrimes 64).getLast?}"
  check "IV derivation (SPEC.md §9)" (ivFromPrimes == IV.toList)
    s!"recomputed {ivFromPrimes.map hex8} but table says {IV.toList.map hex8}"
  let kDiff := (List.range 64).find? (fun i => kFromPrimes[i]! != K.toList[i]!)
  check "K derivation (SPEC.md §9)" (kFromPrimes == K.toList)
    s!"first divergence at index {kDiff}"

/-! ## V5 in the small: known answers

The two digests every SHA-256 implementation must produce, spelled out rather
than hidden inside the vector table. -/

#eval do
  check "empty message"
    (hashHex [] 0 == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    s!"got {hashHex [] 0}"
  check "\"abc\""
    (hashHex [0x61, 0x62, 0x63] 24
      == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    s!"got {hashHex [0x61, 0x62, 0x63] 24}"

-- All the built-in vectors, driven through the same decode path the CLI uses.
#eval do
  for (hex, nbits, expected) in vectors do
    match decodeMessage hex nbits with
    | .error e => throw (IO.userError s!"vector ({hex}, {nbits}) rejected: {e.message}")
    | .ok bytes =>
        let got := digestHex (hashBytes bytes nbits)
        check s!"vector ({hex}, {nbits})" (got == expected) s!"got {got}, want {expected}"

/-! ## The well-formedness validator (SPEC.md §5.1, CLI.md)

`Shavar/Pad.lean` proves `wf_b0_5`, `wf_b8_5` and `not_wf_b4_5` about the
predicate. These check that the CLI's decode path actually consults it, in both
directions — a validator that rejected everything would pass a one-sided test. -/

#eval do
  check "b0/5 accepted" (decodeMessage "b0" 5 |>.toOption |>.isSome)
  check "b8/5 accepted" (decodeMessage "b8" 5 |>.toOption |>.isSome)
  check "b4/5 rejected" (decodeMessage "b4" 5 |>.toOption |>.isNone)
  check "616263/25 rejected (wrong byte count)"
    (decodeMessage "616263" 25 |>.toOption |>.isNone)
  check "zz/8 rejected (malformed hex)" (decodeMessage "zz" 8 |>.toOption |>.isNone)
  check "- /0 accepted" (decodeMessage "-" 0 |>.toOption |>.isSome)

/-! ## Trace shape (CLI.md)

CLI.md fixes how many records of each kind a trace emits, including the
reduced-round case: `W` always has 64 entries because the schedule does not
depend on the round count, while `A`/`E` run from `-4` to `rounds-1` and
`T1`/`T2` from `0` to `rounds-1`. -/

#eval do
  match traceLines [0x61, 0x62, 0x63] 24 0 64, traceLines [0x61, 0x62, 0x63] 24 0 8 with
  | some full, some short => do
      let count (tag : String) (ls : List String) :=
        (ls.filter (fun (l : String) => l.startsWith (tag ++ "\t"))).length
      check "full trace line count" (full.length == 8 + 64 + 68 + 68 + 64 + 64 + 8)
        s!"got {full.length}"
      check "reduced W count" (count "W" short == 64) s!"got {count "W" short}"
      check "reduced A count" (count "A" short == 12) s!"got {count "A" short}"
      check "reduced T1 count" (count "T1" short == 8) s!"got {count "T1" short}"
      -- SPEC.md §3: A[-4] = H[3] and E[-4] = H[7].
      check "A[-4] seeds from H[3]" (full.contains s!"A\t-4\t{hex8 IV[3]}")
      check "E[-4] seeds from H[7]" (full.contains s!"E\t-4\t{hex8 IV[7]}")
  | _, _ => throw (IO.userError "traceLines returned none for block 0")

/-! ## The two forms agree on concrete inputs

`hashBytes_eq_std` proves this for all inputs; running it is still worth a
moment, because it exercises the *compiled* code rather than the proof term and
would catch a compilation-level discrepancy that the kernel proof cannot see. -/

#eval do
  for (hex, nbits, _) in vectors do
    match decodeMessage hex nbits with
    | .error _ => pure ()
    | .ok bytes =>
        check s!"2D = 8-register on ({hex}, {nbits})"
          (hashBytes bytes nbits == hashBytesStd bytes nbits)
  for r in [0, 1, 7, 16, 31, 63, 64] do
    check s!"2D = 8-register at {r} rounds"
      (hashBytes [0x61, 0x62, 0x63] 24 r == hashBytesStd [0x61, 0x62, 0x63] 24 r)

end Tests
end Shavar
