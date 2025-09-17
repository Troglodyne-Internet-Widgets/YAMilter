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
        [SMFIC_HEADER,  "From: test\@test.test\nTo: test\@test.test\nSubject: Test\n\n"],
        [SMFIC_EOH,     ],
        [SMFIC_BODY,    "Testing 123"],
        [SMFIC_BODYEOB, ],
        [SMFIC_QUIT,    ],
    );

    # Returns whenever you either run out of commands or get a code other than SMFIS_CONTINUE or SMFIS_OPTNEG
    # You'll get some kind of SMFIR_* constant returned, usually SMFIR_REPLYCODE when it's a REJ/DEFER w/ SMTP & ESMTP response codes.
    my ($code, $payload) = Milter::Client::sendmail($sock, @gibbering);

=cut

use strict;
use warnings;

use Time::HiRes qw{usleep};
#use Sendmail::PMilter qw{:all};

use Exporter 'import';
our %EXPORT_TAGS = (
    constants => [qw{
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
    }],
);
our @EXPORT_OK = map { @$_ } values(%EXPORT_TAGS);

# Commands:
use constant SMFIC_ABORT    => 'A'; 
use constant SMFIC_BODY     => 'B'; 
use constant SMFIC_CONNECT  => 'C'; 
use constant SMFIC_MACRO    => 'D'; 
use constant SMFIC_BODYEOB  => 'E'; 
use constant SMFIC_HELO     => 'H'; 
use constant SMFIC_HEADER   => 'L'; 
use constant SMFIC_MAIL     => 'M'; 
use constant SMFIC_EOH      => 'N'; 
use constant SMFIC_OPTNEG   => 'O'; 
use constant SMFIC_RCPT     => 'R'; 
use constant SMFIC_QUIT     => 'Q'; 
use constant SMFIC_DATA     => 'T'; # v4 
use constant SMFIC_UNKNOWN  => 'U'; # v3 
# Responses:
use constant SMFIR_ADDRCPT  => '+'; 
use constant SMFIR_DELRCPT  => '-'; 
use constant SMFIR_ADDRCPT_PAR  => '2'; 
use constant SMFIR_ACCEPT   => 'a'; 
use constant SMFIR_REPLBODY => 'b';
use constant SMFIR_CONTINUE => 'c';
use constant SMFIR_DISCARD  => 'd';
use constant SMFIR_ADDHEADER    => 'h';
use constant SMFIR_INSHEADER    => 'i'; # v3, or v2 and Sendmail 8.13+
use constant SMFIR_SETSYMLIST   => 'l';
use constant SMFIR_CHGHEADER    => 'm';
use constant SMFIR_PROGRESS => 'p';
use constant SMFIR_QUARANTINE   => 'q';
use constant SMFIR_REJECT   => 'r';
use constant SMFIR_CHGFROM  => 'e'; # Sendmail 8.14+
use constant SMFIR_TEMPFAIL => 't';
use constant SMFIR_REPLYCODE    => 'y';
# Socktypes
use constant SMFIA_UNKNOWN  => 'U';
use constant SMFIA_UNIX     => 'L';
use constant SMFIA_INET     => '4';
use constant SMFIA_INET6    => '6';

# Pack templates for sending over messages
my %templates = (
    SMFIC_OPTNEG()  => "A N N N",
    SMFIC_CONNECT() => "A Z* A n Z*",
    SMFIC_HELO()    => "A Z*",
    SMFIC_MAIL()    => "A Z*",
    SMFIC_RCPT()    => "A Z*",
    SMFIC_DATA()    => "A",
    SMFIC_HEADER()  => "A Z*",
    SMFIC_EOH()     => "A",
    SMFIC_BODY()    => "A Z*",
    SMFIC_BODYEOB() => "A",
    SMFIC_QUIT()    => "A",
);

=head1 FUNCTIONS

=head2 ($code, $payload) = sendmail($socket, @commands)

Send commands to a milter & read the responses.

Terminates whenever you run out of commands or get something other than SMFIR_CONTINUE.

Dies in the event the socket hangs.

See Synopsis for more details.

=cut

# Bogus sendmail.
sub sendmail {
    my ($sock, @cmds) = @_;

    foreach my $args (@cmds) {
        my $action = $args->[0];
        my $tmpl   = "$templates{$action}";
        my $packed = pack($tmpl, @$args);
        # What we will actually send over the wire
        my $packed_with_length = pack('N a*', length($packed), $packed);
        syswrite $sock, $packed_with_length;
        my ($res, $payload) = _poll($sock);
        # Don't care about the return of the option negotiation process
        next if $res eq SMFIC_OPTNEG;
        warn $payload if $payload;
        return ($res,$payload) if $res ne SMFIR_CONTINUE; 
    }
    return (SMFIR_CONTINUE, undef);
}

sub _poll {
    my $sock = shift;
    my $buf = '';
    my $buf_actual = '';

    # If all else fails and we end up reading a dead pipe
    local $SIG{ALRM} = sub { die };

    for (1..1000) {
        # Don't let things get out of hand
        alarm 1;
        sysread($sock, $buf, 10000);
        alarm 0;

        $buf_actual .= $buf;
        my ($len, $code, $payload) = unpack("NAa*", $buf_actual);
        return ($code,$payload) if $code;

        # If there's nothing (meaningful) in the pipe, give up.
        last if length($buf_actual) >= 5;

        # Otherwise wait for output
        usleep 1000;
    }
    # Presume that if we got no response within timeout, we should continue
    return SMFIR_CONTINUE;
}

1;
