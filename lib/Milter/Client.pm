package Milter::Client;

# ABSTRACT: Send commands to milters and get responses

=head1 WHY

It occurred to me the lack of public development for innovative milters may have something to do with the difficulty of testing them.

There are no milter client modules which are not themselves an MTA I am aware of.
As you might imagine, that complicates the sort of automated testing you might want to do to distribute modular milters.

=head1 SYNOPSIS

    # You'll need the constants, which are the same as in the sendmail headers
    use Milter::Client qw{:constants};

    my $sockfile = '/var/run/feet.sock';
    my $s = IO::Socket::UNIX->new(
        Type => SOCK_STREAM(),
        Peer => $sockfile,
    ) || die "Couldn't connect to $sockfile: $@";

    # Build a "Conversation" with a milter.
    # This is an example of a pretty maximal exchange, mirroring a standard SMTP dialog.
    our @gibbering = (
        # Version, Commands, Capabilities.  Below is a reasonably modern set.  You can omit this entirely.
        [SMFIC_OPTNEG,  6, hex(0x1F), hex(0x1FFFFF)],
        # You'll want to use the proper sock type based on how you are talking to the milter
        # If you aren't using a unix socket, the last argument needs to be an IP address
        [SMFIC_CONNECT, 'test.test', SMFIA_UNIX, 0, $sockfile],
        # Everything from here is pretty self-explanatory based on its SMTP equivalents.
        [SMFIC_HELO,    'test.test'],
        [SMFIC_MAIL,    '<test@test.test>'], # Envelope Sender
        [SMFIC_RCPT,    '<test@test.test>'], # Envelope Recipient
        [SMFIC_DATA,    ],
        # One command per header: name, then value.
        [SMFIC_HEADER,  'From',    'test@test.test'],
        [SMFIC_HEADER,  'To',      'test@test.test'],
        [SMFIC_HEADER,  'Subject', 'Test'],
        [SMFIC_EOH,     ],
        # Bodies over 64k need to be sent in chunks, see body_chunks()
        [SMFIC_BODY,    "Testing 123"],
        [SMFIC_BODYEOB, ],
        [SMFIC_QUIT,    ],
    );

    # Returns whenever you either run out of commands or get a code other than SMFIS_CONTINUE or SMFIS_OPTNEG
    # You'll get some kind of SMFIR_* constant returned, usually SMFIR_REPLYCODE when it's a REJ/DEFER w/ SMTP & ESMTP response codes.
    my ($code, $payload) = Milter::Client::sendmail($sock, @gibbering);

    # Pass options as a hashref before the commands to find out when the milter hangs or dies,
    # rather than presuming it wanted you to continue.
    my ($code, $payload) = Milter::Client::sendmail($sock, { timeout => 5 }, @gibbering);
    warn "Milter hung"  if $code eq CLIENT_TIMEOUT;
    warn "Milter died"  if $code eq CLIENT_EOF;

=cut

use strict;
use warnings;

use Time::HiRes ();

#use Sendmail::PMilter qw{:all};

use Exporter 'import';
our %EXPORT_TAGS = (
    constants => [
        qw{
          SMFIC_ABORT
          SMFIC_BODY
          SMFIC_CONNECT
          SMFIC_MACRO
          SMFIC_BODYEOB
          SMFIC_HELO
          SMFIC_HEADER
          SMFIC_MAIL
          SMFIC_EOH
          SMFIC_OPTNEG
          SMFIC_RCPT
          SMFIC_QUIT
          SMFIC_DATA
          SMFIC_UNKNOWN
          SMFIR_ADDRCPT
          SMFIR_DELRCPT
          SMFIR_ADDRCPT_PAR
          SMFIR_ACCEPT
          SMFIR_REPLBODY
          SMFIR_CONTINUE
          SMFIR_DISCARD
          SMFIR_ADDHEADER
          SMFIR_INSHEADER
          SMFIR_SETSYMLIST
          SMFIR_CHGHEADER
          SMFIR_PROGRESS
          SMFIR_QUARANTINE
          SMFIR_REJECT
          SMFIR_CHGFROM
          SMFIR_TEMPFAIL
          SMFIR_REPLYCODE
          SMFIA_UNKNOWN
          SMFIA_UNIX
          SMFIA_INET
          SMFIA_INET6
          CLIENT_TIMEOUT
          CLIENT_EOF
          MILTER_CHUNK_SIZE
        }
    ],
);
our @EXPORT_OK = map { @$_ } values(%EXPORT_TAGS);

