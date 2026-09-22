use 5.014;
use strict;
use warnings FATAL => 'all';
use re '/aa';

use FindBin::libs;
use Capture::Tiny qw{capture};
use File::Path    qw{make_path};
use File::Temp;
use Test2::V0;
use Test2::Plugin::NoWarnings;

use CorpusTest qw{write_file};

my $tmp = File::Temp->newdir();
ok( lives { require "$FindBin::Bin/../bin/yamilter-contacts" }, 'yamilter-contacts loads as a modulino without running' ) or diag($@);

sub cli {
    my @args = @_;
    my ( $out, $err, $exit ) = capture { YAMilter::Contacts::main(@args) };
    return ( $exit, $out, $err );
}

my $sent = "$tmp/Maildir/.Sent";
make_path( map { "$sent/$_" } qw{cur new tmp} );
write_file( "$sent/cur/1.test:2,S", "From: me\@ours.test\nTo: one\@first.test, two\@second.test\nMessage-ID: <sent1\@ours.test>\nSubject: hi\n\nhello\n" );

my ( $exit, $out, $err ) = cli('help');
is( $exit, 0, 'help exits 0' );
like( $out, qr/yamilter-contacts --contacts FILE seed/, '... and prints the usage' );

like( dies { cli('list') }, qr/--contacts is required/, 'the contacts file is required' );

( $exit, $out ) = cli( '--contacts', "$tmp/c.db", 'seed', $sent );
is( [ $exit, $out ], [ 0, "Read 1 messages; 2 contacts known.\n" ], 'seed' );

( $exit, $out ) = cli( '--contacts', "$tmp/c.db", 'list' );
is( [ map { ( split qr/\t/ )[0] } split qr/\n/, $out ], [qw{address one@first.test two@second.test}], 'list' );

( $exit, $out ) = cli( '--contacts', "$tmp/c.db", 'forget', 'one@first.test' );
is( $exit, 0, 'forget' );
like( dies { cli( '--contacts', "$tmp/c.db", 'forget', 'one@first.test' ) }, qr/is not a contact/, '... once' );

( $exit, $out, $err ) = cli( '--contacts', "$tmp/c.db", 'bogus' );
is( $exit, 2, 'unknown command exits 2' );

done_testing();

__END__

=head1 DESCRIPTION

The yamilter-contacts command line: seeding from a Maildir of sent mail, listing and forgetting contacts.

=cut
