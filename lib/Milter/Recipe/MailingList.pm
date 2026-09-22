package Milter::Recipe::MailingList;

#ABSTRACT: Milter to reject mailing list and bulk mail which breaks the rules for it, and accept lists you trust

use 5.014;
use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Milter::Recipe};

use List::Util qw{any max min};
use Mail::Message;

=head1 DESCRIPTION

Spammers now frequently include a mailing list unsubscribe header, because google looks for it specifically,
and they are rarely careful about getting it right.
Real mailing list software is.

At the end of the header, in this order:

=over 4

=item 1.

A message from a list you trust (see C<allow>) is accepted outright, which ends milter processing for it:
no recipe after this one sees it.  Put this recipe first in C<service.order> for that to mean anything.

=item 2.

A message with a malformed list header is refused:
List-Help, List-Unsubscribe, List-Subscribe, List-Post, List-Owner or List-Archive not per RFC 2369,
List-Id not per RFC 2919,
or List-Unsubscribe-Post not per RFC 8058 (which also requires an https List-Unsubscribe).

=item 3.

A message with any list header, but without all of those named in C<require>, is refused.

=back

At the end of the message, one which has an unsubscribe link in its body but no List-Unsubscribe header is refused.
A link counts when its URL, its text, or the text just before it says unsubscribe or opt out.
The body is decoded (MIME parts, quoted-printable, base64) before it is looked at.

=head1 CONFIGURATION

    [service]
    order=MailingList, EnvelopeMatch

    [MailingList]
    action=reject
    require=List-Id, List-Unsubscribe
    allow=perl.org, some-group.googlegroups.com
    authserv_id=mx.example.com
    allow_spf=0

=over 4

=item C<action>

See L<Milter::Recipe/Recipe configuration>.

=item C<require>

List headers every piece of list mail must carry.  Empty by default, which turns that check off.

=item C<allow>

Lists you trust.  A List-Id matches an entry when it is the entry, or ends with a dot and the entry,
so C<perl.org> trusts every list at perl.org, and C<some-group.googlegroups.com> just that one group.

A List-Id is trivial to forge, so it is only trusted with proof:
an Authentication-Results header from your own MX (see C<authserv_id>) saying C<dkim=pass> for a signing domain (C<header.d>) the List-Id is, or is under.

=item C<authserv_id>

The authserv-id your MX writes into Authentication-Results headers, usually its hostname.  Required with C<allow>.
Headers from anyone else are ignored, as anyone can write one.

Your DKIM verifier (opendkim and the like) must run before yamilter, in C<smtpd_milters> for postfix, so that its Authentication-Results header is there to read.
It should also remove any Authentication-Results headers claiming to be from your authserv-id before adding its own.

=item C<allow_spf>

Also take an SPF pass for an envelope sender whose domain the List-Id is, or is under, as proof.
The pass is read from your MX's Authentication-Results (C<spf=pass> with C<smtp.mailfrom>),
or from the first Received-SPF header (RFC 7208), which is where SPF policy servers for postfix record it,
together with the MAIL FROM yamilter was given.

Received-SPF carries no authserv-id, so this trusts that your MX adds one to every message, above any a sender wrote.
Off by default: plenty of lists only DKIM sign some of their mail, but a list which cannot manage it at all is not one to go out of your way for.

=back

=head2 no_accum

The header checks work with C<no_accum> set.  The body check needs the accumulated message, so it is skipped.

=head1 CALLBACKS

Each keeps what it learns in the connection's private data, under this package's name.

=head2 envfrom($ctx, $sender)

Start a new transaction, forgetting any earlier message on this connection, and keep the envelope sender's domain.

=head2 header($ctx, $name, $value)

Keep list headers, Authentication-Results headers, and the first Received-SPF header.

=head2 eoh($ctx)

The header checks described above.

=head2 eom($ctx)

The body check described above.

=cut

our %cb = (
    envfrom => \&envfrom,
    header  => \&header,
    eoh     => \&eoh,
    eom     => \&eom,
);

