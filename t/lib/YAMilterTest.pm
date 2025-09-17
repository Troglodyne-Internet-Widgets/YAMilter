use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw{fork_and_term getsock getconfig writeconfig};

use File::Temp;
use Config::Simple;
use IO::Socket::UNIX;

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
        Local => $sockfile,
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
