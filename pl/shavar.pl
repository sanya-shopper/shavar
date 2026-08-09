#!/usr/bin/perl
#
# shavar — SHA-256 written as a two-dimensional order-4 recurrence.
# Perl 5 implementation.
#
# Normative references: ../spec/SPEC.md fixes the algorithm, ../spec/CLI.md
# fixes the command line and the output encoding. Where this file disagrees
# with either of them, this file is wrong.
#
# Constraints this file is written under:
#
#   * the system perl (5.34, integers are 64-bit), nothing newer;
#   * no modules whatsoever. `strict` and `warnings` are pragmas that change
#     how the compiler behaves, not libraries; Digest::SHA, MIME::Base64 and
#     bigint are all deliberately unused. Everything below is core syntax.
#
# ===========================================================================
# PERL ORIENTATION, for readers arriving from the C, Python, Lean, Scheme,
# JavaScript or shell versions of this same algorithm.
#
# Perl marks a variable's *shape* with a leading punctuation character (a
# "sigil"), and the sigil describes the thing you are getting back, not the
# thing you are indexing into. That trips up nearly every newcomer, so:
#
#   my $x        a scalar: one number, string, or reference. `my` = lexical
#                declaration, like C's `auto` or JavaScript's `let`.
#   my @a        an array of scalars.
#   my %h        a hash (Python dict / C hashtable).
#   $a[3]        element 3 of @a — ONE scalar, so the sigil is $, not @.
#   @a[3,1,0]    a *slice*: the three-element list (a[3], a[1], a[0]).
#   $a[-1]       the LAST element. Negative indices count from the end, and
#                this file leans on that heavily: see compress().
#   scalar(@a)   the length of @a. In numeric context @a yields its length.
#   \@a          a reference to @a (a pointer). $r = \@a; then @$r is the
#                array again, $r->[3] is element 3, and @{$r}[3,1] is a slice.
#   \&f          a reference to the subroutine f. $c = \&f; then $c->(1,2)
#                calls it. Closures (subs that capture surrounding lexicals)
#                are ordinary values; this file builds four of them.
#
# Context: an expression is evaluated in "list context" or "scalar context"
# depending on where it sits. `my ($p, $q) = f()` takes the first two elements
# of whatever list f() returned; `my $n = f()` would instead take f()'s scalar
# return. Subroutines receive their arguments as one flat list in the array
# @_, which is why `ch(@E[-1,-2,-3])` below passes three separate arguments
# and not one array.
#
# Statement modifiers: `EXPR for LIST;` is a trailing-for loop, equivalent to
# `for (LIST) { EXPR }` with the loop variable in the implicit variable $_.
# Likewise `EXPR if COND;` and `EXPR unless COND;`.
#
# Errors: `die "msg\n"` throws; `eval { ... }` catches, leaving the message in
# the global $@. That is Perl's try/catch, and main() uses it once.
#
# The three operators that carry most of the weight here (pack, unpack, vec)
# are explained in detail at their first use.
# ===========================================================================

use strict;
use warnings;

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Perl's integers are 64-bit, so every 32-bit operation has to be truncated by
# hand. $M32 is that truncation mask. (Underscores in numeric literals are
# ignored by the parser; they are purely for the reader.)
my $M32 = 0xFFFF_FFFF;

# SPEC.md §9. Initial chaining value: the first 32 bits of the fractional
# parts of the square roots of the first eight primes.
my @IV = (
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
);

# Round constants: the first 32 bits of the fractional parts of the cube roots
# of the first sixty-four primes. shavar.t rederives both tables from the
# primes rather than trusting this transcription.
my @K = (
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
);

my $ROUNDS_MAX = scalar @K;    # 64: the schedule and K both stop here

# ---------------------------------------------------------------------------
# The six round functions (SPEC.md §1.1)
#
# SPEC.md §7.1 asks that these stay individually addressable rather than being
# fused into one expression, because the linear/nonlinear split matters for
# cryptanalytic use: ROTR, SHR and the four sigmas are GF(2)-linear, Ch and Maj
# are not.
# ---------------------------------------------------------------------------

