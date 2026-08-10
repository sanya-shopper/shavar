# tests — the shavar cross-implementation test harness

This directory checks that the eight builds of shavar (seven languages, with
the shell implementation run under both `bash` and `zsh`) compute SHA-256, and
that they compute *the same* SHA-256 as each other, for arbitrary bit lengths.

Those are two different claims needing two different kinds of evidence, which
is why the suite is split the way it is. `spec/SPEC.md` §8 names them:

| Obligation | Claim | Where it is discharged |
| --- | --- | --- |
| V5 | the implementations agree with FIPS 180-4 | `nist.sh` — NIST CAVP known-answer vectors; and the external-oracle columns of `crosstest.sh` |
| V6 | the implementations agree with **each other** | `crosstest.sh` — swept and random bit lengths, compared on digests *and* on per-round traces |
| V7 | the proof-of-work comparison reads the digest in the right byte order | `pow.sh` — vectors anchored to the Bitcoin genesis block, run through all eight builds |
| V8 | an out-of-range round count is rejected at the **library** boundary, not only at the CLI | `rounds.sh` — library-level drivers, one per language |

Neither subsumes the other. Eight implementations could agree with each other
and all be wrong (V5 catches that), or all match NIST on byte-aligned input and
diverge on `L = 5` (V6 catches that).

---

## Running it

```sh
tests/run.sh              # fast: a quick smoke, about 30 seconds
tests/run.sh thorough     # the long sweep, about 9 minutes
tests/run.sh thorough --seed 20260809     # replay an earlier run exactly
```

Exit status is nonzero if anything failed. Useful options:

| Option | Meaning |
| --- | --- |
| `--seed SEED` | replay a previous run's random corpus exactly |
| `--jobs N` | shards per implementation (default 4); implementations also run concurrently with each other |
| `--impls "c py"` | restrict to a subset |
| `--keep` | keep the work directory for inspection |
| `--skip-nist`, `--skip-cross` | drop a phase (the run says loudly which obligation is then unchecked) |

The individual scripts also run standalone: `tests/constants.sh`,
`tests/contract.sh`, `tests/nist.sh`, `tests/crosstest.sh`.

### Reproducing a failure

Every run prints its seed at the start and again at the end. The corpus is a
pure function of `(seed, mode)`, and the sampling is snapped to a fixed ladder
so that timing jitter cannot change which rows were selected. Passing the seed
back reproduces the identical corpus:

```
seed 20260809 (mode thorough) — rerun with: tests/crosstest.sh --seed 20260809 --mode thorough
```

Failures additionally print the offending input verbatim as `hex` and `nbits`,
so a single case can be re-run by hand against any implementation.

---

## What each phase does

### `selfcheck.sh` — testing the harness

A harness that cannot fail is worth nothing, and "all green" is the output you
get both from eight correct implementations and from a comparator with a bug in
it. This phase injects a fault of each kind the harness claims to detect and
asserts that it is detected, with the right verdict and a nonzero exit status:
a digest that disagrees with the authority; peers splitting with no authority
available; two authorities contradicting each other; a nonzero exit; a timeout;
a mutated `W[17]`; a fault that is causally earlier than the first differing
*line*; an uppercase hex record; a truncated trace; a corpus message with
nonzero trailing bits; a `Len = 0` vector; a non-deterministic subsample; and a
deliberately hanging process.

It uses no implementation and no network, so it is meaningful even when every
implementation is missing, and it runs in about two seconds.

### `constants.sh` — the constants (SPEC.md §9)

Recomputes `H[0..7]` from the square roots of the first eight primes and
`K[0..63]` from the cube roots of the first sixty-four, in exact integer
arithmetic, and compares them with (a) the tables printed in `spec/SPEC.md`,
catching a typo in the normative document itself, and (b) the `HIN` records of
each implementation's `trace` output, which is the initial chaining value as
that implementation actually holds it.

`K` is not separately observable through the CLI. A mistyped `K[t]` shows up as
a trace divergence at `T1[t]`, which `crosstest.sh` reports precisely.

### `contract.sh` — the CLI encoding (CLI.md)

Shape, not arithmetic. Nine accept cases (including the padding boundaries at
447/448/449 and 512/513 bits) must exit 0 and print exactly 64 lowercase hex
digits plus one newline — 65 bytes, no more. Seven reject cases must exit 2
with **empty stdout**.

The reject cases carry more weight than they look like they do. `SPEC.md` §5.1
requires an implementation to *reject* a final byte with nonzero trailing bits
rather than silently mask them, "because silently masking makes two distinct
inputs hash the same and would hide caller bugs". An implementation that
quietly masked would pass every digest comparison in this harness — the corpus
generator is careful to clear those bits — and only this check would catch it.

### `nist.sh` — known-answer vectors (V5)

