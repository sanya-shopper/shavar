#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Tests for the Python implementation of shavar.

Run with ``python3 py/test_shavar.py``.  Exits 0 if everything passes.

Imports: ``sys`` and the module under test.  Nothing else — in particular no
``hashlib`` (which would make the known-answer vectors circular against
CPython's OpenSSL binding rather than against the standard) and no
``unittest``, ``random`` or ``math``.  The few things those would have provided
are written out below: a twelve-line test runner, a deterministic
pseudo-random generator, and integer square and cube roots.

What is checked, in the vocabulary of SPEC.md §8:

  V1 (local)  the two-dimensional recurrence agrees with the eight-register
              form of SPEC.md §2, over swept inputs, round counts and chaining
              values.  The eight-register version below is transcribed
              independently from §2 and shares no code with the module.
  V3          padding lands on a 512-bit multiple for every L in a wide sweep.
  V4          padding is injective on a sweep of distinct (message, L) pairs.
  V5          the FIPS 180-4 vectors, plus the sub-byte worked example of
              SPEC.md §5.2 built by hand.
  --          the constant tables are recomputed from the primes rather than
              trusted (SPEC.md §9), and the CLI's exit codes and output shapes
              are checked against CLI.md.
"""

import sys

import shavar
from shavar import Word32


# --------------------------------------------------------------------------
# A minimal test runner
# --------------------------------------------------------------------------

TESTS = []


def test(fn):
    """Decorator: ``@test`` above a function registers it.

    A decorator is a function applied to the function defined beneath it; the
    name ends up bound to whatever the decorator returns, here the original
    function, with registration as the side effect.
    """
    TESTS.append(fn)
    return fn


class Failure(Exception):
    pass


def check(condition, message):
    if not condition:
        raise Failure(message)


def check_equal(got, want, message):
    if got != want:
        raise Failure("%s\n    got  %s\n    want %s" % (message, got, want))


# --------------------------------------------------------------------------
# An independent reference: the eight-register form of SPEC.md §2
# --------------------------------------------------------------------------
#
# Deliberately written in a different style from shavar.py — plain ints and
# explicit masking, no Word32, no generators, no negative indexing — so that a
# shared misunderstanding is less likely than a shared line of code.

M32 = 0xFFFFFFFF


def _rotr(x, n):
    return ((x >> n) | (x << (32 - n))) & M32


def _bigsig0(x):
    return _rotr(x, 2) ^ _rotr(x, 13) ^ _rotr(x, 22)


def _bigsig1(x):
    return _rotr(x, 6) ^ _rotr(x, 11) ^ _rotr(x, 25)


def _smallsig0(x):
    return _rotr(x, 7) ^ _rotr(x, 18) ^ (x >> 3)


def _smallsig1(x):
    return _rotr(x, 17) ^ _rotr(x, 19) ^ (x >> 10)


def textbook_compress(h, block, rounds=64):
    """FIPS 180-4 §6.2.2 verbatim: eight working variables that shuffle."""
    k = [int(x) for x in shavar.K]

    w = [0] * 64
    for i in range(16):
        w[i] = (block[4 * i] << 24) | (block[4 * i + 1] << 16) | \
               (block[4 * i + 2] << 8) | block[4 * i + 3]
    for i in range(16, 64):
        w[i] = (_smallsig1(w[i - 2]) + w[i - 7] +
                _smallsig0(w[i - 15]) + w[i - 16]) & M32

    a, b, c, d, e, f, g, hh = [int(x) for x in h]
    for t in range(rounds):
        t1 = (hh + _bigsig1(e) + ((e & f) ^ (~e & M32 & g)) + k[t] + w[t]) & M32
        t2 = (_bigsig0(a) + ((a & b) ^ (a & c) ^ (b & c))) & M32
        hh = g
        g = f
        f = e
        e = (d + t1) & M32
        d = c
        c = b
        b = a
        a = (t1 + t2) & M32

    out = [a, b, c, d, e, f, g, hh]
    return [(int(h[i]) + out[i]) & M32 for i in range(8)]


def textbook_hexdigest(msg, nbits, iv=None, rounds=64):
    """Hash via the reference compression, reusing shavar's padder only.

    Padding is checked separately (test_padding_worked_example,
    test_padding_length, test_padding_injective), so sharing it here isolates
    what this test is for: the shape of the round.
    """
    h = [int(x) for x in (shavar.IV if iv is None else iv)]
    for block in shavar.padded_blocks(msg, nbits):
        h = textbook_compress(h, block, rounds)
    return "".join("%08x" % x for x in h)


# --------------------------------------------------------------------------
# A deterministic pseudo-random source (no ``random`` import)
# --------------------------------------------------------------------------


class Xorshift(object):
    """xorshift64*, sufficient for generating test inputs and nothing else."""

    def __init__(self, seed=0x2545F4914F6CDD1D):
        self.s = seed & 0xFFFFFFFFFFFFFFFF

    def next64(self):
        s = self.s
        s ^= (s << 13) & 0xFFFFFFFFFFFFFFFF
        s ^= s >> 7
        s ^= (s << 17) & 0xFFFFFFFFFFFFFFFF
        self.s = s
        return (s * 0x2545F4914F6CDD1D) & 0xFFFFFFFFFFFFFFFF

    def byte(self):
        return self.next64() & 0xFF

    def bytes(self, n):
        return bytes(self.byte() for _ in range(n))

    def word(self):
        return self.next64() & M32

    def below(self, n):
        return self.next64() % n


# --------------------------------------------------------------------------
# Word32 itself
# --------------------------------------------------------------------------


@test
def test_word32_wraps():
    check_equal(Word32(0xFFFFFFFF) + Word32(1), Word32(0), "addition wraps")
    check_equal(Word32(0) - Word32(1), Word32(0xFFFFFFFF), "subtraction wraps")
    check_equal(~Word32(0), Word32(0xFFFFFFFF), "complement stays 32-bit")
    check_equal(~Word32(0x0F0F0F0F), Word32(0xF0F0F0F0), "complement")
    check_equal(Word32(0x80000000) >> 31, Word32(1), "shift is logical")
    check_equal(str(Word32(0xdeadbeef)), "deadbeef", "str is 8 lowercase hex")
    check_equal(str(Word32(1)), "00000001", "str is zero-padded")
    check_equal(Word32(0b1011).hamming_weight(), 3, "population count")


@test
def test_word32_rotation():
    rng = Xorshift(1)
    for _ in range(200):
        x = Word32(rng.word())
        check_equal(x.rotr(0), x, "rotation by zero is the identity")
        for n in range(1, 32):
            # A rotation is invertible and composes additively.
            check_equal(x.rotr(n).rotr(32 - n), x, "rotr(n) then rotr(32-n)")
            check_equal(x.rotr(n).hamming_weight(), x.hamming_weight(),
                        "rotation preserves weight")


@test
def test_word32_slots():
    w = Word32(0)
    try:
        w.oops = 1
    except AttributeError:
        return
    raise Failure("__slots__ should forbid new attributes")


@test
def test_round_functions():
    """Ch and Maj against their defining descriptions, bit by bit."""
    rng = Xorshift(2)
    for _ in range(64):
        x, y, z = (Word32(rng.word()) for _ in range(3))
        c = shavar.ch(x, y, z)
        m = shavar.maj(x, y, z)
        for i in range(32):
            xb = (int(x) >> i) & 1
            yb = (int(y) >> i) & 1
            zb = (int(z) >> i) & 1
            check_equal((int(c) >> i) & 1, yb if xb else zb, "Ch selects")
            check_equal((int(m) >> i) & 1, 1 if xb + yb + zb >= 2 else 0,
                        "Maj is majority")
        # The Sigma functions are GF(2)-linear (SPEC.md §7.1): f(x^y)=f(x)^f(y).
        for f in (shavar.Sigma0, shavar.Sigma1, shavar.sigma0, shavar.sigma1):
            check_equal(f(x ^ y), f(x) ^ f(y), "%s is GF(2)-linear" % f.__name__)


# --------------------------------------------------------------------------
# Constants recomputed from the primes (SPEC.md §9)
# --------------------------------------------------------------------------


def primes(n):
    """The first n primes, by trial division. n is 64, so this is plenty."""
    found = []
    candidate = 2
    while len(found) < n:
        if all(candidate % p for p in found if p * p <= candidate):
            found.append(candidate)
        candidate += 1
    return found


def iroot(x, k):
    """Floor of the k-th root of a non-negative integer, by bisection.

    ``math.isqrt`` would cover k = 2 and nothing would cover k = 3, and neither
    matters: this is exact integer arithmetic, which is the one thing Python
    hands over for free.
    """
    if x < 2:
        return x
    lo, hi = 1, 1 << ((x.bit_length() + k - 1) // k + 1)
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if mid ** k <= x:
            lo = mid
        else:
            hi = mid - 1
    return lo


@test
def test_iv_from_square_roots():
    """H[i] = first 32 fractional bits of sqrt(p_i), i.e. floor(sqrt(p)*2^32)."""
    for p, want in zip(primes(8), shavar.IV):
        got = iroot(p << 64, 2) & M32
        check_equal("%08x" % got, str(want), "IV entry for prime %d" % p)


@test
def test_k_from_cube_roots():
    """K[i] = first 32 fractional bits of cbrt(p_i)."""
    for p, want in zip(primes(64), shavar.K):
        got = iroot(p << 96, 3) & M32
        check_equal("%08x" % got, str(want), "K entry for prime %d" % p)


@test
def test_constant_table_sizes():
    check_equal(len(shavar.IV), 8, "IV has eight words")
    check_equal(len(shavar.K), 64, "K has sixty-four words")


# --------------------------------------------------------------------------
# The message schedule (SPEC.md §4)
# --------------------------------------------------------------------------


@test
def test_schedule_first_sixteen_are_the_block():
    rng = Xorshift(3)
    block = rng.bytes(64)
    w = shavar.take(64, shavar.message_schedule(block))
    for t in range(16):
        check_equal(int(w[t]), int.from_bytes(block[4 * t:4 * t + 4], "big"),
                    "W[%d] is M[%d]" % (t, t))


@test
def test_schedule_recurrence_and_laziness():
    """The stream is infinite: taking 200 words must work and stay consistent."""
    rng = Xorshift(4)
    block = rng.bytes(64)
    w = shavar.take(200, shavar.message_schedule(block))
    check_equal(len(w), 200, "the schedule stream does not terminate at 64")
    for t in range(16, 200):
        want = shavar.sigma1(w[t - 2]) + w[t - 7] + shavar.sigma0(w[t - 15]) \
            + w[t - 16]
        check_equal(w[t], want, "W[%d] recurrence" % t)
    # And the first 64 agree with the reference schedule.
    ref = [0] * 64
    for i in range(16):
        ref[i] = int.from_bytes(block[4 * i:4 * i + 4], "big")
    for i in range(16, 64):
        ref[i] = (_smallsig1(ref[i - 2]) + ref[i - 7] +
                  _smallsig0(ref[i - 15]) + ref[i - 16]) & M32
    for i in range(64):
        check_equal(int(w[i]), ref[i], "W[%d] against the reference" % i)


# --------------------------------------------------------------------------
# V1: the 2D recurrence equals the eight-register form
# --------------------------------------------------------------------------


@test
def test_equivalence_with_eight_register_form():
    rng = Xorshift(5)
    for trial in range(40):
        block = rng.bytes(64)
        h = [rng.word() for _ in range(8)] if trial else [int(x) for x in shavar.IV]
        for rounds in (0, 1, 2, 3, 4, 5, 16, 31, 48, 63, 64):
            want = textbook_compress(h, block, rounds)
            got = shavar.compress(h, block, rounds).h_out
            check_equal([int(x) for x in got], want,
                        "trial %d, rounds %d" % (trial, rounds))


@test
def test_window_correspondence():
    """At the top of round t: a=A[t-1] b=A[t-2] c=A[t-3] d=A[t-4], and likewise
    e..h from E.  Checked by re-running the reference round by round."""
    rng = Xorshift(6)
    block = rng.bytes(64)
    h = [rng.word() for _ in range(8)]
    tr = shavar.compress(h, block, 64)
    for t in range(0, 65):
        registers = textbook_registers(h, block, t)
        window = (tr.A[t - 1], tr.A[t - 2], tr.A[t - 3], tr.A[t - 4],
                  tr.E[t - 1], tr.E[t - 2], tr.E[t - 3], tr.E[t - 4])
        check_equal([int(x) for x in window], registers,
                    "register window at t = %d" % t)


def textbook_registers(h, block, t):
    """The eight working variables after t rounds of the reference."""
    k = [int(x) for x in shavar.K]
    w = [0] * 64
    for i in range(16):
        w[i] = int.from_bytes(bytes(block[4 * i:4 * i + 4]), "big")
    for i in range(16, 64):
        w[i] = (_smallsig1(w[i - 2]) + w[i - 7] +
                _smallsig0(w[i - 15]) + w[i - 16]) & M32
    a, b, c, d, e, f, g, hh = [int(x) for x in h]
    for i in range(t):
        t1 = (hh + _bigsig1(e) + ((e & f) ^ (~e & M32 & g)) + k[i] + w[i]) & M32
        t2 = (_bigsig0(a) + ((a & b) ^ (a & c) ^ (b & c))) & M32
        hh, g, f, e, d, c, b, a = g, f, e, (d + t1) & M32, c, b, a, (t1 + t2) & M32
    return [a, b, c, d, e, f, g, hh]


@test
def test_trace_internal_consistency():
    """T1, T2, A and E in the trace satisfy the four equations of SPEC.md §3."""
    rng = Xorshift(7)
    block = rng.bytes(64)
    h = [rng.word() for _ in range(8)]
    tr = shavar.compress(h, block, 64)
    for t in range(64):
        t1 = tr.E[t - 4] + shavar.Sigma1(tr.E[t - 1]) \
            + shavar.ch(tr.E[t - 1], tr.E[t - 2], tr.E[t - 3]) \
            + shavar.K[t] + tr.W[t]
        t2 = shavar.Sigma0(tr.A[t - 1]) \
            + shavar.maj(tr.A[t - 1], tr.A[t - 2], tr.A[t - 3])
        check_equal(tr.T1[t], t1, "T1[%d]" % t)
        check_equal(tr.T2[t], t2, "T2[%d]" % t)
        check_equal(tr.E[t], tr.A[t - 4] + tr.T1[t], "E[%d]" % t)
        check_equal(tr.A[t], tr.T1[t] + tr.T2[t], "A[%d]" % t)
    # Seeds and outputs.
    for i in range(4):
        check_equal(tr.A[-1 - i], tr.h_in[i], "A[%d] seed" % (-1 - i))
        check_equal(tr.E[-1 - i], tr.h_in[4 + i], "E[%d] seed" % (-1 - i))
    for i in range(4):
        check_equal(tr.h_out[i], tr.h_in[i] + tr.A[63 - i], "H[%d] out" % i)
        check_equal(tr.h_out[4 + i], tr.h_in[4 + i] + tr.E[63 - i],
                    "H[%d] out" % (4 + i))


@test
def test_track_indexing():
    tr = shavar.compress(shavar.IV, b"\x80" + b"\x00" * 63, 64)
    check_equal(list(tr.A.indices()), list(range(-4, 64)), "A index range")
    check_equal(len(tr.A), 68, "A holds A[-4..63]")
    for bad in (-5, 64, 100):
        try:
            tr.A[bad]
        except IndexError:
            continue
        raise Failure("Track should reject t = %d" % bad)


@test
def test_reduced_rounds_truncate_the_trace():
    tr = shavar.compress(shavar.IV, b"\x80" + b"\x00" * 63, 16)
    check_equal(len(tr.W), 64, "W is emitted in full even when reduced")
    check_equal(list(tr.A.indices()), list(range(-4, 16)), "A stops at rounds-1")
    check_equal(len(tr.T1), 16, "T1 stops at rounds-1")
    check_equal(len(tr.T2), 16, "T2 stops at rounds-1")


# --------------------------------------------------------------------------
# Padding (SPEC.md §5)
# --------------------------------------------------------------------------


@test
def test_padding_worked_example():
    """SPEC.md §5.2, built by hand and compared with the padder."""
    want = bytearray(64)
    want[0] = 0xB4             # 10110 then the appended 1 bit, then zeros
    want[63] = 5               # the 64-bit big-endian length, low byte
    blocks = list(shavar.padded_blocks(b"\xb0", 5))
    check_equal(len(blocks), 1, "a 5-bit message pads to one block")
    check_equal(blocks[0].hex(), bytes(want).hex(), "the §5.2 padded block")


@test
def test_padding_empty_message():
    blocks = list(shavar.padded_blocks(b"", 0))
    want = bytearray(64)
    want[0] = 0x80
    check_equal(len(blocks), 1, "the empty message is one block")
    check_equal(blocks[0].hex(), bytes(want).hex(), "0x80 then 63 zero bytes")


@test
def test_padding_length_and_count():
    """V3: every padded message is a whole number of 512-bit blocks."""
    rng = Xorshift(8)
    lengths = list(range(0, 600)) + [1000, 1023, 1024, 1025, 4096, 100000]
    for nbits in lengths:
        msg = rng.bytes((nbits + 7) // 8)
        if nbits % 8:
            msg = msg[:-1] + bytes([msg[-1] & (0xFF << (8 - nbits % 8)) & 0xFF])
        blocks = list(shavar.padded_blocks(msg, nbits))
        total_bits = 64 * 8 * len(blocks)
        check_equal(total_bits % 512, 0, "L = %d pads to a multiple" % nbits)
        check_equal(len(blocks), shavar.padded_block_count(nbits),
                    "block count for L = %d" % nbits)
        # The last 64 bits encode L, and the 1 bit sits at offset L.
        joined = b"".join(blocks)
        check_equal(int.from_bytes(joined[-8:], "big"), nbits,
                    "length field for L = %d" % nbits)
        bit = (joined[nbits // 8] >> (7 - nbits % 8)) & 1
        check_equal(bit, 1, "the appended 1 bit for L = %d" % nbits)
        # Everything strictly between offset L+1 and the length field is zero.
        tail_bits = 8 * (len(joined) - 8) - (nbits + 1)
        acc = int.from_bytes(joined[:len(joined) - 8], "big")
        check_equal(acc & ((1 << tail_bits) - 1), 0,
                    "zero fill for L = %d" % nbits)


@test
def test_padding_injective():
    """V4, empirically: distinct (message, L) pairs give distinct padded bits."""
    seen = {}
    rng = Xorshift(9)
    for nbits in range(0, 200):
        for _ in range(3):
            msg = rng.bytes((nbits + 7) // 8)
            if nbits % 8:
                msg = msg[:-1] + bytes([msg[-1] & (0xFF << (8 - nbits % 8)) & 0xFF])
            padded = b"".join(shavar.padded_blocks(msg, nbits))
            key = padded
            if key in seen and seen[key] != (msg, nbits):
                raise Failure("padding collision: %r vs %r"
                              % (seen[key], (msg, nbits)))
            seen[key] = (msg, nbits)


@test
def test_trailing_bits_rejected_and_accepted():
    """SPEC.md §5.1 both ways: a validator that rejects everything is no good."""
    accept = [(b"\xb0", 5), (b"\xb8", 5), (b"\x80", 1), (b"\x00", 1),
              (b"\xfe", 7), (b"\xff", 8), (b"", 0), (b"\xf0", 4)]
    for msg, nbits in accept:
        shavar.check_message(msg, nbits)  # must not raise
        shavar.hexdigest(msg, nbits)
    reject = [(b"\xb4", 5), (b"\x01", 1), (b"\xff", 7), (b"\xf1", 4),
              (b"\x00\x01", 9)]
    for msg, nbits in reject:
        try:
            shavar.check_message(msg, nbits)
        except shavar.ShavarError:
            continue
        raise Failure("expected rejection of %r with %d bits" % (msg, nbits))


@test
def test_wrong_buffer_length_rejected():
    for msg, nbits in [(b"", 1), (b"\x00", 0), (b"\x00", 9), (b"\x00\x00", 8)]:
        try:
            shavar.check_message(msg, nbits)
        except shavar.ShavarError:
            continue
        raise Failure("expected rejection of %d bytes with %d bits"
                      % (len(msg), nbits))


@test
def test_bit_length_bound():
    try:
        shavar.check_message(b"", 1 << 64)
    except shavar.ShavarError:
        return
    raise Failure("L must be bounded by 2**64")


# --------------------------------------------------------------------------
# V5: known answers, and agreement with the reference over a sweep
# --------------------------------------------------------------------------


@test
def test_known_answer_vectors():
    for hex_text, nbits, rounds, iv, expected in shavar.VECTORS:
        msg, parsed_bits = shavar.parse_message(hex_text, str(nbits))
        check_equal(parsed_bits, nbits, "vector bit count round-trips")
        got = shavar.hexdigest(msg, nbits, iv=iv, rounds=rounds)
        check_equal(got, expected, "vector %s/%d rounds=%d" % (hex_text, nbits, rounds))


@test
def test_vectors_agree_with_reference():
    """Every built-in vector, recomputed through the eight-register form."""
    for hex_text, nbits, rounds, iv, expected in shavar.VECTORS:
        msg, _ = shavar.parse_message(hex_text, str(nbits))
        got = textbook_hexdigest(msg, nbits, iv=iv, rounds=rounds)
        check_equal(got, expected,
                    "reference disagrees on %s/%d rounds=%d"
                    % (hex_text, nbits, rounds))


@test
def test_swept_bit_lengths_against_reference():
    """A bit-length sweep across block boundaries, both implementations."""
    rng = Xorshift(10)
    lengths = list(range(0, 130)) + list(range(440, 460)) + \
        list(range(500, 530)) + list(range(950, 1030))
    for nbits in lengths:
        msg = rng.bytes((nbits + 7) // 8)
        if nbits % 8:
            msg = msg[:-1] + bytes([msg[-1] & (0xFF << (8 - nbits % 8)) & 0xFF])
        check_equal(shavar.hexdigest(msg, nbits),
                    textbook_hexdigest(msg, nbits),
                    "L = %d" % nbits)


@test
def test_free_start_and_reduced_rounds_against_reference():
    rng = Xorshift(11)
    for _ in range(12):
        nbits = rng.below(1200)
        msg = rng.bytes((nbits + 7) // 8)
        if nbits % 8:
            msg = msg[:-1] + bytes([msg[-1] & (0xFF << (8 - nbits % 8)) & 0xFF])
        iv = [rng.word() for _ in range(8)]
        rounds = rng.below(65)
        check_equal(shavar.hexdigest(msg, nbits, iv=iv, rounds=rounds),
                    textbook_hexdigest(msg, nbits, iv=iv, rounds=rounds),
                    "free start, L = %d, rounds = %d" % (nbits, rounds))


@test
def test_distinct_bit_lengths_give_distinct_digests():
    """The five bits 10110 and the byte 0xb0 must not hash alike."""
    check(shavar.hexdigest(b"\xb0", 5) != shavar.hexdigest(b"\xb0", 8),
          "L must reach the digest, not just the buffer")
    check(shavar.hexdigest(b"\xb0", 5) != shavar.hexdigest(b"\xb8", 5),
          "distinct 5-bit messages must differ")
    check(shavar.hexdigest(b"", 0) != shavar.hexdigest(b"\x00", 1),
          "the empty message differs from a single zero bit")


@test
def test_full_round_is_not_reduced_round():
    a = shavar.hexdigest(b"abc", 24)
    b = shavar.hexdigest(b"abc", 24, rounds=63)
    check(a != b, "63 rounds must differ from 64")


# --------------------------------------------------------------------------
# Difference reporting (SPEC.md §7.3)
# --------------------------------------------------------------------------


@test
def test_difference_report():
    rng = Xorshift(12)
    block = bytearray(rng.bytes(64))
    left = shavar.compress(shavar.IV, bytes(block), 64)
    block[7] ^= 0x01
    right = shavar.compress(shavar.IV, bytes(block), 64)
    diff = shavar.difference(left, right)
    check_equal(sorted(diff), ["A", "E", "W"], "difference reports three tracks")
    check_equal(len(diff["W"]), 64, "one entry per schedule word")
    check_equal(len(diff["A"]), 68, "one entry per A[t], t = -4..63")
    # W[1] carries the flipped bit; W[0] does not.
    w = dict((t, (x, wt)) for t, x, wt, _ in diff["W"])
    check_equal(int(w[0][0]), 0, "W[0] unaffected")
    check_equal(int(w[1][0]), 1, "W[1] differs in exactly the flipped bit")
    check_equal(w[1][1], 1, "Hamming weight of that difference is one")
    # Seeds are shared, so the A/E difference is zero before round 0.
    a = dict((t, x) for t, x, _, _ in diff["A"])
    for t in range(-4, 0):
        check_equal(int(a[t]), 0, "A[%d] is a shared seed" % t)
    check(any(int(a[t]) for t in range(0, 64)), "the difference must propagate")


# --------------------------------------------------------------------------
# The CLI contract (CLI.md)
# --------------------------------------------------------------------------


class Captured(object):
    """Replace sys.stdout/sys.stderr with collectors for one call to main().

    A class with ``__enter__``/``__exit__`` is a *context manager*, usable with
    ``with``; the two methods run on entry and exit, the latter even if the body
    raises.  It is Python's equivalent of RAII.
    """

    class Sink(object):
        """The minimum a writable stream needs to satisfy this module."""

        def __init__(self, buf):
            self.buf = buf

        def write(self, text):
            self.buf.append(text)

        def flush(self):
            pass

    def __init__(self):
        self.out = []
        self.err = []
        self._saved = None

    def __enter__(self):
        self._saved = (sys.stdout, sys.stderr)
        sys.stdout, sys.stderr = self.Sink(self.out), self.Sink(self.err)
        return self

    def __exit__(self, *exc):
        sys.stdout, sys.stderr = self._saved
        return False

    @property
    def stdout(self):
        return "".join(self.out)

    @property
    def stderr(self):
        return "".join(self.err)


def run_cli(*args):
    """Run main() with the given arguments; return (status, stdout, stderr)."""
    cap = Captured()
    with cap:
        status = shavar.main(["shavar.py"] + list(args))
    return status, cap.stdout, cap.stderr


@test
def test_cli_hash():
    status, out, err = run_cli("hash", "-", "0")
    check_equal(status, 0, "empty message exits 0")
    check_equal(out,
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n",
                "digest and one newline, nothing else")
    check_equal(err, "", "nothing on stderr")

    status, out, _ = run_cli("hash", "616263", "24")
    check_equal(status, 0, "abc exits 0")
    check_equal(out,
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\n",
                "abc digest")

    status, out, _ = run_cli("hash", "616263", "24", "64")
    check_equal(status, 0, "explicit 64 rounds exits 0")
    check_equal(out.strip(),
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                "explicit 64 rounds equals the default")

    # Uppercase hex on the way in, lowercase on the way out (CLI.md).
    _, upper, _ = run_cli("hash", "ABCDEF", "24")
    _, lower, _ = run_cli("hash", "abcdef", "24")
    check_equal(upper, lower, "uppercase hex accepted")
    check_equal(upper, upper.lower(), "the digest is always lowercase")


@test
def test_cli_bit_level_accept_and_reject():
    for hex_text in ("b0", "b8"):
        status, out, err = run_cli("hash", hex_text, "5")
        check_equal(status, 0, "%s 5 must be accepted" % hex_text)
        check_equal(len(out), 65, "%s 5 prints a digest" % hex_text)
        check_equal(err, "", "no diagnostics for %s 5" % hex_text)
    status, out, err = run_cli("hash", "b4", "5")
    check_equal(status, 2, "b4 5 has nonzero trailing bits and must be rejected")
    check_equal(out, "", "nothing on stdout when rejecting")
    check(err != "", "a diagnostic on stderr when rejecting")
    # The two accepted five-bit messages are different messages.
    _, a, _ = run_cli("hash", "b0", "5")
    _, b, _ = run_cli("hash", "b8", "5")
    check(a != b, "b0/5 and b8/5 are distinct messages")


@test
def test_cli_usage_errors():
    # Every case here must exit 2 with nothing on stdout. The 23- and 17-bit
    # entries have the right byte count but leave nonzero low bits in 0x63,
    # which SPEC.md §5.1 rejects rather than masks.
    for args in ((), ("bogus",), ("hash",), ("hash", "-"),
                 ("hash", "616263", "23"),
                 ("hash", "616263", "17"),
                 ("hash", "6162", "24"),        # too few bytes
                 ("hash", "61626z", "24"),      # not hex
                 ("hash", "616263", "-1"),      # not a decimal count
                 ("hash", "616263", "24", "65"),  # rounds out of range
                 ("hash", "616263", "24", "64", "x"),  # too many arguments
                 ("trace", "616263", "24", "1"),  # only one block exists
                 ("selftest", "extra")):
        status, out, err = run_cli(*args)
        check_equal(status, 2, "usage error for %r" % (args,))
        check_equal(out, "", "no stdout for %r" % (args,))
        check(err != "", "a diagnostic for %r" % (args,))


@test
def test_cli_selftest():
    status, out, err = run_cli("selftest")
    check_equal(status, 0, "selftest passes")
    check_equal(out, "ok %d\n" % len(shavar.VECTORS), "selftest prints ok <n>")
    check_equal(err, "", "no failures reported")


@test
def test_cli_trace_shape():
    status, out, err = run_cli("trace", "616263", "24")
    check_equal(status, 0, "trace exits 0")
    check_equal(err, "", "no diagnostics")
    lines = out.split("\n")
    check_equal(lines[-1], "", "output ends with a newline")
    lines = lines[:-1]
    check_equal(len(lines), 8 + 64 + 68 + 68 + 64 + 64 + 8, "record count")
    labels = []
    for line in lines:
        fields = line.split("\t")
        check_equal(len(fields), 3, "three tab-separated fields: %r" % line)
        label, t, value = fields
        check_equal(len(value), 8, "hex8 field: %r" % line)
        check_equal(value, value.lower(), "lowercase hex: %r" % line)
        check(all(ch in "0123456789abcdef" for ch in value), "hex digits only")
        int(t)  # raises if not a decimal integer
        labels.append(label)
    # Order and multiplicity, in the sequence CLI.md fixes.
    expected = ["HIN"] * 8 + ["W"] * 64 + ["A"] * 68 + ["E"] * 68 + \
               ["T1"] * 64 + ["T2"] * 64 + ["HOUT"] * 8
    check_equal(labels, expected, "record order")
    # Index columns.
    def column(label):
        return [int(l.split("\t")[1]) for l in lines if l.split("\t")[0] == label]
    check_equal(column("HIN"), list(range(8)), "HIN indices")
    check_equal(column("W"), list(range(64)), "W indices")
    check_equal(column("A"), list(range(-4, 64)), "A indices, negative included")
    check_equal(column("E"), list(range(-4, 64)), "E indices")
    check_equal(column("T1"), list(range(64)), "T1 indices")
    check_equal(column("HOUT"), list(range(8)), "HOUT indices")
    # The seeds are the IV, and A[-4] prints with a leading minus.
    check(("A\t-4\t%s" % shavar.IV[3]) in lines, "A[-4] = H[3], formatted as -4")
    check(("E\t-1\t%s" % shavar.IV[4]) in lines, "E[-1] = H[4]")
    check(("HIN\t0\t6a09e667") in lines, "HIN is the FIPS IV")


@test
def test_cli_trace_reduced_rounds():
    status, out, _ = run_cli("trace", "616263", "24", "0", "16")
    check_equal(status, 0, "reduced trace exits 0")
    lines = out.rstrip("\n").split("\n")
    counts = {}
    for line in lines:
        label = line.split("\t")[0]
        counts[label] = counts.get(label, 0) + 1
    check_equal(counts["W"], 64, "W is complete even when rounds < 64")
    check_equal(counts["A"], 20, "A covers t = -4..15")
    check_equal(counts["E"], 20, "E covers t = -4..15")
    check_equal(counts["T1"], 16, "T1 covers t = 0..15")
    check_equal(counts["T2"], 16, "T2 covers t = 0..15")


@test
def test_cli_trace_second_block():
    """Block 1 of the 896-bit vector: its HIN is block 0's HOUT."""
    hex_text = shavar.VECTORS[3][0]
    _, first, _ = run_cli("trace", hex_text, "896", "0")
    _, second, _ = run_cli("trace", hex_text, "896", "1")
    hout = [l for l in first.rstrip("\n").split("\n") if l.startswith("HOUT")]
    hin = [l for l in second.rstrip("\n").split("\n") if l.startswith("HIN")]
    check_equal([l.split("\t")[2] for l in hin], [l.split("\t")[2] for l in hout],
                "the chaining value carries between blocks")


# --------------------------------------------------------------------------


def run_all():
    failures = 0
    for fn in TESTS:
        try:
            fn()
        except Failure as exc:
            failures += 1
            sys.stdout.write("FAIL %s\n  %s\n" % (fn.__name__, exc))
        except Exception as exc:  # noqa: BLE001 - a test runner must catch all
            failures += 1
            sys.stdout.write("ERROR %s\n  %s: %s\n"
                             % (fn.__name__, type(exc).__name__, exc))
        else:
            sys.stdout.write("ok   %s\n" % fn.__name__)
    sys.stdout.write("\n%d test%s, %d failure%s\n"
                     % (len(TESTS), "" if len(TESTS) == 1 else "s",
                        failures, "" if failures == 1 else "s"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(run_all())
