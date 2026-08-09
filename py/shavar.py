#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""shavar — SHA-256 written as a two-dimensional order-4 recurrence.

This is the Python 3 member of the seven-language set described in
``../spec/SPEC.md``; ``../spec/CLI.md`` fixes the command-line contract.  The
function computed is SHA-256 exactly as in FIPS 180-4.  What differs from the
textbook presentation is the *shape* of the round: instead of eight registers
``a…h`` that shuffle every round, there are two sequences ``A[t]`` and ``E[t]``
with a lookback of four (SPEC.md §3).

    T1[t] = E[t-4] + Σ1(E[t-1]) + Ch(E[t-1], E[t-2], E[t-3]) + K[t] + W[t]
    T2[t] = Σ0(A[t-1]) + Maj(A[t-1], A[t-2], A[t-3])
    E[t]  = A[t-4] + T1[t]
    A[t]  = T1[t] + T2[t]

Dependencies: none.  ``sys`` is imported for ``argv`` and the standard streams
and is the only import in the file; in particular ``hashlib`` is deliberately
not used, here or in the tests.

Notes for a reader who knows C or Lean but not Python
-----------------------------------------------------
Python has no fixed-width integer type.  ``int`` is arbitrary precision, so a
32-bit word has to be *simulated* by masking with ``0xFFFFFFFF`` after every
operation that can grow or go negative.  Rather than scatter that mask across
the round equations — where a single omission would be a silent bug — it is
confined to one class, :class:`Word32`, which overloads the arithmetic
operators.  "Overloading" here means Python looks up a specially named method
(``__add__`` for ``+``, ``__xor__`` for ``^``, and so on; such
double-underscore names are called *dunder* methods) on the left operand's
class.  Defining them lets ``a + b`` and ``a ^ b`` mean 32-bit addition and xor
on our own type, so the round body below can be transcribed straight from the
specification.

The second Python-specific idiom used heavily here is *negative list
indexing*: for a Python list ``xs``, ``xs[-1]`` is the last element, ``xs[-4]``
the fourth from last.  If ``A`` is a list holding ``A[-4] … A[t-1]`` in order,
then at the top of round ``t`` the expression ``A[-4]`` in Python denotes
exactly ``A[t-4]`` in the specification's numbering, and likewise for ``-1``,
``-2``, ``-3``.  A recurrence with lookback ``k`` therefore needs no index
arithmetic at all: the sliding window of SPEC.md §3 *is* the tail of the list.
This is why the round body reads as four lines with no ``+ t`` anywhere.
"""

import sys

# --------------------------------------------------------------------------
# 1.  The 32-bit word
# --------------------------------------------------------------------------


class Word32(object):
    """An unsigned 32-bit word with wrapping arithmetic.

    ``__slots__`` tells Python not to give instances the usual per-object
    attribute dictionary, so a Word32 costs a header plus one pointer instead
    of a dict.  It also makes the type effectively closed: assigning to any
    attribute other than ``v`` raises, which is a cheap guard against typos in
    research code that pokes at traces.
    """

    __slots__ = ("v",)

    MASK = 0xFFFFFFFF

    def __init__(self, value):
        # The single point at which 32-bit-ness is enforced.  Python's ``&``
        # on a negative int behaves as if the int had infinitely many leading
        # sign bits, so masking also converts a negative result (from ``~`` or
        # from subtraction) into its two's-complement 32-bit reading.
        self.v = value & 0xFFFFFFFF

    # -- construction and conversion ---------------------------------------

    @classmethod
    def from_bytes(cls, buf):
        """Big-endian: the first byte of ``buf`` is the most significant."""
        return cls(int.from_bytes(buf, "big"))

    def to_bytes(self):
        return self.v.to_bytes(4, "big")

    def __index__(self):
        # Makes ``int(w)``, ``hex(w)`` and use as a list index all work.  The
        # binary operators below go through ``int(other)``, so any operand
        # implementing __index__ — including a plain Python int — is accepted.
        return self.v

    __int__ = __index__

    # -- operators ---------------------------------------------------------
    #
    # Each returns a fresh Word32; words are immutable by convention, which is
    # what makes retaining the entire A/E history (SPEC.md §3, point 3) safe
    # without copying.

    def __add__(self, other):  # x ⊞ y, addition modulo 2**32
        return Word32(self.v + int(other))

    def __sub__(self, other):  # x ⊟ y, the modular difference of SPEC.md §7.3
        return Word32(self.v - int(other))

    def __xor__(self, other):  # x ⊕ y
        return Word32(self.v ^ int(other))

    def __and__(self, other):  # x ∧ y
        return Word32(self.v & int(other))

    def __or__(self, other):  # x ∨ y
        return Word32(self.v | int(other))

    def __invert__(self):  # ¬x  (Python spells bitwise not as ``~``)
        return Word32(~self.v)

    def __rshift__(self, n):  # SHR^n(x), zero-filled: Python ints have no
        return Word32(self.v >> n)  # sign bit to propagate once masked.

    # ``__radd__`` etc. are omitted on purpose: mixing a bare int on the left
    # of an operator would work but would read as an accident, and every
    # operand in this file is already a Word32.

    def rotr(self, n):
        """ROTR^n(x) — circular right rotation.  ``n`` must be in 0..31."""
        return Word32((self.v >> n) | (self.v << (32 - n)))

    def hamming_weight(self):
        """Population count.  ``int.bit_count`` arrived in Python 3.10; this
        works on 3.9.  Used for the difference diagnostics of SPEC.md §7.3."""
        return bin(self.v).count("1")

    # -- comparison, hashing, display --------------------------------------

    def __eq__(self, other):
        if isinstance(other, Word32):
            return self.v == other.v
        if isinstance(other, int):
            return self.v == other
        return NotImplemented

    def __ne__(self, other):  # Python 2 habit made explicit; harmless on 3.
        result = self.__eq__(other)
        return result if result is NotImplemented else not result

    def __hash__(self):
        return hash(self.v)

    def __str__(self):
        # Exactly eight lowercase hex digits, which is the ``<hex8>`` field of
        # CLI.md.  ``f"{w}"`` and ``str(w)`` both route here.
        return "%08x" % self.v

    def __repr__(self):
        return "Word32(0x%08x)" % self.v


def words_from_hex(text):
    """Parse whitespace-separated 8-digit hex groups into a tuple of words.

    The constant tables below are written as one triple-quoted string laid out
    exactly as in SPEC.md §9 and split on whitespace.  Keeping the visual form
    of the specification removes the commas and brackets that are the usual
    home of a one-digit transcription error.
    """
    return tuple(Word32(int(group, 16)) for group in text.split())


# --------------------------------------------------------------------------
# 2.  Constants (SPEC.md §9)
# --------------------------------------------------------------------------

#: Initial chaining value: first 32 bits of the fractional parts of the square
#: roots of the first eight primes.  ``tests`` recomputes these from the primes
#: rather than trusting the transcription.
IV = words_from_hex("""
    6a09e667 bb67ae85 3c6ef372 a54ff53a 510e527f 9b05688c 1f83d9ab 5be0cd19
