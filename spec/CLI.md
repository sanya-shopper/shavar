# shavar — uniform command-line contract

Every implementation exposes exactly this interface. The cross-testing harness
(`tests/crosstest.sh`) drives all of them through it and diffs the output
byte-for-byte, so any deviation — a capital hex digit, a space instead of a
tab, a missing trailing newline — registers as a failure.

Read this together with `SPEC.md`. This file fixes the *encoding*; `SPEC.md`
fixes the *algorithm*.

---

## Message encoding on the command line

A message is always a pair: **hex bytes** and a **bit count**.

- `<hex>` is exactly `2 * ceil(nbits/8)` lowercase or uppercase hex digits,
  or the single character `-` when the message occupies zero bytes.
- `<nbits>` is a decimal non-negative integer. It may exceed or fall short of
  `8 * (number of hex bytes)` only in the sense that it must satisfy
  `ceil(nbits/8) == number of hex bytes`.
- When `nbits % 8 != 0`, the final byte holds its `nbits % 8` significant bits
  in the **high-order** positions and its low-order bits **must be zero**.
  A nonzero low bit is an error (see Exit codes), never silently masked.

Examples: `abc` as 24 bits is `616263 24`. The 5-bit string `10110` is
`b0 5`. The empty message is `- 0`.

---

## Subcommands

### `hash <hex> <nbits> [rounds]`

Print the digest as **64 lowercase hex digits followed by a single newline**,
and nothing else.

`rounds` defaults to 64. A smaller value runs a reduced-round variant of the
compression function in every block; this is not SHA-256 and is provided for
cryptanalysis only.

### `trace <hex> <nbits> [blockidx] [rounds]`

Print the full interior of the compression of one block. `blockidx` defaults
to 0 and selects a block of the **padded** message.

Output is one record per line, fields separated by a **single tab**, in
exactly this order:

```
HIN    <i>   <hex8>      i = 0..7      chaining value entering the block
W      <t>   <hex8>      t = 0..63     message schedule
A      <t>   <hex8>      t = -4..63    the A track, seeded from H[0..3]
E      <t>   <hex8>      t = -4..63    the E track, seeded from H[4..7]
T1     <t>   <hex8>      t = 0..63
T2     <t>   <hex8>      t = 0..63
HOUT   <i>   <hex8>      i = 0..7      chaining value leaving the block
```

`<hex8>` is exactly 8 lowercase hex digits, zero-padded. `<t>` is a decimal
integer, negative values written with a leading `-`.

The first `A` record of a from-the-IV trace is therefore:

```
A	-4	a54ff53a
```

Note that this is `H[3]`, not `H[0]`. SPEC.md §3 seeds the window in reverse —
`A[-1] = H[0]`, `A[-2] = H[1]`, `A[-3] = H[2]`, `A[-4] = H[3]` — because the
correspondence being encoded is `a = A[t-1], b = A[t-2], c = A[t-3],
d = A[t-4]` read at `t = 0`. The more negative the index, the later the `H`.
Getting this backwards produces wrong digests immediately, so it is called out
here rather than left to be inferred.

When `rounds < 64`, emit `W` for all 64 entries (the schedule is independent
of the round count), but `A`/`E` only for `t = -4 .. rounds-1`, and `T1`/`T2`
only for `t = 0 .. rounds-1`.

### `selftest`

Run the built-in known-answer vectors. Print `ok <n>` to **stdout** where
`<n>` is the number of vectors passed, or one `FAIL` line per failing vector
giving the input, expected, and actual digest. Exit 0 on complete success, 1
otherwise.

Only two things about `selftest` are normative: the **exit code**, and the
`ok <n>` line on stdout when everything passes. `FAIL` diagnostics are for a
human reading a broken build, so an implementation may send them to stdout or
stderr as it prefers, and their wording is not fixed. The harness keys off the
exit code alone.

This is the one place the "diagnostics never go to stdout" rule below is
relaxed, because a failing self-test has no well-formed output to protect.

---

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | success |
| 1 | `selftest` had at least one failing vector |
| 2 | bad usage, malformed hex, or nonzero trailing bits in the final byte |

Diagnostics go to stderr and never to stdout, so that stdout is always either
well-formed output or empty.

---

## Why the contract is this rigid

Cross-testing seven implementations is only as good as the comparison. If each
one printed its trace in a slightly different shape, the harness would need
seven parsers, and each parser would be a place for a bug to hide and make a
real disagreement look like a formatting artefact — or worse, make a
formatting artefact look like a real disagreement. One format, compared with
`diff`, keeps the harness honest and trivial.

Emitting the trace as flat text rather than a structured format is deliberate
for the same reason: every one of these seven languages can print tab-separated
lines using nothing but core features, which is the constraint the project is
built under.
