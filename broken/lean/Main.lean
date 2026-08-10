/-
`sha01lean` — a driver so `../tests/run.sh` can check the Lean implementation
against the C one. Same shape as `../c/sha01`:

    sha01lean hash <sha0|sha1> <hex|-> [rounds]
-/
import Sha01

open Sha01

def hexVal (c : Char) : Option Nat :=
  if '0' ≤ c && c ≤ '9' then some (c.toNat - 48)
  else if 'a' ≤ c && c ≤ 'f' then some (c.toNat - 87)
  else if 'A' ≤ c && c ≤ 'F' then some (c.toNat - 55)
  else none

def parseHex (s : String) : Option (List (BitVec 8)) :=
  if s == "-" then some [] else
  let cs := s.toList
  if cs.length % 2 != 0 then none else
  let rec go : List Char → Option (List (BitVec 8))
    | [] => some []
    | a :: b :: rest =>
        match hexVal a, hexVal b, go rest with
        | some x, some y, some tl => some (BitVec.ofNat 8 (x * 16 + y) :: tl)
        | _, _, _ => none
    | _ => none
  go cs

def main (args : List String) : IO UInt32 := do
  match args with
  | ["hash", vs, hex] | ["hash", vs, hex, _] =>
    let rounds := match args with
      | ["hash", _, _, r] => r.toNat?.getD 80
      | _ => 80
    if rounds > 80 then
      (← IO.getStderr).putStrLn "sha01lean: rounds must be 0..80"
      return 2
    let v ← match vs with
      | "sha0" => pure Variant.sha0
      | "sha1" => pure Variant.sha1
      | _ =>
        (← IO.getStderr).putStrLn s!"sha01lean: variant must be sha0 or sha1"
        return 2
    match parseHex hex with
    | none =>
      (← IO.getStderr).putStrLn "sha01lean: malformed hex"
      return 2
    | some bytes =>
      IO.println (hashHex bytes v rounds)
      return 0
  | _ =>
    (← IO.getStderr).putStrLn "usage: sha01lean hash <sha0|sha1> <hex|-> [rounds]"
    return 2
