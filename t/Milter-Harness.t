use strict;
use warnings;

use FindBin::libs;
use Cwd;
use File::Temp;
use Test2::V0;
use Test2::Plugin::NoWarnings;

use Milter::Client qw{:constants};
use Milter::Harness;
use CorpusTest qw{write_file};

my $run_dir  = Cwd::abs_path("$FindBin::Bin/..");
my $yamilter = "$run_dir/bin/yamilter";
my $tmp      = File::Temp->newdir();

sub config {
    my ($recipes) = @_;
    return write_file( "$tmp/yamilter.cfg", "[service]\nsock=$tmp/yamilter.sock\npidfile=$tmp/yamilter.pid\nworkers=1\n$recipes" );
}

like( dies { Milter::Harness->new( config => config('') ) },                    qr/script is required/,         'script required' );
like( dies { Milter::Harness->new( script => $yamilter ) },                     qr/config is required/,         'config required' );
like( dies { Milter::Harness->new( script => $yamilter, config => '/bogus' ) }, qr/No such configuration file/, 'config must exist' );

subtest 'start, connect, stop' => sub {
    write_file( "$tmp/yamilter.sock", 'stale' );
    my $milter = Milter::Harness->new( script => $yamilter, config => config("[Language]\nlangs=en\n") );
    is( $milter->sock(), "$tmp/yamilter.sock", 'socket read from the configuration' );

    ok( $milter->start(),   'started' );
    ok( -S $milter->sock(), '... in place of a stale file at the socket path' );
    ok( $milter->running(), 'running' );
    like( dies { $milter->start() }, qr/already running/, 'cannot start twice' );

    my $sock = $milter->connect();
    my ($code) = Milter::Client::sendmail( $sock, { timeout => 5 }, [ SMFIC_OPTNEG, 6, 0x1FF, 0x1FFFFF ], [ SMFIC_HELO, 'h.test.test' ] );
    is( $code, SMFIR_CONTINUE, 'milter answers on the connection' );

    like( $milter->stop(), qr/YAMilter starting up.*Loaded milter modules: Language/s, 'stop returns what the milter printed' );
    ok( !$milter->running(), 'stopped' );
    is( $milter->stop(), $milter->output(), 'stopping again is harmless' );
};

subtest 'milter which will not start' => sub {
    my $milter = Milter::Harness->new( script => $yamilter, config => config("[Bogus]\naction=reject\n") );
    like( dies { $milter->start() }, qr/Milter exited before it was ready:.*Bogus/s, 'dies with what the milter printed' );
    ok( !$milter->running(), 'not running' );
};

done_testing();
