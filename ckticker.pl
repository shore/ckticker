#! /usr/bin/env perl
#
# Copyright 2014 Brian Shore.  All Rights Reserved.
# Use of this source code is governed by a BSD-style
# license that can be found in the LICENSE file.

use strict;
use warnings;

use List::Util qw/ max /;
use HTTP::Tiny;
use JSON;

my $DATA_FILE = 'ckticker.yaml';
my $STOP_RATIO = -0.25;

my $SECS_PER_MONTH = 60 * 60 * 24 * 31;

my $DEBUG = 1 if exists $ENV{CK_DEBUG};

sub loadData {
	my $file = shift;
	my $data;

	use YAML;

	$data = YAML::LoadFile($file);

	return $data;
}

sub dumpData {
	my $file = shift;
	my $data = shift;

	rename "$file", "$file.bak";

	use YAML;

	YAML::DumpFile($file, $data);
}

# \%data X \%status -> $stopped_count X $body_text
sub generate_mail_body {
	my $data = shift;
	my $status = shift;

	my $missing = (scalar keys %$data) - (scalar keys %$status);

	my %s = ( 'clear' => [ ], 'stopped' => [ ], 'unstopped' => [ ], );
	my $group;
	for my $key (sort keys %$status) {
		$group = (($$status{$key} > ($$data{$key}{stop_ratio} // $STOP_RATIO)) ? 'clear' :
			($$data{$key}{stopped} ? 'stopped' : 'unstopped'));
		push @{$s{$group}}, $key;
	}

	my $FMT = "\nTotal: %d\nLacking status: %d\n\nStopped out (%d):\n%s\n\nUnstopped (%d):\n%s\n";
	my $SHORT_FMT = '%-6s = %0.3f';
	my $body = sprintf $FMT,
		scalar(keys(%$data)),
		$missing,
		scalar(@{$s{stopped}}),
		join("\n", map { sprintf($SHORT_FMT, $_, 100 * $$status{$_}) } @{$s{stopped}}),
		scalar(@{$s{unstopped}}),
		join("\n", map { sprintf($SHORT_FMT, $_, 100 * $$status{$_}) } @{$s{unstopped}});

	my $clear;
	my $clear_count = scalar @{$s{clear}};
	if ($DEBUG) {
		$clear = join("\n", map { sprintf($SHORT_FMT, $_, 100 * $$status{$_}) } @{$s{clear}});
	}
	else {
		my @chunks;

		while (scalar @{$s{clear}} > 12) {
			push @chunks, [ splice @{$s{clear}}, 0, 12 ];
		}
		push @chunks, [ @{$s{clear}} ];

		$clear = join("\n", map { join(' ', @$_) } @chunks);
	}

	$body .= sprintf "\nClear (%d):\n%s\n", $clear_count, $clear;


	return (scalar(@{$s{stopped}}), $body);
}

# check back 1 month
sub fetch_historical_high_and_close {
	my $sym = shift;
	my $entry_time = shift;

	# find symbol for symbols held multiple times
	(my $sym_root = $sym) =~ s/_\d+$//;

    my $url = qq{https://finance.yahoo.com/quote/$sym_root/history?p=$sym_root};
    my $ua = HTTP::Tiny->new(timeout => 10, );
    my $response = $ua->get($url);
    die "Failed to fetch page for $sym_root\n" unless $response->{success};
    $response->{content} =~ m/root.App.main = ({.*});/ms;
    my $json_data = $1;

    my $json = JSON->new;
    my $blob = $json->decode($json_data);
    $blob = $blob->{context}{dispatcher}{stores}{HistoricalPriceStore}{prices};
    my ($max, $close) = (0, 0);
    foreach my $chunk (sort { $a->{date} <=> $b->{date} } @$blob) {
        next unless $chunk->{close};
        # only consider data points since entering the position
        next if $entry_time > $chunk->{date};
        $close = $chunk->{close};
        $max = $close if $max < $close;
    }

	if ($DEBUG) {
		open my $fh, ">", "recent.$sym.json";
		print $fh $json->pretty->encode($blob);
		close $fh;
	}

	return ($max, $close);
}

# $sym X $last_high -> $delta X $recent_high
sub check_sym {
	my $sym = shift;
	my $last_high = shift;
	my $entry_time = shift;

	my ($recent_high, $close) = fetch_historical_high_and_close($sym, $entry_time);
	return ($recent_high, $close) if $close < 0;

	my $cmp = $recent_high > $last_high ? $recent_high : $last_high;

	# change as percentage of comparison value
	my $delta = ($close / $cmp - 1);

	warn sprintf("%-6s (%07.3f, %07.3f, %07.3f) -> % .3f\n", $sym, $last_high, $recent_high, $close, $delta)
		if $DEBUG;

	return ($delta, $recent_high);
}

sub main {
	my $data = loadData($DATA_FILE);
	my $status = { };
	my $flag_updated = 0;

	for my $sym (sort keys %$data) {
		my @pair = check_sym($sym, $$data{$sym}{last_high}, $$data{$sym}{entry_time} // -1);
		next if $pair[1] < 0;

		$$status{$sym} = $pair[0];

		if ($$data{$sym}{last_high} < $pair[1]) {
			$$data{$sym}{last_high} = $pair[1];
			$flag_updated = 1;
		}
	}

	my ($stopped_count, $body) = generate_mail_body($data, $status);
	warn "$flag_updated updates\n" if $DEBUG;
    if ($flag_updated > 0) {
		dumpData($DATA_FILE, $data);
	}

	# send mail
	if (! $DEBUG) {
		open my $fh, '|-', '/usr/bin/mail', '-s', "Ticker Update ($stopped_count stopped out)", 'brian@cryptomonkeys.org'
			or die "Failed to open /usr/bin/mail";
		print $fh $body;
		close $fh;
	}
	else {
		print $body;
	}

}
main;
