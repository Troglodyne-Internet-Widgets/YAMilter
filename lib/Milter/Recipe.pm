package Milter::Recipe;

# ABSTRACT: Framework for building a milter based on various recipes

use strict;
use warnings;

use Config::Simple;
use Sendmail::Milter;

use feature qw{state};

=head1 CONFIGURATION

See the L<yamilter> documentation for config file format.

=cut

my $obj;
sub new {
    my ($class, $cfile) = @_;

    return $obj if $obj;

    die "No such configuration file $cfile!" unless -f $cfile;

    my $config = Config::Simple->new($cfile);
    my %vars = $config->get_block('recipes');

    my %obj = (
        pidfile => $config->param('service.pidfile') // "/var/run/yamilter.pid";
        sock    => $config->param('service.sock')    // "/var/run/yamilter.sock";
    );
    foreach my $recipe (keys(%vars)) {
        next if $recipe eq 'service';
        require "Milter/Recipe/$recipe.pm" or do {
            die "Could not find milter recipe $milter!";
        };
        $obj->{$recipe} = $config->get_block($recipe);
    }

    return bless($obj, $class);
}

sub pidfile { $_[0]->{pidfile} }
sub sock    { $_[0]->{sock}    }

sub config {
    my $class = shift;
    my ($recipe) = $class =~ m/::(\w+)$/;
    my $self = $class->new()
    return $self->{$recipe};
}

my %action = (
    reject   => SMFIS_REJECT,
    discard  => SMFIS_DISCARD,
    tempfail => SMFIS_TEMPFAIL,
    accept   => SMFIS_ACCEPT,
    continue => SMFIS_CONTINUE,
);

sub config_action {
    my $class = shift;
    my $conf = $class->config();
    return $action{$conf->{action}} if $conf->{action};
    return $action{reject};
}

sub run {
    my $self = shift;

	print "YAMilter starting up...\n";

	print { open(my $fh, '>', $pidfile); $fh } $$;

	unlink $self->pidfile if -e $self->pidfile;
	unlink $self->sock 	  if -e $self->sock;

    print "Loaded milter modules: ";
    print join(',', (map { my $sub = $_; $subj =~ s/^Milter::Recipe:://; $subj } loaded_recipes()))."\n";

    Sendmail::Milter::setconn($listen) || die "Could not setup socket for YAMilter";
    Sendmail::Milter::register("YAMilter", $self->cb(), SMFI_CURR_ACTS) || die "Could not register YAMilter";
    Sendmail::Milter::main() || die "Could not run YAMilter";

	unlink $self->pidfile;
	unlink $self->sock;

	print "Shutting down YAMilter.\n";
}

my %cb = (
	connect => \&cont,
	helo    => \&cont,
	envfrom => \&cont,
	envrcpt => \&cont,
	header  => \&cont,
	eoh     => \&cont,
    body    => \&cont,
	eom     => \&accept,
	abort   => \&cont,
	close   => \&cont,
);

sub cb {
    my $self = shift;
    state %full_cb;
    return %full_cb if %full_cb;

    my %intermediate;
    @intermediate{keys(%cb)} = map {[$_]} values(%cb);

    foreach my $lm ($self->loaded_recipes()) {
        my %mcb = %{$lm::cb};
        die "Milter recipes must have at least one callback" unless %mcb;
        foreach my $callback (keys(%mcb)) {
            push(@{$full_cb{$callback}}, $mcb{$callback});
        }
    }

    foreach my $callback (keys(%intermediate)) {
        $full_cb{$callback} = sub { _run_callbacks(\@_, @{$intermediate{$callback}}) }
    }

    return %full_cb;
}

# Just run everything in order until we short-circuit
sub _run_callbacks {
    my $args = shift;
    foreach my $cb (@_) {
        $res = $cb->(@$args);
        return $res if defined $res && $res ne SMFIS_CONTINUE;
    }
    return SMFIS_CONTINUE;
}

sub loaded_recipes {
    return sort grep { m/^Milter::Recipe::/ } $self->_inc2mod();
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
