#!/usr/bin/perl
# PoW driver for pl/shavar.pl. See tests/pow.sh.
#
# Reads the vector file named on the command line and writes one
# `id <TAB> met|unmet|invalid` line per vector. Marshalling only: every
# decision comes from pl/shavar.pl, pulled in through its modulino guard.
use strict;
use warnings;
use File::Basename qw(dirname);

my $here = dirname(__FILE__);
require "$here/../../pl/shavar.pl";

die "usage: driver.pl VECTORS.tsv\n" unless @ARGV == 1;
open my $fh, '<', $ARGV[0] or die "$ARGV[0]: $!\n";
while (my $line = <$fh>) {
    next if $line =~ /^#/ || $line =~ /^\s*$/;
    chomp $line;
    my ($id, $dhex, $nbhex) = (split /\t/, $line)[0, 1, 2];
    my $digest = pack('H*', $dhex);
    my $nbits  = hex($nbhex);
    my $verdict = eval { main::pow_check($digest, $nbits) ? 'met' : 'unmet' };
    $verdict = 'invalid' unless defined $verdict;
    print "$id\t$verdict\n";
}
close $fh;
