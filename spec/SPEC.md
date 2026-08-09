# shavar — normative specification

This is the single source of truth that all seven implementations follow —
C99, Lean 4, Python 3, Perl 5, R7RS Scheme, JavaScript, and shell. Where an
implementation disagrees with this document, the implementation is wrong.

The algorithm is SHA-256 exactly as defined in FIPS 180-4. Nothing here changes
what the function computes. What changes is *how it is written down*: the
standard presents the compression function as eight registers that shuffle on
every round, and this document presents it as two coupled recurrences with a
lookback of four. The two are provably the same, and that proof is mechanised
in `lean/` (see `Shavar/Equiv.lean`).

---

## 1. Notation

All arithmetic is on 32-bit words unless stated otherwise.

| Symbol | Meaning |
| --- | --- |
| `x ⊕ y` | bitwise exclusive or |
| `x ∧ y`, `x ∨ y`, `¬x` | bitwise and, or, not |
| `x ⊞ y` | addition modulo 2³² |
| `ROTR^n(x)` | circular right rotation by `n` |
| `SHR^n(x)` | logical right shift by `n`, zero-filled |
| `W[t]` | word `t` of the message schedule, `0 ≤ t < 64` |
| `L` | message length **in bits** — an arbitrary non-negative integer |

Bit order is big-endian throughout, matching FIPS 180-4: within a byte the
most significant bit comes first, and within a word the most significant byte
comes first. This matters for sub-byte message lengths (§5).

### 1.1 Round functions

The six auxiliary functions are:

```
Ch(x, y, z)  = (x ∧ y) ⊕ (¬x ∧ z)
Maj(x, y, z) = (x ∧ y) ⊕ (x ∧ z) ⊕ (y ∧ z)

Σ0(x) = ROTR^2(x)  ⊕ ROTR^13(x) ⊕ ROTR^22(x)
Σ1(x) = ROTR^6(x)  ⊕ ROTR^11(x) ⊕ ROTR^25(x)
σ0(x) = ROTR^7(x)  ⊕ ROTR^18(x) ⊕ SHR^3(x)
σ1(x) = ROTR^17(x) ⊕ ROTR^19(x) ⊕ SHR^10(x)
```

`Ch` is "choose": bit `i` of `x` selects between bit `i` of `y` and of `z`.
`Maj` is "majority": bit `i` is whichever value appears at least twice among
the three inputs. The capital-sigma functions are used on the state, the
lowercase-sigma functions on the message schedule.

Read `Σ` and `σ` as *Sigma* and *sigma*; they are unrelated to summation.

---

## 2. The standard eight-register form

FIPS 180-4 keeps eight working variables `a…h` and, for `t = 0 … 63`:

```
T1 = h ⊞ Σ1(e) ⊞ Ch(e,f,g) ⊞ K[t] ⊞ W[t]
T2 = Σ0(a) ⊞ Maj(a,b,c)
h = g;  g = f;  f = e;  e = d ⊞ T1
d = c;  c = b;  b = a;  a = T1 ⊞ T2
```

Six of those eight assignments are pure copies. Only `a` and `e` are computed.
That observation is the whole of §3.

---

## 3. The two-dimensional form with lookback 4

Define two sequences of 32-bit words, `A[t]` and `E[t]`, indexed from `t = -4`.
Seed them from the incoming chaining value `H[0…7]`:

```
A[-1] = H[0]    A[-2] = H[1]    A[-3] = H[2]    A[-4] = H[3]
E[-1] = H[4]    E[-2] = H[5]    E[-3] = H[6]    E[-4] = H[7]
```

Then for `t = 0 … 63`:

```
T1[t] = E[t-4] ⊞ Σ1(E[t-1]) ⊞ Ch(E[t-1], E[t-2], E[t-3]) ⊞ K[t] ⊞ W[t]
T2[t] = Σ0(A[t-1]) ⊞ Maj(A[t-1], A[t-2], A[t-3])

E[t]  = A[t-4] ⊞ T1[t]
A[t]  = T1[t] ⊞ T2[t]
```

and the outgoing chaining value is

```
H[0] ⊞= A[63]   H[1] ⊞= A[62]   H[2] ⊞= A[61]   H[3] ⊞= A[60]
H[4] ⊞= E[63]   H[5] ⊞= E[62]   H[6] ⊞= E[61]   H[7] ⊞= E[60]
```

