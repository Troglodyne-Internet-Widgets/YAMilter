use strict;
use warnings;

use FindBin;
use FindBin::libs;
use Cwd;
use Test2::V0;

use YAMilterTest qw{:all};

my $run_dir = Cwd::abs_path("$FindBin::Bin/..");
my $config = getconfig("$run_dir/t/yamilter.cfg");

my @args = ("$run_dir/bin/yamilter", '--config', $config->param('service.f'));

like(fork_and_term(undef, @args), qr/starting/i, "YAMilter can load milters and responds to signals") or BAIL_OUT();

done_testing();
