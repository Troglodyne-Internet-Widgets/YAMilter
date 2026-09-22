package CorpusTest;

use 5.014;
use strict;
use warnings FATAL => 'all';
use re '/aa';

use Cwd;
use File::Copy qw{copy};
use File::Find;
use File::Path qw{make_path};
use File::Temp;
use FindBin;

use Milter::Corpus;

use Exporter 'import';
our @EXPORT_OK = qw{fixture_corpus write_file};

=head1 FUNCTIONS

=head2 fixture_corpus()

Copies t/corpus into a temporary directory (so tests can rename files in it) and opens an empty corpus database beside it.

Returns a hashref of C<corpus>, C<source> (the copy), C<tmp> (the directory, removed when this goes out of scope) and C<run_dir> (the checkout).

=cut

sub fixture_corpus {
    my $run_dir = Cwd::abs_path("$FindBin::Bin/..");
    my $tmp     = File::Temp->newdir();
    my $source  = "$tmp/mail";

    find(
        {
            no_chdir => 1,
            wanted   => sub {
                my $to = $source . substr( $File::Find::name, length("$run_dir/t/corpus") );
                -d $_ ? make_path($to) : copy( $_, $to ) || die "copy $_: $!";
            },
        },
        "$run_dir/t/corpus"
    );

    return {
        corpus  => Milter::Corpus->new( db => "$tmp/corpus.db" ),
        source  => $source,
        tmp     => $tmp,
        run_dir => $run_dir,
    };
}

sub write_file {
    my ( $file, $text ) = @_;
    open( my $fh, '>', $file ) or die "$file: $!";
    print $fh $text;
    close $fh;
    return $file;
}

1;
