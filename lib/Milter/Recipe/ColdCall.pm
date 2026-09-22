package Milter::Recipe::ColdCall;

#ABSTRACT: Milter to catch sales cold calls: mail from strangers which reads like a pitch

use 5.014;
use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Milter::Recipe};

use List::Util qw{any};
use Mail::Address;
use Milter::Contacts;

=head1 DESCRIPTION

Sales cold calls come from strangers, through the same mail systems everyone else uses, with nothing wrong with their headers.
What gives them away is the combination: nobody here has ever written to them, and they read like a pitch.

A message is a cold call when both:

=over 4

=item *

It is from a stranger: nobody here has written to its From address, or to anyone at its domain
(see L<Milter::Contacts> for what counts, and C<contacts> below for where that is kept).
The recipient's own domain only counts by exact address, so writing to a colleague does not vouch for everything claiming to be from your domain.

=item *

It has at least C<min_traits> of these traits:

=over 4

=item C<meeting request>

Asks for a call or meeting: "15 minutes", "quick call", a calendly link, "worth a chat", "open to a", "book a time" and the like.

=item C<opt out by reply>

Offers to stop if you reply: "reply with no", "not the right person?", "if this isn't relevant".

=item C<follow-up>

Chases a pitch you never answered: "following up", "circling back", "bumping this", "did you get a chance".

=item C<X-Priority>

Has an X-Priority header, which bulk sending tools add and people's mail programs rarely do.

=item C<reply to nothing we sent>

Has a Re: or Fwd: subject, but its In-Reply-To and References name nothing sent from here: a fake thread.

=item C<unsubscribe text without List-Unsubscribe>

Talks about unsubscribing or opting out, but has no List-Unsubscribe header.

=item C<greets you by name>

Opens with "Hi" (or hey, hello, dear) and the recipient's first name, as mail merges do.
The name is taken from the To header and the recipient's address, so nothing needs configuring.

=item C<names your organization>

Mentions the recipient's organization by name, taken from their address's domain, other than as part of an address or hostname.

=item C<P.S.>

Has a postscript, a staple of sales templates.

=back

A stranger who has a real reason to write will show some of these too, which is why C<tag> is the suggested action.

=back

Where the mail comes from is not a trait: cold calls are sent from the same big mail providers as everything else.

Mail with a List-Id header is left to L<Milter::Recipe::MailingList>.

Mail from users of this server (authenticated, so the MTA passes the C<{auth_authen}> macro) is not checked.
Instead its recipients and Message-ID are learned, so the people they write to are not strangers from then on.
For that, run yamilter on your submission port as well as port 25, with this recipe configured the same way.
Seed the contacts from existing sent mail with C<yamilter-contacts>.

=head1 CONFIGURATION

    [ColdCall]
    action=tag
    contacts=/var/lib/yamilter/contacts.db
    min_traits=1

=over 4

=item C<action>

C<tag> is the intended use: the message is delivered with an C<X-YAMilter: ColdCall: ...> header naming the traits, for sieve to file away.
See L<Milter::Recipe/Recipe configuration> for the others.

=item C<contacts>

The contacts file (see L<Milter::Contacts>).  Required.  The user yamilter runs as must be able to write to it and its directory.

=item C<min_traits>

How many traits make a cold call.  Defaults to 1.

=item C<shared_domains>

Domains where knowing one address says nothing about the next.  Defaults to the big free mail providers (see L<Milter::Contacts/shared_domains>).

=back

=head2 no_accum

The header traits work with C<no_accum> set.  The others need the accumulated body, so they are skipped.

=head1 CALLBACKS

=head2 envfrom($ctx, $sender)

Start a new transaction, noting whether the sender authenticated.

=head2 envrcpt($ctx, $recipient)

Keep the recipient, to learn if this is outbound.

=head2 header($ctx, $name, $value)

Keep the headers the checks need.

=head2 eoh($ctx)

Learn from outbound mail; for inbound, decide whether the sender is a stranger, and note the header traits.

=head2 eom($ctx)

Note the body traits, and take the configured action if there are enough.

=cut

our %cb = (
    envfrom => \&envfrom,
    envrcpt => \&envrcpt,
    header  => \&header,
    eoh     => \&eoh,
    eom     => \&eom,
);

