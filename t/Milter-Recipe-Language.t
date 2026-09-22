use 5.014;
use strict;
use warnings FATAL => 'all';
use re '/aa';

use FindBin;
use FindBin::libs;
use Cwd;
use Test2::V0;

use Milter::Client qw{:constants};
use YAMilterTest   qw{:all};

my $run_dir = Cwd::abs_path("$FindBin::Bin/..");
my $config  = getconfig("$run_dir/t/yamilter.cfg");
my @args    = ( "$run_dir/bin/yamilter", '--config', $config->param('service.f') );

my @cmds = gibs();

# Now to test the milters specifically

$config->param( 'Language.langs',  'en' );
$config->param( 'Language.action', 'defer' );
writeconfig();

my ( $result, $payload );
fork_and_term( sub { ( $result, $payload ) = Milter::Client::sendmail( getsock(), @cmds ) }, @args );
is( $result, SMFIR_ACCEPT, "Marked message as ACCEPT when in correct language" );

# The body command
my ($body) = grep { $_->[0] eq SMFIC_BODY } @cmds;
$body->[1] = "Ich bin ein Berliner";
fork_and_term( sub { ( $result, $payload ) = Milter::Client::sendmail( getsock(), @cmds ) }, @args );

# In the event you call setreply(), you will get SMFIR_REPLY as the return regardless of code requested.
is( $result, SMFIR_REPLYCODE, "Marked message as DEFER when NOT in correct language" );
like( $payload, qr/450 4\.7\.1 /, "Correct SMTP/ESMTP status codes returned" );

done_testing();

__END__

=head1 DESCRIPTION

The Language recipe accepts mail in a configured language, and defers the rest with the configured reply.

=cut
