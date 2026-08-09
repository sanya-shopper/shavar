#!/usr/bin/perl
#
# Tests for pl/shavar.pl.  Run:  /usr/bin/perl pl/shavar.t
#
# Same constraint as the implementation: no modules at all, so no Test::More.
# The half-dozen lines of TAP emitted below are hand-rolled.
#
# The centre of this file is an INDEPENDENT SHA-256, written in the textbook
# eight-register style of SPEC.md §2 with its own padding and its own round
# constants derived from the primes.  It shares no code with shavar.pl beyond
# the language itself.  Agreement between the two is the empirical counterpart
# of the Lean equivalence proof (SPEC.md V1) and is what makes the sub-byte
# digests in shavar.pl's selftest table trustworthy: FIPS publishes no
# bit-oriented worked example, so those two vectors are pinned by this
# second implementation rather than by NIST.

use strict;
use warnings;

my $M = 0xFFFF_FFFF;

# Locate and load the implementation next to this file.  shavar.pl returns
# true and skips its own main() when require'd (the modulino idiom).
my $DIR = $0;
$DIR =~ s{[^/]*\z}{};        # strip the file name, keeping any directory part
$DIR =~ s{/+\z}{};           # and any trailing slashes
$DIR = '.' if $DIR eq '';
# require() searches @INC unless the path is absolute or starts with ./ or ../,
# and @INC never contains the current directory on a modern perl, so make the
# relative case explicit.
$DIR = "./$DIR" unless $DIR =~ m{\A[./]};
require "$DIR/shavar.pl";

# ---------------------------------------------------------------------------
# Tiny TAP harness
# ---------------------------------------------------------------------------
my $tests  = 0;
my $failed = 0;

sub ok {
    my ($cond, $name) = @_;
    $tests++;
    if   ($cond) { print "ok $tests - $name\n" }
    else         { $failed++; print "not ok $tests - $name\n" }
    return $cond;
}

sub is {
    my ($got, $want, $name) = @_;
    $got  = '(undef)' if !defined $got;
    $want = '(undef)' if !defined $want;
    my $good = ok($got eq $want, $name);
    print "#   got:      $got\n#   expected: $want\n" if !$good;
    return $good;
}

# ---------------------------------------------------------------------------
# Independent reference implementation (SPEC.md §2, eight registers)
# ---------------------------------------------------------------------------

sub r  { my ($x, $n) = @_; (($x >> $n) | ($x << (32 - $n))) & $M }
sub S0 { my $x = shift; r($x, 2) ^ r($x, 13) ^ r($x, 22) }
sub S1 { my $x = shift; r($x, 6) ^ r($x, 11) ^ r($x, 25) }
sub s0 { my $x = shift; r($x, 7) ^ r($x, 18) ^ ($x >> 3) }
sub s1 { my $x = shift; r($x, 17) ^ r($x, 19) ^ ($x >> 10) }
sub Ch { my ($x, $y, $z) = @_; (($x & $y) ^ (~$x & $z)) & $M }
sub Mj { my ($x, $y, $z) = @_; ($x & $y) ^ ($x & $z) ^ ($y & $z) }

# The first $n primes, by trial division.
sub primes {
    my ($n) = @_;
    # Declared separately on purpose: in `my (@p, $c) = (..., 2)` the array
    # would swallow the whole right-hand list and leave $c undefined.
    my @p;
    my $c = 2;
    while (@p < $n) {
        my $ok = 1;
        for my $q (@p) {
            last if $q * $q > $c;
            if ($c % $q == 0) { $ok = 0; last }
        }
        push @p, $c if $ok;
        $c++;
    }
    return @p;
}

# First 32 bits of the fractional part of $x.  A double carries 53 mantissa
# bits and these roots are all below 8, so 32 bits of fraction are exact.
sub frac32 { my $x = shift; $x -= int($x); return int($x * 4294967296.0) }

my @REF_IV = map { frac32( sqrt($_) ) } primes(8);
my @REF_K  = map { frac32( $_**(1.0 / 3.0) ) } primes(64);

