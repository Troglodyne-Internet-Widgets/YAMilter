use strict;
use warnings;

use FindBin::libs;
use Test2::V0;
use Test2::Plugin::NoWarnings;

use Milter::Recipe;

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

done_testing();
