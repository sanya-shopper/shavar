/-
# `PowDriver` — the proof-of-work driver for `tests/pow.sh`

Reads the shared vector file and writes one `id <TAB> met|unmet|invalid` line
per vector. Marshalling only: every verdict comes from `Shavar.powCheck`.

This exists as a separate executable rather than as a subcommand of `shavar`
because the proof-of-work comparison is deliberately absent from the uniform
command-line contract in `spec/CLI.md`, which is shared with six other
implementations. See `tests/pow.sh` for why the drivers exist at all.
-/
import Shavar

open Shavar

/-- Parse up to eight hex digits into a `UInt32`. `none` on any other
character, so a malformed vector file is a failure rather than a verdict. -/
def parseHex32 (s : String) : Option UInt32 :=
  s.foldl (fun acc c =>
    match acc, hexVal c with
    | some v, some d => some (v * 16 + d)
    | _, _ => none) (some 0) |>.map UInt32.ofNat

/-- Split a line on tab characters. -/
def splitTabs (s : String) : List String := s.splitOn "\t"

def verdict (digest : List (BitVec 8)) (nbits : UInt32) : String :=
  match powCheck digest nbits with
  | none => "invalid"
  | some true => "met"
  | some false => "unmet"

def main (args : List String) : IO UInt32 := do
  match args with
  | [path] =>
    -- A canary, run before any vector. `powCheck` reports an invalid target
    -- as `none`, which the loop below turns into the verdict "invalid"; that
    -- is right for a malformed nBits and would be catastrophically wrong for
    -- a broken driver, which would then print "invalid" eighteen times and
    -- look like a self-consistent opinion. Failing loudly here instead.
    if (targetBytes 0x1d00ffff).length ≠ 32 then
      (← IO.getStderr).putStrLn "powdriver: targetBytes is not 32 bytes"
      return 2
    for line in (← IO.FS.lines path) do
      if line.startsWith "#" || line.trim.isEmpty then
        continue
      match splitTabs line with
      | id :: dhex :: nbhex :: _ =>
        match parseHex (dhex) , parseHex32 nbhex with
        | some digest, some nbits =>
          IO.println s!"{id}\t{verdict digest nbits}"
        | _, _ =>
          (← IO.getStderr).putStrLn s!"powdriver: malformed vector line: {line}"
          return 2
      | _ => continue
    return 0
  | _ =>
    (← IO.getStderr).putStrLn "usage: powdriver VECTORS.tsv"
    return 2
