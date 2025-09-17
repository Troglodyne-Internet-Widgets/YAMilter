package Milter::Recipe;

# ABSTRACT: Framework for building a milter based on various recipes

use strict;
use warnings;

no warnings qw{experimental};
use feature qw{state};
use warnings;

use Config::Simple;
use Sendmail::PMilter qw{:all};

=head1 CONFIGURATION

See the L<yamilter> documentation for config file format.

=cut

=head1 CONSTRUCTOR

=head2 new($cfile)

Creates the Milter recipe singleton.  Subsequent calls simply return the same object.

=cut

my $DEBUG=0;

# This here is what you call a 'singleton'
my $singleton;
sub new {
    my ($class, $cfile) = @_;

    return $singleton if $singleton;

    die "No such configuration file $cfile!" unless -f $cfile;

    my $config = Config::Simple->new($cfile);

    #XXX passing no block to get_block returns the list of blocks, but this is undocumented.
    my @blocks = grep { $_ ne 'service' } ($config->get_block());

    my %obj = (
        pidfile => $config->param('service.pidfile') // "/var/run/yamilter.pid",
        sock    => $config->param('service.sock')    // "/var/run/yamilter.sock",
        workers => $config->param('service.workers') // 10,
        cfile   => $cfile,
        debug   => $config->param('service.debug') // 0,
    );
    $DEBUG = $obj{debug};
    foreach my $recipe (@blocks) {
        next if $recipe eq 'service';
        require "Milter/Recipe/$recipe.pm" or do {
            die "Could not find milter recipe $recipe!";
        };
        $obj{$recipe} = $config->get_block($recipe);
    }

    $singleton = bless(\%obj, $class);
    return $singleton;
}

sub pidfile { $_[0]->{pidfile} }
sub sock    { $_[0]->{sock}    }
sub workers { $_[0]->{workers} }
sub cfile   { $_[0]->{cfile}   }
sub debug   { $_[0]->{debug}   }

=head1 STATIC METHODS

=head2 $class->config()

Retrieve the config section relevant to the current class.

If your Recipe requires configuration, this is the method to call.

=cut

sub config {
    my $class = shift;

    state $section;
    return $section if $section;

    my ($recipe) = $class =~ m/::(\w+)$/;
    my $self = $class->new();
    $section = $self->{$recipe};
    $section->{debug} = $self->debug();
    return $section;
}

my %action = (
    reject   => SMFIS_REJECT,
    discard  => SMFIS_DISCARD,
    tempfail => SMFIS_TEMPFAIL,
    defer    => SMFIS_TEMPFAIL,
    accept   => SMFIS_ACCEPT,
    continue => SMFIS_CONTINUE,
    loop     => SMFIS_MSG_LOOP,
);

=head2 $class->config_action()

Every recipe MUST support returning an action to take after doing its' test.

Acceptable actions are (reject, discard, tempfail, accept, continue, loop).

This is the sub to call to accomplish that:

    ...
    return __PACKAGE__->config_action(); 
    ...

=cut

sub config_action {
    my $class = shift;
    my $conf = $class->config();
    warn "Taking configured action of $conf->{action} ($action{$conf->{action}})" if $conf->{debug};
    return $action{$conf->{action}} if $conf->{action};
    return $action{reject};
}

=head2 ($smtp_code, $esmtp_code) = $class->config_code()

Sometimes you will want a callback to do $ctx->setreply() to have a complicated response.

This will map the config action to the appropriate response code to use as the first arg to setreply().

Dies in the event your action has no appropriate code (e.g. discard, loop).

=cut

my %action2code = (
    SMFIS_REJECT()   => [550, '5.7.1'],
    SMFIS_TEMPFAIL() => [450, '4.7.1'],
    SMFIS_ACCEPT()   => [250, '2.0.0'],
    SMFIS_CONTINUE() => [354, '3.0.0'],
);

sub config_code {
    my $class  = shift;
    my $action = $class->config_action();
    warn "Action: $action";
    my $code   = $action2code{$action};
    die "No appropriate code available for the configured action" unless $code;
    return @$code
}

=head1 METHODS

=head2 run

Actually run the milter.

=cut

