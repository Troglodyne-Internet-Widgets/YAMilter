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
use Milter::Contacts;
use Milter::Harness;
use Milter::Recipe;
use Milter::Recipe::ColdCall;
use Sendmail::PMilter qw{:all};
use CorpusTest        qw{write_file};

my $run_dir = Cwd::abs_path("$FindBin::Bin/..");
my $tmp     = File::Temp->newdir();
my $file    = "$tmp/contacts.db";

sub config {
    my ($extra) = @_;
    return write_file( "$tmp/yamilter.cfg", "[service]\nsock=$tmp/yamilter.sock\npidfile=$tmp/yamilter.pid\nworkers=1\n$extra" );
}

my $contacts = Milter::Contacts->new( file => $file );

# A colleague at our own domain, so that the own domain rule has something to refuse
$contacts->learn( addresses => [qw{client@customer.test colleague@ours.test}], message_ids => ['sent-1@ours.test'] );

subtest 'recipient_names' => sub {
    my %names = Milter::Recipe::ColdCall::recipient_names( 'Alex Someone <alex@ours.test>', [qw{<alex@ours.test> <info@shop.example.co.uk> <j.doe@ours.test>}] );
    is( \%names, { first => ['alex'], organization => [qw{example ours}] }, 'first names from the display name and plain mailbox names, not roles; organizations from domains' );
};

subtest 'header_traits' => sub {
    is( [ Milter::Recipe::ColdCall::header_traits( { 'x-priority' => '3' },                                        $contacts ) ], ['X-Priority'],               'X-Priority' );
    is( [ Milter::Recipe::ColdCall::header_traits( { subject => 'Re: our chat' },                                  $contacts ) ], ['reply to nothing we sent'], 'a Re: with no references' );
    is( [ Milter::Recipe::ColdCall::header_traits( { subject => 'RE: x', references => '<other@elsewhere.test>' }, $contacts ) ], ['reply to nothing we sent'], 'a Re: referencing something we did not send' );
    is( [ Milter::Recipe::ColdCall::header_traits( { subject => 'Re: x', 'in-reply-to' => '<sent-1@ours.test>' },  $contacts ) ], [],                           'a real reply' );
    is( [ Milter::Recipe::ColdCall::header_traits( { subject => 'Reports' },                                       $contacts ) ], [],                           'Re at the start of a word is not a reply' );
};

subtest 'body_traits' => sub {
    my %names = ( first => ['alex'], organization => ['ours'] );
    my %cases = (
        'meeting request'                           => "Do you have 15 minutes next week?",
        'opt out by reply'                          => "If this isn't relevant, just reply with no.",
        'follow-up'                                 => "Just circling back on my last note.",
        'unsubscribe text without List-Unsubscribe' => "Reply to unsubscribe.",
        'P.S.'                                      => "Thanks.\nP.S. We work with companies like yours.",
        'greets you by name'                        => "Hi Alex,\n\nI noticed your work.",
        'names your organization'                   => "I have an idea for Ours this quarter.",
    );
    foreach my $trait ( sort keys %cases ) {
        is( [ Milter::Recipe::ColdCall::body_traits( [ [ $cases{$trait}, 0 ] ], 0, %names ) ], [$trait], $trait );
    }
    is( [ Milter::Recipe::ColdCall::body_traits( [ [ '<p>Hey <b>Alex</b>, <a href="https://x.test">book a call</a></p>', 1 ] ], 0, %names ) ], [ 'meeting request', 'greets you by name' ], 'HTML is read as text' );
    is( [ Milter::Recipe::ColdCall::body_traits( [ [ "Write to alex\@ours.test or see https://www.ours.test/ours",       0 ] ], 0, %names ) ], [],                                          'the organization inside an address, hostname or URL does not count' );
    is( [ Milter::Recipe::ColdCall::body_traits( [ [ "To unsubscribe, click here",                                       0 ] ], 1, %names ) ], [],                                          'unsubscribe text is fine with a List-Unsubscribe header' );
    is( [ Milter::Recipe::ColdCall::body_traits( [ [ "Thanks for the invoice.",                                          0 ] ], 0, %names ) ], [],                                          'ordinary mail has none' );
};

# The configuration is a singleton, but config() hands back the live section, so tests adjust it
Milter::Recipe->new( config("[ColdCall]\naction=tag\ncontacts=$file\n") );
my $conf = Milter::Recipe::ColdCall->config();

sub ctx {
    my (%macros) = @_;
    return mock { priv => {}, headers => [] } => (
        add => [
            getpriv   => sub { $_[0]{priv} },
            setpriv   => sub { $_[0]{priv} = $_[1] },
            getsymval => sub { $macros{ $_[1] } },
            addheader => sub { push @{ $_[0]{headers} }, [ $_[1], $_[2] ] },
            setreply  => sub { },
        ],
    );
}