**Why these are the same.** The eight registers are not eight independent
things; they are two sliding windows of width four over the histories of `A`
and `E`. At the top of round `t` the correspondence is exactly:

```
a = A[t-1]   b = A[t-2]   c = A[t-3]   d = A[t-4]
e = E[t-1]   f = E[t-2]   g = E[t-3]   h = E[t-4]
```

Substituting that into §2 turns the six copy-assignments into nothing at all —
they are the window sliding — and the two real assignments into the two
recurrences above. The register shuffle was never computation; it was an
artefact of writing a recurrence with an explicit shift register.

This is the form every implementation in this repository uses. It is preferred
here for three reasons:

1. **It is smaller.** Two recurrences instead of eight assignments, and the
   round body is four lines with no permutation to get wrong.
2. **It is the natural object of study.** Differential and algebraic attacks
   on SHA-256 reason about the sequences `A[t]` and `E[t]` and their
   differences, not about register names. See §7.
3. **It keeps the whole history.** `A[-4…63]` and `E[-4…63]` are 136 words;
   retaining them costs 544 bytes and makes every intermediate value of the
   compression addressable after the fact. See §6.

### 3.1 Dependency depth

`A[t]` depends on `A[t-1..t-4]` and `E[t-1..t-4]`; `E[t]` depends on
`A[t-4]` and `E[t-1..t-4]`. Both are order-4. Note the asymmetry worth
remembering: `E` reaches into the `A` history at exactly one point, `A[t-4]`,
and `A` reaches into the `E` history at four points. The two tracks are not
symmetric, and the single `A[t-4]` term is the only path by which the `A`
track influences the `E` track at all.

---

## 4. The message schedule as an order-16 recurrence

The schedule has the same shape one dimension down. For a 512-bit block split
into sixteen big-endian words `M[0…15]`:

```
W[t] = M[t]                                                    0 ≤ t < 16
W[t] = σ1(W[t-2]) ⊞ W[t-7] ⊞ σ0(W[t-15]) ⊞ W[t-16]            16 ≤ t < 64
```

So the whole of SHA-256 is one linear-feedback-shaped order-16 recurrence
(`W`) driving a nonlinear order-4 recurrence in two tracks (`A`, `E`). That
two-sentence description is the entire algorithm, and it is the framing this
repository is built around.

`W` is worth isolating because it is **`GF(2)`-linear apart from its three
additions**. `σ0` and `σ1` are `⊕` of rotations and shifts, hence linear over
`GF(2)`; only the `⊞` carries break linearity. Message-modification attacks
exploit precisely this.

---

## 5. Padding for arbitrary bit length

`L` is a bit count, not a byte count, and may be any non-negative integer —
including values that are not multiples of 8. This is required by FIPS 180-4
and is where most hobby implementations quietly do the wrong thing.

Append to the message:

1. a single `1` bit;
2. `k` zero bits, where `k` is the smallest non-negative solution of
   `L + 1 + k ≡ 448 (mod 512)`;
3. `L` itself as a 64-bit big-endian integer.

The result has length `L + 1 + k + 64 ≡ 0 (mod 512)`.

### 5.1 Representation convention

Every implementation here takes a message as **a byte buffer plus a bit count
`L`**. The buffer holds `⌈L/8⌉` bytes. When `L` is not a multiple of 8, the
final byte holds its `L mod 8` significant bits **in the high-order positions**,
and the remaining low-order bits of that byte *must be zero*.

Implementations reject a final byte with nonzero padding bits rather than
silently masking, because silently masking makes two distinct inputs hash the
same and would hide caller bugs.

So the `1` bit of step 1 lands at bit offset `L`, which is bit `7 - (L mod 8)`
of byte `⌊L/8⌋`, counting bit 7 as the most significant.

### 5.2 Worked example

For `L = 5` and the five bits `10110`:

- buffer is one byte `0b10110000` = `0xB0`;
- the appended `1` bit goes at position 5, giving `0b10110100` = `0xB4`;
- zeros fill to bit 448, then the 64-bit big-endian value `5` ends the block.

`L = 0` is legal: the padded message is a single block of `0x80` followed by
63 zero bytes, and the digest is the well-known
`e3b0c442 98fc1c14 9afbf4c8 996fb924 27ae41e4 649b934c a495991b 7852b855`.

