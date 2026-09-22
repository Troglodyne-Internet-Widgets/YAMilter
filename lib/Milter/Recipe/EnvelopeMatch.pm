package Milter::Recipe::EnvelopeMatch;

#ABSTRACT: Milter to ensure the envelope sender and From: header in email matches

use 5.014;
use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Milter::Recipe};

use List::Util qw{any};
use Mail::Address;

=head1 DESCRIPTION

It is necessary to ensure that the envelope sender and the From: header in emails match.
This is because people spamming from compromised boxes are rarely careful about using the -f flag from sendmail, which may or may not be implemented on the installed version.

It is also valuable to check that the To: header contains the envelope recipient, as it is common practice by spammers to set the To: header to 'undisclosed recipients'.

At the end of the header, the configured action is taken when either:

=over 4

=item *

No address in the From: header is the envelope sender.

=item *

No envelope recipient is an address in the To: or Cc: headers.
With several recipients, one is enough, since the others may have been Bcc'd.

=back

Addresses are compared whole and without regard to case.

Mail with a null envelope sender (C<< MAIL FROM:<> >>) is not checked, since that is how bounces and other delivery notifications are sent,
and their From: is whatever the reporting system calls itself.

Expect this to catch legitimate mail too: mailing lists and bulk mail services send with an envelope sender of their own for bounces,
and mailing list mail is addressed To: the list rather than to you.
Try it on your own mail with C<yamilter-corpus> before deploying it.

=head1 CONFIGURATION

    [EnvelopeMatch]
    action=reject

Only C<action> is used.  See L<Milter::Recipe/Recipe configuration>.

=head2 no_accum

This recipe keeps the addresses it needs as the headers arrive, so it works with C<no_accum> set.

=head1 CALLBACKS

Each keeps what it learns in the connection's private data, under this package's name.

=head2 envfrom($ctx, $sender, @esmtp_args)

Start a new transaction: keep the envelope sender, and forget everything about any earlier message on this connection.

=head2 envrcpt($ctx, $recipient, @esmtp_args)

Keep an envelope recipient.

=head2 header($ctx, $name, $value)

Keep the addresses in the From:, To: and Cc: headers.

=head2 eoh($ctx)

Compare the two, and take the configured action if they do not match as described above.

=cut

our %cb = (
    envfrom => \&envfrom,
    envrcpt => \&envrcpt,
    header  => \&header,
    eoh     => \&eoh,
);

sub envfrom {
    my ( $ctx, $sender ) = @_;
    _state( $ctx, { sender => _envelope_address($sender), recipients => [], from => [], to => [] } );
    return __PACKAGE__->cont();
}

sub envrcpt {
    my ( $ctx, $recipient ) = @_;
    push @{ _state($ctx)->{recipients} }, _envelope_address($recipient);
    return __PACKAGE__->cont();
}

my %KEPT = (
    from => 'from',
    to   => 'to',
    cc   => 'to',
);

sub header {
    my ( $ctx, $name, $value ) = @_;
    my $kept = $KEPT{ lc $name } or return __PACKAGE__->cont();
    push @{ _state($ctx)->{$kept} }, map { lc $_->address } Mail::Address->parse($value);
    return __PACKAGE__->cont();
}

sub eoh {
    my ($ctx) = @_;
    my $state = _state($ctx);
    my $debug = __PACKAGE__->config()->{debug};

    return __PACKAGE__->cont() if $state->{sender} eq '';

    if ( !any { $_ eq $state->{sender} } @{ $state->{from} } ) {
        warn "Envelope sender does not match header From, rejecting" if $debug;
        return __PACKAGE__->config_reply( $ctx, "Envelope sender does not match From in header" );
    }

    my %addressed = map { $_ => 1 } @{ $state->{to} };
    if ( !any { $addressed{$_} } @{ $state->{recipients} } ) {
        warn "Envelope recipient not present within To: or Cc:, rejecting" if $debug;
        return __PACKAGE__->config_reply( $ctx, "Envelope recipient not present within To: or Cc: in header" );
    }
    return __PACKAGE__->cont();
}

sub _state {
    my ( $ctx, $fresh ) = @_;
    return __PACKAGE__->stash( $ctx, $fresh ) // __PACKAGE__->stash( $ctx, { sender => '', recipients => [], from => [], to => [] } );
}

# MAIL FROM and RCPT TO arguments are <address>, or <> for the null sender
sub _envelope_address {
    my ($arg) = @_;
    $arg //= '';
    $arg =~ s/\A\s*<?|>?\s*\z//g;
    return lc $arg;
}

1;