# Padding built from a literal string of '0'/'1' characters.  unpack('B*', $s)
# renders a byte string as bits with the most significant bit of each byte
# first -- i.e. FIPS 180-4 order directly, in contrast to the vec()-plus-XOR-7
# route the implementation takes.  Two unrelated mechanisms, same answer.
sub ref_pad {
    my ($msg, $nbits) = @_;
    my $bits = unpack('B*', $msg);
    die "short buffer\n" if length($bits) < $nbits;
    die "nonzero trailing bits\n" if substr($bits, $nbits) =~ /1/;
    $bits = substr($bits, 0, $nbits) . '1';
    $bits .= '0' x ((448 - length($bits) % 512) % 512);
    $bits .= sprintf('%064b', $nbits);
    return pack('B*', $bits);
}

sub ref_compress {
    my ($h, $block, $rounds) = @_;
    my @w = unpack('N16', $block);
    for my $t (16 .. 63) {
        $w[$t] = ( s1($w[$t-2]) + $w[$t-7] + s0($w[$t-15]) + $w[$t-16] ) & $M;
    }
    my ($a, $b, $c, $d, $e, $f, $g, $hh) = @$h;
    for my $t (0 .. $rounds - 1) {
        my $T1 = ( $hh + S1($e) + Ch($e, $f, $g) + $REF_K[$t] + $w[$t] ) & $M;
        my $T2 = ( S0($a) + Mj($a, $b, $c) ) & $M;
        ($hh, $g, $f, $e) = ($g, $f, $e, ($d + $T1) & $M);
        ($d, $c, $b, $a)  = ($c, $b, $a, ($T1 + $T2) & $M);
    }
    my @add = ($a, $b, $c, $d, $e, $f, $g, $hh);
    return [ map { ( $h->[$_] + $add[$_] ) & $M } 0 .. 7 ];
}

sub ref_hash {
    my ($msg, $nbits, $iv, $rounds) = @_;
    $iv     = \@REF_IV unless defined $iv;
    $rounds = 64       unless defined $rounds;
    my $padded = ref_pad($msg, $nbits);
    my $h      = [@$iv];
    $h = ref_compress( $h, substr($padded, 64 * $_, 64), $rounds )
        for 0 .. length($padded) / 64 - 1;
    return sprintf( '%08x' x 8, @$h );
}

# ---------------------------------------------------------------------------
# Helpers for driving the CLI as a subprocess
# ---------------------------------------------------------------------------

my $PROG = "$DIR/shavar.pl";

# Returns (stdout, exit code).  stderr is discarded; the tests that care about
# it check only that stdout stayed empty.
sub run_cli {
    my @args = @_;
    my $cmd  = join ' ', map { "'$_'" } ( $^X, $PROG, @args );
    my $out  = `$cmd 2>/dev/null`;
    return ( $out, $? >> 8 );
}

# ---------------------------------------------------------------------------
# 1. Constants
# ---------------------------------------------------------------------------

is( sprintf( '%08x' x 8, @REF_IV ),
    '6a09e667bb67ae853c6ef372a54ff53a510e527f9b05688c1f83d9ab5be0cd19',
    'IV rederived from sqrt of the first eight primes' );

is( sprintf( '%08x' x 8, @REF_K[ 0 .. 7 ] ),
    '428a2f9871374491b5c0fbcfe9b5dba53956c25b59f111f1923f82a4ab1c5ed5',
    'K[0..7] rederived from cbrt of the first eight primes' );

is( sprintf( '%08x' x 8, @REF_K[ 56 .. 63 ] ),
    '748f82ee78a5636f84c878148cc7020890befffaa4506cebbef9a3f7c67178f2',
    'K[56..63] rederived from cbrt of primes 57..64' );

# The reference tables are derived, the implementation's are transcribed.
# Hashing agreement below is what ties the two together, but check the IV
# directly too since a wrong IV would otherwise only show up as a wrong digest.
is( sprintf( '%08x' x 8, main::hash_ex( '', 0, \@REF_IV, 64 ) ),
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    'implementation with the derived IV gives the empty-message digest' );

# ---------------------------------------------------------------------------
# 2. Padding, against SPEC.md §5.2 byte for byte
# ---------------------------------------------------------------------------

