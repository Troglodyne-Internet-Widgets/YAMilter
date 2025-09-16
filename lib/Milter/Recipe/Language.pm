package Milter::Recipe::Language;

use strict;
use warnings;

use parent qw{Milter::Recipe};

use List::Util qw{any};
use Lingua::Identify qw(:language_identification);

our %cb = (
    body => \&body;
);

sub body {
    my $ctx = shift;
    my $body_chunk = shift;
    my $body_ref = $ctx->getpriv();
    ${$body_ref} .= $body_chunk;
    $ctx->setpriv($body_ref);

    # Reject languages our users do not understand
	# Also emits a logline we can fail2ban on
    if ( !any { langof($body_ref) } @allowed_langs ) {
        $ctx->setreply(550, '5.7.6', "Language used in mail body is incomprehensible to our users");
        return __CLASS__->config_action();
    }

    # Instructs Sendmail::Milter to do SMFIS_CONTINUE
    return undef;
}

1;
