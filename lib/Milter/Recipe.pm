package Milter::Recipe;

# ABSTRACT: Framework for building a milter based on various recipes

use 5.014;
use strict;
use warnings FATAL => 'all';
use re '/aa';

use Config::Simple;
use Sendmail::PMilter qw{:all};

=head1 SYNOPSIS

    # What yamilter --config /etc/yamilter.cfg does
    use Milter::Recipe;
    Milter::Recipe->new('/etc/yamilter.cfg')->run();

=head1 DESCRIPTION

Yet another Milter program.

The focus here is to have some overlooked filters & common business logic that you can load up with simple configuration.

Any sub-namespace of C<Milter::Recipe> is considered available to be loaded.

Based on L<Sendmail::PMilter>; most of the work making a recipe is in writing a milter callback used thereby.

While there exist older modular milters such as C<Mail::Milter>, they have not received updates in many, many years.
Most of the functionality therein is better covered by other software such as opendmarc/opendkim or postfix itself.

=head1 CONFIGURATION

    [service]
    pidfile=/var/run/yamilter.pid
    sock=/var/run/yamilter.sock
    workers=10
    debug=0
    [Language]
    langs=en, fr, es
    action=discard
    ...

List the recipes you want to load, and then specify any configuration relevant to them (if applicable).

A recipe section must have at least one key (C<action=reject> will do).
L<Config::Simple> does not see a section with no keys, so the recipe is not loaded.

=head2 Service configuration

Included in the F<service/> directory is a systemd service configuration you can drop in and use right away.
It is written to refer to F</etc/yamilter.cfg> as the config file.

The C<service> section above allows configuration of where the PID/Socket files live, and how many workers to run.
The values above are the defaults if you omit these parameters.

You'll likely want to configure chrooted dovecot to have the sock inside its chroot.

=head2 Recipe configuration

Each recipe will accept an C<action> parameter.
By default, each recipe MUST reject, but if the action is set, do that instead.

The only meaningful actions to take other than reject are discard or tempfail.
Maybe you want to accept, but that is usually ill-advised.

TODO: add a 'spam' action to add a spam header and accept.

All other recipe configuration is up to the recipe itself and you should refer to their documentation.

=head1 RECIPES

The ones provided with the YAMilter program are both scratching my personal itch,
and considered sufficient example for other authors to do the same.

=over 4

=item L<Milter::Recipe::Language>

Reject mails which are not comprehensible to your userbase.

=back

Writing them should be made significantly easier thanks to being able to test with L<Milter::Client>,
and L<Milter::Harness>, which runs the milter for the duration of a test.

=head2 Testing recipes against real mail

C<yamilter-corpus> replays a copy of your mailboxes through a yamilter configuration,
and records the verdict for each message in an SQLite database.
You can then look at the mail that got through for patterns, and write a recipe for them.

    yamilter-corpus index  --db corpus.db --source /path/to/Maildir
    yamilter-corpus run    --db corpus.db --config recipes.cfg --each --jobs 8
    yamilter-corpus report --db corpus.db headers
    yamilter-corpus report --db corpus.db diff 1 2

=head1 FURTHER IDEAS

Based on the spam I currently receive, implementing these below (and the above) would remove 99.99% of the spam I receive on my mx.

I suspect most of this has prior art elsewhere, as if I could come up with this in an afternoon I'm sure for-pay MXes figured these out years ago.

=head2 MatchingFrom

Reject mails which have a differing envelope sender and 'From' Header.

A common oversight by spammers, especially when they are sending spoofed email from a rooted box.

=head2 RejectUnsolicitedMailingLists

Spammers now frequently include a Mailing list unsubscribe header, because google looks for it specifically.

Normally, mailing list software has a mechanism to verify that a user has in fact signed up for this list.

Spammers do not get in the habit of hosting services which might respond in the affirmative to this, as people tend to retaliate against them quite fiercely.

As such, checking for this much like sender verification connections is valuable.

It is also of value to reject mails without an unsubscribe header, but some variation of "to stop receiving such communications reply, or click etc".

=head2 419Detect

Uses an LLM to identify if an email is obviously a 419 (advance fee) scam of some kind, and rejects it.

=head2 InsiderThreats

Reject sender domains coming from local which are known to not resolve to this host.

This is one of the problems with shared hosting.
You will eventually get a client that wants to run sendmail overtime to phish with a stolen CC.

This way they at least have to go to the trouble of buying a domain to attempt fraud.

=head2 PhishingDomains

Reject mails from domains which resolve to other live domains when homoglyph replaced, as these are almost always phishing.

Reject mails from domains which resolve to other live domains when the TLD is swapped, e.g. C<google.su> versus C<google.com>.

(You should already configure your mx to reject domains that do not resolve).

=head2 ASNBlock