# L = 5, bits 10110: buffer 0xb0, the appended 1 bit makes 0xb4, zeros to bit
# 448, then the 64-bit big-endian value 5.
is( unpack( 'H*', main::pad_message( "\xb0", 5 ) ),
    'b4' . ( '00' x 55 ) . '0000000000000005',
    'SPEC.md §5.2 worked example: 5 bits 10110 pad to b4 00.. 0005' );

is( unpack( 'H*', main::pad_message( '', 0 ) ),
    '80' . ( '00' x 63 ),
    'SPEC.md §5.2: the empty message pads to 0x80 and 63 zero bytes' );

# The 1 bit exactly fills the 448-bit window: no zero fill at all.
is( length( main::pad_message( "\0" x 56, 447 ) ), 64,
    '447 bits pad to exactly one block' );
is( unpack( 'H*', substr( main::pad_message( "\0" x 56, 447 ), 55, 1 ) ),
    '01', '447 bits put the appended 1 in the last bit of byte 55' );

# 448 bits needs a second block for the length.
is( length( main::pad_message( "\0" x 56, 448 ) ), 128,
    '448 bits pad to two blocks' );

# Padded length is a multiple of 512 bits for every L in a wide sweep,
# including every residue mod 8 and both sides of each block boundary
# (SPEC.md V3).
{
    my @bad = grep { length( main::pad_message( "\0" x int( ( $_ + 7 ) / 8 ), $_ ) ) % 64 }
              ( 0 .. 600, 1000 .. 1100 );
    is( scalar @bad, 0, 'padded length is a multiple of 64 bytes for L = 0..600, 1000..1100' );
}

# Padding agrees with the independent bit-string construction everywhere.
{
    my @bad;
    for my $L ( 0 .. 600 ) {
        my $nb = int( ( $L + 7 ) / 8 );
        # A message whose bits are pseudo-random but whose trailing bits are
        # zero, so it is a legal input.
        my $msg = join '', map { chr( ( $_ * 37 + 11 ) & 0xFF ) } 1 .. $nb;
        if ( $L % 8 ) {
            substr( $msg, -1, 1 ) =
                chr( ord( substr( $msg, -1, 1 ) ) & ( 0xFF << ( 8 - $L % 8 ) ) & 0xFF );
        }
        push @bad, $L if main::pad_message( $msg, $L ) ne ref_pad( $msg, $L );
    }
    is( scalar @bad, 0, 'pad_message matches the independent bit-string padding for L = 0..600' );
}

# ---------------------------------------------------------------------------
# 3. Digests against the independent eight-register implementation
#    (SPEC.md V1 empirically, V6 in miniature)
# ---------------------------------------------------------------------------

{
    my @bad;
    for my $L ( 0 .. 600 ) {
        my $nb  = int( ( $L + 7 ) / 8 );
        my $msg = join '', map { chr( ( $_ * 53 + 7 ) & 0xFF ) } 1 .. $nb;
        if ( $L % 8 ) {
            substr( $msg, -1, 1 ) =
                chr( ord( substr( $msg, -1, 1 ) ) & ( 0xFF << ( 8 - $L % 8 ) ) & 0xFF );
        }
        my $got  = sprintf( '%08x' x 8, main::hash( $msg, $L ) );
        my $want = ref_hash( $msg, $L );
        push @bad, "$L: $got vs $want" if $got ne $want;
    }
    is( scalar @bad, 0, 'digests match the eight-register form for every L = 0..600' )
        or print "#   first mismatch: $bad[0]\n";
}

# Every sub-byte residue at a size that spans two blocks.
{
    my @bad;
    for my $L ( 897 .. 912 ) {
        my $nb  = int( ( $L + 7 ) / 8 );
        my $msg = "\xff" x ( $nb - 1 );
        $msg .= chr( 0xFF & ( 0xFF << ( ( 8 - $L % 8 ) % 8 ) ) );
        push @bad, $L
            if sprintf( '%08x' x 8, main::hash( $msg, $L ) ) ne ref_hash( $msg, $L );
    }
    is( scalar @bad, 0, 'all-ones messages of 897..912 bits match the reference' );
}

# ---------------------------------------------------------------------------
# 4. Free-start IV and reduced rounds (SPEC.md §6)
# ---------------------------------------------------------------------------

