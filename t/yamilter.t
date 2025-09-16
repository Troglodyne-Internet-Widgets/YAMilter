use strict;
use warnings;

use FindBin;
use Cwd;
use Test2::V0;

my $run_dir = Cwd::abs_path("$FindBin::Bin/..");

sub fork_and_term {
    my @args = @_;
    open(my $output, '+<', undef);
    $output->autoflush(1);
    select $output;
    my $pid = fork();
    die "Could not fork" unless defined $pid;
    if (!$pid) {
        $output->autoflush(1);
        select $output;
        my $script = shift @args;
        print "Running $script\n";
        local @ARGV = @args;
        do $script;
        exit YAMilter::main(@args);
    }
    select STDOUT;
    sleep 1;
    kill 'TERM', $pid;
    my $exited = 0;
    foreach (1..10) {
        my $res = waitpid($pid, 1);
        if ($res !=0) {
            $exited=1;
            last;
        }
        sleep 1;
    }
    if (!$exited) {
        kill('KILL', $pid);
        waitpid($pid, 0);
    }
    seek($output, 0, 0);
    my $o = join("\n", (readline $output));
    close $output;
    return $o;
}

like(fork_and_term("$run_dir/bin/yamilter", '--config', "$run_dir/t/yamilter.cfg"), qr/shutting down/i, "YAMilter can load milters and responds to signals");

done_testing();