Runs every implementation against the NIST CAVP SHAVS response files committed
under `vectors/`:

| File | Vectors | Lengths | Sub-byte |
| --- | --- | --- | --- |
| `byte/SHA256ShortMsg.rsp` | 65 | 0 – 512 bits | 0 |
| `byte/SHA256LongMsg.rsp` | 64 | 1304 – 51200 bits | 0 |
| `bit/SHA256ShortMsg.rsp` | 513 | 0 – 512 bits | 448 |
| `bit/SHA256LongMsg.rsp` | 512 | 611 – 51200 bits | 448 |

**The bit-oriented pair is the important one.** Arbitrary-bit-length hashing is
the headline feature of this project, and those 1025 vectors are the only
authoritative external reference for it that exists on this machine — no
installed SHA-256 program can hash a partial byte. 896 of them have a length
that is not a multiple of 8.

Also runs each implementation's built-in `selftest`.

Three conventions in the `.rsp` files are easy to get wrong, and
`lib/nistload.py` documents and handles each:

* `Len` is in **bits**, never bytes.
* A `Len = 0` entry still carries a dummy `Msg = 00` line. It denotes the
  **empty** message. Hashing the byte `00` instead yields `6e340b9c…` rather
  than `e3b0c442…`, so this one line of special-casing is the difference
  between a passing suite and a silently wrong one.
* In the bit-oriented files the message bits are left-justified in the final
  byte with the unused low bits zero — exactly the convention of `CLI.md`. No
  transformation is applied, only verification: all 1154 vectors pass that
  validation, and any that did not would be written to a `rejected` file with a
  reason rather than repaired.

### `pow.sh` — the proof-of-work comparison (V7)

Runs the 18 vectors of `pow-vectors.tsv` through every implementation and
compares the columns, twice over: against the expected verdicts, and against
each other.

This phase exists separately because the comparison specified in `SPEC.md` §10
is **library-only**. It has no subcommand, so `crosstest.sh` — which drives
everything through `spec/CLI.md` — cannot see it, and without `pow.sh` it
would be the one part of the repository whose mutual agreement nothing
checked. Each implementation therefore gets a small driver under
`pow-drivers/`, which marshals arguments and nothing else: no driver decides
anything, every verdict comes from the implementation it loads.

What the vectors are for: reading a digest as a 256-bit number requires
choosing a byte order, and Bitcoin's choice is little-endian — `digest[0]`,
the first byte the hash function emitted, is the *least* significant. Two
vectors, `genesis-le` and `genesis-be`, are the same 32 bytes in opposite
orders and disagree. An implementation that read the digest big-endian would
swap both verdicts and remain perfectly self-consistent, so that pair is what
separates a correct reading from a plausible one. Both are anchored to the
real Bitcoin genesis block rather than to this repository's own arithmetic.

The last phase mutates a copy of `c/shavar.c` to read the digest big-endian
and requires the comparison to reject it — 5 of the 18 vectors do. Nothing in
the repository is touched; the mutant is built from a copy in the work
directory. Without that step a green run would be consistent with a harness
that never looked.

The Lean version is checked here too, and additionally *proves* the byte
order: `lean/Shavar/Pow.lean` shows the byte-at-a-time walk agrees with the
ordering of the two numbers those bytes denote, kernel-only, no `sorry`.

### `rounds.sh` — the library round-count contract (V8)

`rounds` may be 0…64. Outside that there is no such function, and `SPEC.md`
§6.1 requires every implementation to *reject* rather than interpret. This
phase calls each library directly with nine counts and checks the verdicts,
then checks that the accepted counts produce the same digest everywhere.

It exists for the same structural reason `pow.sh` does, and the reason is
worth stating because it hid a real bug for the life of the repository so far.
`spec/CLI.md` already fixed the range, and every implementation obeyed it *at
the command line*. That constrained the library not at all, and nothing here
could see the difference, because `crosstest.sh` drives everything through the
CLI and the CLI rejects an out-of-range count before the library is reached.

Underneath that blind spot the seven had diverged four ways on the same call:

| | behaviour with `rounds = 100` |
| --- | --- |
| Python, JavaScript | rejected — correct |
| C, Lean | silently clamped to 64, returning genuine SHA-256 with a success status |
| Perl, shell | ran the loop past the end of `K`, returning a digest that is not any reduced-round variant of anything |
| Scheme | crashed with an interpreter backtrace |

The clamp is the worst of the four: a correct-looking answer to a request that
means nothing. `PROJECT_LOG.md` records that being fixed once already — at the
CLI layer, where it had been noticed rather than where it lived.

The last phase puts the clamp back into a copy of `c/shavar.c` and requires
the contract check to catch it; 4 of the 9 counts do.

### `crosstest.sh` — cross-implementation agreement (V6)

Builds a deterministic corpus from the seed and runs it through everything:

