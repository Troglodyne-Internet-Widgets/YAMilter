use 5.014;
use strict;
use warnings FATAL => 'all';
use re '/aa';

use FindBin::libs;
use Cwd;
use File::Temp;
use MIME::Base64 qw{encode_base64};
use Test2::V0;
use Test2::Plugin::NoWarnings;

use Milter::Client qw{:constants};
use Milter::Harness;
use Milter::Recipe;
use Milter::Recipe::MailingList;
use Sendmail::PMilter qw{:all};
use CorpusTest        qw{write_file};

my $run_dir = Cwd::abs_path("$FindBin::Bin/..");
my $tmp     = File::Temp->newdir();
my $mx      = 'mx.test.test';

sub config {
    my ($extra) = @_;
    return write_file( "$tmp/yamilter.cfg", "[service]\nsock=$tmp/yamilter.sock\npidfile=$tmp/yamilter.pid\nworkers=1\n$extra" );
}

subtest 'valid_list_header' => sub {
    my %cases = (
        'List-Unsubscribe'      => [ [ '<mailto:leave@test.test>, <https://test.test/u?id=1>', 1 ], [ '<https://test.test/u> (click it)', 1 ], [ "<https://test.test/very/\n long/url>", 1 ], [ 'https://test.test/u', 0 ], [ '<https://test.test/u', 0 ], [ '=?us-ascii?Q?=3Chttps=3A=2F=2Ftest.test=2Fu=3E?=', 0 ], [ '<not a url>', 0 ], [ '', 0 ] ],
        'List-Post'             => [ [ 'NO (posting not allowed)', 1 ], [ '<mailto:list@test.test>', 1 ], [ 'maybe', 0 ] ],
        'List-Archive'          => [ [ '<https://test.test/archive/>', 1 ], [ '<https://test.test/archive/', 0 ] ],
        'List-Id'               => [ [ 'Perl people <p5p.lists.test.test>', 1 ], [ '<local-list.localhost>', 1 ], [ '=?utf-8?q?Caf=C3=A9?= <cafe.test.test>', 1 ], [ '<nodots>', 0 ], [ 'p5p.lists.test.test', 0 ], [ '<' . ( 'a' x 250 ) . '.test.test>', 0 ] ],
        'List-Unsubscribe-Post' => [ [ 'List-Unsubscribe=One-Click', 1 ], [ 'List-Unsubscribe=one-click', 0 ], [ 'yes', 0 ] ],
    );
    foreach my $name ( sort keys %cases ) {
        foreach my $case ( @{ $cases{$name} } ) {
            my ( $value, $ok ) = @$case;
            is( Milter::Recipe::MailingList::valid_list_header( $name, $value ) ? 1 : 0, $ok, ( $ok ? 'valid' : 'malformed' ) . " $name: $value" );
        }
    }
};

subtest 'list_id' => sub {
    is( Milter::Recipe::MailingList::list_id('Some List (comment) <Some.List.Test.Test>'), 'some.list.test.test', 'lowercased identifier, phrase and comment dropped' );
    is( Milter::Recipe::MailingList::list_id('<bad>'),                                     undef,                 'undef when malformed' );
};

subtest 'authentication_results' => sub {
    my ( $servid, @results ) = Milter::Recipe::MailingList::authentication_results("$mx (comment (nested)); dkim=pass (2048-bit key) header.d=lists.test.test header.s=sel; spf/1=fail smtp.mailfrom=\"bounce\@test.test\"");
    is( $servid,                                                              $mx,                                                                                                                                                                                                      'authserv-id, comments removed' );
    is( \@results,                                                            [ { method => 'dkim', result => 'pass', props => { 'header.d' => 'lists.test.test', 'header.s' => 'sel' } }, { method => 'spf', result => 'fail', props => { 'smtp.mailfrom' => 'bounce@test.test' } } ], 'results, versions and quotes removed' );
    is( [ Milter::Recipe::MailingList::authentication_results("$mx; none") ], [$mx],                                                                                                                                                                                                    'no results' );
    is( [ Milter::Recipe::MailingList::authentication_results('') ],          [],                                                                                                                                                                                                       'nothing at all' );
};