my @ODD_IV = ( 0x01234567, 0x89abcdef, 0xfedcba98, 0x76543210,
               0x0f0f0f0f, 0xf0f0f0f0, 0xdeadbeef, 0xcafebabe );

is( sprintf( '%08x' x 8, main::hash_ex( 'abc', 24, \@ODD_IV, 64 ) ),
    ref_hash( 'abc', 24, \@ODD_IV, 64 ),
    'free-start: a caller-supplied chaining value matches the reference' );

{
    my @bad;
    for my $rounds ( 0, 1, 2, 3, 4, 5, 16, 31, 32, 63, 64 ) {
        my $got  = sprintf( '%08x' x 8, main::hash_ex( 'abc', 24, \@ODD_IV, $rounds ) );
        my $want = ref_hash( 'abc', 24, \@ODD_IV, $rounds );
        push @bad, "$rounds: $got vs $want" if $got ne $want;
    }
    is( scalar @bad, 0, 'reduced-round variants match the reference for 0..64 rounds' )
        or print "#   first mismatch: $bad[0]\n";
}

ok( sprintf( '%08x' x 8, main::hash_ex( 'abc', 24, \@ODD_IV, 64 ) ) ne
        sprintf( '%08x' x 8, main::hash( 'abc', 24 ) ),
    'a different IV really does give a different digest' );

# ---------------------------------------------------------------------------
# 5. The trace is internally consistent with SPEC.md §3
# ---------------------------------------------------------------------------

{
    my $block = main::pad_message( 'abc', 24 );
    my @h     = ( 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 );
    my %tr;
    main::compress( \@h, $block, 64, \%tr );

    is( scalar @{ $tr{A} }, 68, 'trace records A[-4..63]' );
    is( scalar @{ $tr{E} }, 68, 'trace records E[-4..63]' );
    is( scalar @{ $tr{W} }, 64, 'trace records W[0..63]' );

    # Seeds: A[-1]=H[0] .. A[-4]=H[3], E[-1]=H[4] .. E[-4]=H[7].
    my @seed_ok = grep { $tr{A}[ 3 - $_ ] == $tr{hin}[$_] } 0 .. 3;
    is( scalar @seed_ok, 4, 'A[-1..-4] seeded from H[0..3]' );
    @seed_ok = grep { $tr{E}[ 3 - $_ ] == $tr{hin}[ 4 + $_ ] } 0 .. 3;
    is( scalar @seed_ok, 4, 'E[-1..-4] seeded from H[4..7]' );

    # Recheck each round's two recurrences straight from the recorded arrays,
    # using the reference implementation's round functions rather than the
    # implementation's own.
    my @bad;
    for my $t ( 0 .. 63 ) {
        my $i = $t + 4;    # storage index of element t
        my $t1 = ( $tr{E}[ $i - 4 ]
                 + S1( $tr{E}[ $i - 1 ] )
                 + Ch( $tr{E}[ $i - 1 ], $tr{E}[ $i - 2 ], $tr{E}[ $i - 3 ] )
                 + $REF_K[$t]
                 + $tr{W}[$t] ) & $M;
        my $t2 = ( S0( $tr{A}[ $i - 1 ] )
                 + Mj( $tr{A}[ $i - 1 ], $tr{A}[ $i - 2 ], $tr{A}[ $i - 3 ] ) ) & $M;
        push @bad, "T1[$t]" if $t1 != $tr{T1}[$t];
        push @bad, "T2[$t]" if $t2 != $tr{T2}[$t];
        push @bad, "E[$t]"  if $tr{E}[$i] != ( ( $tr{A}[ $i - 4 ] + $t1 ) & $M );
        push @bad, "A[$t]"  if $tr{A}[$i] != ( ( $t1 + $t2 ) & $M );
    }
    is( scalar @bad, 0, 'every round of the trace satisfies the §3 recurrences' )
        or print "#   first mismatch: $bad[0]\n";

    # Schedule recurrence, §4.
    @bad = ();
    for my $t ( 16 .. 63 ) {
        my $w = ( s1( $tr{W}[ $t - 2 ] ) + $tr{W}[ $t - 7 ]
                + s0( $tr{W}[ $t - 15 ] ) + $tr{W}[ $t - 16 ] ) & $M;
        push @bad, $t if $w != $tr{W}[$t];
    }
    is( scalar @bad, 0, 'the message schedule satisfies the §4 recurrence' );

    # Feed-forward, and compress() really did update @h in place.
    my @ff_ok = grep { $tr{hout}[$_] == ( ( $tr{hin}[$_] + $tr{A}[ 67 - $_ ] ) & $M ) } 0 .. 3;
    is( scalar @ff_ok, 4, 'H[0..3] += A[63..60]' );
    @ff_ok = grep { $tr{hout}[$_] == ( ( $tr{hin}[$_] + $tr{E}[ 71 - $_ ] ) & $M ) } 4 .. 7;
    is( scalar @ff_ok, 4, 'H[4..7] += E[63..60]' );
    is( sprintf( '%08x' x 8, @h ), sprintf( '%08x' x 8, @{ $tr{hout} } ),
        'compress() updated the chaining value in place' );
}

