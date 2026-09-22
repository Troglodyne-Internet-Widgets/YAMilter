use strict;
use warnings;

use FindBin::libs;

use Exporter 'import';
our @EXPORT_OK = qw{fork_and_term getsock getconfig writeconfig};

use Milter::Client qw{:constants};
use Milter::Harness;
use File::Temp;
use Config::Simple;
use IO::Socket::UNIX;

# Mock up a session for us to use.
# Unfortunately for us we can't just use SMTP commands and instead have to freebase C structs
our @gibbering = (
    [ SMFIC_OPTNEG,  6, hex(0x1F), hex(0x1FFFFF) ],
    [ SMFIC_CONNECT, 'test.test', SMFIA_UNIX, 0, getconfig()->param('service.sock') ],
    [ SMFIC_HELO,    'test.test' ],
    [ SMFIC_MAIL,    '<test@test.test>' ],
    [ SMFIC_RCPT,    '<test@test.test>' ],
    [ SMFIC_DATA, ],
    [ SMFIC_HEADER, 'From',    'test@test.test' ],
    [ SMFIC_HEADER, 'To',      'test@test.test' ],
    [ SMFIC_HEADER, 'Subject', 'Test' ],
    [ SMFIC_EOH, ],
    [ SMFIC_BODY, "Testing 123" ],
    [ SMFIC_BODYEOB, ],
    [ SMFIC_QUIT, ],
);

sub gibs {
    return @gibbering;
}

my $c_actual;

# Test2 seeds srand from the date, so parallel tests draw the same tmpnam() names; mkdir at least fails and retries on collision.
my $dir;

sub getconfig {
    return $c_actual if $c_actual;

    $dir = File::Temp->newdir();
    my $cfg_file = "$dir/yamilter.cfg";
    my $sock     = "$dir/yamilter.sock";
    my $pid      = "$dir/yamilter.pid";

    my $ncf = Config::Simple->new( syntax => 'ini' );
    $ncf->param( 'service.sock',    $sock );
    $ncf->param( 'service.pidfile', $pid );
    $ncf->param( 'service.workers', 1 );
    $ncf->param( 'service.f',       $cfg_file );

    #$ncf->param('service.debug', 1);

    $ncf->write($cfg_file);

    $c_actual = $ncf;
    return $ncf;
}

sub writeconfig {
    my $c = getconfig();
    $c->write( $c->param('service.f') );
}

sub getsock {
    my $sockfile = getconfig()->param('service.sock');

    return IO::Socket::UNIX->new(
        Type => SOCK_STREAM(),
        Peer => $sockfile,
    ) || die "Couldn't connect to $sockfile: $@";
}

# Run the milter in a child for the duration of $callback, then return what it printed.
sub fork_and_term {
    my ( $callback, $script, %args ) = @_;
    my $milter = Milter::Harness->new( script => $script, config => $args{'--config'} );
    $milter->start();
    if ($callback) {
        local $@;
        eval { $callback->() } or do {
            print "$@\n";
        }
    }
    return $milter->stop();
}

1;
