use strict;
use warnings;

use FindBin::libs;
use File::Path qw{make_path};
use Test2::V0;
use Test2::Plugin::NoWarnings;

use Milter::Client qw{:constants};
use Milter::Corpus::Replay;
use CorpusTest qw{fixture_corpus write_file};

my $fx       = fixture_corpus();
my $corpus   = $fx->{corpus};
my $tmp      = $fx->{tmp};
my $yamilter = "$fx->{run_dir}/bin/yamilter";

subtest 'commands' => sub {
    my $body = ( "x" x 99 . "\n" ) x 1000;
    my @cmds = Milter::Corpus::Replay::commands( "From: a\@test.test\nSubject: s\n\n$body", { client_ip => '192.0.2.1', helo => 'h', mail_from => '', rcpt_to => 'r@test.test' } );
    is( $cmds[1], [ SMFIC_CONNECT, '[192.0.2.1]', SMFIA_INET, 25, '192.0.2.1' ], 'connect with the client address' );
    is( $cmds[3], [ SMFIC_MAIL, '<>' ], 'null sender kept' );
    is( [ grep { $_->[0] eq SMFIC_HEADER } @cmds ], [ [ SMFIC_HEADER, 'From', 'a@test.test' ], [ SMFIC_HEADER, 'Subject', 's' ] ], 'one command per header' );
    my @chunks = grep { $_->[0] eq SMFIC_BODY } @cmds;
    is( scalar(@chunks), 2, 'a 101k body is sent in two chunks' );
    ok( !( grep { length( $_->[1] ) > MILTER_CHUNK_SIZE } @chunks ), '... none over the chunk size' );
    is( join( '', map { $_->[1] } @chunks ), ( "x" x 99 . "\r\n" ) x 1000, '... with CRLF line endings' );
    is( [ map { $_->[0] } @cmds[ -2, -1 ] ], [ SMFIC_BODYEOB, SMFIC_QUIT ], 'ends with end of message, then quit' );

    @cmds = Milter::Corpus::Replay::commands( "Subject: s\n\nx", {} );
    is( $cmds[1], [ SMFIC_CONNECT, 'localhost', SMFIA_UNKNOWN, 25, '' ], 'no client address, unknown family' );

    @cmds = Milter::Corpus::Replay::commands( "Subject: s\n\nx", { client_ip => '2001:db8::1', client_host => 'v6.test.test' } );
    is( $cmds[1], [ SMFIC_CONNECT, 'v6.test.test', SMFIA_INET6, 25, '2001:db8::1' ], 'IPv6 client' );
};

$corpus->index_source( $fx->{source} );

subtest 'run' => sub {
    like( dies { Milter::Corpus::Replay->new( corpus => $corpus, script => $yamilter, config => '/bogus' ) }, qr/No such configuration file/, 'missing configuration dies' );

    my $cfg    = write_file( "$tmp/lang.cfg", "[Language]\nlangs=en\naction=defer\n" );
    my $replay = Milter::Corpus::Replay->new( corpus => $corpus, script => $yamilter, config => $cfg );
    my ($run)  = $replay->run( label => 'english', jobs => 2, timeout => 5 );

    my ( undef, $rows ) = $corpus->query(
        q{SELECT h.value, r.action, r.reply FROM results r JOIN headers h ON h.message_id = r.message_id AND h.name = 'subject'
          WHERE r.run_id = ? ORDER BY h.value}, $run
    );
    my %got = map { $_->[0] => $_ } @$rows;
    is( scalar(@$rows),              5,          'every message replayed, across two jobs' );
    is( $got{'Quarterly report'}[1], 'accept',   'english mail accepted' );
    is( $got{'Ihre Bestellung'}[1],  'tempfail', 'german mail deferred' );
    like( $got{'Ihre Bestellung'}[2], qr/^450 4\.7\.1 /, '... with the configured reply' );

    ( undef, $rows ) = $corpus->query( 'SELECT label, config, recipes, finished IS NOT NULL, milter_log FROM runs WHERE id = ?', $run );
    my ( $label, $config, $recipes, $finished, $log ) = @{ $rows->[0] };
    is( $label,  'english',                              'labelled' );
    is( $config, "[Language]\naction=defer\nlangs=en\n", 'the recipe configuration is kept, without the service section' );
    like( $recipes, qr/^\{"Language":"[0-9a-f]{64}"\}\z/, 'with a hash of the recipe source' );
    ok( $finished, 'marked finished' );
    like( $log, qr/Loaded milter modules: Language/, 'with what the milter printed' );

    my ($de) = Milter::Corpus::Replay->new( corpus => $corpus, script => $yamilter, config => write_file( "$tmp/de.cfg", "[Language]\nlangs=de\naction=defer\n" ) )->run( folder => '.', timeout => 5 );
    ( undef, $rows ) = $corpus->query( 'SELECT COUNT(*) FROM results WHERE run_id = ?', $de );
    is( $rows->[0][0], 2, 'folder filter limits the replay' );

    my $broken = Milter::Corpus::Replay->new( corpus => $corpus, script => $yamilter, config => write_file( "$tmp/broken.cfg", "[Bogus]\naction=reject\n" ) );
    like( dies { $broken->run() }, qr/Milter exited before it was ready/, 'a milter which will not start dies' );
    ( undef, $rows ) = $corpus->query('SELECT COUNT(*) FROM runs WHERE finished IS NULL');
    is( $rows->[0][0], 0, '... and leaves no unfinished run behind' );

    like( dies { Milter::Corpus::Replay->new( corpus => $corpus, script => $yamilter, config => write_file( "$tmp/empty.cfg", "[Language]\n" ) )->run() }, qr/No recipes configured/, 'a recipe section with no keys is not a recipe' );
};

subtest 'each' => sub {

    # A copy of Language under another name, so there are two recipes to run without depending on other recipes working
    my $lib = "$tmp/lib/Milter/Recipe";
    make_path($lib);
    open( my $in, '<', "$fx->{run_dir}/lib/Milter/Recipe/Language.pm" ) or die $!;
    my $code = do { local $/; <$in> };
    $code =~ s/Milter::Recipe::Language/Milter::Recipe::Langtoo/g;
    write_file( "$lib/Langtoo.pm", $code );
    local @INC = ( "$tmp/lib", @INC );

    my $cfg  = write_file( "$tmp/each.cfg", "[Language]\nlangs=en\naction=defer\n[Langtoo]\nlangs=de\naction=reject\n" );
    my @runs = Milter::Corpus::Replay->new( corpus => $corpus, script => $yamilter, config => $cfg )->run( label => 'each', each => 1, folder => '.', timeout => 5 );
    is( scalar(@runs), 2, 'one run per recipe' );

    my ( undef, $rows ) = $corpus->query( 'SELECT DISTINCT batch FROM runs WHERE id IN (?, ?)', @runs );
    is( $rows, [ [ $runs[0] ] ], 'in one batch' );

    ( undef, $rows ) = $corpus->query( 'SELECT label, config FROM runs WHERE id IN (?, ?) ORDER BY id', @runs );
    is( $rows, [ [ 'each Langtoo', "[Langtoo]\naction=reject\nlangs=de\n" ], [ 'each Language', "[Language]\naction=defer\nlangs=en\n" ] ], 'labelled by recipe, each with only its own section' );

    my ( $cols, $summary ) = $corpus->report('summary');
    my ($blocked) = grep { $_->[0] eq 'batch' && $_->[2] eq 'blocked' } @$summary;
    is( $blocked->[3], 2, 'the batch blocks what either recipe blocked' );
};

done_testing();