""")

#: Round constants: first 32 bits of the fractional parts of the cube roots of
#: the first sixty-four primes.
K = words_from_hex("""
    428a2f98 71374491 b5c0fbcf e9b5dba5 3956c25b 59f111f1 923f82a4 ab1c5ed5
    d807aa98 12835b01 243185be 550c7dc3 72be5d74 80deb1fe 9bdc06a7 c19bf174
    e49b69c1 efbe4786 0fc19dc6 240ca1cc 2de92c6f 4a7484aa 5cb0a9dc 76f988da
    983e5152 a831c66d b00327c8 bf597fc7 c6e00bf3 d5a79147 06ca6351 14292967
    27b70a85 2e1b2138 4d2c6dfc 53380d13 650a7354 766a0abb 81c2c92e 92722c85
    a2bfe8a1 a81a664b c24b8b70 c76c51a3 d192e819 d6990624 f40e3585 106aa070
    19a4c116 1e376c08 2748774c 34b0bcb5 391c0cb3 4ed8aa4a 5b9cca4f 682e6ff3
    748f82ee 78a5636f 84c87814 8cc70208 90befffa a4506ceb bef9a3f7 c67178f2
""")

ROUNDS = 64  #: full SHA-256; a smaller count is a reduced-round variant
BLOCK_BYTES = 64
DIGEST_BYTES = 32
MAX_BITS = 1 << 64  #: FIPS 180-4 encodes L in 64 bits, so L < 2**64

assert len(IV) == 8 and len(K) == 64, "constant table mis-transcribed"


# --------------------------------------------------------------------------
# 3.  The six round functions (SPEC.md §1.1)
# --------------------------------------------------------------------------
#
# Python 3 identifiers may contain any Unicode letter, and Σ and σ are letters,
# so these can carry the specification's own names.  ASCII aliases follow for
# callers who would rather not type Greek.  They are kept as six separate
# functions rather than folded into the round body because SPEC.md §7.1 turns
# on which of them are GF(2)-linear, and research code needs to replace or
# instrument them one at a time.


def ch(x, y, z):
    """Ch(x,y,z) = (x ∧ y) ⊕ (¬x ∧ z) — bit i of x chooses y or z."""
    return (x & y) ^ (~x & z)


def maj(x, y, z):
    """Maj(x,y,z) = (x ∧ y) ⊕ (x ∧ z) ⊕ (y ∧ z) — bitwise majority."""
    return (x & y) ^ (x & z) ^ (y & z)


def Σ0(x):
    """Σ0(x) = ROTR^2(x) ⊕ ROTR^13(x) ⊕ ROTR^22(x). State function."""
    return x.rotr(2) ^ x.rotr(13) ^ x.rotr(22)


def Σ1(x):
    """Σ1(x) = ROTR^6(x) ⊕ ROTR^11(x) ⊕ ROTR^25(x). State function."""
    return x.rotr(6) ^ x.rotr(11) ^ x.rotr(25)


def σ0(x):
    """σ0(x) = ROTR^7(x) ⊕ ROTR^18(x) ⊕ SHR^3(x). Schedule function."""
    return x.rotr(7) ^ x.rotr(18) ^ (x >> 3)


def σ1(x):
    """σ1(x) = ROTR^17(x) ⊕ ROTR^19(x) ⊕ SHR^10(x). Schedule function."""
    return x.rotr(17) ^ x.rotr(19) ^ (x >> 10)


# ASCII spellings of the same four functions.
Sigma0, Sigma1, sigma0, sigma1 = Σ0, Σ1, σ0, σ1


# --------------------------------------------------------------------------
# 4.  The message schedule as a lazy stream (SPEC.md §4)
# --------------------------------------------------------------------------


def message_schedule(block):
    """Yield W[0], W[1], W[2], … for a 64-byte block, without end.

    A Python function containing ``yield`` is a *generator*: calling it runs no
    code but returns an iterator, and each ``next()`` on that iterator resumes
    the body until the following ``yield``.  The function therefore describes a
    potentially infinite sequence while only ever holding the state it needs —
    which for an order-16 recurrence is sixteen words, no matter how far the
    consumer walks.  SHA-256 stops at t = 63, but the recurrence itself does
    not, and writing it this way says so.

    ``W[t] = M[t]`` for t < 16, and thereafter
    ``W[t] = σ1(W[t-2]) ⊞ W[t-7] ⊞ σ0(W[t-15]) ⊞ W[t-16]``.
    """
    # ``range(0, 64, 4)`` is start, stop, step; ``block[i:i+4]`` is a slice.
    # The list comprehension below is the whole of "split the block into
    # sixteen big-endian words".
    window = [Word32.from_bytes(block[i:i + 4]) for i in range(0, BLOCK_BYTES, 4)]

    # ``yield from`` delegates to another iterable: emit W[0..15] verbatim.
    yield from window

    while True:
        # Negative indices are the lookback, exactly as in the formula.
        nxt = σ1(window[-2]) + window[-7] + σ0(window[-15]) + window[-16]
        window.append(nxt)
        del window[0]  # keep the window at sixteen: bounded state, endless stream
        yield nxt


def take(n, iterable):
    """First ``n`` items of an iterable, as a list.

    ``itertools.islice`` would do this, but the project forbids imports, and
    zipping against ``range(n)`` is the standard import-free equivalent: ``zip``
    stops at its shortest argument, so the infinite side is only advanced n
    times.
    """
    return [item for item, _ in zip(iterable, range(n))]


# --------------------------------------------------------------------------
# 5.  Traces
# --------------------------------------------------------------------------


class Track(object):
    """A read-only view of ``A[-4 … r-1]`` (or ``E``) indexed by the spec's t.

    Inside :func:`compress` the tracks are plain Python lists whose negative
    indices happen to mean the right thing *during* the loop.  Once the loop is
    over that coincidence expires — the last element is no longer ``A[t-1]`` for
    the current t — so the finished list is wrapped in this class, whose
    ``__getitem__`` (the dunder behind the ``x[i]`` syntax) shifts by the four
    seed entries.  ``trace.A[-4]`` is then the seed H[0] and ``trace.A[63]`` the
    final value, matching SPEC.md §3 and the ``<t>`` column of CLI.md.
    """

    __slots__ = ("_w",)

    def __init__(self, words):
        self._w = list(words)

    def __getitem__(self, t):
        if isinstance(t, slice):
            raise TypeError("Track is indexed by a single round number t")
        if not -4 <= t < len(self._w) - 4:
            raise IndexError("round index %r out of range [-4, %d)"
                             % (t, len(self._w) - 4))
        return self._w[t + 4]

    def __len__(self):
        return len(self._w)

    def __iter__(self):
        return iter(self._w)

    def indices(self):
        """The valid t values, ``-4 … rounds-1``, as a range object."""
        return range(-4, len(self._w) - 4)

    def items(self):
        """Pairs ``(t, word)`` in increasing t — for printing and diffing."""
        return zip(self.indices(), self._w)

    def __repr__(self):
        return "Track(%d words, t = -4..%d)" % (len(self._w), len(self._w) - 5)


class Trace(object):
    """Everything one block's compression produced.

    Retaining it is not a debugging affordance bolted on afterwards: the A and E
    histories have to exist anyway to serve the lookback, so the only extra cost
    is T1 and T2.  SPEC.md §3 budgets 544 bytes for A and E in C; in Python the
    real cost is object headers rather than words, which is a reason to keep the
    class small and ``__slots__``-ed.
    """

    __slots__ = ("h_in", "h_out", "W", "A", "E", "T1", "T2", "rounds")

    def __init__(self, h_in, h_out, W, A, E, T1, T2, rounds):
        self.h_in = tuple(h_in)
        self.h_out = tuple(h_out)
        self.W = list(W)  # always 64 entries; the schedule ignores `rounds`
        self.A = Track(A)
        self.E = Track(E)
        self.T1 = list(T1)
        self.T2 = list(T2)
        self.rounds = rounds

    def rows(self):
        """Yield ``(label, t, word)`` in the order CLI.md fixes for `trace`."""
        for i, w in enumerate(self.h_in):
            yield ("HIN", i, w)
        for t, w in enumerate(self.W):
            yield ("W", t, w)
        for t, w in self.A.items():
            yield ("A", t, w)
        for t, w in self.E.items():
            yield ("E", t, w)
        for t, w in enumerate(self.T1):
            yield ("T1", t, w)
        for t, w in enumerate(self.T2):
            yield ("T2", t, w)
        for i, w in enumerate(self.h_out):
            yield ("HOUT", i, w)

    def __repr__(self):
        return "Trace(rounds=%d, h_out=%s)" % (
            self.rounds, " ".join(str(w) for w in self.h_out))


# --------------------------------------------------------------------------
# 6.  The compression function (SPEC.md §3)
# --------------------------------------------------------------------------


def compress(h, block, rounds=ROUNDS):
    """Compress one 64-byte ``block`` into the chaining value ``h``.

    ``h`` is any iterable of eight words or plain ints — *not* necessarily
    :data:`IV`.  Accepting a caller-supplied chaining value is what makes
    free-start (chosen-IV) analysis expressible, and ``rounds`` below what makes
    reduced-round analysis expressible; SPEC.md §6 requires both, and neither is
    reachable through an ordinary hashing API.

    Returns a :class:`Trace`.  The new chaining value is ``trace.h_out``.
    """
    if not 0 <= rounds <= ROUNDS:
        raise ShavarError("rounds must be in 0..%d, got %r" % (ROUNDS, rounds))
    h_in = tuple(Word32(int(x)) for x in h)
    if len(h_in) != 8:
        raise ShavarError("chaining value must have 8 words, got %d" % len(h_in))
    if len(block) != BLOCK_BYTES:
        raise ShavarError("block must be %d bytes, got %d"
                          % (BLOCK_BYTES, len(block)))

    # The schedule is independent of the round count, so it is always taken to
    # 64 (CLI.md says to print all 64 even for a reduced run).
    W = take(ROUNDS, message_schedule(block))

    # Seeds, from SPEC.md §3:  A[-1..-4] = H[0..3],  E[-1..-4] = H[4..7].
    # Stored in increasing t, so the list reads A[-4], A[-3], A[-2], A[-1] and
    # its Python negative indices already denote the spec's lookback terms.
    # ``[::-1]`` is a slice with step -1: reverse.
    A = list(h_in[0:4][::-1])
    E = list(h_in[4:8][::-1])
    T1s, T2s = [], []

    for t in range(rounds):
        # ---- the recurrence, transcribed ---------------------------------
        T1 = E[-4] + Σ1(E[-1]) + ch(E[-1], E[-2], E[-3]) + K[t] + W[t]
        T2 = Σ0(A[-1]) + maj(A[-1], A[-2], A[-3])
        E.append(A[-4] + T1)  # must precede the A append: it reads the old A window
        A.append(T1 + T2)
        # ------------------------------------------------------------------
        T1s.append(T1)
        T2s.append(T2)

    # Outgoing chaining value.  After the loop the four newest entries of each
    # list are, in order, the spec's A[r-4..r-1]; the pairing below is
    # H[0] ⊞= A[r-1], H[1] ⊞= A[r-2], … , H[7] ⊞= E[r-4], which for r = 64 is
    # exactly SPEC.md §3.  ``zip`` walks the two 8-tuples in step.
    tail = (A[-1], A[-2], A[-3], A[-4], E[-1], E[-2], E[-3], E[-4])
    h_out = tuple(x + y for x, y in zip(h_in, tail))

    return Trace(h_in, h_out, W, A, E, T1s, T2s, rounds)


# --------------------------------------------------------------------------
# 7.  Padding for arbitrary bit length (SPEC.md §5)
# --------------------------------------------------------------------------


class ShavarError(Exception):
    """Bad input: malformed hex, wrong lengths, nonzero trailing bits.

    Raised rather than handled locally so that the whole CLI can convert any of
    them into exit code 2 in one place (CLI.md, Exit codes).
    """


def check_message(msg, nbits):
    """Validate the (buffer, bit count) pair of SPEC.md §5.1.

    The buffer must hold exactly ``ceil(nbits/8)`` bytes, and when ``nbits`` is
    not a multiple of 8 the unused low-order bits of the final byte must be
    zero.  They are *rejected*, never masked: masking would send two distinct
    inputs to one digest and hide the caller's bug.
    """
    if nbits < 0:
        raise ShavarError("bit length must be non-negative")
    if nbits >= MAX_BITS:
        raise ShavarError("bit length must be < 2**64 (FIPS 180-4 bound)")
    whole, rem = divmod(nbits, 8)  # divmod returns quotient and remainder
    if len(msg) != whole + (1 if rem else 0):
        raise ShavarError("message is %d bytes but %d bits needs %d"
                          % (len(msg), nbits, whole + (1 if rem else 0)))
    if rem and (msg[whole] & ((1 << (8 - rem)) - 1)):
        raise ShavarError(
            "final byte 0x%02x has nonzero bits below the top %d; "
            "SPEC.md §5.1 requires them to be zero" % (msg[whole], rem))


def padded_block_count(nbits):
    """Number of 512-bit blocks after padding.

    ``L + 1 + k + 64 ≡ 0 (mod 512)`` with k minimal, so the count is
    ``ceil((L + 65) / 512)``, written here without floats.
    """
    return (nbits + 65 + 511) // 512


def padded_blocks(msg, nbits):
    """Yield the padded message as 64-byte blocks, lazily.

    Blocks made up entirely of message bytes are handed out as slices of the
    input, so a long message is never copied into one big padded buffer; only
    the final one or two blocks are built.  Being a generator, this can also be
    consumed partway — which is what the `trace` subcommand does when asked for
    block 0 of a long message.
    """
    check_message(msg, nbits)
    whole, rem = divmod(nbits, 8)

    full_blocks = nbits // (8 * BLOCK_BYTES)  # blocks holding message bits only
    for i in range(full_blocks):
        yield msg[i * BLOCK_BYTES:(i + 1) * BLOCK_BYTES]

    # Whatever message bytes are left, plus the padding.  ``bytearray`` is the
    # mutable sibling of ``bytes``.
    tail = bytearray(msg[full_blocks * BLOCK_BYTES:whole])

    # Step 1: the single 1 bit, at bit offset L — that is, bit 7 - (L mod 8) of
    # byte floor(L/8).  ``0x80 >> rem`` places it, and for rem == 0 that is a
    # fresh 0x80 byte, so the two cases are one expression.  When rem != 0 the
    # partial byte's own bits are already validated as clean, so ``|`` cannot
    # collide with them.
    tail.append((msg[whole] if rem else 0) | (0x80 >> rem))

    # Step 2: zeros up to 56 bytes mod 64, i.e. bit 448 mod 512.
    while len(tail) % BLOCK_BYTES != 56:
        tail.append(0)

    # Step 3: L as a 64-bit big-endian integer.  This is what makes padding
    # injective (SPEC.md §5.3).
    tail += nbits.to_bytes(8, "big")

    for i in range(0, len(tail), BLOCK_BYTES):
        yield bytes(tail[i:i + BLOCK_BYTES])


# --------------------------------------------------------------------------
# 8.  Hashing
# --------------------------------------------------------------------------


def block_chain(msg, nbits, iv=IV, rounds=ROUNDS):
    """Merkle–Damgård over the padded blocks; the final chaining value.

    ``iv`` and ``rounds`` are the free-start and reduced-round handles of
    SPEC.md §6.  With the defaults this is SHA-256; with anything else it is
    explicitly not, and is provided for cryptanalysis.
    """
    h = tuple(Word32(int(x)) for x in iv)
    for block in padded_blocks(msg, nbits):
        h = compress(h, block, rounds).h_out
    return h


def digest(msg, nbits, iv=IV, rounds=ROUNDS):
    """The digest as 32 bytes."""
    return b"".join(w.to_bytes() for w in block_chain(msg, nbits, iv, rounds))


def hexdigest(msg, nbits, iv=IV, rounds=ROUNDS):
    """The digest as 64 lowercase hex characters."""
    return "".join(str(w) for w in block_chain(msg, nbits, iv, rounds))


def block_trace(msg, nbits, index=0, iv=IV, rounds=ROUNDS):
    """The :class:`Trace` of block ``index`` of the padded message.

    Blocks before it are compressed to obtain the chaining value entering it;
    blocks after it are never generated, because :func:`padded_blocks` is lazy
    and this loop simply stops.
    """
    count = padded_block_count(nbits)
    if not 0 <= index < count:
        raise ShavarError("block index %d out of range; the padded message has "
                          "%d block%s" % (index, count, "" if count == 1 else "s"))
    h = tuple(Word32(int(x)) for x in iv)
    trace = None
    # ``enumerate`` pairs each item with its position.
    for i, block in enumerate(padded_blocks(msg, nbits)):
        trace = compress(h, block, rounds)
        h = trace.h_out
        if i == index:
            return trace
    raise AssertionError("unreachable: block count disagreed with the generator")


def difference(left, right):
    """Per-round xor and modular differences of two traces (SPEC.md §7.3).

    Returns a dict mapping ``'W'``, ``'A'``, ``'E'`` to a list of
    ``(t, xor, hamming_weight, modular_difference)``.  Not used by the CLI; it
    is here because the trace exists to be differenced, and doing it in the
    implementation rather than in the harness keeps the definition of "the
    difference" in one place.
    """
    out = {}
    for name in ("W", "A", "E"):
        a, b = getattr(left, name), getattr(right, name)
        if name == "W":
            pairs = list(zip(range(len(a)), a, b))
        else:
            pairs = [(t, a[t], b[t]) for t in a.indices()]
        out[name] = [(t, x ^ y, (x ^ y).hamming_weight(), x - y)
                     for t, x, y in pairs]
    return out


# --------------------------------------------------------------------------
# 8a.  Proof-of-work comparison (SPEC.md §10)
# --------------------------------------------------------------------------
#
# The parameter called ``nbits`` in this section is Bitcoin's compact *target*
# encoding and has nothing to do with the message bit length called ``nbits``
# everywhere else in this file.  The collision is inherited from both
# conventions rather than chosen here.


def pow_target(nbits):
    """Decode a compact ``nBits`` target into 32 **big-endian** bytes.

    ``target[0]`` is the most significant byte.  Raises :class:`ShavarError`
    if the encoding is negative, overflows 256 bits, or denotes zero.

    Python has arbitrary-precision integers and could simply shift, but this
    builds the byte array the same way the six other implementations must,
    because none of them may use a bignum library (SPEC.md §6) and the point
    of having seven versions is that they agree for the same reasons.
    """
    exponent = nbits >> 24
    mantissa = nbits & 0x007FFFFF

    # The sign bit.  A target is an unsigned magnitude, so this is an error
    # rather than something to mask off.  Guarded on a nonzero mantissa to
    # match Bitcoin's SetCompact exactly.
    if mantissa != 0 and (nbits & 0x00800000) != 0:
        raise ShavarError("nBits 0x%08x is negative" % nbits)

    if mantissa != 0 and (exponent > 34
                          or (mantissa > 0xFF and exponent > 33)
                          or (mantissa > 0xFFFF and exponent > 32)):
        raise ShavarError("nBits 0x%08x overflows 256 bits" % nbits)

    target = bytearray(32)
    if exponent <= 3:
        v = mantissa >> (8 * (3 - exponent))
        target[31] = v & 0xFF
        target[30] = (v >> 8) & 0xFF
        target[29] = (v >> 16) & 0xFF
    else:
        # ``shift`` is the byte offset of the mantissa's low byte from the
        # least significant end, so in a big-endian array it lands at index
        # 31 - shift.  The overflow test above guarantees no nonzero byte
        # would land at a negative index.
        shift = exponent - 3
        if 31 - shift >= 0:
            target[31 - shift] = mantissa & 0xFF
        if 30 - shift >= 0:
            target[30 - shift] = (mantissa >> 8) & 0xFF
        if 29 - shift >= 0:
            target[29 - shift] = (mantissa >> 16) & 0xFF

    # A zero target is unsatisfiable, so it is a malformed request rather
    # than a verdict of "no" against every possible digest.
    if not any(target):
        raise ShavarError("nBits 0x%08x denotes a zero target" % nbits)
    return bytes(target)


def pow_check(digest_bytes, nbits):
    """Does ``digest_bytes`` meet the target encoded by ``nbits``?

    ``digest_bytes`` is the digest in **emission order** — the order
    :func:`digest` returns, and the order the hex of :func:`hexdigest` reads.

    THE BYTE ORDER, which is the only thing here that is easy to get wrong:
    the digest is read LITTLE-endian.  ``digest_bytes[0]``, the first byte the
    hash function emitted, is the LEAST significant byte of the 256-bit value;
    ``digest_bytes[31]`` is the MOST significant.  That is the reverse of the
    order the bytes are written in, and it is why a Bitcoin block hash is
    displayed reversed relative to the digest actually computed.  See
    SPEC.md §10.1.

    The comparison is ``value <= target``, not ``<``.
    """
    if len(digest_bytes) != DIGEST_BYTES:
        raise ShavarError("digest must be %d bytes, got %d"
                          % (DIGEST_BYTES, len(digest_bytes)))
    target = pow_target(nbits)

    # Both values walked most significant byte first.  ``target`` is already
    # in that order; the digest is not, so it is indexed backwards.  That
    # index expression is the whole convention: writing ``digest_bytes[i]``
    # there is the classic byte-order bug, and it is silent.
    for i in range(DIGEST_BYTES):
        a = digest_bytes[DIGEST_BYTES - 1 - i]
        b = target[i]
        if a < b:
            return True
        if a > b:
            return False
    return True  # every byte equal: value == target, and the relation is <=


# --------------------------------------------------------------------------
# 9.  Known-answer vectors
# --------------------------------------------------------------------------
#
# Each entry is (hex, nbits, rounds, iv, expected-digest).
#
# The first five are FIPS 180-4 / CAVP byte-oriented vectors.  The remainder
# cannot be quoted from a standard: NIST's bit-oriented vectors are not
# reproduced here, and reduced-round and chosen-IV outputs are by definition not
# SHA-256 and appear in no reference.  They were obtained instead from an
# independent second implementation — the textbook eight-register form of
# SPEC.md §2, transcribed separately in ``test_shavar.py`` — and, for the
# sub-byte cases, cross-checked against the padded block written out by hand
# from the worked example in SPEC.md §5.2.  ``test_shavar.py`` re-derives all of
# them on every run, so they are checked rather than merely asserted.

VECTORS = (
    # empty message
    ("-", 0, ROUNDS, IV,
     "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
    # "abc"
    ("616263", 24, ROUNDS, IV,
     "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
    # "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", 448 bits,
    # one block after padding
    ("6162636462636465636465666465666765666768666768696768696a68696a6b"
     "696a6b6c6a6b6c6d6b6c6d6e6c6d6e6f6d6e6f706e6f7071", 448, ROUNDS, IV,
     "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
    # the 896-bit example: two blocks, exercising the chaining value
    ("61626364656667686263646566676869636465666768696a6465666768696a6b"
     "65666768696a6b6c666768696a6b6c6d6768696a6b6c6d6e68696a6b6c6d6e6f"
     "696a6b6c6d6e6f706a6b6c6d6e6f70716b6c6d6e6f7071726c6d6e6f70717273"
     "6d6e6f70717273746e6f707172737475", 896, ROUNDS, IV,
     "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"),
    # exactly one block of message plus a whole block of padding
    ("00" * 64, 512, ROUNDS, IV,
     "f5a5fd42d16a20302798ef6ed309979b43003d2320d9f0e8ea9831a92759fb4b"),
    # sub-byte lengths (SPEC.md §5).
    # 10110 — the worked example of §5.2.
    ("b0", 5, ROUNDS, IV,
     "82c9ef980dfdf26f0cb97f59d34a60dc39c82e489da9ca2132681fe0aa14270a"),
    # a single 1 bit.
    ("80", 1, ROUNDS, IV,
     "b9debf7d52f36e6468a54817c1fa071166c3a63d384850e1575b42f702dc5aa1"),
    # 10111 — same buffer width as `b0 5`, differing in the fifth bit, so a
    # padder that dropped or misplaced significant bits would collide with it.
    ("b8", 5, ROUNDS, IV,
     "9103bf6cd9f1134d81807ade91d54d9888b1a3df1f947f735ce00220dca5261c"),
    # 892 bits: a sub-byte length that also spans two blocks.
    ("61626364656667686263646566676869636465666768696a6465666768696a6b"
     "65666768696a6b6c666768696a6b6c6d6768696a6b6c6d6e68696a6b6c6d6e6f"
     "696a6b6c6d6e6f706a6b6c6d6e6f70716b6c6d6e6f7071726c6d6e6f70717273"
     "6d6e6f70717273746e6f7071727374f0", 892, ROUNDS, IV,
     "602d928ca765d1c3f0a0a1b507ceb154fff6fb312ab7f508204aa9ed9d21be72"),
    # reduced round count — not SHA-256; see SPEC.md §6
    ("616263", 24, 16, IV,
     "1b0409f57bcc0e6315a1de882ce11eca5867604ca6985a9893de22897a384f31"),
    ("616263", 24, 48, IV,
     "ab7c18f45cb3c335af1a3f03cbb27d4f4fdd5e457080fd35d6f9374c03efdf09"),
    # free start: a chaining value that is not the FIPS one
    ("616263", 24, ROUNDS,
     words_from_hex("00000000 11111111 22222222 33333333 "
                    "44444444 55555555 66666666 77777777"),
     "1412bffa0384dd818671197dca40bb3f0b1e64d8697e67e74e5178863197640d"),
)


# --------------------------------------------------------------------------
# 10.  Command line (CLI.md)
# --------------------------------------------------------------------------

EXIT_OK = 0
EXIT_SELFTEST_FAILED = 1
EXIT_USAGE = 2

USAGE = """\
usage: shavar.py hash  <hex> <nbits> [rounds]
       shavar.py trace <hex> <nbits> [blockidx] [rounds]
       shavar.py selftest

