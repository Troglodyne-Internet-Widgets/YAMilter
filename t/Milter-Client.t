use 5.014;
use strict;
use warnings FATAL => 'all';
use re '/aa';

use FindBin::libs;
use Socket;
use Test2::V0;
use Test2::Plugin::NoWarnings;

use Milter::Client qw{:constants};

# A fake milter on the other end of a socketpair: reads one packet per command, and answers each with the next scripted reply.
# A reply of undef means say nothing; running out of replies hangs up.
sub converse {
    my ( $opts, $replies, @cmds ) = @_;
    socketpair( my $client, my $milter, AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or die "socketpair: $!";
    my $pid = fork() // die "fork: $!";
    if ( !$pid ) {
        close $client;
        my @seen;
        foreach my $reply (@$replies) {
            read( $milter, my $len,    4 ) == 4 or last;
            read( $milter, my $packet, unpack( 'N', $len ) );
            next unless defined $reply;
            syswrite( $milter, pack( 'N a*', length($_), $_ ) ) for ( ref $reply ? @$reply : $reply );
        }
        close $milter;
        exit 0;
    }
    close $milter;
    my @res = Milter::Client::sendmail( $client, ( $opts ? $opts : () ), @cmds );
    close $client;
    waitpid( $pid, 0 );
    return @res;
}

my @cmds = ( [SMFIC_EOH], [SMFIC_BODYEOB] );

is( [ converse( undef, [ SMFIR_CONTINUE, SMFIR_ACCEPT ], @cmds ) ], [ SMFIR_ACCEPT, '', [] ], 'final reply returned' );

is(
    [ converse( undef, [ SMFIR_CONTINUE, [ SMFIR_ADDHEADER . "X-Spam\0yes\0", SMFIR_PROGRESS, SMFIR_ACCEPT ] ], @cmds ) ],
    [ SMFIR_ACCEPT, '', [ [ SMFIR_ADDHEADER, "X-Spam\0yes" ] ] ],
    'modifications collected ahead of the final reply, progress dropped'
);

is( [ converse( { timeout => 0.2 }, [ SMFIR_CONTINUE, undef, 'unused' ], @cmds ) ], [ CLIENT_TIMEOUT, undef, [] ], 'silence is a timeout when asked' );
is( [ converse( { timeout => 0.2 }, [SMFIR_CONTINUE],                    @cmds ) ], [ CLIENT_EOF,     undef, [] ], 'hanging up is EOF when asked' );
is( [ converse( undef, [SMFIR_CONTINUE], @cmds ) ], [ SMFIR_CONTINUE, undef, [] ], 'without options, both are presumed CONTINUE' );

is( [ converse( { timeout => 0.2 }, [ SMFIR_CONTINUE, undef, SMFIR_ACCEPT ], [SMFIC_EOH], [SMFIC_QUIT], [SMFIC_BODYEOB] ) ], [ SMFIR_ACCEPT, '', [] ], 'no reply is waited for after QUIT' );

is( [ Milter::Client::body_chunks('') ],                                                          [],                       'empty body, no chunks' );
is( [ map { length( $_->[1] ) } Milter::Client::body_chunks( 'x' x ( MILTER_CHUNK_SIZE + 1 ) ) ], [ MILTER_CHUNK_SIZE, 1 ], 'body split at the chunk size' );

done_testing();

__END__

=head1 DESCRIPTION

L<Milter::Client> against a scripted fake milter: final replies, modifications, timeouts, hangups and body chunking.

=cut
