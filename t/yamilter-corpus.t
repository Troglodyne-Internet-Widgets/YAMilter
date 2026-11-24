use 5.014;
use strict;
use warnings FATAL => 'all';
use re '/aa';

use FindBin::libs;
use Capture::Tiny qw{capture};
use Test2::V0;
use Test2::Plugin::NoWarnings;

use CorpusTest qw{fixture_corpus write_file};

my $fx = fixture_corpus();
my $db = "$fx->{tmp}/cli.db";

# do, because the path is only known at run time
my $script = "$fx->{run_dir}/bin/yamilter-corpus";
ok( lives { do $script; die $@ if $@ }, "yamilter-corpus loads as a modulino without running" ) or diag($@);

sub cli {
    my @args = @_;
    my ( $out, $err, $exit ) = capture { YAMilter::Corpus::main(@args) };
    return ( $exit, $out, $err );
}

my ( $exit, $out, $err ) = cli('bogus');
is( $exit, 2, 'unknown command exits 2' );
like( $err . $out, qr/Unknown\ command\ 'bogus'/sx, '... and says why' );

( $exit, $out ) = cli('help');
is( $exit, 0, 'help exits 0' );
like( $out, qr/yamilter-corpus\ index/sx, '... and prints the usage' );

like( dies { cli( 'index', '--db', $db ) }, qr/--source\ is\ required/sx, 'index needs a source' );

( $exit, $out, $err ) = cli( 'index', '--db', $db, '--source', $fx->{source} );
is( $exit, 0, 'index exits 0' );
like( $out, qr/^5\ messages\ indexed\.$/msx,             'index reports the message count' );
like( $err, qr/6\ files,\ 6\ read,\ 5\ new\ messages/sx, '... and its progress' );

like( dies { cli( 'report', '--db', $db ) }, qr/No\ runs\ to\ report\ on/sx, 'report before any run dies' );

my $cfg = write_file( "$fx->{tmp}/lang.cfg", "[Language]\nlangs=en\naction=defer\n" );
( $exit, $out ) = cli( 'run', '--db', $db, '--config', $cfg, '--yamilter', "$fx->{run_dir}/bin/yamilter", '--timeout', 5 );
is( $exit, 0, 'run exits 0' );
like( $out, qr/^Recorded\ run\(s\):\ 1$/msx, 'run names the run it recorded' );

( $exit, $out ) = cli( qw{report --db}, $db, qw{list --verdict blocked --tsv} );
is( $exit, 0, 'report exits 0' );
my @tsv_rows = grep { $_ ne q{} } split qr/\n/sx, $out;
is( [ map { ( split qr/\t/sx, $_ )[3] } @tsv_rows ], [ 'subject', 'Ihre Bestellung' ], 'tsv output, header row first' );

( $exit, $out ) = cli( qw{report --db}, $db, 'summary' );
is( index( $out, "Batch 1: run 1 (Language)\nNo ignore rules; of the 5 others, 4 accepted, 1 blocked, 0 errors\n\n" ), 0, 'reports say what they are about' );

( $exit, $out ) = cli( qw{ignore --db}, $db, qw{--folder Trash} );
like( $out, qr/^1\s+Trash\s+2\s*$/msx, 'ignore adds a rule and lists them' );
( $exit, $out ) = cli( qw{report --db}, $db, 'summary' );
ok( index( $out, '2 messages left out by 1 ignore rule; of the 3 others' ) >= 0, '... which the reports then leave out' );
( $exit, $out ) = cli( qw{ignore --db}, $db, qw{--remove 1} );
unlike( $out, qr/Trash/sx, 'ignore --remove takes it away' );
like( dies { cli( qw{ignore --db}, $db, qw{--remove 1} ) }, qr/No\ ignore\ rule\ 1/sx, '... once' );

( $exit, $out ) = cli( 'show', '--db', $db, 1 );
like( $out, qr/^Subject:\ /msx, 'show prints the message' );

my $to = "$fx->{tmp}/exported";
( $exit, $out ) = cli( 'export', '--db', $db, '--to', $to );
like( $out, qr/^Exported\ 4\ messages/msx, 'export copies the accepted mail' );
my @files = glob("'$to/cur/*'");
is( scalar(@files), 4, '... into cur/' );

done_testing();

1;

__END__

=head1 DESCRIPTION

The yamilter-corpus command line: each command against the fixture mail in F<t/corpus>, and its errors.

=cut