<hex> is 2*ceil(nbits/8) hex digits, or - for the empty message.
"""


def parse_message(hex_text, nbits_text):
    """Decode the ``<hex> <nbits>`` pair of CLI.md into (bytes, int)."""
    nbits = parse_count(nbits_text, "nbits")
    if nbits >= MAX_BITS:
        raise ShavarError("nbits must be < 2**64 (FIPS 180-4 bound)")
    want_bytes = (nbits + 7) // 8
    digits = "" if hex_text == "-" else hex_text
    if len(digits) != 2 * want_bytes:
        raise ShavarError("expected %d hex digits for %d bits, got %d"
                          % (2 * want_bytes, nbits, len(digits)))
    try:
        msg = bytes.fromhex(digits)
    except ValueError:
        raise ShavarError("malformed hex: %r" % hex_text)
    check_message(msg, nbits)  # rejects nonzero trailing bits
    return msg, nbits


def parse_count(text, what):
    """A decimal non-negative integer, and nothing else.

    ``int(text)`` alone would accept ``+7``, ``  7  ``, ``1_0`` and ``-0``; the
    explicit digit test keeps seven implementations agreeing on what is legal.
    """
    if not text.isdigit():
        raise ShavarError("%s must be a decimal non-negative integer, got %r"
                          % (what, text))
    return int(text)


def cmd_hash(args):
    if not 2 <= len(args) <= 3:
        raise ShavarError("hash takes <hex> <nbits> [rounds]")
    msg, nbits = parse_message(args[0], args[1])
    rounds = parse_rounds(args[2]) if len(args) == 3 else ROUNDS
    sys.stdout.write(hexdigest(msg, nbits, rounds=rounds) + "\n")
    return EXIT_OK


def cmd_trace(args):
    if not 2 <= len(args) <= 4:
        raise ShavarError("trace takes <hex> <nbits> [blockidx] [rounds]")
    msg, nbits = parse_message(args[0], args[1])
    index = parse_count(args[2], "blockidx") if len(args) >= 3 else 0
    rounds = parse_rounds(args[3]) if len(args) >= 4 else ROUNDS
    tr = block_trace(msg, nbits, index, rounds=rounds)
    # Build the whole report and write it once: the format is a single tab
    # between three fields, and a generator expression inside ``join`` is the
    # usual Python way to say that without a loop variable escaping.
    sys.stdout.write("".join("%s\t%d\t%s\n" % row for row in tr.rows()))
    return EXIT_OK


def parse_rounds(text):
    rounds = parse_count(text, "rounds")
    if rounds > ROUNDS:
        raise ShavarError("rounds must be in 0..%d" % ROUNDS)
    return rounds


def cmd_selftest(args):
    """Run :data:`VECTORS`; ``ok <n>`` on stdout, FAIL lines on stderr.

    Failures go to stderr because CLI.md requires stdout to be either
    well-formed output or empty.
    """
    if args:
        raise ShavarError("selftest takes no arguments")
    failures = 0
    for hex_text, nbits, rounds, iv, expected in VECTORS:
        msg, _ = parse_message(hex_text, str(nbits))
        got = hexdigest(msg, nbits, iv=iv, rounds=rounds)
        if got != expected:
            failures += 1
            sys.stderr.write("FAIL\t%s %d rounds=%d\texpected %s\tgot %s\n"
                             % (hex_text, nbits, rounds, expected, got))
    if failures:
        return EXIT_SELFTEST_FAILED
    sys.stdout.write("ok %d\n" % len(VECTORS))
    return EXIT_OK


def main(argv):
    """Return the process exit status; see the table in CLI.md."""
    commands = {"hash": cmd_hash, "trace": cmd_trace, "selftest": cmd_selftest}
    if len(argv) < 2 or argv[1] not in commands:
        sys.stderr.write(USAGE)
        return EXIT_USAGE
    try:
        return commands[argv[1]](argv[2:])
    except ShavarError as exc:
        sys.stderr.write("shavar: %s\n" % exc)
        return EXIT_USAGE


# ``__name__`` is "__main__" only when the file is run as a program, so
# importing it from the tests does not execute the CLI.
if __name__ == "__main__":
    sys.exit(main(sys.argv))
