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

    $cb{body}->( $ctx, "first body" );
    $cb{envfrom}->( $ctx, '<c@test.test>' );
    $cb{header}->( $ctx, 'Subject', 'second' );
    is( [ @{ $ctx->getpriv }{qw{header body}} ], [ "Subject: second\n", undef ], 'the next message on the connection starts with nothing accumulated' );
};

subtest 'config' => sub {
    my $tmp = File::Temp->newdir();

    # Two recipes which do nothing, so each can have a configuration of its own
    make_path("$tmp/lib/Milter/Recipe");
    for my $name (qw{First Second}) {
        write_file( "$tmp/lib/Milter/Recipe/$name.pm", "package Milter::Recipe::$name;\nuse parent qw{Milter::Recipe};\nour %cb = ( eoh => sub { __PACKAGE__->cont() } );\n1;\n" );
    }
    local @INC = ( "$tmp/lib", @INC );

    Milter::Recipe->new( write_file( "$tmp/yamilter.cfg", "[service]\ndebug=0\norder=Second\n[First]\naction=defer\nsetting=one\n[Second]\naction=discard\n" ) );

    is( Milter::Recipe::First->config(),  { action => 'defer', setting => 'one', debug => 0, no_accum => 0 }, 'a recipe gets its own section' );
    is( Milter::Recipe::Second->config(), { action => 'discard', debug => 0, no_accum => 0 },                 'and so does the next one asked, rather than the first one\'s' );
    is( Milter::Recipe::First->config(),  { action => 'defer', setting => 'one', debug => 0, no_accum => 0 }, 'asking again gives the same answer' );

    is( [ Milter::Recipe::First->config_action(), Milter::Recipe::Second->config_action() ], [ SMFIS_TEMPFAIL, SMFIS_DISCARD ], 'so each takes its own action' );

    is( [ Milter::Recipe->loaded_recipes() ], [qw{Milter::Recipe::Second Milter::Recipe::First}], 'recipes named in service.order run first' );

    is( [ Milter::Recipe->config_list(' a , b,,c ') ],     [qw{a b c}], 'config_list splits a string, trimming and dropping empties' );
    is( [ Milter::Recipe->config_list( [ ' a', 'b ' ] ) ], [qw{a b}],   '... takes Config::Simple\'s arrayref' );
    is( [ Milter::Recipe->config_list(undef) ],            [],          '... and makes nothing of undef' );
};

# Each yamilter run here gets its configuration and a set of one-callback recipes
sub converse {
    my ( $service, $recipes, @sections ) = @_;
    my $tmp = File::Temp->newdir();
    make_path("$tmp/lib/Milter/Recipe");
    foreach my $name ( sort keys %$recipes ) {
        write_file( "$tmp/lib/Milter/Recipe/$name.pm", "package Milter::Recipe::$name;\nuse parent qw{Milter::Recipe};\nour %cb = ( $recipes->{$name} );\n1;\n" );
    }
    local @INC = ( "$tmp/lib", @INC );

    my $cfg    = write_file( "$tmp/yamilter.cfg", "[service]\nsock=$tmp/yamilter.sock\npidfile=$tmp/yamilter.pid\nworkers=1\n$service" . join( '', map { "[$_]\naction=reject\n" } sort keys %$recipes ) );
    my $milter = Milter::Harness->new( script => "$FindBin::Bin/../bin/yamilter", config => $cfg );
    my $out    = eval { $milter->start(); 1 } ? undef : $@;
    return ( undef, undef, $out ) if $out;
    my ( $code, $reply ) = Milter::Client::sendmail(
        $milter->connect(),
        { timeout => 5 },
        [ SMFIC_OPTNEG, 6, 0x1FF, 0x1FFFFF ],
        [ SMFIC_HELO,   'client.test.test' ],
        [ SMFIC_MAIL,   '<a@test.test>' ],
        [ SMFIC_RCPT,   '<b@test.test>' ],
        [SMFIC_DATA],
        [ SMFIC_HEADER, 'Subject', 'hi' ],
        [SMFIC_EOH],
        [ SMFIC_BODY, "hi\r\n" ],
        [SMFIC_BODYEOB],
        [SMFIC_QUIT],
    );
    return ( $code, $reply, $milter->stop() );
}

subtest 'order and end of message, in yamilter' => sub {
    my %recipes = (
        Accepts => 'eoh => sub { __PACKAGE__->accept() }',
        Rejects => 'eoh => sub { __PACKAGE__->config_reply( $_[0], "no" ) }',
    );
    my ( $code, $reply, $log ) = converse( "order=Accepts\n", \%recipes );
    is( $code, SMFIR_ACCEPT, 'a recipe ordered first can accept before the others see the message' ) or diag($log);

    ( $code, $reply, $log ) = converse( "order=Rejects\n", \%recipes );
    is( [ $code, $reply ], [ SMFIR_REPLYCODE, '550 5.7.1 no' ], 'and ordered second, it never gets the chance' ) or diag($log);

    ( $code, $reply, $log ) = converse( '', { AtTheEnd => 'eom => sub { __PACKAGE__->config_reply( $_[0], "not at the end either" ) }' } );
    is( [ $code, $reply ], [ SMFIR_REPLYCODE, '550 5.7.1 not at the end either' ], 'a recipe\'s end of message callback runs before the default accept' ) or diag($log);

    ( $code, $reply, $log ) = converse( "order=Nonesuch\n", \%recipes );
    like( $log, qr/service\.order names Nonesuch, which has no section of its own/, 'an order naming an unconfigured recipe stops yamilter starting' );
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