# Commands:
use constant SMFIC_ABORT   => 'A';
use constant SMFIC_BODY    => 'B';
use constant SMFIC_CONNECT => 'C';
use constant SMFIC_MACRO   => 'D';
use constant SMFIC_BODYEOB => 'E';
use constant SMFIC_HELO    => 'H';
use constant SMFIC_HEADER  => 'L';
use constant SMFIC_MAIL    => 'M';
use constant SMFIC_EOH     => 'N';
use constant SMFIC_OPTNEG  => 'O';
use constant SMFIC_RCPT    => 'R';
use constant SMFIC_QUIT    => 'Q';
use constant SMFIC_DATA    => 'T';    # v4
use constant SMFIC_UNKNOWN => 'U';    # v3

# Responses:
use constant SMFIR_ADDRCPT     => '+';
use constant SMFIR_DELRCPT     => '-';
use constant SMFIR_ADDRCPT_PAR => '2';
use constant SMFIR_ACCEPT      => 'a';
use constant SMFIR_REPLBODY    => 'b';
use constant SMFIR_CONTINUE    => 'c';
use constant SMFIR_DISCARD     => 'd';
use constant SMFIR_ADDHEADER   => 'h';
use constant SMFIR_INSHEADER   => 'i';    # v3, or v2 and Sendmail 8.13+
use constant SMFIR_SETSYMLIST  => 'l';
use constant SMFIR_CHGHEADER   => 'm';
use constant SMFIR_PROGRESS    => 'p';
use constant SMFIR_QUARANTINE  => 'q';
use constant SMFIR_REJECT      => 'r';
use constant SMFIR_CHGFROM     => 'e';    # Sendmail 8.14+
use constant SMFIR_TEMPFAIL    => 't';
use constant SMFIR_REPLYCODE   => 'y';

# Socktypes
use constant SMFIA_UNKNOWN => 'U';
use constant SMFIA_UNIX    => 'L';
use constant SMFIA_INET    => '4';
use constant SMFIA_INET6   => '6';

# Not part of the milter protocol.  Returned by sendmail() when asked to report on a hung or dead milter.
use constant CLIENT_TIMEOUT => 'timeout';
use constant CLIENT_EOF     => 'eof';

# Largest body chunk a milter will accept unless it negotiates otherwise (MILTER_CHUNK_SIZE in libmilter)
use constant MILTER_CHUNK_SIZE => 65535;

# Pack templates for sending over messages
my %templates = (
    SMFIC_OPTNEG()  => "A N N N",
    SMFIC_CONNECT() => "A Z* A n Z*",
    SMFIC_HELO()    => "A Z*",
    SMFIC_MAIL()    => "A Z*",
    SMFIC_RCPT()    => "A Z*",
    SMFIC_DATA()    => "A",
    SMFIC_HEADER()  => "A Z* Z*",
    SMFIC_EOH()     => "A",
    SMFIC_BODY()    => "A a*",
    SMFIC_BODYEOB() => "A",
    SMFIC_QUIT()    => "A",
);

=head1 FUNCTIONS

=head2 ($code, $payload, $modifications) = sendmail($socket, [\%options], @commands)

Send commands to a milter & read the responses.

Terminates whenever you run out of commands or get something other than SMFIR_CONTINUE.

Requests to modify the message (add a header, change the body, quarantine it and so forth) are not a final reply.
They are returned in C<$modifications>, an arrayref of C<[ $code, $payload ]>.

Headers are sent one per command, as C<[SMFIC_HEADER, $name, $value]>.
The older form of C<[SMFIC_HEADER, $all_the_headers]> still works, but the milter will see it as one header with an empty value.

No reply is waited for after SMFIC_QUIT, as milters do not send one.

Without options, a milter which says nothing within a second is presumed to want you to continue.
Pass a hashref of options before the commands to change that:

=over 4

=item C<timeout>