# Rotate right. The left half can push bits above bit 31, so mask afterwards.
# (>> on a value already inside 32 bits never needs masking, but SHR is
# written symmetrically with ROTR for readability.)
sub rotr { my ($x, $n) = @_; return (($x >> $n) | ($x << (32 - $n))) & $M32 }

# Logical (zero-filled) right shift. Perl's >> on a non-negative integer is
# already zero-filled — there is no signed-shift trap here as there is in C,
# because the operands are unsigned integer values, not int32_t.
sub shr32 { my ($x, $n) = @_; return ($x >> $n) & $M32 }

# Ch(x,y,z) = (x AND y) XOR (NOT x AND z). Perl's ~ complements all 64 bits,
# so the result is masked back down to 32.
sub ch { my ($x, $y, $z) = @_; return (($x & $y) ^ (~$x & $z)) & $M32 }

# Maj(x,y,z): each output bit is the majority of the three input bits. No mask
# needed — AND and XOR of values already inside 32 bits cannot escape it.
sub maj { my ($x, $y, $z) = @_; return ($x & $y) ^ ($x & $z) ^ ($y & $z) }

# The four sigma functions are all the same shape: XOR three transformed
# copies of the input. Rather than write that shape out four times and risk a
# transcription slip in one of them, write the shape once and keep the four
# instances as a table that can be read straight off SPEC.md §1.1.

my %OP = (ROTR => \&rotr, SHR => \&shr32);    # names to code references

# xor_of(TERM, TERM, TERM) returns a *closure*: a new anonymous subroutine
# that has captured @ops and will still see it after xor_of has returned.
# Each TERM is a two-element array reference [ 'ROTR'|'SHR', amount ].
sub xor_of {
    # Resolve the operation names to code references once, at build time,
    # instead of doing a hash lookup on every call.
    my @ops = map { [ $OP{ $_->[0] }, $_->[1] ] } @_;
    return sub {
        my ($x) = @_;
        my $acc = 0;
        # $_->[0] is the code reference, $_->[1] the shift amount.
        # ^= on two numbers is numeric XOR. (Beware: in Perl ^ on two
        # *strings* is a bytewise string XOR, an entirely different operator
        # chosen by the operands' types. $acc starts as the number 0, and
        # rotr/shr32 return numbers, so this stays numeric throughout.)
        $acc ^= $_->[0]->($x, $_->[1]) for @ops;
        return $acc;
    };
}

# `=>` is the "fat comma": it behaves like a comma but also auto-quotes a bare
# word on its left, so [ROTR => 2] is exactly ['ROTR', 2].
my $Sigma0 = xor_of([ ROTR => 2 ],  [ ROTR => 13 ], [ ROTR => 22 ]);
my $Sigma1 = xor_of([ ROTR => 6 ],  [ ROTR => 11 ], [ ROTR => 25 ]);
my $sigma0 = xor_of([ ROTR => 7 ],  [ ROTR => 18 ], [ SHR  => 3 ]);
my $sigma1 = xor_of([ ROTR => 17 ], [ ROTR => 19 ], [ SHR  => 10 ]);

# ---------------------------------------------------------------------------
# Padding for arbitrary bit length (SPEC.md §5)
# ---------------------------------------------------------------------------

