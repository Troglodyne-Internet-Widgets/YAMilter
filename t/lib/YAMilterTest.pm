package YAMilterTest;

use 5.014;
use strict;
use warnings FATAL => 'all';
use re '/aa';

use FindBin::libs;

use Exporter 'import';
our @EXPORT_OK   = qw{fork_and_term getconfig};
our %EXPORT_TAGS = ( all => \@EXPORT_OK );

use Milter::Harness;
use File::Temp;
use Config::Simple;

=head1 DESCRIPTION

Helpers for the test which runs yamilter from its script: a configuration in a temporary directory, and a wrapper around L<Milter::Harness>.

=cut

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
