# -*- mode: cperl -*-

BEGIN {
    $|++;
    unless (@ARGV && shift(@ARGV) eq "--doit") {
        $|=1;
        print "1..0 # SKIP test only run when called with --doit\n";
        eval "require POSIX; 1" and POSIX::_exit(0);
        exit;
    }
}

use Test::More;
eval "use Test::Pod 1.00";
plan skip_all => "Test::Pod 1.00 required for testing POD" if $@;
all_pod_files_ok();