### 5.3 Why padding must be injective

The Merkle–Damgård security argument needs `pad` to be injective: if two
distinct messages padded to the same bit string, a collision would exist for
trivial reasons having nothing to do with the compression function. Encoding
`L` in the final 64 bits is what buys injectivity, and `lean/` proves it
(§8).

Note the standard's implicit bound: `L < 2⁶⁴`. Implementations here carry `L`
as a 64-bit count and document the bound rather than pretending it is absent.

---

## 6. What implementations must expose

To be useful for research (§7) rather than only for hashing, every
implementation in this repository exposes the same three operations. Uniformity
is what makes the cross-testing harness possible: any implementation can be
checked against any other, round by round.

- **`hash <hex> <nbits>`** — digest of the message given as hex bytes plus a
  bit length. Prints 64 lowercase hex characters.
- **`trace <hex> <nbits> [block]`** — the full interior of one block's
  compression: `W[0…63]`, `A[-4…63]`, `E[-4…63]`, and `T1[t]`, `T2[t]` for
  every round, as tab-separated hex.
- **`selftest`** — run the built-in known-answer vectors, exit nonzero on
  failure.

Beyond the CLI, each implementation offers the compression function on a
**caller-supplied chaining value** and for a **reduced number of rounds**.
Neither is reachable through a normal hashing API, and both are indispensable:
free-start (chosen-IV) attacks and reduced-round distinguishers are the bread
and butter of hash cryptanalysis, and a library that only ever starts from the
FIPS initial value cannot express them.

Each implementation also offers the **proof-of-work comparison** of §10 —
decode a compact `nBits` target and decide whether a digest meets it. This one
is library-only: it has no CLI verb, so `tests/pow.sh` drives it through a
small per-language driver instead of through the uniform command line.

---

## 7. Notes for cryptanalytic use

Three structural facts that the 2D form makes visible, recorded here because
they determine what the code needs to expose.

### 7.1 The linear/nonlinear split

Partition the operations by behaviour over `GF(2)`:

| Linear over `GF(2)` | Nonlinear |
| --- | --- |
| `⊕`, `ROTR`, `SHR` | `⊞` (via carries) |
| hence `Σ0, Σ1, σ0, σ1` | `Ch`, `Maj` |

If `⊞` were replaced by `⊕` and `Ch`/`Maj` by linear functions, SHA-256 would
collapse into an affine map over `GF(2)^256` and be broken by linear algebra
alone. All of its strength sits in the carry chains and in the two bitwise
selectors. The implementations therefore keep `Ch`, `Maj`, and each `⊞`
separately addressable rather than fusing them into one expression.

### 7.2 Bit-slices are coupled only by carries

`Ch`, `Maj`, and `⊕` all act bit-position-wise: bit `i` of the output depends
only on bit `i` of the inputs. Rotations permute bit positions but do not mix
them. **The only operation that moves information from bit `i` to bit `j > i`
is the carry in `⊞`.**

Consequently, if every `⊞` were replaced by `⊕`, SHA-256 would decompose into
32 completely independent 1-bit ciphers. Carry propagation is the sole
mechanism of diffusion across the word, and it is directional — carries move
towards the most significant bit only. This asymmetry is the reason low-order
bit differences are cheap to control and high-order ones are not, which is why
published differential paths concentrate their differences in the low bits.

### 7.3 Differences and the trace

For differential work, what is wanted is not a digest but the pair of traces
for two related messages and their difference. The harness computes, for
messages `M` and `M'`:

```
ΔW[t] = W[t] ⊕ W'[t]      ΔA[t] = A[t] ⊕ A'[t]      ΔE[t] = E[t] ⊕ E'[t]
```

together with the Hamming weight of each, which is the usual first diagnostic
for whether a path is behaving. Modular differences (`A[t] ⊟ A'[t]`) are also
reported, since signed-difference paths are stated that way in the literature
and the two notions diverge exactly where carries fire.

---

## 8. Verification obligations

What "correct" means here, and how each claim is discharged. The point of
listing these separately is that they are different kinds of claim needing
different kinds of evidence.

