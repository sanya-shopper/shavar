# broken/ — SHA-0 and SHA-1, and how they died

**Nothing here is safe to use.** Both functions are cryptographically dead.
This directory exists to show *how* they died, with code that runs the
argument rather than describing it.

Start with **[`sha-broken.pdf`](sha-broken.pdf)** (7 pages). The rest of this
file is the map.

## The one-sentence version

SHA-0 (FIPS 180, 1993) and SHA-1 (FIPS 180-1, 1995) are the same function.
They differ in one expression:

```c
uint32_t f = W[t-3] ^ W[t-8] ^ W[t-14] ^ W[t-16];
W[t] = sha01_rotl(f, v);        /* v = 0 -> SHA-0, v = 1 -> SHA-1 */
```

NIST withdrew SHA-0 two years after publishing it and never said why. That
rotation is the reason.

## Layout

| Path | What it is |
| --- | --- |
| `c/sha01.c`, `c/sha01.h` | both functions, one file, portable C99 |
| `c/main.c` | `sha01 hash\|trace <sha0\|sha1> <hex> [rounds]` |
| `lean/Sha01/Expansion.lean` | the structural weakness, **proved** |
| `lean/Sha01/Hash.lean` | the executable Lean implementation |
| `attack/expansion.c` | the expansion code, enumerated |
| `attack/collide.c` | local collisions measured; real collisions found |
| `sha-broken.tex` → `.pdf` | the write-up, with the history and the diagrams |
| `tests/run.sh` | is the implementation right, and does the attack work |
| `test_doc.sh` | the PDF is an output, and this tests it |

## Running it

```sh
make -C broken                     # build the C
make -C broken check               # implementation + attack tests

broken/attack/expansion spread     # a one-bit difference, in both functions
broken/attack/expansion code       # enumerate all 65536 codewords
broken/attack/collide verify       # local-collision probabilities, measured
broken/attack/collide search --rounds 25    # find a real collision, now

cd broken/lean && lake build       # the proofs
sh broken/test_doc.sh              # build and test the PDF
```

## What the code establishes

**A one-bit difference stays in one bit column under SHA-0.** `expansion
spread` expands a single-bit difference through both functions:

| | SHA-0 | SHA-1 |
| --- | --- | --- |
| difference bits over 80 rounds | 31 | 109 |
| distinct bit positions touched | **1** | **23** |

**And that is provable, not just observable.** `lean/Sha01/Expansion.lean`
proves SHA-0's expansion commutes with masking — it never moves information
between bit positions — and refutes the same statement for SHA-1 by explicit
counterexample. Both proofs are kernel-only: `[propext, Quot.sound]`, no
`Classical.choice`, no SAT-backed tactic.

**So the usable difference patterns can be enumerated.** SHA-0's expansion is
32 independent copies of one GF(2) recurrence, so the patterns in one column
form a [80,16] code with 65536 codewords. `expansion code` enumerates all of
them in a tenth of a second; the minimum weight usable in a full attack is 25.

**And collisions follow.** `collide search --rounds 25` finds two distinct
64-byte messages with the same 25-round SHA-0 digest, in milliseconds. Both
are one block, so they pad identically and it is a collision of the whole
hash, not just the compression function.

## Two things the measurements corrected

- **The Parity rounds are not free.** The folklore is that a linear `f` makes
  a local collision cost nothing. Measured: ≈2⁻³ — eight times cheaper than
  the `Ch`/`Maj` rounds, not free. The residual is *carries*: the round adds
  mod 2³² while the differential is XOR.
- **A disturbance vector is only usable if its five time-shifts are also
  codewords.** That is 15 extra linear conditions, cutting 65535 candidates to
  2047. The first version of `collide.c` omitted it and reported every
  differential unmountable — correctly, as it turned out.

## What is not here

Full SHA-0 (≈2³⁹) and SHA-1 (≈2⁶³) collisions, message modification (which is
why the search stops around 25 rounds), and the historic SHAttered blocks
(cited and mirrored in `refs/` instead).

**SHA-0 has no oracle anywhere.** SHA-1 is checked against three independent
implementations; SHA-0 is implemented by nothing current, so it rests on
published vectors plus the structural check that switching the rotation on
turns each SHA-0 answer into the oracle-verified SHA-1 one. The C and Lean
implementations were written separately and agree.