my @RFC2369   = qw{List-Help List-Unsubscribe List-Subscribe List-Post List-Owner List-Archive};
my %CANONICAL = map { lc($_) => $_ } @RFC2369, qw{List-Id List-Unsubscribe-Post};

sub envfrom {
    my ( $ctx, $sender ) = @_;
    my ($domain) = ( $sender // '' ) =~ m/\@([^\s>]+)/;
    _state( $ctx, { lists => {}, auth => [], sender_domain => lc( $domain // '' ) } );
    return __PACKAGE__->cont();
}

sub header {
    my ( $ctx, $name, $value ) = @_;
    my $lc = lc $name;
    $value =~ s/\r?\n(?=[ \t])//g;
    if ( $CANONICAL{$lc} ) {
        push @{ _state($ctx)->{lists}{$lc} }, $value;
    }
    elsif ( $lc eq 'authentication-results' ) {
        push @{ _state($ctx)->{auth} }, $value;
    }
    elsif ( $lc eq 'received-spf' ) {
        _state($ctx)->{received_spf} //= $value;
    }
    return __PACKAGE__->cont();
}

sub eoh {
    my ($ctx) = @_;
    my $state = _state($ctx);
    my $conf  = __PACKAGE__->config();
    my %lists = %{ $state->{lists} };

    if ( _trusted( $conf, \%lists, $state ) ) {
        warn "Mail from a trusted list, accepting" if $conf->{debug};
        return __PACKAGE__->accept();
    }

    foreach my $lc ( sort keys %lists ) {
        foreach my $value ( @{ $lists{$lc} } ) {
            next                                               if valid_list_header( $CANONICAL{$lc}, $value );
            warn "Malformed $CANONICAL{$lc} header, rejecting" if $conf->{debug};
            return __PACKAGE__->config_reply( $ctx, "Malformed $CANONICAL{$lc} header (" . _rfc($lc) . ")" );
        }
    }

    if ( $lists{'list-unsubscribe-post'} && !any { m{<\s*https://}i } @{ $lists{'list-unsubscribe'} || [] } ) {
        warn "List-Unsubscribe-Post without an https List-Unsubscribe, rejecting" if $conf->{debug};
        return __PACKAGE__->config_reply( $ctx, "List-Unsubscribe-Post without an https List-Unsubscribe (RFC 8058)" );
    }

    if (%lists) {
        foreach my $required ( __PACKAGE__->config_list( $conf->{require} ) ) {
            next                                                   if $lists{ lc $required };
            warn "List mail without a $required header, rejecting" if $conf->{debug};
            return __PACKAGE__->config_reply( $ctx, "Mailing list mail without a $required header" );
        }
    }
    return __PACKAGE__->cont();
}

sub eom {
    my ($ctx) = @_;
    my $state = _state($ctx);
    my $conf  = __PACKAGE__->config();
    return __PACKAGE__->cont() if $state->{lists}{'list-unsubscribe'} || $conf->{no_accum};

    my $priv = $ctx->getpriv();
    return __PACKAGE__->cont() unless defined $priv->{body};
    if ( body_has_unsubscribe_link( $priv->{header} // '', $priv->{body} ) ) {
        warn "Unsubscribe link in the body without a List-Unsubscribe header, rejecting" if $conf->{debug};
        return __PACKAGE__->config_reply( $ctx, "Unsubscribe link in the body without a List-Unsubscribe header (RFC 2369)" );
    }
    return __PACKAGE__->cont();
}

sub _rfc {
    my ($lc) = @_;
    return 'RFC 2919' if $lc eq 'list-id';
    return 'RFC 8058' if $lc eq 'list-unsubscribe-post';
    return 'RFC 2369';
}

# Whether the List-Id is one we trust, and our own MX vouches for it
sub _trusted {
    my ( $conf, $lists, $state ) = @_;
    my @allow = map { lc } __PACKAGE__->config_list( $conf->{allow} );
    return 0 unless @allow && $lists->{'list-id'};

    my $list_id = list_id( $lists->{'list-id'}[0] ) // return 0;
    return 0 unless any { _within( $list_id, $_ ) } @allow;

    my %ours = map { lc($_) => 1 } __PACKAGE__->config_list( $conf->{authserv_id} );
    die "The MailingList recipe needs authserv_id configured to use allow\n" unless %ours;

    # The envelope sender is what yamilter was given, so it needs no vouching for, only its SPF result
    return 1 if $conf->{allow_spf} && ( $state->{received_spf} // '' ) =~ m/\A\s*pass\b/i && length $state->{sender_domain} && _within( $list_id, $state->{sender_domain} );

    foreach my $header ( @{ $state->{auth} } ) {
        my ( $servid, @results ) = authentication_results($header);
        next unless defined $servid && $ours{ lc $servid };
        foreach my $result (@results) {
            next unless $result->{result} eq 'pass';
            if ( $result->{method} eq 'dkim' ) {
                my $domain = $result->{props}{'header.d'} // ( $result->{props}{'header.i'} // '' ) =~ s/\A.*\@//r;
                return 1 if length $domain && _within( $list_id, $domain );
            }
            if ( $result->{method} eq 'spf' && $conf->{allow_spf} ) {
                my $domain = ( $result->{props}{'smtp.mailfrom'} // '' ) =~ s/\A.*\@//r;
                return 1 if length $domain && _within( $list_id, $domain );
            }
        }
    }
    return 0;
}

# Whether $name is $domain or under it
sub _within {
    my ( $name, $domain ) = map { lc } @_;
    return $name eq $domain || substr( $name, -( length($domain) + 1 ) ) eq ".$domain";
}

sub _state {
    my ( $ctx, $fresh ) = @_;
    return __PACKAGE__->stash( $ctx, $fresh ) // __PACKAGE__->stash( $ctx, { lists => {}, auth => [], sender_domain => '' } );
}

=head1 FUNCTIONS

=head2 valid_list_header($name, $value)

Whether an unfolded list header value is well formed for its name:
RFC 2369's comma separated list of angle bracketed URLs (or C<NO> for List-Post),
RFC 2919's List-Id, or RFC 8058's C<List-Unsubscribe=One-Click>.
Comments are ignored, and so is whitespace within the angle brackets, as RFC 2369 allows URLs to be folded.
Encoded words (RFC 2047) are not allowed in any of them, so they make a header malformed.

=cut

my $URL = qr/<[A-Za-z][A-Za-z0-9+.\-]*:[^<>\s]+>/;

sub valid_list_header {
    my ( $name, $value ) = @_;
    my $lc = lc $name;
    my $v  = _uncomment($value);
    $v =~ s/\A\s+|\s+\z//g;

    return defined list_id($value)            if $lc eq 'list-id';
    return $v eq 'List-Unsubscribe=One-Click' if $lc eq 'list-unsubscribe-post';
    return 0 unless $CANONICAL{$lc};
    return 1 if $lc eq 'list-post' && lc($v) eq 'no';

    # Whitespace inside the brackets is folding, and not part of the URL
    $v =~ s/<([^<>]*)>/ '<' . ( $1 =~ s{\s+}{}gr ) . '>' /ge;
    return $v =~ m/\A$URL(?:\s*,\s*$URL)*\z/ ? 1 : 0;
}

=head2 list_id($value)

The list identifier (label and namespace, e.g. C<perl5-porters.perl.org>) from an RFC 2919 List-Id header, lowercased,
or undef if the header is malformed.

=cut

my $ATEXT = qr{[A-Za-z0-9!#\$%&'*+/=?^_`{|}~\-]};

sub list_id {
    my ($value) = @_;
    my $v = _uncomment($value);

    # An optional phrase, which may hold encoded words, then the identifier in angle brackets
    my ($id) = $v =~ m/\A[^<>]*<($ATEXT+(?:\.$ATEXT+)+)>\s*\z/;
    return if !defined $id || length($id) > 255;
    return lc $id;
}

=head2 ($authserv_id, @results) = authentication_results($value)

Parse an RFC 8601 Authentication-Results header value.
Each result is a hashref of C<method> and C<result> (lowercased), and C<props>, a hashref of C<ptype.property> (lowercased) to value.
Returns nothing for a header with no authserv-id.

=cut

sub authentication_results {
    my ($value) = @_;
    my ( $servid, @resinfo ) = split( qr/;/, _uncomment($value) );
    ($servid) = ( $servid // '' ) =~ m/\A\s*(\S+)/ or return;

    my @results;
    foreach my $resinfo (@resinfo) {
        my ( $method, $result, $rest ) = $resinfo =~ m{\A\s*([A-Za-z0-9\-_]+)(?:/\d+)?\s*=\s*([A-Za-z0-9\-_]+)(.*)\z}s or next;
        my %props;
        while ( $rest =~ m/([A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+)\s*=\s*("[^"]*"|[^\s;]+)/g ) {
            my ( $prop, $pvalue ) = ( lc $1, $2 );
            $pvalue =~ s/\A"|"\z//g;
            $props{$prop} = $pvalue;
        }
        push @results, { method => lc $method, result => lc $result, props => \%props };
    }
    return ( $servid, @results );
}

=head2 body_has_unsubscribe_link($header, $body)

Whether any text part of a message (given as its header and body) has an unsubscribe link.  See C<unsubscribe_link> below.

=cut

sub body_has_unsubscribe_link {
    my ( $header, $body ) = @_;
    my $raw = "$header\n$body";
    $raw =~ s/\r\n/\n/g;

    my @texts;
    my $ok = eval {
        my $message = Mail::Message->read( \$raw, log => 'NONE', trace => 'NONE' );
        foreach my $part ( $message->parts('RECURSE') ) {
            next if $part->isMultipart;
            my $type = lc $part->contentType;
            next unless $type eq 'text/plain' || $type eq 'text/html';
            push @texts, [ $part->decoded->string, $type eq 'text/html' ];
        }
        1;
    };

    # Mail too broken to take apart is looked at as it came
    if ( !$ok || !@texts ) {
        my ($raw_body) = $raw =~ m/\n\n(.*)\z/s;
        @texts = ( [ $raw_body // '', ( $raw_body // '' ) =~ m/<a\b/i ] );
    }
    return any { unsubscribe_link(@$_) } @texts;
}

=head2 unsubscribe_link($text, $is_html)

Whether a decoded text has an unsubscribe link:
an http(s) or mailto link whose URL, anchor text, or the 100 or so characters before it say unsubscribe or opt out.

=cut

my $UNSUB_URL   = qr/unsub|opt-?out/i;
my $UNSUB_WORDS = qr/\b(?:unsubscribe|opt[\s-]?out)\b/i;

sub unsubscribe_link {
    my ( $text, $is_html ) = @_;
    my @links;
    if ($is_html) {
        while ( $text =~ m{<a\b[^>]*?\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>(.*?)</a\s*>}gis ) {
            my ( $href, $inner, $start ) = ( $1 // $2 // $3, $4, $-[0] );
            my $before = _html_text( substr( $text, max( 0, $start - 1000 ), min( 1000, $start ) ) );
            push @links, [ $href, substr( $before, -100 ) . ' ' . _html_text($inner) ];
        }
    }
    else {
        while ( $text =~ m{((?:https?://|mailto:)[^\s<>"]+)}gi ) {
            my ( $url, $start ) = ( $1, $-[0] );
            push @links, [ $url, substr( $text, max( 0, $start - 100 ), min( 100, $start ) ) ];
        }
    }
    return ( any { $_->[0] =~ $UNSUB_URL || $_->[1] =~ $UNSUB_WORDS } @links ) ? 1 : 0;
}

sub _html_text {
    my ($html) = @_;
    $html =~ s/<[^>]*>/ /g;
    $html =~ s/&nbsp;/ /gi;
    $html =~ s/&amp;/&/gi;
    $html =~ s/\s+/ /g;
    return $html;
}

# Remove RFC 5322 comments, innermost first so nested ones go too
sub _uncomment {
    my ($value) = @_;
    my $v = $value // '';
    1 while $v =~ s/\((?:[^()\\]|\\.)*\)/ /g;
    return $v;
}

1;