subtest 'unsubscribe_link' => sub {
    my %cases = (
        'a link to an unsubscribe URL'       => [ '<p><a href="https://test.test/unsub?u=1">click</a></p>',                          1, 1 ],
        'a link saying unsubscribe'          => [ '<a href=\'https://test.test/x\'>Unsubscribe</a>',                                 1, 1 ],
        'a link after unsubscribe'           => [ '<p>To <b>opt out</b> of these emails <a href=https://test.test/x>click here</a>', 1, 1 ],
        'an ordinary link'                   => [ '<p>Read the <a href="https://test.test/news">news</a></p>',                       1, 0 ],
        'unsubscribe far from any link'      => [ 'unsubscribe' . ( ' filler' x 50 ) . ' <a href="https://test.test/x">x</a>',       1, 0 ],
        'plain text unsubscribe URL'         => [ "Leave: https://test.test/optout/1\n",                                             0, 1 ],
        'plain text saying unsubscribe'      => [ "To unsubscribe from this list visit\nhttps://test.test/x\n",                      0, 1 ],
        'plain text mailto'                  => [ "To unsubscribe, write to mailto:leave\@test.test\n",                              0, 1 ],
        'plain text with an ordinary link'   => [ "See https://test.test/docs for details.\n",                                       0, 0 ],
        'plain text unsubscribe with no URL' => [ "Reply with unsubscribe to stop.\n",                                               0, 0 ],
    );
    foreach my $name ( sort keys %cases ) {
        my ( $text, $html, $want ) = @{ $cases{$name} };
        is( Milter::Recipe::MailingList::unsubscribe_link( $text, $html ), $want, $name );
    }
};

subtest 'body_has_unsubscribe_link' => sub {
    my $html   = encode_base64('<a href="https://test.test/unsub">Unsubscribe</a>');
    my $header = qq{Subject: s\nMIME-Version: 1.0\nContent-Type: multipart/alternative; boundary="b"\n};
    my $body   = "--b\r\nContent-Type: text/plain\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nHello=20there\r\n--b\r\nContent-Type: text/html\r\nContent-Transfer-Encoding: base64\r\n\r\n$html\r\n--b--\r\n";
    ok( Milter::Recipe::MailingList::body_has_unsubscribe_link( $header, $body ), 'found in a base64 encoded HTML part' );

    my $none = encode_base64('<p>nothing to see</p>');
    ( my $plain = $body ) =~ s{\Q$html\E}{$none};
    ok( !Milter::Recipe::MailingList::body_has_unsubscribe_link( $header, $plain ), 'not found when no part has one' );

    ok( Milter::Recipe::MailingList::body_has_unsubscribe_link( "Subject: s\nContent-Type: multipart/mixed\n", "no boundary, but https://test.test/unsubscribe\r\n" ), 'mail too broken to take apart is read as it came' );
};

# The configuration is a singleton, but config() hands back the live section, so tests adjust it
Milter::Recipe->new( config("[MailingList]\naction=reject\nallow=lists.test.test, one.groups.test.test\nauthserv_id=$mx\n") );
my $conf = Milter::Recipe::MailingList->config();

sub ctx {
    return mock { priv => {}, reply => undef } => (
        add => [
            getpriv  => sub { $_[0]{priv} },
            setpriv  => sub { $_[0]{priv} = $_[1] },
            setreply => sub { my $self    = shift; $self->{reply} = join ' ', @_ },
        ],
    );
}

# Play a message through the callbacks yamilter would run (the defaults, then this recipe's); returns the verdict and reply.
# With no body, it stops at end of header.
sub transaction {
    my ( $sender, $headers, $body ) = @_;
    my $ctx = ctx();
    my %cb  = Milter::Recipe->cb();
    $cb{connect}->($ctx);
    $cb{envfrom}->( $ctx, $sender );
    $cb{header}->( $ctx, @$_ ) for @$headers;
    my $res = $cb{eoh}->($ctx);

    if ( $res eq SMFIS_CONTINUE && defined $body ) {
        $cb{body}->( $ctx, $body );
        $res = $cb{eom}->($ctx);
    }
    return ( $res, $ctx->{reply} );
}

my @list = ( [ 'List-Id', '<p5p.lists.test.test>' ], [ 'List-Unsubscribe', '<mailto:leave@lists.test.test>' ] );

