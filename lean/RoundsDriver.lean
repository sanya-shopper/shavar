/-
# `RoundsDriver` — the rounds-contract driver for `tests/rounds.sh`

Prints `<rounds> <TAB> accepted|rejected|unrepresentable <TAB> <digest|->`.
Marshalling only: every verdict comes from `Shavar.hashHex?`.

Lean's round count is a `Nat`, so a negative row cannot be passed to the
library at all. That is reported as `unrepresentable` rather than as a
rejection: "the type forbids it" and "the code checks for it" are different
claims, and only the second one is what the other six implementations are
being asked to demonstrate.
-/
import Shavar

open Shavar

def main (args : List String) : IO UInt32 := do
  match args with
  | [path] =>
    let msg : List (BitVec 8) := [0x61, 0x62, 0x63]
    -- Canary: a driver that could not hash at all would otherwise print
    -- "rejected" for every row and look like a self-consistent opinion.
    if (hashHex? msg 24 64).isNone then
      (← IO.getStderr).putStrLn "roundsdriver: cannot hash at 64 rounds"
      return 2
    for line in (← IO.FS.lines path) do
      if line.startsWith "#" || line.trim.isEmpty then continue
      let field := (line.splitOn "\t").headD ""
      if field.startsWith "-" then
        IO.println s!"{field}\tunrepresentable\t-"
      else
        match field.toNat? with
        | none => pure ()
        | some r =>
          match hashHex? msg 24 r with
          | none => IO.println s!"{r}\trejected\t-"
          | some d => IO.println s!"{r}\taccepted\t{d}"
    return 0
  | _ =>
    (← IO.getStderr).putStrLn "usage: roundsdriver VECTORS.tsv"
    return 2