# Play a message through the callbacks yamilter would run; returns the headers it added
sub transaction {
    my (%m) = @_;
    my $ctx = ctx( %{ $m{macros} || {} } );
    my %cb  = Milter::Recipe->cb();
    $cb{connect}->($ctx);
    $cb{envfrom}->( $ctx, $m{from} // '<a@stranger.test>' );
    $cb{envrcpt}->( $ctx, $_ ) for @{ $m{to} || ['<alex@ours.test>'] };
    $cb{header}->( $ctx, @$_ ) for @{ $m{headers} };
    $cb{eoh}->($ctx);
    $cb{body}->( $ctx, $m{body} // '' );
    my $res = $cb{eom}->($ctx);
    return ( $res, $ctx->{headers} );
}

my @pitch = ( [ 'From', 'Sales Person <a@stranger.test>' ], [ 'To', 'Alex <alex@ours.test>' ], [ 'Subject', 'Quick question' ] );

subtest 'inbound' => sub {
    is(
        [ transaction( headers => \@pitch, body => "Hi Alex,\r\nDo you have 15 minutes?\r\n" ) ],
        [ SMFIS_ACCEPT, [ [ 'X-YAMilter', 'ColdCall: stranger; meeting request, greets you by name' ] ] ],
        'a stranger\'s pitch is accepted with a tag naming the traits'
    );
    is( [ transaction( headers => \@pitch, body => "Invoice attached.\r\n" ) ], [ SMFIS_ACCEPT, [] ], 'a stranger without the traits is not tagged' );

    my @client = ( [ 'From', 'client@customer.test' ], @pitch[ 1, 2 ] );
    is( [ transaction( headers => \@client, body => "Hi Alex,\r\nDo you have 15 minutes?\r\n" ) ],                             [ SMFIS_ACCEPT, [] ],                                                                              'a contact is not checked' );
    is( [ transaction( headers => [ [ 'From', 'new@customer.test' ], @pitch[ 1, 2 ] ], body => "Hi Alex, 15 minutes?\r\n" ) ], [ SMFIS_ACCEPT, [] ],                                                                              '... nor anyone at their organization' );
    is( [ transaction( headers => [ [ 'From', 'forged@ours.test' ], @pitch[ 1, 2 ] ], body => "Hi Alex, 15 minutes?\r\n" ) ],  [ SMFIS_ACCEPT, [ [ 'X-YAMilter', 'ColdCall: stranger; meeting request, greets you by name' ] ] ], 'our own domain vouches for nobody by domain' );
    is( [ transaction( headers => [ @pitch, [ 'List-Id', '<news.lists.test>' ] ], body => "Hi Alex, 15 minutes?\r\n" ) ],      [ SMFIS_ACCEPT, [] ],                                                                              'list mail is left to MailingList' );

    local $conf->{min_traits} = 3;
    is( [ transaction( headers => \@pitch, body => "Hi Alex,\r\nDo you have 15 minutes?\r\n" ) ], [ SMFIS_ACCEPT, [] ], 'min_traits' );
};

subtest 'outbound' => sub {
    my @mine = ( [ 'From', 'alex@ours.test' ], [ 'To', 'Prospect <new@prospect.test>' ], [ 'Subject', 'Hi' ], [ 'Message-ID', '<out-1@ours.test>' ] );
    is( [ transaction( macros => { '{auth_authen}' => 'alex' }, from => '<alex@ours.test>', to => ['<new@prospect.test>'], headers => \@mine, body => "Do you have 15 minutes?\r\n" ) ], [ SMFIS_ACCEPT, [] ], 'authenticated mail is not checked' );
    ok( $contacts->known('new@prospect.test'), '... its recipients are learned' );
    ok( $contacts->sent('out-1@ours.test'),    '... and its Message-ID' );

    is( [ transaction( headers => [ [ 'From', 'Prospect <new@prospect.test>' ], [ 'To', 'alex@ours.test' ], [ 'Subject', 'Re: Hi' ], [ 'In-Reply-To', '<out-1@ours.test>' ] ], body => "Sure, 15 minutes works.\r\n" ) ], [ SMFIS_ACCEPT, [] ], 'so their reply is from a contact' );
};

subtest 'in yamilter' => sub {
    my $milter = Milter::Harness->new( script => "$run_dir/bin/yamilter", config => config("tag_header=X-Cold\n[ColdCall]\naction=tag\ncontacts=$file\n") );
    $milter->start();
    my ( $code, $reply, $mods ) = Milter::Client::sendmail(
        $milter->connect(),
        { timeout => 5 },
        [ SMFIC_OPTNEG, 6, 0x1FF, 0x1FFFFF ],
        [ SMFIC_HELO,   'client.test.test' ],
        [ SMFIC_MAIL,   '<a@stranger.test>' ],
        [ SMFIC_RCPT,   '<alex@ours.test>' ],
        [SMFIC_DATA],
        ( map { [ SMFIC_HEADER, @$_ ] } @pitch ),
        [SMFIC_EOH],
        [ SMFIC_BODY, "Hi Alex,\r\nWorth a quick chat?\r\n" ],
        [SMFIC_BODYEOB],
        [SMFIC_QUIT],
    );
    my $log = $milter->stop();
    is( [ $code, $mods ], [ SMFIR_ACCEPT, [ [ SMFIR_ADDHEADER, "X-Cold\0ColdCall: stranger; meeting request, greets you by name" ] ] ], 'accepted, with the tag_header added' ) or diag($log);
};

done_testing();

__END__

=head1 DESCRIPTION

L<Milter::Recipe::ColdCall>: recipient names, each trait, strangers against contacts, learning from outbound mail, and tagging in yamilter.

=cut
