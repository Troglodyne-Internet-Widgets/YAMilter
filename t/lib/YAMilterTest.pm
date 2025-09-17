use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw{fork_and_term getsock getconfig writeconfig SMFIR_ACCEPT SMFIR_CONTINUE SMFIR_DISCARD SMFIR_REJECT};

use Time::HiRes qw{usleep};
use Sendmail::PMilter qw{:all};
use File::Temp;
use Config::Simple;
use IO::Socket::UNIX;

#XXX had to steal these from the Context module because they aren't exported.
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

use constant SMFIA_UNIX => 'L';

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

# Mock up a session for us to use.
# Unfortunately for us we can't just use SMTP commands and instead have to freebase C structs
our @gibbering = (
    [SMFIC_OPTNEG,  6, hex(0x1F), hex(0x1FFFFF)],
    [SMFIC_CONNECT, 'test.test', SMFIA_UNIX, 0, getconfig()->param('service.sock')],
    [SMFIC_HELO,    'test.test'],
    [SMFIC_MAIL,    '<test@test.test>'],
    [SMFIC_RCPT,    '<test@test.test>'],
    [SMFIC_DATA,    ],
    [SMFIC_HEADER,  "From: test\@test.test\nTo: test\@test.test\nSubject: Test\n\n"],
    [SMFIC_EOH,     ],
    [SMFIC_BODY,    "Testing 123"],
    [SMFIC_BODYEOB, ],
    [SMFIC_QUIT,    ],
);

sub gibs {
    return @gibbering;
}

# Bogus sendmail.
sub sendmail {
    my (@cmds) = @_;

    my $sock = getsock();
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


my $c_actual;
sub getconfig {
    return $c_actual if $c_actual;

    my $cfg_file = File::Temp::tmpnam();
    my $sock     = File::Temp::tmpnam();
    my $pid      = File::Temp::tmpnam();

    my $ncf = Config::Simple->new( syntax => 'ini' );
    $ncf->param('service.sock',    $sock);
    $ncf->param('service.pidfile', $pid);
    $ncf->param('service.workers', 1);
    $ncf->param('service.f',       $cfg_file );
    $ncf->param('service.debug', 1);

    $ncf->write($cfg_file);

    $c_actual = $ncf;
    return $ncf;
}

sub writeconfig {
    my $c = getconfig();
    $c->write($c->param('service.f'));
}

sub getsock {
    my $sockfile = getconfig()->param('service.sock');

    return IO::Socket::UNIX->new(
        Type => SOCK_STREAM(),
        Peer => $sockfile,
    ) || die "Couldn't connect to $sockfile: $@";
}

sub fork_and_term {
    my ($callback, @args) = @_;
    open(my $output, '+<', undef);
    $output->autoflush(1);
    select $output;
    my $pid = fork();
    die "Could not fork" unless defined $pid;
    if (!$pid) {
        $output->autoflush(1);
        select $output;
        my $script = shift @args;
        print "Running $script\n";
        local @ARGV = @args;
        do $script;
        exit YAMilter::main(@args);
    }
    select STDOUT;
    sleep 1;
    if ($callback) {
        local $@;
        eval { $callback->() } or do {
            print "$@\n";
        }
    }
    kill 'TERM', $pid;
    my $exited = 0;
    foreach (1..10) {
        my $res = waitpid($pid, 1);
        if ($res !=0) {
            $exited=1;
            last;
        }
        sleep 1;
    }
    if (!$exited) {
        kill('KILL', $pid);
        waitpid($pid, 0);
    }
    seek($output, 0, 0);
    my $o = join("\n", (readline $output));
    close $output;
    return $o;
}


1;
