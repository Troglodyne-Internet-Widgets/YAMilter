use 5.014;
use strict;
use warnings FATAL => 'all';
use re '/aa';

use FindBin::libs;
use Cwd;
use File::Temp;
use Test2::V0;
use Test2::Plugin::NoWarnings;

use Milter::Client qw{:constants};
use Milter::Harness;
use Milter::Recipe;
use Milter::Recipe::EnvelopeMatch;
use Sendmail::PMilter qw{:all};
use CorpusTest        qw{write_file};

my $run_dir = Cwd::abs_path("$FindBin::Bin/..");
my $tmp     = File::Temp->newdir();

sub config {
    my ($action) = @_;
    return write_file( "$tmp/yamilter.cfg", "[service]\nsock=$tmp/yamilter.sock\npidfile=$tmp/yamilter.pid\nworkers=1\n[EnvelopeMatch]\naction=$action\n" );
}

# The configuration is a singleton, so the in-process tests all use this one
Milter::Recipe->new( config('reject') );

# Just enough of Sendmail::PMilter::Context, keeping the reply it was given
sub ctx {
    return mock { priv => {}, reply => undef } => (
        add => [
            getpriv  => sub { $_[0]{priv} },
            setpriv  => sub { $_[0]{priv} = $_[1] },
            setreply => sub { my $self    = shift; $self->{reply} = join ' ', @_ },
        ],
    );
}

# Play one transaction through the callbacks, returning eoh's verdict and the reply set
sub transaction {
    my ( $ctx, $sender, $recipients, %headers ) = @_;
    my %cb = %Milter::Recipe::EnvelopeMatch::cb;
    $cb{envfrom}->( $ctx, $sender, 'SIZE=100' );
    $cb{envrcpt}->( $ctx, $_ ) for @$recipients;
    $cb{header}->( $ctx, $_, $headers{$_} ) for sort keys %headers;
    my $res = $cb{eoh}->($ctx);
    return ( $res, delete $ctx->{reply} );
}

subtest 'matching' => sub {
    my $ctx = ctx();
    is( [ transaction( $ctx, '<a@test.test>', ['<b@test.test>'], From => 'a@test.test', To => 'b@test.test' ) ],                                   [ SMFIS_CONTINUE, undef ], 'sender in From, recipient in To' );
    is( [ transaction( $ctx, '<A@Test.Test>', ['<b@test.test>'], From => '"Someone" <a@test.TEST>', To => 'Other <b@test.test>' ) ],               [ SMFIS_CONTINUE, undef ], 'display names and case do not matter' );
    is( [ transaction( $ctx, '<a@test.test>', ['<b@test.test>'], From => 'a@test.test', To => 'x@test.test', Cc => 'y@test.test, b@test.test' ) ], [ SMFIS_CONTINUE, undef ], 'recipient in Cc' );
    is( [ transaction( $ctx, '<a@test.test>', [ '<hidden@test.test>', '<b@test.test>' ], From => 'a@test.test', To => 'b@test.test' ) ],           [ SMFIS_CONTINUE, undef ], 'one addressed recipient is enough; the rest may be Bcc' );
    is( [ transaction( $ctx, '<>', ['<b@test.test>'], From => 'Mail Delivery System <MAILER-DAEMON@test.test>', To => 'b@test.test' ) ],           [ SMFIS_CONTINUE, undef ], 'bounces are not checked' );
};

subtest 'not matching' => sub {
    my $ctx = ctx();
    is( [ transaction( $ctx, '<a@test.test>',   ['<b@test.test>'], From => 'someone.else@test.test',   To => 'b@test.test' ) ],              [ SMFIS_REJECT, '550 5.7.1 Envelope sender does not match From in header' ],              'sender not in From' );
    is( [ transaction( $ctx, '<bob@test.test>', ['<b@test.test>'], From => 'notbob@test.test.invalid', To => 'b@test.test' ) ],              [ SMFIS_REJECT, '550 5.7.1 Envelope sender does not match From in header' ],              'an address containing the sender is not the sender' );
    is( [ transaction( $ctx, '<a@test.test>',   ['<b@test.test>'], From => 'a@test.test',              To => 'undisclosed-recipients:;' ) ], [ SMFIS_REJECT, '550 5.7.1 Envelope recipient not present within To: or Cc: in header' ], 'recipient not addressed' );
    is( [ transaction( $ctx, '<a@test.test>', ['<b@test.test>'], From => 'a@test.test' ) ], [ SMFIS_REJECT, '550 5.7.1 Envelope recipient not present within To: or Cc: in header' ], 'no To at all' );
};

subtest 'one transaction does not leak into the next' => sub {
    my $ctx = ctx();
    transaction( $ctx, '<a@test.test>', ['<b@test.test>'], From => 'a@test.test', To => 'b@test.test' );
    is( [ transaction( $ctx, '<c@test.test>', ['<d@test.test>'], From => 'a@test.test', To => 'b@test.test' ) ], [ SMFIS_REJECT, '550 5.7.1 Envelope sender does not match From in header' ], 'the second message on a connection is judged on its own addresses' );
};

subtest 'in yamilter' => sub {
    my @commands = (
        [ SMFIC_OPTNEG,  6, 0x1FF, 0x1FFFFF ],
        [ SMFIC_CONNECT, 'client.test.test', SMFIA_INET, 25, '192.0.2.1' ],
        [ SMFIC_HELO,    'client.test.test' ],
        [ SMFIC_MAIL,    '<a@test.test>' ],
        [ SMFIC_RCPT,    '<b@test.test>' ],
        [SMFIC_DATA],
        [ SMFIC_HEADER, 'From', 'a@test.test' ],
        [ SMFIC_HEADER, 'To',   'b@test.test' ],
        [SMFIC_EOH],
        [ SMFIC_BODY, "hello\r\n" ],
        [SMFIC_BODYEOB],
        [SMFIC_QUIT],
    );
    my @forged = map { $_->[0] eq SMFIC_HEADER && $_->[1] eq 'From' ? [ SMFIC_HEADER, 'From', 'someone.else@test.test' ] : $_ } @commands;

    my $converse = sub {
        my ( $action, @cmds ) = @_;
        my $milter = Milter::Harness->new( script => "$run_dir/bin/yamilter", config => config($action) );
        $milter->start();
        my @res = Milter::Client::sendmail( $milter->connect(), { timeout => 5 }, @cmds );
        my $log = $milter->stop();
        return ( @res[ 0, 1 ], $log );
    };

    my ( $code, $reply, $log ) = $converse->( 'reject', @commands );
    is( $code, SMFIR_ACCEPT, 'matching mail accepted' ) or diag($log);

    ( $code, $reply, $log ) = $converse->( 'reject', @forged );
    is( [ $code, $reply ], [ SMFIR_REPLYCODE, '550 5.7.1 Envelope sender does not match From in header' ], 'forged From rejected with the reply' ) or diag($log);

    ( $code, $reply, $log ) = $converse->( 'discard', @forged );
    is( $code, SMFIR_DISCARD, 'discard needs no reply, and no longer dies trying to find one' ) or diag($log);
};

done_testing();

__END__

=head1 DESCRIPTION

L<Milter::Recipe::EnvelopeMatch>: its callbacks against a mock context, and the recipe running in yamilter with the reject and discard actions.

=cut