# pad_message($bytes, $nbits) -> padded byte string whose length is a multiple
# of 64. $bytes must hold exactly ceil($nbits/8) bytes, with any unused
# low-order bits of the final byte zero; a nonzero one is an error, never
# silently masked (SPEC.md §5.1).
#
# This is where Perl's vec() earns its place. vec($str, $i, $bits) treats a
# string as a packed array of $bits-wide unsigned fields and returns field $i;
# used as an lvalue it assigns to that field, extending the string with zero
# bytes if $i is past the end. With $bits == 1 it is direct bit addressing of
# a byte string, which is exactly the primitive this section wants.
#
# One wrinkle, and it is the only awkward thing in the whole file. vec numbers
# its sub-byte fields from the LEAST significant end of each byte, whereas
# FIPS 180-4 numbers message bits from the MOST significant end. So FIPS bit
# index i lives at vec index i^7: XOR by 7 leaves the byte number alone (bits
# 3 and up are untouched) and maps the offset r within the byte to 7-r, which
# is precisely the two conventions' disagreement. Every vec() below therefore
# reads `$i ^ 7`.
sub pad_message {
    my ($msg, $nbits) = @_;

    my $need = int(($nbits + 7) / 8);
    die "message buffer is @{[ length $msg ]} bytes, need $need for $nbits bits\n"
        if length($msg) != $need;

    # Reject a final byte whose unused low bits are set. `..` builds the range
    # of FIPS bit indices past the end of the message (at most 7 of them);
    # grep keeps the ones whose bit is 1; in the boolean context of `if`, the
    # resulting list yields its own length, so a nonempty list is true.
    if (grep { vec($msg, $_ ^ 7, 1) } $nbits .. 8 * length($msg) - 1) {
        die "nonzero trailing bits in final byte (nbits=$nbits)\n";
    }

    # Step 1: the mandatory single 1 bit at bit offset $nbits. When $nbits is
    # a multiple of 8 this addresses a byte one past the end of the string and
    # vec grows the string by one zero byte first, giving 0x80 — no special
    # case needed for the byte-aligned path.
    my $padded = $msg;                  # copy; Perl assigns strings by value
    vec($padded, $nbits ^ 7, 1) = 1;

    # Step 2: zero bits up to the next length congruent to 448 mod 512, i.e.
    # 56 mod 64 bytes. `x` is the string repetition operator, so "\0" x 3 is
    # three NUL bytes. Note that Perl's % always returns a result with the
    # sign of its right operand, so (56 - 63) % 64 is 57 and not C's -7; this
    # expression would need an extra +64 in C.
    $padded .= "\0" x ((56 - length($padded) % 64) % 64);

    # Step 3: the bit length as a 64-bit big-endian integer. In a pack
    # template 'Q' is a 64-bit unsigned integer and the '>' modifier forces
    # big-endian byte order regardless of the host. (SPEC.md §5 notes the
    # standard's implicit bound L < 2**64, which is exactly what 'Q' holds.)
    $padded .= pack('Q>', $nbits);

    return $padded;
}

# ---------------------------------------------------------------------------
# The compression function (SPEC.md §3 and §4)
# ---------------------------------------------------------------------------