subtest 'trusted lists' => sub {
    is( [ transaction( '<bounce@lists.test.test>', [ @list, [ 'Authentication-Results', "$mx; dkim=pass header.d=lists.test.test" ] ] ) ],                                       [ SMFIS_ACCEPT,   undef ], 'our DKIM pass for the list domain: accepted outright' );
    is( [ transaction( '<bounce@lists.test.test>', [ [ 'List-Id', '<one.groups.test.test>' ], [ 'Authentication-Results', "$mx; dkim=pass header.i=\@groups.test.test" ] ] ) ],  [ SMFIS_ACCEPT,   undef ], 'a list named exactly, signed by its host (header.i)' );
    is( [ transaction( '<bounce@groups.test.test>', [ [ 'List-Id', '<other.groups.test.test>' ], [ 'Authentication-Results', "$mx; dkim=pass header.d=groups.test.test" ] ] ) ], [ SMFIS_CONTINUE, undef ], 'another list on the same host is not trusted' );
    is( [ transaction( '<bounce@lists.test.test>', [ @list, [ 'Authentication-Results', "evil.test.test; dkim=pass header.d=lists.test.test" ] ] ) ],                            [ SMFIS_CONTINUE, undef ], 'a DKIM pass from someone else\'s authserv-id proves nothing' );
    is( [ transaction( '<bounce@lists.test.test>', [ @list, [ 'Authentication-Results', "$mx; dkim=pass header.d=elsewhere.test" ] ] ) ],                                        [ SMFIS_CONTINUE, undef ], 'a DKIM pass for some other domain proves nothing' );
    is( [ transaction( '<bounce@lists.test.test>', [ @list, [ 'Authentication-Results', "$mx; dkim=fail header.d=lists.test.test" ] ] ) ],                                       [ SMFIS_CONTINUE, undef ], 'nor does a DKIM fail' );

    my @spf = ( @list, [ 'Received-SPF', 'Pass (mailfrom) identity=mailfrom; client-ip=192.0.2.1' ] );
    is( [ transaction( '<bounce@lists.test.test>', \@spf ) ], [ SMFIS_CONTINUE, undef ], 'SPF is not proof unless allow_spf' );
    local $conf->{allow_spf} = 1;
    is( [ transaction( '<bounce@lists.test.test>', \@spf ) ],                                                                                          [ SMFIS_ACCEPT,   undef ], 'with allow_spf, a Received-SPF pass for an envelope sender in the list domain' );
    is( [ transaction( '<bounce@elsewhere.test>', \@spf ) ],                                                                                           [ SMFIS_CONTINUE, undef ], '... but not for one elsewhere' );
    is( [ transaction( '<bounce@lists.test.test>', [ @list, [ 'Received-SPF', 'Softfail' ], [ 'Received-SPF', 'Pass (forged)' ] ] ) ],                 [ SMFIS_CONTINUE, undef ], '... and only the first Received-SPF counts' );
    is( [ transaction( '<bounce@lists.test.test>', [ @list, [ 'Authentication-Results', "$mx; spf=pass smtp.mailfrom=bounce\@lists.test.test" ] ] ) ], [ SMFIS_ACCEPT,   undef ], '... or our Authentication-Results spf=pass' );
};

subtest 'malformed and missing headers' => sub {
    is( [ transaction( '<a@test.test>', [ [ 'List-Unsubscribe', 'https://test.test/u' ] ] ) ],                                                              [ SMFIS_REJECT,   '550 5.7.1 Malformed List-Unsubscribe header (RFC 2369)' ],                       'malformed List-Unsubscribe' );
    is( [ transaction( '<a@test.test>', [ [ 'List-Id', '<nodots>' ] ] ) ],                                                                                  [ SMFIS_REJECT,   '550 5.7.1 Malformed List-Id header (RFC 2919)' ],                                'malformed List-Id' );
    is( [ transaction( '<a@test.test>', [ [ 'List-Unsubscribe-Post', 'List-Unsubscribe=One-Click' ], [ 'List-Unsubscribe', '<mailto:x@test.test>' ] ] ) ],  [ SMFIS_REJECT,   '550 5.7.1 List-Unsubscribe-Post without an https List-Unsubscribe (RFC 8058)' ], 'one-click without https' );
    is( [ transaction( '<a@test.test>', [ [ 'List-Unsubscribe-Post', 'List-Unsubscribe=One-Click' ], [ 'List-Unsubscribe', '<https://test.test/u>' ] ] ) ], [ SMFIS_CONTINUE, undef ],                                                                          'one-click with https' );

    local $conf->{require} = [qw{List-Id List-Unsubscribe}];
    is( [ transaction( '<a@test.test>', [ [ 'List-Unsubscribe', '<https://test.test/u>' ] ] ) ], [ SMFIS_REJECT,   '550 5.7.1 Mailing list mail without a List-Id header' ], 'required header missing from list mail' );
    is( [ transaction( '<a@test.test>', [ [ 'Subject',          'hello' ] ] ) ],                 [ SMFIS_CONTINUE, undef ],                                                  'mail without list headers is not list mail' );
    is( [ transaction( '<a@test.test>', \@list ) ], [ SMFIS_CONTINUE, undef ], 'all there' );
};