Outright block entire ASNs.  For when all else fails.

=head2 HeaderIfSize

Add a header (likely to control relaying behavior) if the mail is above a certain size.

It is a common practice to throw up your hands and use a for-pay SMTP relay to be deliverable to the big 10 email providers.
However this can get pricey (or fail outright) if you send things with big attachments, and you probably want to avoid that.

=cut

=head1 CONSTRUCTOR

=head2 new($cfile)

Creates the Milter recipe singleton.  Subsequent calls simply return the same object.

=cut

my $DEBUG    = 0;
my $NO_ACCUM = 0;

# This here is what you call a 'singleton'
my $singleton;

sub new {
    my ( $class, $cfile ) = @_;

    return $singleton if $singleton;

    my $config = Config::Simple->new($cfile) or die "Could not read configuration file $cfile: " . Config::Simple->error() . "\n";

    #XXX passing no block to get_block returns the list of blocks, but this is undocumented.
    my @blocks = grep { $_ ne 'service' } ( $config->get_block() );

    my %obj = (
        pidfile  => $config->param('service.pidfile') // "/var/run/yamilter.pid",
        sock     => $config->param('service.sock')    // "/var/run/yamilter.sock",
        workers  => $config->param('service.workers') // 10,
        cfile    => $cfile,
        debug    => $config->param('service.debug')    // 0,
        no_accum => $config->param('service.no_accum') // 0,
    );

    # Set things that callbacks need to be aware of
    $DEBUG    = $obj{debug};
    $NO_ACCUM = $obj{no_accum};

    foreach my $recipe (@blocks) {
        next if $recipe eq 'service';
        require "Milter/Recipe/$recipe.pm" or do {
            die "Could not find milter recipe $recipe!";
        };
        $obj{$recipe} = $config->get_block($recipe);
    }

    $singleton = bless( \%obj, $class );
    return $singleton;
}

=head2 pidfile, sock, workers, cfile, debug

The C<service> settings from the configuration (with their defaults), and the configuration file's path.

=cut

sub pidfile { $_[0]->{pidfile} }
sub sock    { $_[0]->{sock} }
sub workers { $_[0]->{workers} }
sub cfile   { $_[0]->{cfile} }
sub debug   { $_[0]->{debug} }

=head1 STATIC METHODS

=head2 $class->config()

Retrieve the config section relevant to the current class, as a hashref, with the service's C<debug> setting added.

If your Recipe requires configuration, this is the method to call.
It is a lookup on the singleton, so calling it from every callback costs nothing to speak of.

=cut

sub config {
    my $class = shift;

    my ($recipe) = $class =~ m/::(\w+)$/;
    my $self     = $class->new();
    my $section  = $self->{$recipe} //= {};
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
    my $conf  = $class->config();
    warn "Taking configured action of $conf->{action} ($action{$conf->{action}})" if $conf->{debug};
    return $action{ $conf->{action} }                                             if $conf->{action};
    return $action{reject};
}

=head2 ($smtp_code, $esmtp_code) = $class->config_code()

Sometimes you will want a callback to do $ctx->setreply() to have a complicated response.

This will map the config action to the appropriate response code to use as the first arg to setreply().

Dies in the event your action has no appropriate code (e.g. discard, loop).

=cut

my %action2code = (
    SMFIS_REJECT()   => [ 550, '5.7.1' ],
    SMFIS_TEMPFAIL() => [ 450, '4.7.1' ],
    SMFIS_ACCEPT()   => [ 250, '2.0.0' ],
    SMFIS_CONTINUE() => [ 354, '3.0.0' ],
);

sub config_code {
    my $class  = shift;
    my $action = $class->config_action();
    warn "Action: $action" if $DEBUG;
    my $code = $action2code{$action};
    die "No appropriate code available for the configured action" unless $code;
    return @$code;
}

=head1 METHODS

=head2 run

Actually run the milter.

Sets up some default milter callbacks that generally do the right thing:

=over 4

=item 1)
Continue until EOM, then accept.  It is presumed any milter callbacks you configure do what they need to do before this point.

=item 2)
On Connect() we setpriv an empty hashref that you can store connection specific state within to support functionality requiring multiple callbacks.

=item 3)
On Header() and Body() we accumulate the header and body fragments into the 'header' and 'body' keys of said hashref, that you might consult them in EOH, EOB and EOM.
Each header is accumulated as a C<"Name: value\n"> line.

=back

3. Has some consequences in that if you don't limit the size of msgs and headers.
With 10 workers each handling 100 conns, your upper limit if say, you get a bunch of 1MB mails would be ~1GB of ram worst case.

DOS prevention is outside the scope of this milter.  You should limit the scope of such with mailserver size limits and # of workers available to the milter.

