package Milter::Recipe::Language;

#ABSTRACT: Milter which will reject mails written in languages your users don't understand

use 5.014;
use strict;
use warnings FATAL => 'all';
use re '/aa';

use parent qw{Milter::Recipe};

use Lingua::Identify qw(:language_identification);

=head1 DESCRIPTION

Reject mails which are not comprehensible to your userbase.

At the end of the message, the text the sender wrote is taken out of it:
the text parts are decoded (MIME, quoted-printable, base64, HTML), and quoted replies, signatures, URLs, addresses and anything with a digit in it
(hashes, IDs, dates, figures) are removed.
L<Lingua::Identify> then guesses its language, and the configured action is taken when a language your users do not read
is at least C<confidence> times as likely as all the ones they do put together.

Mail it cannot judge fairly is left alone:

=over 4

=item *

Automated mail (an Auto-Submitted header other than C<no>): cron reports, notifications and the like are mostly paths, numbers and log lines, which have no language to guess.

=item *

Mail with fewer than C<min_words> words of its own: there is too little to tell languages apart.

=back

=head1 CONFIGURATION

    [Language]
    langs=en, es
    action=tag
    min_words=50
    confidence=2

=over 4

=item C<langs>

The languages your users read, as the two letter codes L<Lingua::Identify> returns.  Required.

=item C<action>

What to do with mail in any other language.  See L<Milter::Recipe/Recipe configuration>.

=item C<min_words>

How many words of their own a message needs before its language is guessed, counted across all its text parts
(so plain and HTML versions of the same text count twice).  Defaults to 50.

=item C<confidence>

How many times likelier than all the configured languages together another language must be.  Defaults to 2.

=back

=head2 no_accum

This recipe reads the accumulated message, so with C<no_accum> set it does nothing.

=head1 CALLBACKS

=head2 envfrom($ctx)

Start a new transaction, forgetting any earlier message on this connection.

=head2 header($ctx, $name, $value)

Notes an Auto-Submitted header.

=head2 eom($ctx)

Guesses the language, as described above.

=cut

our %cb = (
    envfrom => \&envfrom,
    header  => \&header,
    eom     => \&eom,
);

sub envfrom {
    my ($ctx) = @_;
    __PACKAGE__->stash( $ctx, { automated => 0 } );
    return __PACKAGE__->cont();
}

sub header {
    my ( $ctx, $name, $value ) = @_;
    if ( lc($name) eq 'auto-submitted' && $value !~ m/\A\s*no\b/i ) {
        ( __PACKAGE__->stash($ctx) // __PACKAGE__->stash( $ctx, {} ) )->{automated} = 1;
    }
    return __PACKAGE__->cont();
}

sub eom {
    my ($ctx) = @_;
    my $conf = __PACKAGE__->config();
    die "Language milter requires the 'langs' param to be configured\n" unless defined $conf->{langs};
    return __PACKAGE__->cont() if $conf->{no_accum} || ( __PACKAGE__->stash($ctx) // {} )->{automated};

    my $priv = $ctx->getpriv();
    my $text = own_text( __PACKAGE__->message_texts( $priv->{header}, $priv->{body} ) );
    my ( $lang, $why ) = foreign_language(
        $text,
        langs      => [ __PACKAGE__->config_list( $conf->{langs} ) ],
        min_words  => $conf->{min_words}  // 50,
        confidence => $conf->{confidence} // 2,
    );
    warn "Language: $why" if $conf->{debug};
    return __PACKAGE__->cont() unless $lang;

    # Also emits a logline we can fail2ban on
    warn "Unrecognized language $lang detected, rejecting" if $conf->{debug};
    return __PACKAGE__->config_reply( $ctx, "Language used in mail body is incomprehensible to our users" );
}

=head1 FUNCTIONS

=head2 $text = own_text(@texts)

The text a sender wrote, given texts as from C<message_texts> in L<Milter::Recipe>:
every text part, HTML reduced to text; from each, and quoted lines, a signature, a reply's attribution and all below it, URLs, addresses and anything with a digit in it removed.

=cut

sub own_text {
    my @texts = @_;
    my @own;
    foreach my $part (@texts) {
        my ( $t, $html ) = @$part;
        if ($html) {
            $t =~ s/<(?:style|script)\b.*?<\/(?:style|script)\s*>//gis;
            $t =~ s/<[^>]*>/ /g;
            $t =~ s/&nbsp;/ /gi;
            $t =~ s/&amp;/&/gi;
        }
        $t =~ s/\r\n/\n/g;
        $t = join( "\n", grep { !m/\A\s*>/ } split( qr/\n/, $t ) );
        $t =~ s/\n--[ \t]*\n.*\z//s;
        $t =~ s/^On\b.{0,200}\bwrote:.*\z//ms;
        $t =~ s{\b(?:https?|ftp|mailto):\S+}{ }gi;
        $t =~ s/\S+\@\S+/ /g;

        # Hashes, keys, IDs, dates and figures are no language at all
        $t =~ s/\S*\d\S*/ /g;
        push @own, $t;
    }
    return join( "\n", @own );
}

=head2 word_count($text)

Roughly how many words C<$text> has, in any script: runs of two or more letters,
with each Han, Hiragana or Katakana character counted as a word of its own, as those scripts do not separate words with spaces.

=cut

sub word_count {
    my ($text) = @_;

    # Unicode properties, as /aa leaves [[:alpha:]] and \b knowing only ASCII
    my $ideographs = () = $text =~ m/[\p{Han}\p{Hiragana}\p{Katakana}]/g;
    my $words      = () = $text =~ m/(?<!\p{L})(?:(?![\p{Han}\p{Hiragana}\p{Katakana}])\p{L}){2,}(?!\p{L})/g;
    return $words + $ideographs;
}

=head2 ($language, $why) = foreign_language($text, langs => \@codes, min_words => $n, confidence => $x)

The language of C<$text> if it is not one of C<langs>, and confidently so; otherwise undef.
C<$why> says what was decided, for debugging.

=cut

sub foreign_language {
    my ( $text, %opt ) = @_;
    my $words = word_count($text);
    return ( undef, "only $words words, too few to judge" ) if $words < $opt{min_words};

    my @guesses = langof($text);
    return ( undef, 'no language found' ) unless @guesses;
    my %p       = @guesses;
    my %allowed = map { lc($_) => 1 } @{ $opt{langs} };
    my $best    = $guesses[0];
    return ( undef, "looks like $best, which is allowed" ) if $allowed{$best};

    my $ours = 0;
    $ours += $p{$_} // 0 for keys %allowed;
    return ( undef, "looks like $best, but not confidently enough" ) if $p{$best} < $opt{confidence} * $ours;
    return ( $best, "looks like $best" );
}

1;