| # | Claim | How it is established |
| --- | --- | --- |
| V1 | The 2D recurrence equals the 8-register form, for one round and hence for 64 | Machine-checked in Lean (`Shavar/Equiv.lean`) |
| V2 | `Ch`/`Maj` identities used for optimisation are sound | `bv_decide` — bit-blasted to SAT, LRAT certificate checked by the Lean kernel |
| V3 | Padding lands on a 512-bit multiple, for every `L` | Lean, by arithmetic on `L mod 512` |
| V4 | Padding is injective | Lean |
| V5 | The implementations agree with FIPS 180-4 | NIST CAVP known-answer vectors, byte- and bit-oriented |
| V6 | The implementations agree with **each other** | Cross-testing on digests *and* on per-round traces, over a swept corpus of bit lengths |
| V7 | The PoW comparison (§10) reads the digest in the right byte order | Vectors anchored to the Bitcoin genesis block, run through every implementation by `tests/pow.sh`; the Lean version additionally proves the byte-wise loop equals the 256-bit integer comparison |

V5 and V6 answer different questions. V5 catches a shared misreading of the
standard; V6 catches a transcription slip in one language, and because it
compares traces it names the round where the slip happened. Neither subsumes
the other: seven implementations could agree with each other and all be wrong,
or all match NIST on byte-aligned input and diverge on `L = 5`.

A caveat stated plainly: `bv_decide` discharges goals by bit-blasting to
CaDiCaL and checking the returned LRAT certificate inside Lean. The SAT solver
is *not* trusted. The certificate check, however, runs as compiled native
code, which places the Lean compiler in the trusted computing base. Proofs
obtained that way are machine-checked modulo the compiler, not modulo the
kernel alone.

Concretely, on the toolchain used here (Lean 4.32.2) a `bv_decide` proof
carries a per-theorem axiom named `<theorem>._native.bv_decide.ax_N`, so
`#print axioms` on such a theorem reports something like:

```
'tst' depends on axioms: [propext, Classical.choice, Quot.sound,
                          tst._native.bv_decide.ax_1_5]
```

whereas a kernel-only proof reports just `[propext, Quot.sound]` (plus
`Classical.choice` where classical reasoning is used). The distinction is
visible and mechanically checkable, which is why `lean/Shavar/Audit.lean`
prints the axiom list for every headline theorem on each build rather than
asserting in prose that the proofs are clean.

Older material — including Lean's own 4.12 release notes, when `bv_decide`
was introduced — describes the mechanism as using the `Lean.ofReduceBool`
axiom. That is no longer accurate for 4.32.2; the trust story is unchanged
(solver untrusted, compiler trusted) but the axiom name is different. Verified
directly against the installed toolchain rather than taken from the
documentation.

Worth noting for anyone reading the proofs: the two identities named in V2 are
proved *twice* in `lean/`, once by `bv_decide` and once by case analysis on
individual bit positions. The second route needs no compiler trust, so for
those particular claims the caveat above does not actually bite. Where a proof
is kernel-only, the repository says so and shows the axiom list.

---

## 9. Constants

Initial chaining value `H[0…7]` — the first 32 bits of the fractional parts of
the square roots of the first eight primes:

```
6a09e667 bb67ae85 3c6ef372 a54ff53a 510e527f 9b05688c 1f83d9ab 5be0cd19
```

Round constants `K[0…63]` — the first 32 bits of the fractional parts of the
cube roots of the first sixty-four primes:

```
428a2f98 71374491 b5c0fbcf e9b5dba5 3956c25b 59f111f1 923f82a4 ab1c5ed5
d807aa98 12835b01 243185be 550c7dc3 72be5d74 80deb1fe 9bdc06a7 c19bf174
e49b69c1 efbe4786 0fc19dc6 240ca1cc 2de92c6f 4a7484aa 5cb0a9dc 76f988da
983e5152 a831c66d b00327c8 bf597fc7 c6e00bf3 d5a79147 06ca6351 14292967
27b70a85 2e1b2138 4d2c6dfc 53380d13 650a7354 766a0abb 81c2c92e 92722c85
a2bfe8a1 a81a664b c24b8b70 c76c51a3 d192e819 d6990624 f40e3585 106aa070
19a4c116 1e376c08 2748774c 34b0bcb5 391c0cb3 4ed8aa4a 5b9cca4f 682e6ff3
748f82ee 78a5636f 84c87814 8cc70208 90befffa a4506ceb bef9a3f7 c67178f2
```