* **sweep** — every bit length `0..600` in thorough mode, which straddles the
  one-block/two-block padding boundary at 447/448 and the 512-bit block
  boundary, plus bands around the two- and three-block boundaries at 959/960
  and 1471/1472. A message of `L` bits pads into `⌊(L+64)/512⌋ + 1` blocks, so
  the last length that still fits in `n` blocks is `512n − 65`.
* **random** — random content at random lengths up to several thousand bits,
  with a tail up to 24000 bits so multi-block messages are exercised. Most of
  these are not byte-aligned.

Then it diffs **full per-round traces** between implementations on a sample of
inputs, at block 0 and at the final block of the padded message. This is the
part that makes the harness more than a digest diff: a digest mismatch says two
implementations disagree, whereas a trace diff says *where*, for example

```
impl pl diverges from c first at W[17]  (c=1c0d0e2f, pl=1c0d0e2e)
```

which is the difference between a broken message schedule and a broken round
function. `lib/tracediff.py` sorts records into **causal** order — for each
round `t`, `W[t]` first, then `T1[t]`/`T2[t]`, then `A[t]`/`E[t]` — rather than
the emission order of `CLI.md`, because emission order groups all 64 `A` values
before the first `T1` and would blame `A[3]` for a fault originating in `T1[3]`.

---

## External oracles, and the limit of what they can witness

Four independent SHA-256 programs on this machine are used as authorities for
the byte-aligned inputs. Two of them are genuinely separate codebases:

| id | Program |
| --- | --- |
| `ssl-libre` | `/usr/bin/openssl dgst -sha256` (LibreSSL 3.3.6) |
| `ssl-openssl` | `/opt/homebrew/bin/openssl dgst -sha256` (OpenSSL 3.x) |
| `shasum` | `/usr/bin/shasum -a 256` (Perl `Digest::SHA`) |
| `sha256sum` | `/sbin/sha256sum` (Darwin) |

They are fed raw bytes on stdin, and they are cross-checked against **each
other** as well: if two authorities disagree the run says so loudly rather than
silently picking one.

**None of them can hash a message that is not a whole number of bytes.** This
is the central coverage limitation of the project's headline feature, and the
harness states it at the end of every run rather than printing a clean bill of
health that overstates what was checked. For `nbits % 8 != 0` the evidence is:

1. the NIST **bit-oriented** vectors — external and authoritative, but only for
   the 896 specific sub-byte lengths those files contain; and
2. cross-implementation agreement — real evidence, but weaker, because eight
   transcriptions of one misreading agree with each other perfectly.

The summary table keeps these apart on purpose. `verified` counts digests that
matched an authority; `agreed` counts digests that only matched other
implementations. They are never added together.

---

## Sampling, and why it is measured rather than guessed

Implementations differ in cost by two orders of magnitude, so the harness
calibrates each one at startup — three one-block invocations for the fixed
per-invocation cost, one eight-block invocation for the marginal cost of a
block — and derives every sampling rate from that plus the mean block count of
the phase's inputs.

This replaced a hardcoded table, because the hardcoded table was wrong. The
guess going in was that the shell implementation would be the bottleneck at
"seconds per block". Measured on the development machine:

| impl | per invocation | per extra block |
| --- | --- | --- |
| `c` | 2.2 ms | ~0.02 ms |
| `pl` | 6.7 ms | |
| `js` | 8.5 ms | |
| `sh` | 9.4 ms | ~6.8 ms |
| `py` | 31 ms | |
| `scm` | 189 ms | ~1 ms |

The shell implementation is one of the *faster* ones; `chibi-scheme` costs 189
ms before it has hashed anything at all. Measuring also means the harness keeps
working as the implementations are optimised.

Derived budgets are snapped to a fixed ladder (`1 2 3 5 8 12 20 30 50 80 130
200 350 600 1000 1700 3000`) so ordinary timing jitter cannot change which rows
were selected between two runs on the same machine.

Overrides, in order of precedence:

| Variable | Effect |
| --- | --- |
| `SHAVAR_BUDGET_<IMPL>_<PHASE>` | exact row count, or `all` — e.g. `SHAVAR_BUDGET_SCM_SWEEP=12` |
| `SHAVAR_TIME_BUDGET_MS` | ms per implementation per phase (default 2500 fast, 400000 thorough) |
| `SHAVAR_TIME_TRACE_MS` | the same for the trace phase |
| `SHAVAR_TIMEOUT` | per-invocation wall-clock limit, default 120 s |
| `SHAVAR_JOBS` | shards per implementation |

Every invocation is bounded by a timeout. The implementations are under active
development and one of them hanging must not hang the suite; a timeout is
recorded as `timeout` in the exit-status column and surfaces in the comparator's
`error` count, never as a pass and never as a silent skip.

---

## Discovery: absent, broken, ok