# compress($h, $block, $rounds, $tr)
#
#   $h      array reference to the eight-word chaining value, updated IN PLACE.
#           Any chaining value is accepted, not only @IV: free-start attacks
#           need that and SPEC.md §6 requires it.
#   $block  a 64-byte string.
#   $rounds how many rounds to run, 0 .. 64. Fewer than 64 is not SHA-256; it
#           is the reduced-round variant, also required by §6.
#   $tr     optional hash reference. If given, it is emptied and refilled with
#           the complete interior of this block's compression.
#
# The two arrays @A and @E are grown with push, and the lookback window of
# SPEC.md §3 is then just their last four elements. Perl's negative indexing
# makes that literal: at the top of round t, @A holds A[-4 .. t-1], so $A[-1]
# IS A[t-1], $A[-4] IS A[t-4], and the slice @A[-1,-2,-3] IS the argument list
# (A[t-1], A[t-2], A[t-3]). Nothing has to be shuffled, offset by four, or
# renamed, and the code below is a transcription of the spec's recurrences
# with the indices left as the spec writes them.
sub compress {
    my ($h, $block, $rounds, $tr) = @_;

    # --- message schedule, SPEC.md §4 -------------------------------------
    # unpack('N16', $s) splits the string into sixteen values, each read as a
    # 32-bit unsigned big-endian integer ('N' is mnemonic for network order,
    # the count '16' repeats it). This is the whole of the byte-order problem
    # in one token: no shifting, no host-endianness question.
    my @W = unpack('N16', $block);

    # W[t] = sigma1(W[t-2]) + W[t-7] + sigma0(W[t-15]) + W[t-16], and since
    # @W has exactly t elements at the moment W[t] is computed, the negative
    # indices are the spec's indices unchanged.
    #
    # Four 32-bit values sum to at most 2**34, comfortably inside a 64-bit
    # integer (and even inside a double's 53-bit mantissa, so this stays exact
    # on a perl built without 64-bit integers). One mask at the end of the sum
    # is therefore equivalent to masking after each addition.
    for my $t (16 .. $ROUNDS_MAX - 1) {
        push @W,
            ( $sigma1->($W[-2]) + $W[-7] + $sigma0->($W[-15]) + $W[-16] ) & $M32;
    }

    # --- the two tracks, SPEC.md §3 ---------------------------------------
    # Seed A[-4..-1] from H[3,2,1,0] and E[-4..-1] from H[7,6,5,4]: the spec
    # writes A[-1] = H[0], and A[-1] is the last element, so the seeds go in
    # reversed. @{$h}[3,2,1,0] is a slice of the array behind the reference.
    my @A = @{$h}[ 3, 2, 1, 0 ];
    my @E = @{$h}[ 7, 6, 5, 4 ];
    my (@T1, @T2);

    for my $t (0 .. $rounds - 1) {
        # T1 sums five 32-bit values, at most 2**34.4 — still exact.
        my $t1 = ( $E[-4]
                 + $Sigma1->($E[-1])
                 + ch(@E[ -1, -2, -3 ])
                 + $K[$t]
                 + $W[$t] ) & $M32;
        my $t2 = ( $Sigma0->($A[-1]) + maj(@A[ -1, -2, -3 ]) ) & $M32;

        # E[t] = A[t-4] + T1[t] must read $A[-4] before @A grows, so push @E
        # first. A[t] = T1[t] + T2[t] needs no history at all.
        push @E, ( $A[-4] + $t1 ) & $M32;
        push @A, ( $t1 + $t2 ) & $M32;
        push @T1, $t1;
        push @T2, $t2;
    }

    # --- feed forward ------------------------------------------------------
    # H[0..3] += A[63,62,61,60] and H[4..7] += E[63,62,61,60]. Written as the
    # last four elements of each track, which is both what the spec means and
    # the right generalisation when $rounds < 64.
    my @hin   = @$h;
    my @final = ( @A[ -1, -2, -3, -4 ], @E[ -1, -2, -3, -4 ] );
    $h->[$_] = ( $h->[$_] + $final[$_] ) & $M32 for 0 .. 7;

    if ($tr) {
        # %$tr is the hash behind the reference; assigning a list to it
        # replaces its contents wholesale.
        %$tr = (
            hin => \@hin,
            # A and E are stored with the seeds still at the front, so index i
            # holds t = i-4, the same +4 offset the C version documents.
            A      => \@A,
            E      => \@E,
            W      => \@W,
            T1     => \@T1,
            T2     => \@T2,
            hout   => [@$h],
            rounds => $rounds,
        );
    }
    return;
}

# ---------------------------------------------------------------------------
# Hashing
# ---------------------------------------------------------------------------

# hash_ex($bytes, $nbits, $iv, $rounds) -> the eight-word digest as a LIST.
# A list return is the natural Perl shape: the caller writes
# `my @d = hash_ex(...)` for the words or feeds it straight to sprintf.
sub hash_ex {
    my ($msg, $nbits, $iv, $rounds) = @_;
    my $padded = pad_message($msg, $nbits);
    my @h      = @$iv;
    compress( \@h, substr($padded, 64 * $_, 64), $rounds )
        for 0 .. length($padded) / 64 - 1;
    return @h;
}

# The plain interface: FIPS initial value, all 64 rounds.
sub hash {
    my ($msg, $nbits) = @_;
    return hash_ex($msg, $nbits, \@IV, $ROUNDS_MAX);
}

# Eight words to 64 lowercase hex digits. `'%08x' x 8` repeats the format
# string eight times before sprintf ever sees it, so the format is built to
# match the argument list rather than the arguments being looped over.
sub hexdigest { return sprintf('%08x' x 8, @_) }

# ---------------------------------------------------------------------------
# Proof-of-work comparison (SPEC.md §10)
# ---------------------------------------------------------------------------
#
# The argument called $nbits here is Bitcoin's compact *target* encoding and
# has nothing to do with the message bit length called $nbits elsewhere in
# this file. The collision is inherited from both conventions.