Seconds (fractions allowed) to wait for each reply.
When given, a milter which does not reply in time returns C<CLIENT_TIMEOUT>, and one which hangs up returns C<CLIENT_EOF>.

=back

See Synopsis for more details.

=cut

my %MODIFICATIONS = map { $_ => 1 } ( SMFIR_ADDRCPT, SMFIR_DELRCPT, SMFIR_ADDRCPT_PAR, SMFIR_REPLBODY, SMFIR_ADDHEADER, SMFIR_INSHEADER, SMFIR_CHGHEADER, SMFIR_CHGFROM, SMFIR_QUARANTINE, SMFIR_PROGRESS );

# Bogus sendmail.
sub sendmail {
    my ( $sock, @cmds ) = @_;
    my %opts = ref $cmds[0] eq 'HASH' ? %{ shift @cmds } : ();
    my @mods;

    # A milter which hangs up is reported (or presumed to continue), not fatal
    local $SIG{PIPE} = 'IGNORE';

    foreach my $args (@cmds) {
        my $action = $args->[0];

        # The single string form of SMFIC_HEADER needs the value terminator added
        my @args   = ( $action eq SMFIC_HEADER && @$args == 2 ) ? ( @$args, '' ) : @$args;
        my $packed = pack( $templates{$action}, @args );

        # What we will actually send over the wire
        my $packed_with_length = pack( 'N a*', length($packed), $packed );
        my $sent = syswrite $sock, $packed_with_length;
        next if $action eq SMFIC_QUIT;

        my ( $res, $payload ) = $sent ? _poll( $sock, $opts{timeout} ) : (CLIENT_EOF);

        # A milter may send any number of modifications (and progress reports) before its final reply, each a packet of its own
        while ( $MODIFICATIONS{$res} ) {
            push @mods, [ $res, $payload ] unless $res eq SMFIR_PROGRESS;
            ( $res, $payload ) = _poll( $sock, $opts{timeout} );
        }

        if ( $res eq CLIENT_TIMEOUT || $res eq CLIENT_EOF ) {
            return ( $res, undef, \@mods ) if defined $opts{timeout};
            next;
        }

        # Don't care about the return of the option negotiation process
        next                              if $res eq SMFIC_OPTNEG;
        return ( $res, $payload, \@mods ) if $res ne SMFIR_CONTINUE;
    }
    return ( SMFIR_CONTINUE, undef, \@mods );
}

=head2 @commands = body_chunks($body)

Split a message body into SMFIC_BODY commands no bigger than MILTER_CHUNK_SIZE, as an MTA would.

An empty body yields no commands.

=cut

sub body_chunks {
    my ($body) = @_;
    my @chunks;
    for ( my $pos = 0; $pos < length($body); $pos += MILTER_CHUNK_SIZE ) {
        push @chunks, [ SMFIC_BODY, substr( $body, $pos, MILTER_CHUNK_SIZE ) ];
    }
    return @chunks;
}

# Read one reply packet: 4 byte length, then that many bytes of code & payload.
sub _poll {
    my ( $sock, $timeout ) = @_;
    $timeout ||= 1;

    my $packet;
    local $@;
    my $ok = eval {
        local $SIG{ALRM} = sub { die CLIENT_TIMEOUT . "\n" };
        Time::HiRes::alarm($timeout);
        my $len = unpack( 'N', _read_exactly( $sock, 4 ) );
        $packet = _read_exactly( $sock, $len );
        Time::HiRes::alarm(0);
        1;
    };
    Time::HiRes::alarm(0);
    if ( !$ok ) {
        my $err = $@;
        chomp $err;
        return CLIENT_TIMEOUT if $err eq CLIENT_TIMEOUT;
        return CLIENT_EOF;
    }

    my ( $code, $payload ) = unpack( 'a a*', $packet );
    $payload =~ s/\0\z// if defined $payload;
    return ( $code, $payload );
}

sub _read_exactly {
    my ( $sock, $want ) = @_;
    my $buf = '';
    while ( length($buf) < $want ) {
        my $got = sysread( $sock, $buf, $want - length($buf), length($buf) );
        die CLIENT_EOF . "\n" unless $got;
    }
    return $buf;
}

1;
