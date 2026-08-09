# tests/vectors — NIST CAVP known-answer vectors

Response (`.rsp`) files from the NIST Cryptographic Algorithm Validation
Program, Secure Hash Algorithm Validation System (SHAVS). They are committed
so that `tests/nist.sh` runs offline and any checkout is testable against the
same vectors.

| File | Vectors | Bit lengths | Not byte-aligned |
| --- | --- | --- | --- |
| `byte/SHA256ShortMsg.rsp` | 65 | 0 – 512 | 0 |
| `byte/SHA256LongMsg.rsp` | 64 | 1304 – 51200 | 0 |
| `bit/SHA256ShortMsg.rsp` | 513 | 0 – 512 | 448 |
| `bit/SHA256LongMsg.rsp` | 512 | 611 – 51200 | 448 |
| **total** | **1154** | | **896** |

## Provenance

CAVS 11.0, generated 2011-03-15. Retrieved 2026-08-09 by
`tests/fetch-vectors.sh` from:

- <https://csrc.nist.gov/CSRC/media/Projects/Cryptographic-Algorithm-Validation-Program/documents/shs/shabytetestvectors.zip>
- <https://csrc.nist.gov/CSRC/media/Projects/Cryptographic-Algorithm-Validation-Program/documents/shs/shabittestvectors.zip>

Both URLs returned HTTP 200 on that date. `SHA256SUMS` records the digest of
each extracted file as committed; verify with:

```sh
cd tests/vectors && shasum -a 256 -c SHA256SUMS
```

Only the four SHA-256 files are kept. The archives also contain SHA-1,
SHA-224, SHA-384, SHA-512 and Monte Carlo files, which this project does not
use — the Monte Carlo files specify 100 × 1000 chained iterations, which
through a per-invocation command-line interface would be 300 000 process
spawns for no coverage the short and long message files do not already give.

## Format notes

Three conventions in these files are easy to get wrong. `tests/lib/nistload.py`
handles all three and rejects, rather than repairs, anything that does not fit.

1. **`Len` is in bits**, never bytes.
2. **A `Len = 0` entry still carries a dummy `Msg = 00` line**, and it denotes
   the *empty* message. Hashing the byte `00` instead gives `6e340b9c…` rather
   than the correct `e3b0c442…`.
3. **In the bit-oriented files the message bits are left-justified** in the
   final byte with the unused low bits zero — exactly the convention of
   `spec/CLI.md`, so no transformation is needed. All 1154 vectors were
   verified to satisfy it; none required rejection.

## Why the bit-oriented files matter most

Arbitrary-bit-length hashing is the headline feature of this project, and these
1025 bit-oriented vectors are the only authoritative external reference for it.
No SHA-256 program installed on this machine — `openssl`, `shasum`,
`sha256sum` — can hash a message that is not a whole number of bytes. Remove
these files and 896 sub-byte cases lose their only outside witness, leaving
nothing but cross-implementation agreement.