# pow_target($nbits) -> 32 bytes, BIG-endian: byte 0 is the most significant.
# Dies on an encoding that is negative, overflows 256 bits, or denotes zero.
#
# Built byte by byte rather than by shifting an integer, because Perl's native
# integers are 64-bit and a 256-bit target does not fit in one. The other six
# implementations have the same constraint for the same reason, which is why
# they can be expected to agree.
sub pow_target {
    my ($nbits)  = @_;
    my $exponent = ($nbits >> 24) & 0xFF;
    my $mantissa = $nbits & 0x007FFFFF;

    # The sign bit. A target is an unsigned magnitude, so a set sign bit is an
    # error rather than something to mask away. Guarded on a nonzero mantissa
    # to match Bitcoin's SetCompact exactly.
    die sprintf("nBits 0x%08x is negative\n", $nbits)
        if $mantissa != 0 && ($nbits & 0x00800000) != 0;

    die sprintf("nBits 0x%08x overflows 256 bits\n", $nbits)
        if $mantissa != 0
        && ( $exponent > 34
          || ($mantissa > 0xFF   && $exponent > 33)
          || ($mantissa > 0xFFFF && $exponent > 32) );

    my @t = (0) x 32;
    if ($exponent <= 3) {
        my $v = $mantissa >> (8 * (3 - $exponent));
        $t[31] = $v & 0xFF;
        $t[30] = ($v >> 8) & 0xFF;
        $t[29] = ($v >> 16) & 0xFF;
    }
    else {
        # $shift is the byte offset of the mantissa's low byte from the least
        # significant end, so in a big-endian array it lands at index
        # 31 - $shift. The overflow test above guarantees that no nonzero
        # byte would land at a negative index.
        my $shift = $exponent - 3;
        $t[31 - $shift] = $mantissa & 0xFF          if 31 - $shift >= 0;
        $t[30 - $shift] = ($mantissa >> 8) & 0xFF   if 30 - $shift >= 0;
        $t[29 - $shift] = ($mantissa >> 16) & 0xFF  if 29 - $shift >= 0;
    }

    # A zero target is unsatisfiable, so it is a malformed request rather than
    # a verdict of "no" against every possible digest.
    die sprintf("nBits 0x%08x denotes a zero target\n", $nbits)
        unless grep { $_ != 0 } @t;

    return pack('C32', @t);
}

# pow_check($digest, $nbits) -> 1 if the digest meets the target, 0 if not.
# Dies if $nbits is invalid. $digest is 32 raw bytes in EMISSION order.
#
# THE BYTE ORDER, the only thing here that is easy to get wrong: the digest is
# read LITTLE-endian. Byte 0 — the first byte the hash function emitted — is
# the LEAST significant byte of the 256-bit value and byte 31 is the MOST
# significant. That is the reverse of the order the bytes are written in, and
# it is why a Bitcoin block hash is displayed reversed relative to the digest
# actually computed. See SPEC.md §10.1. The comparison is <=, not <.
sub pow_check {
    my ($digest, $nbits) = @_;
    die sprintf("digest must be 32 bytes, got %d\n", length($digest))
        unless length($digest) == 32;

    my @d = unpack('C32', $digest);
    my @t = unpack('C32', pow_target($nbits));

    # Both values walked most significant byte first. @t is already in that
    # order; the digest is not, so it is indexed backwards. `$d[31 - $i]` is
    # the whole convention — writing `$d[$i]` there is the classic byte-order
    # bug, and it is silent.
    for my $i (0 .. 31) {
        my $a = $d[31 - $i];
        my $b = $t[$i];
        return 1 if $a < $b;
        return 0 if $a > $b;
    }
    return 1;   # every byte equal: value == target, and the relation is <=
}

# ---------------------------------------------------------------------------
# Command line (CLI.md)
# ---------------------------------------------------------------------------

# A here-document: everything up to the line reading exactly USAGE is a string.
# Quoting the terminator as 'USAGE' suppresses variable interpolation, so the
# $ and @ characters in the text below are literal.
sub usage {
    return <<'USAGE';
shavar — SHA-256 as a two-dimensional order-4 recurrence (see spec/SPEC.md)

usage:
  shavar.pl hash  <hex> <nbits> [rounds]
  shavar.pl trace <hex> <nbits> [blockidx] [rounds]
  shavar.pl selftest

  <hex>      2*ceil(nbits/8) hex digits, or - for a zero-byte message
  <nbits>    message length in BITS; when not a multiple of 8 the final byte
             carries its significant bits high and its low bits must be zero
  [rounds]   0..64, default 64. Below 64 this is not SHA-256.
  [blockidx] which block of the PADDED message to trace, default 0

exit: 0 ok, 1 selftest failure, 2 bad usage / bad hex / bad trailing bits
USAGE
}