The eight builds are written in parallel, so at any moment some may not exist.
Discovery classifies each one and the distinction is load-bearing:

* **absent** — the source file or its interpreter is not there. Reported, not
  counted as a pass, and not counted as a failure either.
* **broken** — present, but cannot answer `hash 616263 24` with 64 lowercase
  hex digits. This **is** a failure and fails the run. It is never quietly
  dropped from the suite.
* **ok** — speaks the contract. Whether it is *correct* is what the rest of the
  suite exists to determine; the smoke test deliberately never compares against
  a known digest.

---

## Refreshing the NIST vectors

The `.rsp` files are committed so the suite runs offline. `fetch-vectors.sh`
records where they came from and refreshes them:

```sh
tests/fetch-vectors.sh                # re-download and extract
tests/fetch-vectors.sh --verify-only  # just report what is present
cd tests/vectors && shasum -a 256 -c SHA256SUMS   # verify what is committed
```

`vectors/README.md` records the counts, the retrieval date, and the three
`.rsp` format traps in more detail.

Source: NIST Cryptographic Algorithm Validation Program, Secure Hash Algorithm
Validation System response files, CAVS 11.0, generated 2011-03-15, retrieved
2026-08-09 from `csrc.nist.gov`. If the URLs 404 the script says so and stops —
it never substitutes expected digests from elsewhere. **No expected digest in
this suite is invented.** Every one comes from NIST, from an external oracle,
or is explicitly reported as unresolved cross-implementation agreement.

The Monte Carlo files in those archives are deliberately not used: they specify
100 × 1000 chained iterations, which through a per-invocation command-line
interface would be 300 000 process spawns for no coverage the short and long
message files do not already provide.

---

## Layout

```
tests/
  run.sh              driver: fast / thorough, final summary table
  selfcheck.sh        tests the harness itself against injected faults
  constants.sh        SPEC.md §9 constants
  contract.sh         CLI.md encoding, exit codes, rejection rules
  nist.sh             NIST CAVP known-answer vectors            (V5)
  crosstest.sh        swept + random corpus, oracles, trace diff (V6)
  pow.sh              proof-of-work comparison, all eight builds (V7)
  pow-vectors.tsv     the 18 shared vectors, SPEC.md §10.5
  pow-drivers/        one marshalling shim per language; they decide nothing
  rounds.sh           the library round-count contract, all eight builds (V8)
  rounds-vectors.tsv  the 9 counts under test, SPEC.md §6.1
  rounds-drivers/     ditto
  fetch-vectors.sh    (re)download the NIST archives
  vectors/
    README.md         provenance, counts, and the .rsp format traps
    SHA256SUMS        digests of the committed vectors
    byte/SHA256{Short,Long}Msg.rsp
    bit/SHA256{Short,Long}Msg.rsp
  lib/
    common.sh         discovery, calibration, budgets, phase driver
    runner.py         runs one implementation over a shard, with timeouts
    oneshot.py        one bounded invocation, for the non-loop calls
    gen_corpus.py     deterministic corpus from a seed
    nistload.py       .rsp -> inputs + expectations
    compare.py        the comparator: pass / agree / fail / disputed / error
    tracediff.py      localises a divergence to a round and register
    constants.py      recompute H and K from the primes
    summarize.py      the final table
```

The harness may use `awk`, `sed` and `python3` freely. The "core language only,
no modules" rule constrains the eight implementations under test, not the tools
testing them.

One further file in this directory is not invoked by `run.sh`:

* `node-cli.js` — an adapter that drives `js/shavar.js` under Node, for Linux
  CI runners where `jsc` does not exist. It is not a second implementation: it
  loads `js/shavar.js` verbatim and only marshals argv and exit codes.

There was briefly also a `ci-crosscheck.sh`, a small dependency-free agreement
gate written before this harness existed. It has been deleted rather than kept
alongside `crosstest.sh`: two scripts checking the same property is exactly how
the two drift apart and start disagreeing about what "passing" means. CI now
runs `nist.sh` and `run.sh fast`.

## Reading the summary table

```
  impl         status    verified    agreed   FAILED  disputed   error   skipped
  c            ok            1196       164        0         0       0         0
```

| Column | Meaning |
| --- | --- |
| `verified` | matched an authority: a NIST expected digest or an external oracle |
| `agreed` | no authority available for that row, and every implementation gave the same answer |
| `FAILED` | disagreed with an authority — a real, attributable bug |
| `disputed` | no authority, and the implementations split into groups. Blame is **not** assigned by majority vote: a majority of seven agreeing transcriptions of one misreading is exactly the failure mode V5 exists to catch. Every participant is marked disputed and the groups are printed. |
| `error` | no digest, malformed digest, nonzero exit, or timeout |
| `skipped` | not run for that row: sampled away by the cost budget, or the row is not byte-aligned and the column is a byte-only oracle |