Both derivations are checkable, and `tests/` recomputes them from the primes
rather than trusting the transcription above. A mistyped constant is the
classic way one of five implementations ends up subtly different from the
other four, and it is cheap to rule out.

---

## 10. Proof-of-work comparison

A hash function used for proof of work (PoW) is not asked "what is the
digest?" but "is the digest small enough?". *Small* requires reading the 32
digest bytes as a single 256-bit integer, and **the order in which those bytes
are read is a convention, not a fact about the digest**. Getting it wrong
produces a comparison that is wrong roughly all of the time while still
looking entirely plausible, so this section fixes the order explicitly.

This repository implements the **Bitcoin** convention, because it is the one
in wide use and the one whose byte order most often surprises people.

Terms used below, defined before use:

- **PoW** — proof of work: a search for an input whose digest is numerically
  below a threshold.
- **target** — that threshold, a 256-bit unsigned integer.
- **nBits** — a 32-bit *compact* encoding of a target, a three-byte mantissa
  with a one-byte exponent. Bitcoin block headers carry the target in this
  form.

### 10.1 The digest is read little-endian

Let `D[0…31]` be the digest bytes **in the order the hash function emits
them** — `D[0]` is the first output byte, the most significant byte of `H[0]`
(§1). The PoW value is

```
value = Σ  D[i] · 256^i           for i = 0 … 31
```

That is: **`D[0]` is the LEAST significant byte and `D[31]` is the MOST
significant byte.**

```
    D[0]  D[1]  D[2]   ...   D[29] D[30] D[31]
     6f    e2    8c            19    00    00
     ^^                                    ^^
   LEAST significant              MOST significant
   (256^0)                            (256^31)
```

This is the reverse of the order the bytes are written in. It is also why a
Bitcoin block hash is *displayed* with its bytes reversed relative to the
digest the hash function actually produced: the display shows the integer
most-significant-byte-first, as numbers are normally written.

Worked example, the Bitcoin genesis block. Hashing its 80-byte header with
SHA-256 twice gives, in emission order:

```
D = 6fe28c0a b6f1b372 c1a6a246 ae63f74f 931e8365 e15a089c 68d61900 00000000
```

Read little-endian per the rule above, the value is

```
value = 0x00000000 0019d668 9c085ae1 65831e93 4ff763ae 46a2a6c1 72b3f1b6 0a8ce26f
```

which is exactly the block hash as everyone quotes it. Reading the same bytes
big-endian instead would give `0x6fe28c0a…`, a number about 2^216 times
larger, which fails every target ever used. §10.5 makes this a test case.

### 10.2 Decoding nBits to a target

Given the 32-bit value `nBits`:

```
exponent = nBits >> 24                     (the high byte)
mantissa = nBits & 0x007FFFFF              (the low 23 bits)

if exponent ≤ 3:   target = mantissa >> (8 · (3 − exponent))
else:              target = mantissa << (8 · (exponent − 3))
```

So `exponent` counts **bytes**, not bits, and the mantissa's least significant
byte sits at byte position `exponent − 3` counting from the least significant
end of the 256-bit target.

Bit `0x00800000` of `nBits` is a **sign** bit. A target is never negative, so
its being set is an error rather than something to mask away.

An `nBits` value is **invalid** if any of the following hold, and an
implementation must report an error rather than return a verdict:

| Condition | Why |
| --- | --- |
| `mantissa ≠ 0` and `nBits & 0x00800000 ≠ 0` | negative target |
| `mantissa ≠ 0` and `exponent > 34` | target does not fit in 256 bits |
| `mantissa > 0x0000FF` and `exponent > 33` | same, one byte tighter |
| `mantissa > 0x00FFFF` and `exponent > 32` | same, two bytes tighter |
| `target = 0` | nothing can be below it; always unsatisfiable |

Note that the overflow tests are all conditioned on `mantissa ≠ 0`: a zero
mantissa means a zero target, which is caught by the last row instead.

### 10.3 The comparison

The PoW is **met** if and only if

```
value ≤ target
```

The relation is `≤`, not `<`. A digest exactly equal to the target satisfies
the requirement.

### 10.4 The byte-wise procedure implementations actually use