# ---------------------------------------------------------------------------
# 6. Trailing-bit validation, both directions (SPEC.md §5.1)
# ---------------------------------------------------------------------------

# Accepted: low bits genuinely zero.
for my $case ( [ "\xb0", 5, '1011 0000' ], [ "\xb8", 5, '1011 1000' ],
               [ "\x80", 1, '1000 0000' ], [ "\xfe", 7, '1111 1110' ] ) {
    my ( $byte, $L, $shown ) = @$case;
    my $got = eval { sprintf( '%08x' x 8, main::hash( $byte, $L ) ) };
    ok( defined $got, "accepted: $shown as $L bits" );
    is( $got, ref_hash( $byte, $L ), "  ...and matches the reference" );
}

# Rejected: at least one low bit set.
for my $case ( [ "\xb4", 5, '1011 0100' ], [ "\x01", 5, '0000 0001' ],
               [ "\xff", 7, '1111 1111' ], [ "\x40", 1, '0100 0000' ] ) {
    my ( $byte, $L, $shown ) = @$case;
    my $got = eval { main::pad_message( $byte, $L ); 1 };
    ok( !$got, "rejected: $shown as $L bits" );
}

# A wrong-sized buffer is an error too, in both directions.
ok( !eval { main::pad_message( "\xb0\xb0", 5 ); 1 }, 'rejected: buffer too long for L' );
ok( !eval { main::pad_message( '', 5 ); 1 },         'rejected: buffer too short for L' );

# ---------------------------------------------------------------------------
# 7. The command-line contract (CLI.md)
# ---------------------------------------------------------------------------

{
    my ( $out, $rc ) = run_cli( 'hash', '-', '0' );
    is( $out, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n",
        'CLI hash - 0: 64 lowercase hex digits and one newline' );
    is( $rc, 0, 'CLI hash - 0 exits 0' );
}
{
    my ( $out, $rc ) = run_cli( 'hash', '616263', '24' );
    is( $out, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\n",
        'CLI hash 616263 24' );
    is( $rc, 0, 'exits 0' );
}
{
    my ( $out, $rc ) = run_cli( 'hash', '616263', '24', '64' );
    is( $out, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\n",
        'an explicit rounds=64 is the same as the default' );
}
{
    my ( $out, $rc ) = run_cli( 'hash', 'B0', '5' );
    my ( $lo, undef ) = run_cli( 'hash', 'b0', '5' );
    is( $out, $lo, 'uppercase hex input is accepted and gives the same digest' );
    is( $rc,  0,   'uppercase input exits 0' );
}
{
    my ( $out, $rc ) = run_cli( 'hash', 'b8', '5' );
    is( $rc, 0, 'CLI accepts b8 5 (low three bits are zero)' );
    is( $out, ref_hash( "\xb8", 5 ) . "\n", 'and prints the reference digest' );
}
{
    my ( $out, $rc ) = run_cli( 'hash', 'b4', '5' );
    is( $rc,  2,  'CLI rejects b4 5 with exit code 2 (low bits 100)' );
    is( $out, '', 'and prints nothing at all on stdout' );
}
{
    my ( $out, $rc ) = run_cli( 'hash', 'zz', '8' );
    is( $rc,  2,  'malformed hex exits 2' );
    is( $out, '', 'and stdout stays empty' );
}
{
    my ( $out, $rc ) = run_cli( 'hash', '616263', '25' );
    is( $rc, 2, 'nbits inconsistent with the byte count exits 2' );
}
{
    my ( $out, $rc ) = run_cli( 'hash', '616263', '24', '65' );
    is( $rc, 2, 'rounds above 64 exits 2' );
}
{
    my ( $out, $rc ) = run_cli('bogus');
    is( $rc,  2,  'an unknown subcommand exits 2' );
    is( $out, '', 'and prints usage to stderr, not stdout' );
}
{
    my ( $out, $rc ) = run_cli();
    is( $rc, 2, 'no arguments exits 2' );
}
{
    my ( $out, $rc ) = run_cli('selftest');
    is( $rc,  0,       'selftest exits 0' );
    is( $out, "ok 9\n", 'selftest reports all nine vectors passing' );
}