sub run {
    my $self = shift;

	print "YAMilter starting up...\n";
    print "YAMilter using config file ".$self->cfile()."\n";

	unlink $self->pidfile()   if -e $self->pidfile();
	unlink $self->sock() 	  if -e $self->sock();

	print { open(my $fh, '>', $self->pidfile()); $fh } $$;
    print "YAMilter listening on ".$self->sock()."\n";

    print "Loaded milter modules: ";
    print join(',', (map { my $subj = $_; $subj =~ s/^Milter::Recipe:://; $subj } loaded_recipes()))."\n";

    my $listen = "local:".$self->sock();
    my %callbacks = $self->cb();

    my $dispatcher = Sendmail::PMilter::prefork_dispatcher(
        max_children           => $self->workers(),
        max_requests_per_child => 100,
    );

    $Sendmail::PMilter::DEBUG=1 if $self->debug();
    my $milter = Sendmail::PMilter->new();
    $milter->setconn($listen) || die "Could not setup socket for YAMilter";
    $milter->register("YAMilter", \%callbacks, SMFI_V6_PROT) || die "Could not register YAMilter";
    $milter->set_dispatcher($dispatcher);
    $milter->main() || die "Could not run YAMilter";

	unlink $self->pidfile();
	unlink $self->sock();

	print "Shutting down YAMilter.\n";
}

my %cb = (
    negotiate => \&cont,
	connect   => \&cont,
	helo      => \&cont,
	envfrom   => \&cont,
	envrcpt   => \&cont,
	header    => \&cont,
	eoh       => \&cont,
    body      => \&cont,
	eom       => \&accept,
	abort     => \&cont,
	close     => \&cont,
);

=head2 cb

Return the hash of callbacks to be run by the milter.

=cut

sub cb {
    my $self = shift;
    state %full_cb;
    return %full_cb if %full_cb;

    my %intermediate;
    @intermediate{keys(%cb)} = map {[[ Default => $_ ]]} values(%cb);

    no strict 'refs';
    foreach my $lm ($self->loaded_recipes()) {
        my $cb = "$lm\:\:cb";
        my %mcb = %{*$cb{HASH}};
        die "Milter recipes must have at least one callback" unless %mcb;
        foreach my $callback (keys(%mcb)) {
            push(@{$intermediate{$callback}}, [ $lm => $mcb{$callback} ]);
        }
    }
    use strict 'refs';

    foreach my $callback (keys(%intermediate)) {
        $full_cb{$callback} = sub { _run_callbacks($callback, \@_, @{$intermediate{$callback}}) }
    }

    return %full_cb;
}

# Doing this on purpose to catch bad parses
no warnings qw{uninitialized};
my %mr = (
    SMFIS_CONTINUE() => 'CONTINUE',
    SMFIS_TEMPFAIL() => 'TEMPFAIL',
    SMFIS_REJECT()   => 'REJECT',
    SMFIS_ACCEPT()   => 'ACCEPT',
    SMFIS_MSG_LOOP() => 'HELO LOOP',
    undef()          => 'UNKNOWN',
    ''               => 'UNKNOWN',
);
use warnings;

# Just run everything in order until we short-circuit
sub _run_callbacks {
    my $callback = shift;
    my $args = shift;
    foreach my $cbo (@_) {
        my $module = $cbo->[0];
        my $cb     = $cbo->[1];
        warn "Running $module $callback callback" if $DEBUG;
        my $res = $cb->(@$args);
        if ($DEBUG) {
            no warnings qw{uninitialized};
            my $res_trans = $mr{$res};
            use warnings;
            warn "Response from callback: $res_trans ($res)";
        }
        return $res if defined $res && $res ne SMFIS_CONTINUE;
    }
    return SMFIS_CONTINUE;
}

sub loaded_recipes {
    return sort grep { m/^Milter::Recipe::/ } _inc2mod();
}

sub _inc2mod {
    return map {
        my $subj = $_;
        $subj =~ s|/|::|g;
        $subj =~ s|\.pm$||;
        $subj
    } keys(%INC);
}

sub accept {
	return SMFIS_ACCEPT;
}

sub cont {
	return SMFIS_CONTINUE;
}

sub reject {
    return SMFIS_REJECT;
}

1;
