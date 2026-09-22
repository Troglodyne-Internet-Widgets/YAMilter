package Milter::Harness;

# ABSTRACT: Start and stop a yamilter process for testing recipes against

use strict;
use warnings;

use Config::Simple;
use File::Temp;
use IO::Socket::UNIX;
use POSIX       qw{WNOHANG};
use Time::HiRes qw{usleep};

=head1 SYNOPSIS

    my $milter = Milter::Harness->new(
        script => '/path/to/bin/yamilter',
        config => '/path/to/yamilter.cfg',
    );
    $milter->start();
    my $sock = $milter->connect();
    ...
    my $output = $milter->stop();

=head1 DESCRIPTION

Runs the yamilter script in a child process, and waits for it to be ready to take connections.

The child is started with exec(), so it shares no state (loaded recipes, database handles) with the caller.
The caller's @INC is passed on to it, so what you can load, it can load.

Everything the child prints to STDOUT or STDERR is kept, and returned by stop().

=head1 CONSTRUCTOR

=head2 new(%args)

=over 4

=item C<script>

Path to the yamilter script.  Required.

=item C<config>

Path to the configuration file to run it with.  Required.
The socket path is read from the C<service.sock> key therein.

=item C<wait>

Seconds to wait for the socket to show up.  Defaults to 10.

=back

=cut

sub new {
    my ( $class, %args ) = @_;
    die "script is required"                       unless $args{script};
    die "config is required"                       unless $args{config};
    die "No such configuration file $args{config}" unless -f $args{config};

    my $cfg = Config::Simple->new( $args{config} ) or die Config::Simple->error();
    $args{sock} = $cfg->param('service.sock') // '/var/run/yamilter.sock';
    $args{wait} //= 10;

    return bless( \%args, $class );
}

sub sock { $_[0]->{sock} }
sub pid  { $_[0]->{pid} }

=head1 METHODS

=head2 start

Fork & exec the milter, then wait for its socket to show up.

Dies if the child exits early or the socket does not show up in time, with whatever the child printed.

=cut

sub start {
    my $self = shift;
    die "Milter already running" if $self->{pid};

    # Otherwise a stale socket makes us think the milter is ready before it is
    unlink $self->sock() if -e $self->sock();

    $self->{log} = File::Temp->new();
    my $pid = fork();
    die "Could not fork: $!" unless defined $pid;
    if ( !$pid ) {
        open( STDOUT, '>&', $self->{log} ) or POSIX::_exit(1);
        open( STDERR, '>&', $self->{log} ) or POSIX::_exit(1);
        local $ENV{PERL5LIB} = join( ':', grep { !ref } @INC );
        exec( $^X, $self->{script}, '--config', $self->{config} ) or POSIX::_exit(1);
    }
    $self->{pid}   = $pid;
    $self->{owner} = $$;

    my $tries = $self->{wait} * 20;
    foreach ( 1 .. $tries ) {
        return 1 if -S $self->sock();
        if ( waitpid( $pid, WNOHANG ) == $pid ) {
            delete $self->{pid};
            die "Milter exited before it was ready:\n" . $self->output();
        }
        usleep 50_000;
    }
    my $out = $self->stop();
    die "Milter did not create " . $self->sock() . " within $self->{wait} seconds:\n$out";
}

=head2 connect

Returns a new connection to the milter's socket.

=cut

sub connect {
    my $self = shift;
    return IO::Socket::UNIX->new(
        Type => IO::Socket::UNIX::SOCK_STREAM(),
        Peer => $self->sock(),
    ) || die "Could not connect to " . $self->sock() . ": $!";
}

=head2 running

True if the child is still alive.

=cut

sub running {
    my $self = shift;
    return 0 unless $self->{pid};
    return 0 if waitpid( $self->{pid}, WNOHANG ) == $self->{pid};
    return 1;
}

=head2 output

Returns everything the child printed so far.

=cut

sub output {
    my $self = shift;
    return '' unless $self->{log};
    open( my $fh, '<', $self->{log}->filename ) or return '';
    local $/;
    return <$fh> // '';
}

=head2 stop

Sends the child a TERM, then a KILL if it has not gone away within 10 seconds.

Returns everything the child printed.

=cut

sub stop {
    my $self = shift;
    my $pid  = delete $self->{pid};
    return $self->output() unless $pid;

    kill( 'TERM', $pid );
    foreach ( 1 .. 100 ) {
        return $self->output() if waitpid( $pid, WNOHANG ) != 0;
        usleep 100_000;
    }
    kill( 'KILL', $pid );
    waitpid( $pid, 0 );
    return $self->output();
}

# Forked children of the caller get a copy of this object; only the process which started the milter stops it.
sub DESTROY {
    my $self = shift;
    local ( $?, $@ );
    $self->stop() if $self->{pid} && $self->{owner} == $$;
}

1;
