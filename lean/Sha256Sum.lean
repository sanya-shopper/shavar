/-
# `Sha256Sum` — the `sha256sum` executable

A shasum-style front end for hashing local files:

```
sha256sum [FILE]...
```

For each argument it prints `<64 lowercase hex digits>  <name>` — the digest,
two spaces, the name — which is the line format of coreutils `sha256sum` and
of `shasum -a 256`, so the output can be checked with either. With no
arguments, or with the argument `-`, it hashes standard input and prints `-`
as the name. An unreadable file gets a diagnostic on stderr and the remaining
arguments are still processed; the exit code is then 1. Exit code 2 means the
tool itself could not start (it takes no options, so today that cannot
happen; the code is reserved to match the repo's usage-error convention).

This is deliberately a separate executable rather than a subcommand of
`shavar`: the uniform contract in `spec/CLI.md` is shared with six other
implementations and takes messages as hex on the command line, not as files.
`sha256sum` is a Lean-only convenience, like `powdriver`, and exists mainly
as a worked example of a Lean CLI that does ordinary I/O — reading binary
files and stdin, streaming, error recovery, exit codes.

One caveat: the digest comes from `Shavar.hashBytes`, the *verified
reference* implementation, which computes on `List (BitVec 8)`. It is exactly
as fast as correctness-first code gets, which is not very. Hashing megabytes
works; hashing gigabytes is a lesson in why production tools compile to
mutable buffers.
-/
import Shavar

open Shavar

/-- Read a stream to exhaustion in 64 KiB chunks. `IO.FS.Stream.read` returns
an empty chunk exactly at end of input. (`partial` because termination depends
on the stream, which Lean cannot see.) -/
partial def readAll (s : IO.FS.Stream) (acc : ByteArray := .empty) : IO ByteArray := do
  let chunk ← s.read 65536
  if chunk.isEmpty then pure acc else readAll s (acc ++ chunk)

/-- The digest of a whole `ByteArray`, as 64 lowercase hex digits. The message
is always byte-aligned here, so the bit length is just eight times the size. -/
def digestOf (bytes : ByteArray) : String :=
  let msg := bytes.toList.map (fun b => (BitVec.ofNat 8 b.toNat))
  digestHex (hashBytes msg (8 * bytes.size))

/-- Hash one named input: `-` is stdin, anything else is a file path. Returns
`false` when the input could not be read, after diagnosing on stderr. -/
def hashOne (name : String) : IO Bool := do
  let bytesE : Except IO.Error ByteArray ←
    try
      if name == "-" then .ok <$> readAll (← IO.getStdin)
      else .ok <$> IO.FS.readBinFile name
    catch e => pure (.error e)
  match bytesE with
  | .error e =>
    -- `IO.Error`'s rendering spans two lines and repeats the file name; the
    -- first line ("no such file or directory (error code: ...)") is the part
    -- worth relaying.
    let reason := (e.toString.splitOn "\n").headD e.toString
    (← IO.getStderr).putStrLn s!"sha256sum: {name}: {reason}"
    pure false
  | .ok bytes =>
    IO.println s!"{digestOf bytes}  {name}"
    pure true

def main (args : List String) : IO UInt32 := do
  let names := if args.isEmpty then ["-"] else args
  let mut ok := true
  for name in names do
    ok := (← hashOne name) && ok
  pure (if ok then 0 else 1)
