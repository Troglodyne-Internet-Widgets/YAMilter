package Milter::Recipe::Language;

#ABSTRACT: Milter which will reject mails written in languages your users don't understand

use 5.014;
use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Milter::Recipe};

use List::Util       qw{any};
use Lingua::Identify qw(:language_identification);

=head1 DESCRIPTION

Reject mails which are not comprehensible to your userbase.

Uses L<Lingua::Identify> to guess the language of each chunk of a message body as it arrives,
and takes the configured action on the first chunk which is not in one of the configured languages.

It works on each chunk rather than the accumulated body, so it works with C<no_accum> set.

=head1 CONFIGURATION

    [Language]
    langs=en, es
    action=defer

=over 4

=item C<langs>

The languages your users read, as the two letter codes L<Lingua::Identify> returns.  Required.

=item C<action>

What to do with mail in any other language.  See L<Milter::Recipe/Recipe configuration>.

=back

=cut

our %cb = (
    body => \&body,
);

sub body {
    my ( $ctx, $body_chunk ) = @_;

    state @allowed_langs;
    state $debug;
    if ( !@allowed_langs ) {
        my $conf = __PACKAGE__->config();
        die "Language milter requires the 'langs' param to be configured" unless defined $conf->{langs};
        $conf->{langs} = [ $conf->{langs} ] unless ref $conf->{langs} eq 'ARRAY';
        @allowed_langs = @{ $conf->{langs} };
        $debug         = $conf->{debug};
    }

    # Reject languages our users do not understand
    # Also emits a logline we can fail2ban on
    my $lang = langof($body_chunk);
    warn "Body language of $lang detected" if $debug;
    if ( !any { $lang eq $_ } @allowed_langs ) {
        warn "Unrecognized language $lang detected, rejecting" if $debug;
        $ctx->setreply( ( __PACKAGE__->config_code() ), "Language used in mail body is incomprehensible to our users" );
        return __PACKAGE__->config_action();
    }

    # Instructs Sendmail::Milter to do SMFIS_CONTINUE
    return __PACKAGE__->cont();
}

1;