subtest 'unsubscribe links in the body' => sub {

    # Through to end of message, where passing means the default accept
    my $body = "To unsubscribe visit https://test.test/x\r\n";
    is( [ transaction( '<a@test.test>', [ [ 'Subject', 'deals' ] ],                                                  $body ) ],                            [ SMFIS_REJECT, '550 5.7.1 Unsubscribe link in the body without a List-Unsubscribe header (RFC 2369)' ], 'link without the header' );
    is( [ transaction( '<a@test.test>', [ [ 'Subject', 'deals' ], [ 'List-Unsubscribe', '<https://test.test/u>' ] ], $body ) ],                            [ SMFIS_ACCEPT, undef ],                                                                                 'link with the header' );
    is( [ transaction( '<a@test.test>', [ [ 'Subject', 'hello' ] ],                                                  "See https://test.test/docs\r\n" ) ], [ SMFIS_ACCEPT, undef ],                                                                                 'no unsubscribe link' );

    # config() copies no_accum from the service settings on every call
    my $service = Milter::Recipe->new();
    local $service->{no_accum} = 1;
    is( [ transaction( '<a@test.test>', [ [ 'Subject', 'deals' ] ], $body ) ], [ SMFIS_ACCEPT, undef ], 'skipped with no_accum' );
};

subtest 'with EnvelopeMatch, in yamilter' => sub {
    my $converse = sub {
        my ( $headers, $body ) = @_;
        my $milter = Milter::Harness->new(
            script => "$run_dir/bin/yamilter",
            config => config("order=MailingList, EnvelopeMatch\n[MailingList]\naction=reject\nallow=lists.test.test\nauthserv_id=$mx\n[EnvelopeMatch]\naction=reject\n")
        );
        $milter->start();
        my ( $code, $reply ) = Milter::Client::sendmail(
            $milter->connect(),
            { timeout => 5 },
            [ SMFIC_OPTNEG, 6, 0x1FF, 0x1FFFFF ],
            [ SMFIC_HELO,   'client.test.test' ],
            [ SMFIC_MAIL,   '<bounce@lists.test.test>' ],
            [ SMFIC_RCPT,   '<me@test.test>' ],
            [SMFIC_DATA],
            ( map { [ SMFIC_HEADER, @$_ ] } @$headers ),
            [SMFIC_EOH],
            [ SMFIC_BODY, $body ],
            [SMFIC_BODYEOB],
            [SMFIC_QUIT],
        );
        my $log = $milter->stop();
        return ( $code, $reply, $log );
    };

    # List mail is From its author and To the list, so EnvelopeMatch would refuse it
    my @headers = ( [ 'From', 'author@elsewhere.test' ], [ 'To', 'p5p@lists.test.test' ], @list );
    my ( $code, $reply, $log ) = $converse->( [ @headers, [ 'Authentication-Results', "$mx; dkim=pass header.d=lists.test.test" ] ], "hi\r\n" );
    is( $code, SMFIR_ACCEPT, 'a trusted list is accepted before EnvelopeMatch sees it' ) or diag($log);

    ( $code, $reply, $log ) = $converse->( \@headers, "hi\r\n" );
    is( [ $code, $reply ], [ SMFIR_REPLYCODE, '550 5.7.1 Envelope sender does not match From in header' ], 'without proof it goes on to EnvelopeMatch' ) or diag($log);

    ( $code, $reply, $log ) = $converse->( [ [ 'From', 'bounce@lists.test.test' ], [ 'To', 'me@test.test' ] ], "To unsubscribe visit https://test.test/x\r\n" );
    is( [ $code, $reply ], [ SMFIR_REPLYCODE, '550 5.7.1 Unsubscribe link in the body without a List-Unsubscribe header (RFC 2369)' ], 'the body check runs at end of message' ) or diag($log);
};

done_testing();

__END__

=head1 DESCRIPTION

L<Milter::Recipe::MailingList>: the RFC 2369, 2919, 8058 and 8601 parsing, unsubscribe link detection,
the callbacks against a mock context, and the recipe running in yamilter ahead of EnvelopeMatch.

=cut
