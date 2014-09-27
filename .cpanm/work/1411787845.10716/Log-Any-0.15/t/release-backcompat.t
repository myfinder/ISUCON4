#!perl

BEGIN {
  unless ($ENV{RELEASE_TESTING}) {
    require Test::More;
    Test::More::plan(skip_all => 'these tests are for release candidate testing');
  }
}

#
# Test old Log::Any->set_adapter API
#
use strict;
use warnings;
use Capture::Tiny qw/capture_merged/;
use Log::Any;
use Test::More tests => 1;

use Log::Dispatch;
my $log = Log::Dispatch->new(outputs => [['Screen', newline => 1, min_level => 'debug']]);
Log::Any->set_adapter('Dispatch', dispatcher => $log);
my $merged = capture_merged { $log->error("bleah") };
is($merged, "bleah\n", "got log");