None of the implementations here may use a bignum library (§6 — core language
only), so no implementation forms `value` as an integer. Instead the target is
built as a 32-byte **big-endian** array `T[0…31]`, where `T[0]` is its most
significant byte, and the comparison is done byte by byte:

```
for i = 0 … 31:
    a = D[31 − i]          ← digest, reversed: most significant byte first
    b = T[i]               ← target, already most significant byte first
    if a < b:  return MET
    if a > b:  return NOT MET
return MET                 ← all 32 bytes equal, so value = target
```

The single line that carries the entire convention is `a = D[31 − i]`. Writing
`D[i]` there instead is the byte-order bug this section exists to prevent, and
it is silent: it compiles, it runs, and it answers plausibly.

Building `T` from `nBits` without a bignum, given the decode of §10.2, means
placing at most three mantissa bytes into a zeroed 32-byte array. With
`shift = exponent − 3` (the byte offset from the least significant end) the
three mantissa bytes land at big-endian indices `31 − shift`, `31 − shift − 1`
and `31 − shift − 2`; any that would land at a negative index must be zero, or
the value overflows and §10.2 has already rejected it.

### 10.5 Test vectors

`tests/pow.sh` runs these through every implementation. Digests are written in
**emission order**, the order the hash function produced them — the same order
`hash` prints — so `D[0]` is the leftmost byte pair.

| # | digest `D[0…31]` (emission order) | nBits | verdict |
| --- | --- | --- | --- |
| 1 | `6fe28c0ab6f1b372c1a6a246ae63f74f931e8365e15a089c68d6190000000000` | `1d00ffff` | met |
| 2 | `000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f` | `1d00ffff` | **not met** |
| 3 | `0000…0000` (all zero) | `1d00ffff` | met |
| 4 | `0100…0000` | `01010000` | met |
| 5 | `0200…0000` | `01010000` | not met |
| 6 | `ffff…ffff` (all ones) | `207fffff` | not met |
| 7 | `0000000000000000000000000000000000000000000000000000ffff00000000` | `1d00ffff` | met (equality) |
| 8 | `7f00…0000` | `017f0000` | met |
| 9 | `8000…0000` | `017f0000` | not met |
| 10 | `8000…0000` | `02008000` | met |
| 11 | `0100000000000000000000000000000000000000000000000000ffff00000000` | `1d00ffff` | not met (target + 1) |

Vectors 1 and 2 are the same 32 bytes in opposite orders, and they disagree.
That pair is the whole point of this section: an implementation that reads the
digest big-endian passes vector 2 and fails vector 1, and no other vector in
the table distinguishes the two readings as sharply. Vector 1 is the real
Bitcoin genesis block digest and `1d00ffff` is its real `nBits`, so the pair is
anchored to something external rather than to this document's own arithmetic.

Vector 7 pins `≤` rather than `<`, and vector 11 pins that one more than the
target is rejected.

These `nBits` values must all be **rejected** as invalid:

| nBits | why |
| --- | --- |
| `00000000` | mantissa zero, so target zero |
| `01003456` | mantissa shifts out entirely, target zero |
| `1d800000` | sign bit set but mantissa zero, so target zero |
| `1d8000ff` | sign bit set with a nonzero mantissa: negative |
| `ff123456` | exponent 0xff: overflow |
| `23000100` | mantissa > 0xff with exponent > 33: overflow |
| `22010000` | mantissa > 0xffff with exponent > 32: overflow |

### 10.6 What this is not

The comparison takes an already-computed digest. It does not iterate a nonce,
and no implementation here contains a mining loop — searching for a
satisfying input is the caller's business and would say nothing about SHA-256
that §7 does not already say.

Bitcoin additionally rejects any target above a chain-specific maximum
(`powLimit`) before checking a header. That is a consensus-rule parameter, not
a property of the encoding, so it is deliberately outside this specification;
`nBits` values that decode to a valid but very large target are accepted here.

Nor is the conventional floating-point *difficulty* (`difficulty_1_target ÷
target`) computed anywhere. It is a human-facing ratio, it needs division that
several of these languages have no native form of — the shell implementation
has no floating-point arithmetic at all — and seven independently rounded
approximations of one ratio is precisely the sort of unstated boundary §8
exists to keep out of this repository.
