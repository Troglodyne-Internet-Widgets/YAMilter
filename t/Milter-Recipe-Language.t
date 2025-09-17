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

my @cmds = gibs();

# Now to test the milters specifically

$config->param('Language.langs', 'en');
$config->param('Language.action', 'defer');
writeconfig();

my $result;
fork_and_term(sub { $result = sendmail(@cmds) }, @args);
is($result, SMFIR_ACCEPT, "Marked message as ACCEPT when in correct language");

# The body command
$cmds[8][1] = "Ich bin ein Berliner";
use Data::Dumper;
print Dumper($cmds[8]);
fork_and_term(sub { $result = sendmail(@cmds) }, @args);
is($result, SMFIR_TEMPFAIL, "Marked message as DEFER when NOT in correct language");

done_testing();