# Parse a decimal non-negative integer, or die. \A and \z anchor to the very
# start and end of the string (unlike ^ and $, which also match at newlines).
sub want_uint {
    my ($s, $what) = @_;
    die "$what must be a non-negative decimal integer, got '$s'\n"
        unless defined $s && $s =~ /\A[0-9]+\z/;
    return 0 + $s;    # force the string to a number
}

sub want_rounds {
    my ($s) = @_;
    my $r = want_uint($s, 'rounds');
    die "rounds must be 0..$ROUNDS_MAX, got $r\n" if $r > $ROUNDS_MAX;
    return $r;
}

# Hex text to a byte string, with the CLI.md length rule enforced.
sub decode_hex {
    my ($hex, $nbits) = @_;
    $hex = '' if $hex eq '-';
    die "malformed hex: '$hex'\n"              unless $hex =~ /\A[0-9A-Fa-f]*\z/;
    die "hex needs an even number of digits\n" if length($hex) % 2;

    # pack('H*', $s) reads $s as hex digits, high nibble of each byte first,
    # and returns the bytes. '*' means "as many as are there". unpack('H*',...)
    # is the inverse. This one template replaces a hand-written nibble loop.
    my $msg  = pack('H*', $hex);
    my $need = int(($nbits + 7) / 8);
    die "nbits=$nbits needs $need message bytes, got @{[ length $msg ]}\n"
        if length($msg) != $need;
    return $msg;
}

sub cmd_hash {
    my ($hex, $nbits, $rounds) = @_;
    my $msg = decode_hex($hex, $nbits);
    print hexdigest( hash_ex($msg, $nbits, \@IV, $rounds) ), "\n";
    return 0;
}

sub cmd_trace {
    my ($hex, $nbits, $blockidx, $rounds) = @_;
    my $msg     = decode_hex($hex, $nbits);
    my $padded  = pad_message($msg, $nbits);
    my $nblocks = length($padded) / 64;
    die "blockidx $blockidx out of range: padded message has $nblocks block(s)\n"
        if $blockidx >= $nblocks;

    my @h = @IV;
    my %tr;
    # Run every block up to the one wanted; only that one records a trace.
    for my $b (0 .. $blockidx) {
        compress( \@h, substr($padded, 64 * $b, 64), $rounds,
                  $b == $blockidx ? \%tr : undef );
    }

    # One record per line, three tab-separated fields, in the order CLI.md
    # fixes. %08x is eight zero-padded lowercase hex digits; \t is a tab.
    printf "HIN\t%d\t%08x\n",  $_,     $tr{hin}[$_]  for 0 .. 7;
    printf "W\t%d\t%08x\n",    $_,     $tr{W}[$_]    for 0 .. $ROUNDS_MAX - 1;
    # A and E run from t = -4, and are stored at index t+4.
    printf "A\t%d\t%08x\n",    $_ - 4, $tr{A}[$_]    for 0 .. $rounds + 3;
    printf "E\t%d\t%08x\n",    $_ - 4, $tr{E}[$_]    for 0 .. $rounds + 3;
    printf "T1\t%d\t%08x\n",   $_,     $tr{T1}[$_]   for 0 .. $rounds - 1;
    printf "T2\t%d\t%08x\n",   $_,     $tr{T2}[$_]   for 0 .. $rounds - 1;
    printf "HOUT\t%d\t%08x\n", $_,     $tr{hout}[$_] for 0 .. 7;
    return 0;
}

