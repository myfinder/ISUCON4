use Test::Pod::Coverage tests=>1;
pod_coverage_ok(
	"Time::Duration",
	# This module has a number of private methods whose names do not begin with
	# _.  This is kind of unfortunate, but it's too late now to change things,
	# so I will just manually omit them.
	{ also_private => [qw/^(?:interval|interval_exact)$/], },
	"Time::Duration is covered"
);
