package Milter::Recipe::Language;

use strict;
use warnings;

no warnings qw{experimental};
use feature qw{state};
use warnings;

use parent qw{Milter::Recipe};

use List::Util qw{any};
use Lingua::Identify qw(:language_identification);

our %cb = (
    body => \&body,
);

sub body {
    my ($ctx, $body_chunk, $body_length) = @_;

    state @allowed_langs;
    state $debug;
    if (!@allowed_langs) {
        my $conf = __PACKAGE__->config();
        die "Language milter requires the 'langs' param to be configured" unless defined $conf->{langs};
        $conf->{langs} = [$conf->{langs}] unless ref $conf->{langs} eq 'ARRAY';
        @allowed_langs = @{$conf->{langs}};
        $debug = $conf->{debug};
    }

    # Reject languages our users do not understand
	# Also emits a logline we can fail2ban on
    my $lang = langof($body_chunk);
    warn "Body language of $lang detected" if $debug;
    if ( !any { $lang eq $_ } @allowed_langs ) {
        warn "Unrecognized language $lang detected, rejecting" if $debug;
        $ctx->setreply((__PACKAGE__->config_code()), "Language used in mail body is incomprehensible to our users");
        return __PACKAGE__->config_action();
    }

    # Instructs Sendmail::Milter to do SMFIS_CONTINUE
    return __PACKAGE__->cont();
}

1;
