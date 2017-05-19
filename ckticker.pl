#! /usr/bin/env perl
#
# Copyright 2014 Brian Shore.  All Rights Reserved.
# Use of this source code is governed by a BSD-style
# license that can be found in the LICENSE file.

use strict;
use warnings;

use List::Util qw/ max /;

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
	my (@start, @stop);

	@start = localtime(time - $SECS_PER_MONTH);
	@stop  = localtime(time);

	# find symbol for symbols held multiple times
	(my $sym_root = $sym) =~ s/_\d+$//;

	my %params = (
		a => $start[4],
		b => $start[3],
		c => $start[5] + 1900,
		d => $stop[4],
		e => $stop[3],
		f => $stop[5] + 1900,
		s => $sym_root,
		ignore => '.csv',
	);

	use HTTP::Tiny;
	my $ua = HTTP::Tiny->new(timeout => 10, );
	my $response = $ua->get(
		join('?', 'http://real-chart.finance.yahoo.com/table.csv',
			join('&', map { "$_=$params{$_}" } sort keys %params))
	);

	unless ($response->{success}) {
		warn "$sym: failed to fetch recent data";
		return (-1, -1);
	}

	my $max = 0;
	my $close;
	for my $i (split(/\n/, $response->{content})) {
		my @i = split(/,/, $i);
		next unless $i[6] =~ /^[.0-9]+$/;
		$max = $i[6] if $i[6] > $max;
		$close = $i[6] unless defined $close;
	}

	if ($DEBUG) {
		open my $fh, ">", "recent.$sym.csv";
		print $fh $response->{content};
		close $fh;
	}

	return ($max, $close);
}

# $sym X $last_high -> $delta X $recent_high
sub check_sym {
	my $sym = shift;
	my $last_high = shift;

	my ($recent_high, $close) = fetch_historical_high_and_close($sym);
	return ($recent_high, $close) if $close < 0;

	my $cmp = $recent_high > $last_high ? $recent_high : $last_high;

	# change as percentage of comparison value
	my $delta = ($close / $cmp - 1);

	warn sprintf("%-6s (%07.3f, %07.3f) -> % .3f\n",
			$sym, $last_high, $recent_high, $delta)
		if $DEBUG;

	return ($delta, $recent_high);
}

sub main {
	my $data = loadData($DATA_FILE);
	my $status = { };
	my $flag_updated = 0;

	for my $sym (sort keys %$data) {
		my @pair = check_sym($sym, $$data{$sym}{last_high});
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