If absolutely necessary, accumulation can be disabled with the C<service.no_accum> config flag, but you will need to use Milter modules which can stream rather than slurp.
This is advertised to modules as the C<no_accum> flag passed in their config, so they can make sane decisions about this.
It is necessary that Milter::Recipe child modules document what they do about this.

The acccumulation feature is primarily here to ease development and testing of new milters,
but there exist rare problems which require full context to be correct and which have incompressible intermediate results.

=cut

sub run {
    my $self = shift;

    # Under systemd or Milter::Harness this goes to a pipe or file, where block buffering would lose it on TERM
    STDOUT->autoflush(1);
    print "YAMilter starting up...\n";
    print "YAMilter using config file " . $self->cfile() . "\n";

    unlink $self->pidfile() if -e $self->pidfile();
    unlink $self->sock()    if -e $self->sock();

    print {
        open( my $fh, '>', $self->pidfile() );
        $fh
    } $$;
    print "YAMilter listening on " . $self->sock() . "\n";

    print "Loaded milter modules: ";
    print join( ',', ( map { my $subj = $_; $subj =~ s/^Milter::Recipe:://; $subj } loaded_recipes() ) ) . "\n";

    my $listen    = "local:" . $self->sock();
    my %callbacks = $self->cb();

    my $dispatcher = Sendmail::PMilter::prefork_dispatcher(
        max_children           => $self->workers(),
        max_requests_per_child => 100,
    );

    $Sendmail::PMilter::DEBUG = 1 if $self->debug();
    my $milter = Sendmail::PMilter->new();
    $milter->setconn($listen)                                  || die "Could not setup socket for YAMilter";
    $milter->register( "YAMilter", \%callbacks, SMFI_V6_PROT ) || die "Could not register YAMilter";
    $milter->set_dispatcher($dispatcher);
    $milter->main() || die "Could not run YAMilter";

    unlink $self->pidfile();
    unlink $self->sock();

    print "Shutting down YAMilter.\n";
}

my %cb = (
    negotiate => \&cont,
    connect   => sub {
        my ($ctx) = @_;
        $ctx->setpriv( {} );
        return cont();
    },
    helo    => \&cont,
    envfrom => \&cont,
    envrcpt => \&cont,
    header  => sub {
        my ( $ctx, $name, $value ) = @_;
        return cont() if $NO_ACCUM;
        my $p = $ctx->getpriv();
        $p->{header} .= "$name: $value\n";
        $ctx->setpriv($p);
        return cont();
    },
    eoh  => \&cont,
    body => sub {
        my ( $ctx, $data, $len ) = @_;
        return cont() if $NO_ACCUM;
        my $p = $ctx->getpriv();
        $p->{body} .= $data;
        $ctx->setpriv($p);
        return cont();
    },
    eom   => \&accept,
    abort => \&cont,
    close => \&cont,
);

=head2 cb

Return the hash of callbacks to be run by the milter.

=cut

sub cb {
    my $self = shift;
    state %full_cb;
    return %full_cb if %full_cb;

    my %intermediate;
    @intermediate{ keys(%cb) } = map { [ [ Default => $_ ] ] } values(%cb);

    no strict 'refs';
    foreach my $lm ( $self->loaded_recipes() ) {
        my $cb  = "$lm\:\:cb";
        my %mcb = %{ *$cb{HASH} };
        die "Milter recipes must have at least one callback" unless %mcb;
        foreach my $callback ( keys(%mcb) ) {
            push( @{ $intermediate{$callback} }, [ $lm => $mcb{$callback} ] );
        }
    }
    use strict 'refs';

    foreach my $callback ( keys(%intermediate) ) {
        $full_cb{$callback} = sub { _run_callbacks( $callback, \@_, @{ $intermediate{$callback} } ) }
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

# Just run everything in order until we short-circuit
sub _run_callbacks {
    my $callback = shift;
    my $args     = shift;
    foreach my $cbo (@_) {
        my $module = $cbo->[0];
        my $cb     = $cbo->[1];
        warn "Running $module $callback callback" if $DEBUG;
        my $res = $cb->(@$args);
        if ($DEBUG) {
            no warnings qw{uninitialized};
            my $res_trans = $mr{$res};
            warn "Response from callback: $res_trans ($res)" if $DEBUG;
        }
        return $res if defined $res && $res ne SMFIS_CONTINUE;
    }
    return SMFIS_CONTINUE;
}

=head2 loaded_recipes

The package names of the recipes loaded from the configuration, sorted.

=cut

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

=head2 accept, cont, reject

Return C<SMFIS_ACCEPT>, C<SMFIS_CONTINUE> or C<SMFIS_REJECT>, for recipe callbacks to return.
Most callbacks want C<< __PACKAGE__->cont() >>, or C<< __PACKAGE__->config_action() >> when they have made up their mind.

=cut

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