# Known-answer vectors: [ hex, nbits, expected digest ].
#
# Vector 1 is the empty-message digest quoted in SPEC.md §5.2; 2-4 are the
# FIPS 180-2 worked examples ("abc", the 448-bit and the 896-bit). 5-7 are padding
# boundary cases (55, 57 and 64 bytes: the last block that still has room for
# the length field, the first that does not, and an exact block) verified
# against an independent SHA-256. 8-9 exercise the sub-byte path of SPEC.md
# §5, which no published FIPS example covers: vector 8 is the spec's own
# worked example (§5.2, the five bits 10110 padding to 0xb4) and vector 9 is
# 447 zero bits, the length at which the appended 1 bit exactly fills the
# 448-bit window. Both digests were cross-checked against the independent
# eight-register implementation in shavar.t rather than taken from NIST.
my @VECTORS = (
    [ '-', 0, 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' ],
    [ '616263', 24, 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' ],
    [   '6162636462636465636465666465666765666768666768696768696a68696a6b'
      . '696a6b6c6a6b6c6d6b6c6d6e6c6d6e6f6d6e6f706e6f7071',
        448,
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1' ],
    [   '61626364656667686263646566676869636465666768696a6465666768696a6b'
      . '65666768696a6b6c666768696a6b6c6d6768696a6b6c6d6e68696a6b6c6d6e6f'
      . '696a6b6c6d6e6f706a6b6c6d6e6f70716b6c6d6e6f7071726c6d6e6f70717273'
      . '6d6e6f70717273746e6f707172737475',
        896,
        'cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1' ],
    [ '61' x 55, 440, '9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318' ],
    [ '61' x 57, 456, 'f13b2d724659eb3bf47f2dd6af1accc87b81f09f59f2b75e5c0bed6589dfe8c6' ],
    [ '61' x 64, 512, 'ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb' ],
    [ 'b0', 5, '82c9ef980dfdf26f0cb97f59d34a60dc39c82e489da9ca2132681fe0aa14270a' ],
    [ '00' x 56, 447, '43fdd2eed4df6d2c38e971da884115051951aa68d892720f79689d4962c9efae' ],
);

sub cmd_selftest {
    my $pass = 0;
    my $fail = 0;
    for my $v (@VECTORS) {
        my ($hex, $nbits, $want) = @$v;
        my $got = eval { hexdigest( hash( decode_hex($hex, $nbits), $nbits ) ) };
        $got = "error: $@" if !defined $got;
        chomp $got;
        if ($got eq $want) { $pass++ }
        else {
            $fail++;
            # Diagnostics go to stderr so that stdout stays either well-formed
            # or empty, per CLI.md.
            print STDERR "FAIL\t$hex\t$nbits\twant=$want\tgot=$got\n";
        }
    }
    print "ok $pass\n" if !$fail;
    return $fail ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

sub main {
    my @argv = @_;
    my $cmd  = shift @argv;

    # eval BLOCK is Perl's try. Anything that dies below lands here with the
    # message in $@, and every such message is a usage/encoding problem, so
    # they all map to exit code 2.
    my $rc = eval {
        if ( !defined $cmd ) {
            die usage();
        }
        elsif ( $cmd eq 'hash' ) {
            die usage() if @argv < 2 || @argv > 3;
            cmd_hash( $argv[0],
                      want_uint( $argv[1], 'nbits' ),
                      defined $argv[2] ? want_rounds( $argv[2] ) : $ROUNDS_MAX );
        }
        elsif ( $cmd eq 'trace' ) {
            die usage() if @argv < 2 || @argv > 4;
            cmd_trace( $argv[0],
                       want_uint( $argv[1], 'nbits' ),
                       defined $argv[2] ? want_uint( $argv[2], 'blockidx' ) : 0,
                       defined $argv[3] ? want_rounds( $argv[3] ) : $ROUNDS_MAX );
        }
        elsif ( $cmd eq 'selftest' ) {
            die usage() if @argv;
            cmd_selftest();
        }
        else {
            die usage();
        }
    };
    if ($@) { print STDERR $@; return 2 }
    return $rc;
}

# The "modulino" idiom. caller() is false when this file is the program being
# run and true when it has been require'd by another file, so the same file is
# both a command-line tool and a library — which is how shavar.t gets at
# compress() and pad_message() directly. The trailing 1 is the true value that
# require insists a file return.
exit main(@ARGV) unless caller;
1;