# trace: shape and content.
{
    my ( $out, $rc ) = run_cli( 'trace', '616263', '24' );
    is( $rc, 0, 'trace exits 0' );
    my @lines = split /\n/, $out, -1;
    pop @lines;    # trailing empty field after the final newline
    is( scalar @lines, 8 + 64 + 68 + 68 + 64 + 64 + 8, 'trace emits the right number of lines' );

    my %count;
    my $malformed = 0;
    for my $l (@lines) {
        my @f = split /\t/, $l, -1;
        $malformed++ if @f != 3 || $f[1] !~ /\A-?[0-9]+\z/ || $f[2] !~ /\A[0-9a-f]{8}\z/;
        $count{ $f[0] }++;
    }
    is( $malformed, 0, 'every trace line is tag<TAB>index<TAB>8 lowercase hex digits' );
    is( join( ',', map { "$_=$count{$_}" } sort keys %count ),
        'A=68,E=68,HIN=8,HOUT=8,T1=64,T2=64,W=64',
        'trace record counts are as CLI.md specifies' );

    is( $lines[0],  "HIN\t0\t6a09e667", 'first line is HIN 0 with the FIPS IV' );
    is( $lines[8],  "W\t0\t61626380",   'W[0] is the first padded word' );
    is( $lines[72], "A\t-4\ta54ff53a",  'A[-4] is H[3], with a negative index' );
    is( $lines[140], "E\t-4\t5be0cd19", 'E[-4] is H[7]' );
    is( $lines[-8], "HOUT\t0\tba7816bf", 'HOUT[0] is the first digest word' );
}

# trace with reduced rounds: W stays at 64 entries, A/E and T1/T2 shrink.
{
    my ( $out, $rc ) = run_cli( 'trace', '616263', '24', '0', '10' );
    is( $rc, 0, 'trace with rounds=10 exits 0' );
    my %count;
    for my $l ( split /\n/, $out ) { $count{ (split /\t/, $l)[0] }++ }
    is( join( ',', map { "$_=$count{$_}" } sort keys %count ),
        'A=14,E=14,HIN=8,HOUT=8,T1=10,T2=10,W=64',
        'rounds=10 gives W[0..63] but A/E[-4..9] and T1/T2[0..9]' );
}

# trace of the second block of a two-block message, and its HIN must equal the
# first block's HOUT.
{
    my $hex = '61' x 57;
    my ( $b0 ) = run_cli( 'trace', $hex, '456', '0' );
    my ( $b1, $rc ) = run_cli( 'trace', $hex, '456', '1' );
    is( $rc, 0, 'trace of block 1 exits 0' );
    my @hout0 = grep { /^HOUT\t/ } split /\n/, $b0;
    my @hin1  = grep { /^HIN\t/ }  split /\n/, $b1;
    s/^HOUT/X/ for @hout0;
    s/^HIN/X/  for @hin1;
    is( join( '|', @hin1 ), join( '|', @hout0 ),
        "block 1's incoming chaining value is block 0's outgoing one" );

    my ( undef, $rc2 ) = run_cli( 'trace', $hex, '456', '2' );
    is( $rc2, 2, 'a block index past the end of the padded message exits 2' );
}

# ---------------------------------------------------------------------------

print "1..$tests\n";
if ($failed) {
    print "# $failed of $tests tests FAILED\n";
    exit 1;
}
print "# all $tests tests passed\n";
exit 0;
