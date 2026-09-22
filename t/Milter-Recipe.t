use 5.014;
use strict;
use warnings FATAL => 'all';
use re '/aa';

use FindBin::libs;
use Test2::V0;
use Test2::Plugin::NoWarnings;

use File::Path qw{make_path};
use File::Temp;
use Milter::Client qw{:constants};
use Milter::Harness;
use Milter::Recipe;
use Sendmail::PMilter qw{:all};
use CorpusTest        qw{write_file};

# cb() is computed once, so this runs before any recipe is loaded below
subtest 'default callbacks' => sub {

    # Just enough of Sendmail::PMilter::Context for the default callbacks
    my $ctx = mock { priv => undef } => (
        add => [
            getpriv => sub { $_[0]{priv} },
            setpriv => sub { $_[0]{priv} = $_[1] },
        ],
    );

    my %cb = Milter::Recipe->cb();
    $cb{connect}->($ctx);
    $cb{header}->( $ctx, 'From',    'a@test.test' );
    $cb{header}->( $ctx, 'Subject', 'hi' );
    is( $ctx->getpriv->{header}, "From: a\@test.test\nSubject: hi\n", 'headers accumulate as Name: value lines' );
};

subtest 'config' => sub {
    my $tmp = File::Temp->newdir();

    # Two recipes which do nothing, so each can have a configuration of its own
    make_path("$tmp/lib/Milter/Recipe");
    for my $name (qw{First Second}) {
        write_file( "$tmp/lib/Milter/Recipe/$name.pm", "package Milter::Recipe::$name;\nuse parent qw{Milter::Recipe};\nour %cb = ( eoh => sub { __PACKAGE__->cont() } );\n1;\n" );
    }
    local @INC = ( "$tmp/lib", @INC );

    Milter::Recipe->new( write_file( "$tmp/yamilter.cfg", "[service]\ndebug=0\n[First]\naction=defer\nsetting=one\n[Second]\naction=discard\n" ) );

    is( Milter::Recipe::First->config(),  { action => 'defer', setting => 'one', debug => 0 }, 'a recipe gets its own section' );
    is( Milter::Recipe::Second->config(), { action => 'discard', debug => 0 },                 'and so does the next one asked, rather than the first one\'s' );
    is( Milter::Recipe::First->config(),  { action => 'defer', setting => 'one', debug => 0 }, 'asking again gives the same answer' );

    is( [ Milter::Recipe::First->config_action(), Milter::Recipe::Second->config_action() ], [ SMFIS_TEMPFAIL, SMFIS_DISCARD ], 'so each takes its own action' );
};

subtest 'config, in yamilter' => sub {
    my $tmp = File::Temp->newdir();

    # Reads its configuration at HELO, before Language reads its own at the first body chunk
    make_path("$tmp/lib/Milter/Recipe");
    write_file( "$tmp/lib/Milter/Recipe/Early.pm", "package Milter::Recipe::Early;\nuse parent qw{Milter::Recipe};\nour %cb = ( helo => sub { __PACKAGE__->config(); __PACKAGE__->cont() } );\n1;\n" );
    local @INC = ( "$tmp/lib", @INC );

    my $cfg    = write_file( "$tmp/yamilter.cfg", "[service]\nsock=$tmp/yamilter.sock\npidfile=$tmp/yamilter.pid\nworkers=1\n[Early]\naction=discard\n[Language]\nlangs=en\naction=defer\n" );
    my $milter = Milter::Harness->new( script => "$FindBin::Bin/../bin/yamilter", config => $cfg );
    $milter->start();
    my ( $code, $reply ) = Milter::Client::sendmail(
        $milter->connect(),
        { timeout => 5 },
        [ SMFIC_OPTNEG, 6, 0x1FF, 0x1FFFFF ],
        [ SMFIC_HELO,   'client.test.test' ],
        [ SMFIC_MAIL,   '<a@test.test>' ],
        [ SMFIC_RCPT,   '<b@test.test>' ],
        [SMFIC_DATA],
        [ SMFIC_HEADER, 'Subject', 'Bestellung' ],
        [SMFIC_EOH],
        [ SMFIC_BODY, "Sehr geehrte Damen und Herren, wir freuen uns Ihnen mitteilen zu koennen, dass Ihre Bestellung heute versandt wurde.\r\n" ],
        [SMFIC_BODYEOB],
        [SMFIC_QUIT],
    );
    my $log = $milter->stop();
    is( [ $code, $reply ], [ SMFIR_REPLYCODE, '450 4.7.1 Language used in mail body is incomprehensible to our users' ], "Language takes its own action, not the recipe which asked first" ) or diag($log);
};

done_testing();

__END__

=head1 DESCRIPTION

The default callbacks of L<Milter::Recipe>, and each recipe getting its own configuration.

=cut
