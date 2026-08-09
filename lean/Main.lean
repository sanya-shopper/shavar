/-
# `Main` — the `shavar` executable

The uniform command-line contract of CLI.md:

```
shavar hash  <hex> <nbits> [rounds]
shavar trace <hex> <nbits> [blockidx] [rounds]
shavar selftest
```

Exit codes: 0 success, 1 a failing `selftest` vector, 2 bad usage / malformed
hex / nonzero trailing bits. Diagnostics go to stderr so that stdout is always
either well-formed output or empty.
-/
import Shavar

open Shavar

/-- Print a diagnostic and return CLI.md's exit code 2. -/
def fail2 (msg : String) : IO UInt32 := do
  (← IO.getStderr).putStrLn s!"shavar: {msg}"
  pure 2

/-- Parse a decimal argument, or fail with exit code 2. -/
def parseNat (what arg : String) : Except String Nat :=
  match arg.toNat? with
  | some n => .ok n
  | none => .error s!"{what} must be a non-negative decimal integer, got '{arg}'"

def runHash (hex nbits : String) (roundsArg : Option String) : IO UInt32 := do
  match parseNat "nbits" nbits with
  | .error e => fail2 e
  | .ok L =>
    let roundsE : Except String Nat :=
      match roundsArg with
      | none => .ok 64
      | some r => parseNat "rounds" r
    match roundsE with
    | .error e => fail2 e
    | .ok rounds =>
      if rounds > 64 then fail2 s!"rounds must be at most 64, got {rounds}"
      else match decodeMessage hex L with
        | .error e => fail2 e.message
        | .ok bytes =>
          IO.println (digestHex (hashBytes bytes L rounds))
          pure 0

def runTrace (hex nbits : String) (blkArg roundsArg : Option String) : IO UInt32 := do
  match parseNat "nbits" nbits with
  | .error e => fail2 e
  | .ok L =>
    let blkE : Except String Nat :=
      match blkArg with | none => .ok 0 | some b => parseNat "blockidx" b
    let roundsE : Except String Nat :=
      match roundsArg with | none => .ok 64 | some r => parseNat "rounds" r
    match blkE, roundsE with
    | .error e, _ => fail2 e
    | _, .error e => fail2 e
    | .ok blk, .ok rounds =>
      if rounds > 64 then fail2 s!"rounds must be at most 64, got {rounds}"
      else match decodeMessage hex L with
        | .error e => fail2 e.message
        | .ok bytes =>
          match traceLines bytes L blk rounds with
          | none => fail2 s!"block index {blk} is past the end of the padded message"
          | some lines =>
            for l in lines do IO.println l
            pure 0

def runSelftest : IO UInt32 := do
  let mut passed := 0
  let mut failed := 0
  for (hex, nbits, expected) in vectors do
    match decodeMessage hex nbits with
    | .error e =>
        failed := failed + 1
        IO.println s!"FAIL\t{hex}\t{nbits}\t{expected}\t<rejected: {e.message}>"
    | .ok bytes =>
        let got := digestHex (hashBytes bytes nbits)
        if got == expected then
          passed := passed + 1
        else
          failed := failed + 1
          IO.println s!"FAIL\t{hex}\t{nbits}\t{expected}\t{got}"
  if failed == 0 then
    IO.println s!"ok {passed}"
    pure 0
  else
    pure 1

def usage : String :=
  "usage:\n" ++
  "  shavar hash  <hex> <nbits> [rounds]\n" ++
  "  shavar trace <hex> <nbits> [blockidx] [rounds]\n" ++
  "  shavar selftest"

def main (args : List String) : IO UInt32 := do
  match args with
  | ["selftest"] => runSelftest
  | ["hash", hex, nbits] => runHash hex nbits none
  | ["hash", hex, nbits, r] => runHash hex nbits (some r)
  | ["trace", hex, nbits] => runTrace hex nbits none none
  | ["trace", hex, nbits, b] => runTrace hex nbits (some b) none
  | ["trace", hex, nbits, b, r] => runTrace hex nbits (some b) (some r)
  | _ => fail2 usage
