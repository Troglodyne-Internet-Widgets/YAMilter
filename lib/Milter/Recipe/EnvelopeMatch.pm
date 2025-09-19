package Milter::Recipe::EnvelopeMatch;

use strict;
use warnings;

use parent qw{Milter::Recipe};

=head1 DESCRIPTION

It is necessary to ensure that the envelope sender and the From: header in emails match.
This is because people spamming from compromised boxes are rarely careful about using the -f flag from sendmail, which may or may not be implemented on the installed version.

It is also valuable to check that the To: header contains the envelope recipient, as it is common practice by spammers to set the To: header to 'undisclosed recipients'.

=head2 no_accum

Setting no_accum is not supported by this plugin at this time.

It should be possible to have full support for such, however.

=cut


our %cb = (
    envfrom => \&store_envelope,
    envrcpt => \&store_envelope,
    eoh     => \&check_header_vs_envelope,
);

my %envelope;

sub store_envelope_sender    { store_envelope('sender', @_ ) }
sub store_envelope_recipient { store_envelope('recipient', @_ ) }

sub store_envelope {
    my ($type, $ctx, $data, $dlen) = @_;
    # Email validation is basically crazy.
    my ($addr) = $data =~ m/<?(.+@[^>]+)>?/

    my $stash = $ctx->getpriv();
    $stash{$type} = $addr || '';
    $ctx->setpriv($stash);
}

sub check_header_vs_envelope {
    my ($ctx, $data, $dlen) = @_;

    my $stash = $ctx->gepriv();
    my $conf = __PACKAGE__->config();
    my $debug = $conf->{debug};

    # You can only have one from, but many to.
    my ($fromline) = $stash->{header} =~ m/^From:/mg;
    my ($toline)   = $stash->{header} =~ m/^To:/mg;

    if ( $fromline !~ m/\Q$stash{sender}\E/ ) ) {
        warn "Envelope sender does not match header From, rejecting" if $debug;
        $ctx->setreply((__PACKAGE__->config_code()), "Envelope sender does not match From in header");
        return __PACKAGE__->config_action();
    }

    if ( $toline !~ m/\Q$stash{recipient}\E/) {
        warn "Envelope recipient does not present within To:, rejecting" if $debug;
        $ctx->setreply((__PACKAGE__->config_code()), "Envelope recipient not present within To: in header");
        return __PACKAGE__->config_action();
    }
    return __PACKAGE__->cont();
}