my %KEPT = map { $_ => 1 } qw{from to subject in-reply-to references x-priority list-id list-unsubscribe message-id};

sub envfrom {
    my ($ctx) = @_;
    my $authenticated = eval { $ctx->getsymval('{auth_authen}') };
    _state( $ctx, { outbound => ( defined $authenticated && length $authenticated ) ? 1 : 0, recipients => [], headers => {}, traits => [] } );
    return __PACKAGE__->cont();
}

sub envrcpt {
    my ( $ctx, $recipient ) = @_;
    push @{ _state($ctx)->{recipients} }, $recipient;
    return __PACKAGE__->cont();
}

sub header {
    my ( $ctx, $name, $value ) = @_;
    my $lc = lc $name;
    return __PACKAGE__->cont() unless $KEPT{$lc};
    $value =~ s/\r?\n(?=[ \t])//g;
    _state($ctx)->{headers}{$lc} //= $value;
    return __PACKAGE__->cont();
}

sub eoh {
    my ($ctx)    = @_;
    my $state    = _state($ctx);
    my %h        = %{ $state->{headers} };
    my $contacts = _contacts();

    if ( $state->{outbound} ) {
        $contacts->learn( addresses => $state->{recipients}, message_ids => [ grep { defined } $h{'message-id'} ] );
        $state->{done} = 1;
        return __PACKAGE__->cont();
    }

    # List mail answers to the MailingList recipe; its replies reference list traffic rather than anything we sent
    my ($from) = Mail::Address->parse( $h{from} // '' );
    my @ours = map { m/\@([^<>\s]+?)>?\z/ ? $1 : () } @{ $state->{recipients} };
    if ( defined $h{'list-id'} || ( $from && $contacts->known( $from->address, @ours ) ) ) {
        $state->{done} = 1;
        return __PACKAGE__->cont();
    }

    push @{ $state->{traits} }, header_traits( \%h, $contacts );
    return __PACKAGE__->cont();
}

sub eom {
    my ($ctx) = @_;
    my $state = _state($ctx);
    return __PACKAGE__->cont() if $state->{done};

    my $conf   = __PACKAGE__->config();
    my @traits = @{ $state->{traits} };
    if ( !$conf->{no_accum} ) {
        my $priv = $ctx->getpriv();
        push @traits, body_traits( [ __PACKAGE__->message_texts( $priv->{header}, $priv->{body} ) ], defined $state->{headers}{'list-unsubscribe'}, recipient_names( $state->{headers}{to}, $state->{recipients} ) );
    }

    my $min = $conf->{min_traits} // 1;
    return __PACKAGE__->cont()                if @traits < $min;
    warn "Cold call from a stranger: @traits" if $conf->{debug};
    return __PACKAGE__->config_reply( $ctx, 'stranger; ' . join( ', ', @traits ) );
}

=head1 FUNCTIONS

=head2 @traits = header_traits(\%headers, $contacts)

The traits the headers show, given them as a hashref of lowercased names to values, and a L<Milter::Contacts>.

=cut

sub header_traits {
    my ( $h, $contacts ) = @_;
    my @traits;
    push @traits, 'X-Priority' if defined $h->{'x-priority'};

    if ( ( $h->{subject} // '' ) =~ m/\A\s*(?:re|fwd?|aw|sv)\s*:/i ) {
        my @refs = ( join( ' ', $h->{'in-reply-to'} // '', $h->{references} // '' ) =~ m/<([^<>\s]+)>/g );
        push @traits, 'reply to nothing we sent' unless any { $contacts->sent($_) } @refs;
    }
    return @traits;
}

=head2 %names = recipient_names($to_header, \@envelope_recipients)

What a sender who looked the recipient up would call them: C<first> names (the first word of the To display name,
and envelope recipients' mailbox names which are plain words and not roles like info@ or sales@),
and C<organization> names (the name part of the envelope recipients' domains, e.g. C<example> for C<example.com>).
Each is an arrayref, lowercased.

=cut

my %ROLE = map { $_ => 1 } qw{info sales admin support contact hello office team mail billing noreply postmaster abuse webmaster hostmaster root};

sub recipient_names {
    my ( $to, $recipients ) = @_;
    my ( %first, %organization );
    foreach my $address ( Mail::Address->parse( $to // '' ) ) {
        $first{ lc $1 } = 1 if ( $address->phrase // '' ) =~ m/\A\W*([A-Za-z]{2,})/;
    }
    foreach my $recipient ( @{ $recipients || [] } ) {
        my ( $local, $host ) = lc($recipient) =~ m/<?([^<>\s\@]+)\@([^<>\s]+?)>?\z/ or next;
        $first{$local} = 1 if $local =~ m/\A[a-z]{3,}\z/ && !$ROLE{$local};
        my ($name) = Milter::Contacts::domain("x\@$host") =~ m/\A([a-z0-9-]+)\./;
        $organization{$name} = 1 if defined $name && length($name) >= 4;
    }
    return ( first => [ sort keys %first ], organization => [ sort keys %organization ] );
}

=head2 @traits = body_traits(\@texts, $has_list_unsubscribe, [%names])

The traits the text of a message shows, given its texts as from C<message_texts> in L<Milter::Recipe>,
and what the recipient is called, as from C<recipient_names> above.

=cut

my %BODY_TRAIT = (
    'meeting request'  => qr/\b(?:(?:10|15|20|30)[- ]?min(?:ute)?s?\b|quick (?:call|chat)|calendly\.com|worth a (?:quick )?(?:chat|call|conversation)|open to (?:a|an)\b|hop on a call|book a (?:time|call|meeting)|schedule a (?:time|call))/i,
    'opt out by reply' => qr/(?:reply (?:with )?["']?(?:no|stop|remove|unsubscribe|not interested|1)\b|not (?:the right person|interested)\?|if (?:this|it) (?:isn'?t|is not) (?:relevant|a fit)|let me know if (?:you'?re|you are) not)/i,
    'follow-up'        => qr/\b(?:following up|circling back|bumping this|just checking in|floating this|last (?:email|note|attempt)|did you get a chance)\b/i,
);

sub body_traits {
    my ( $texts, $has_list_unsubscribe, %names ) = @_;
    my $text = join( "\n", map { $_->[1] ? _html_text( $_->[0] ) : $_->[0] } @$texts );

    my @traits = grep { $text =~ $BODY_TRAIT{$_} } sort keys %BODY_TRAIT;
    push @traits, 'unsubscribe text without List-Unsubscribe' if !$has_list_unsubscribe && $text =~ m/\b(?:unsubscribe|opt[\s-]?out)\b/i;
    push @traits, 'P.S.'                                      if $text                           =~ m/^\s*p\.?\s?s\.?\s*[:\-]?\s+\S/im;
    push @traits, 'greets you by name'                        if any { $text =~ m/^\W*(?:hi|hey|hello|dear|good (?:morning|afternoon))\s+\Q$_\E\b/im } @{ $names{first} || [] };

    # As a word of its own, not as part of an address, hostname or URL
    push @traits, 'names your organization' if any { $text =~ m/(?<![\@.\/\w-])\Q$_\E(?![\w-]|\.[a-z])/i } @{ $names{organization} || [] };
    return @traits;
}

sub _html_text {
    my ($html) = @_;
    $html =~ s/<(?:style|script)\b.*?<\/(?:style|script)\s*>//gis;
    $html =~ s/<[^>]*>/ /g;
    $html =~ s/&nbsp;/ /gi;
    $html =~ s/&amp;/&/gi;
    $html =~ s/&#39;|&rsquo;/'/gi;
    return $html;
}

# One per process, as Milter::Contacts reconnects after a fork
my $CONTACTS;

sub _contacts {
    my $conf = __PACKAGE__->config();
    die "The ColdCall recipe needs contacts configured\n" unless $conf->{contacts};
    $CONTACTS = undef if $CONTACTS && $CONTACTS->{file} ne $conf->{contacts};
    my @shared = __PACKAGE__->config_list( $conf->{shared_domains} );
    return $CONTACTS //= Milter::Contacts->new( file => $conf->{contacts}, ( @shared ? ( shared_domains => \@shared ) : () ) );
}

sub _state {
    my ( $ctx, $fresh ) = @_;
    return __PACKAGE__->stash( $ctx, $fresh ) // __PACKAGE__->stash( $ctx, { outbound => 0, recipients => [], headers => {}, traits => [] } );
}

1;
