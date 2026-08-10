#!/usr/bin/perl
# Rounds-contract driver for pl/shavar.pl. See tests/rounds.sh.
use strict; use warnings; use File::Basename qw(dirname);
my $here = dirname(__FILE__);
require "$here/../../pl/shavar.pl";
my @iv = (0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
          0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19);
open my $fh, '<', $ARGV[0] or die "$ARGV[0]: $!\n";
while (my $l = <$fh>) {
    next if $l =~ /^#/ || $l =~ /^\s*$/;
    my ($r) = split /\t/, $l;
    my @h = eval { main::hash_ex("abc", 24, \@iv, $r) };
    if ($@) { print "$r\trejected\t-\n" }
    else    { print "$r\taccepted\t", main::hexdigest(@h), "\n" }
}
