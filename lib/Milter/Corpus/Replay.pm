package Milter::Corpus::Replay;

# ABSTRACT: Replay indexed mail through yamilter and record what it did with each piece

use 5.014;
use strict;
use warnings FATAL => 'all';
use re '/aa';

use Config::Simple;
use Digest::SHA qw{sha256_hex};
use File::Temp;
use IO::Select;
use Cpanel::JSON::XS;
use POSIX       qw{WNOHANG};
use Time::HiRes qw{time};

use Milter::Client qw{:constants};
use Milter::Corpus qw{split_message};
use Milter::Harness;
use Milter::Recipe;

=head1 SYNOPSIS

    my $replay = Milter::Corpus::Replay->new(
        corpus => Milter::Corpus->new( db => 'corpus.db' ),
        script => '/path/to/bin/yamilter',
        config => '/path/to/recipes.cfg',
    );
    my @run_ids = $replay->run( each => 1, jobs => 4 );

=head1 DESCRIPTION

Starts yamilter with the given configuration, and plays every indexed message through it as an MTA would:
OPTNEG, CONNECT (with the client address from the message's Received headers), HELO, MAIL, RCPT, DATA,
one HEADER per header, EOH, the body in chunks (with bare LF turned into CRLF, as on the wire), and end of message.

Each message gets a fresh connection.
yamilter writes a decision_log for the run, which is how each result records the recipe which decided it.
The first reply which is not CONTINUE is recorded as the verdict, mapped to one of these actions:
accept, reject, tempfail, discard, quarantine, timeout (the milter said nothing in time) or error (the milter hung up, or the message could not be read).
Reaching the end of the message with nothing but CONTINUE counts as accept, as that is what an MTA would do.

The configuration's C<service> section is replaced: the socket and pidfile go in a temporary directory, and C<workers> matches C<jobs>.
Only C<order> is kept, less any recipe a run leaves out.

=cut

# 0x1FF: every action a v6 MTA can offer.  0x1FFFFF: every protocol step.
my @OPTNEG = ( SMFIC_OPTNEG, 6, 0x1FF, 0x1FFFFF );

# Replayed messages get this and their id as the MTA queue id ({i} macro), so the decision_log can be tied back to them
my $QUEUE_ID_PREFIX = 'yamilter-corpus-';

my %ACTION = (
    SMFIR_ACCEPT()   => 'accept',
    SMFIR_CONTINUE() => 'accept',
    SMFIR_REJECT()   => 'reject',
    SMFIR_TEMPFAIL() => 'tempfail',
    SMFIR_DISCARD()  => 'discard',
    CLIENT_TIMEOUT() => 'timeout',
    CLIENT_EOF()     => 'error',
);

=head1 CONSTRUCTOR

=head2 new(%args)

C<corpus> (a L<Milter::Corpus>), C<script> (path to yamilter) and C<config> (path to a yamilter configuration) are required.

=cut

sub new {
    my ( $class, %args ) = @_;
    for my $req (qw{corpus script config}) {
        die "$req is required" unless $args{$req};
    }
    $args{cfg} = Config::Simple->new( $args{config} ) or die "Could not read configuration file $args{config}: " . Config::Simple->error() . "\n";
    return bless( \%args, $class );
}

=head1 METHODS

=head2 @run_ids = run(%opts)

=over 4

=item C<label>

Name the run(s), to tell them apart in reports.  With C<each>, the recipe name is appended.

=item C<each>

Make one run per recipe in the configuration, so that every message gets a verdict from each recipe.
The runs share a batch, and a batch's reports treat a message as blocked if any recipe blocked it.

=item C<folder>, C<limit>

Passed to L<Milter::Corpus/messages> to pick which messages to replay.

=item C<jobs>

How many messages to replay at once.  Defaults to 1.

=item C<timeout>

Seconds to wait for each milter reply before recording a timeout.  Defaults to 10.

=item C<progress>

Called with C<($run_id, $done, $total)> every so often.

=back

=cut

sub run {
    my ( $self, %opts ) = @_;
    $opts{jobs}    ||= 1;
    $opts{timeout} ||= 10;

    my $corpus   = $self->{corpus};
    my $messages = $corpus->messages( folder => $opts{folder}, limit => $opts{limit} );
    die "No messages to replay.  Index some mail first.\n" unless @$messages;

    my @configs = $self->_configs( $opts{each} );
    my ( $batch, @runs );
    foreach my $cfg (@configs) {
        my $label = join( ' ', grep { defined && length } $opts{label}, ( $opts{each} ? $cfg->{recipes}[0] : () ) );
        my $run   = $corpus->start_run(
            batch   => $batch,
            label   => $label,
            config  => $cfg->{text},
            recipes => _describe_recipes( @{ $cfg->{recipes} } ),
        );
        $batch //= $run;
        push @runs, $run;

        # A run which did not finish would otherwise become the latest batch in reports
        my $log = eval { $self->_replay( $run, $cfg, $messages, \%opts ) };
        if ( !defined $log ) {
            my $err = $@;
            $corpus->dbh->do( 'DELETE FROM runs WHERE id = ?', undef, $run );
            die $err;
        }
        $corpus->finish_run( $run, $log );
    }
    return @runs;
}

# The configurations to run: the whole thing, or one per recipe
sub _configs {
    my ( $self, $each ) = @_;
    my $cfg     = $self->{cfg};
    my @recipes = sort grep { $_ ne 'service' } $cfg->get_block();
    die "No recipes configured in $self->{config}.  Note that a recipe section needs at least one key (e.g. action=reject) to be seen.\n" unless @recipes;

    my @order = Milter::Recipe->config_list( $cfg->param('service.order') );

    my @groups = $each ? ( map { [$_] } @recipes ) : ( \@recipes );
    return map {
        my @group = @$_;
        my %in    = map { $_ => 1 } @group;
        {
            recipes => \@group,
            text    => _ini( map { ( $_ => $cfg->get_block($_) ) } @group ),

            # yamilter refuses an order naming a recipe it has no section for, which --each leaves out
            order => join( ', ', grep { $in{$_} } @order ),
        }
    } @groups;
}

# Config::Simple cannot write a section with no keys, and yamilter cannot see one, so we write these ourselves.
sub _ini {
    my (%blocks) = @_;
    my $text = '';
    foreach my $block ( sort keys %blocks ) {
        $text .= "[$block]\n";
        foreach my $key ( sort keys %{ $blocks{$block} } ) {
            my $value = $blocks{$block}{$key};
            $value = join( ', ', @$value ) if ref $value eq 'ARRAY';
            $text .= "$key=$value\n";
        }
    }
    return $text;
}

# Which recipe code produced a run's results, so a later run can be compared knowing whether the code changed
sub _describe_recipes {
    my @recipes = @_;
    my %desc;
    foreach my $recipe (@recipes) {
        my ($file) = grep { -e } map { "$_/Milter/Recipe/$recipe.pm" } grep { !ref } @INC;
        $desc{$recipe} = $file
          ? sha256_hex(
            do { local ( @ARGV, $/ ) = ($file); <> }
          )
          : undef;
    }
    return Cpanel::JSON::XS->new->canonical->encode( \%desc );
}

sub _replay {
    my ( $self, $run, $cfg, $messages, $opts ) = @_;

    my $dir  = File::Temp->newdir();
    my $file = "$dir/yamilter.cfg";
    open( my $fh, '>', $file ) or die "Could not write $file: $!";
    print $fh _ini(
        service => {
            sock         => "$dir/yamilter.sock",
            pidfile      => "$dir/yamilter.pid",
            workers      => $opts->{jobs},
            decision_log => "$dir/decisions.log",
            ( length $cfg->{order} ? ( order => $cfg->{order} ) : () ),
        },
    );
    print $fh $cfg->{text};
    close $fh;

    my $milter = Milter::Harness->new( script => $self->{script}, config => $file );
    $milter->start();

    my @readers;
    foreach my $job ( 0 .. $opts->{jobs} - 1 ) {
        pipe( my $reader, my $writer ) or die "Could not pipe: $!";
        my $pid = fork() // die "Could not fork: $!";
        if ( !$pid ) {
            close $reader;
            $writer->autoflush(1);
            my @mine = @$messages[ grep { $_ % $opts->{jobs} == $job } 0 .. $#$messages ];
            _worker( $milter, $writer, \@mine, $opts->{timeout} );
            POSIX::_exit(0);
        }
        close $writer;
        push @readers, [ $reader, $pid ];
    }

    my $select = IO::Select->new( map { $_->[0] } @readers );
    my $json   = Cpanel::JSON::XS->new;
    my ( $done, @pending ) = (0);
    while ( $select->count() ) {
        foreach my $reader ( $select->can_read(5) ) {
            my $line = readline($reader);
            if ( !defined $line ) {
                $select->remove($reader);
                close $reader;
                next;
            }
            push @pending, $json->decode($line);
        }
        if ( @pending >= 500 || !$select->count() ) {
            $done += $self->{corpus}->record_results( $run, splice(@pending) );
            $opts->{progress}->( $run, $done, scalar(@$messages) ) if $opts->{progress};
        }
        if ( !$milter->running() ) {
            kill( 'TERM', map { $_->[1] } @readers );
            die "Milter died mid-replay:\n" . $milter->output();
        }
    }
    $self->{corpus}->record_results( $run, @pending ) if @pending;
    waitpid( $_->[1], 0 ) for @readers;

    my $log = $milter->stop();
    $self->{corpus}->record_recipes( $run, _decisions("$dir/decisions.log") );
    return $log;
}

# Which recipe decided each message, from the milter's decision_log: message id => recipe
sub _decisions {
    my ($file) = @_;
    open( my $fh, '<', $file ) or return {};
    my %recipe;
    while ( my $line = <$fh> ) {
        chomp $line;
        my ( undef, $queue_id, $recipe ) = split( qr/\t/, $line );
        my ($id) = ( $queue_id // '' ) =~ m/\A\Q$QUEUE_ID_PREFIX\E(\d+)\z/ or next;
        $recipe{$id} = $recipe;
    }
    return \%recipe;
}

sub _worker {
    my ( $milter, $out, $messages, $timeout ) = @_;
    my $json = Cpanel::JSON::XS->new->canonical;
    foreach my $msg (@$messages) {
        my $start  = time;
        my $result = eval { _replay_one( $milter, $msg, $timeout ) } // { code => CLIENT_EOF, action => 'error', reply => "$@" };
        $result->{message_id} = $msg->{id};
        $result->{elapsed_ms} = int( ( time - $start ) * 1000 );
        print $out $json->encode($result) . "\n";
    }
    return;
}

sub _replay_one {
    my ( $milter, $msg, $timeout ) = @_;
    my $raw = Milter::Corpus::read_bytes( @$msg{qw{path offset length}} );
    return { code => CLIENT_EOF, action => 'error', reply => "Could not read $msg->{path}" } unless defined $raw;

    my $sock = $milter->connect();
    my ( $code, $payload, $mods ) = Milter::Client::sendmail( $sock, { timeout => $timeout }, commands( $raw, $msg, "$QUEUE_ID_PREFIX$msg->{id}" ) );
    close $sock;

    my $action = $ACTION{$code};
    if ( $code eq SMFIR_REPLYCODE ) {
        $action = $payload =~ m/^5/ ? 'reject' : $payload =~ m/^4/ ? 'tempfail' : 'accept';
    }

    # A quarantined message is accepted by the MTA, but held rather than delivered
    $action = 'quarantine' if ( $action // '' ) eq 'accept' && grep { $_->[0] eq SMFIR_QUARANTINE } @$mods;

    return {
        code          => $code,
        action        => $action // "other",
        reply         => $payload,
        modifications => ( $mods && @$mods ) ? Cpanel::JSON::XS->new->canonical->encode($mods) : undef,
    };
}

=head1 FUNCTIONS

=head2 @commands = commands($raw, \%envelope, [$queue_id])

The milter conversation an MTA would have for a message, given its raw content and envelope (as from L<Milter::Corpus/messages>).
With C<$queue_id>, it is sent as the C<{i}> macro before MAIL FROM, as postfix does.

=cut

sub commands {
    my ( $raw, $env, $queue_id ) = @_;
    my ( $fields, $body ) = split_message($raw);
    $body =~ s/(?<!\r)\n/\r\n/g;

    my $ip     = $env->{client_ip};
    my $family = !$ip ? SMFIA_UNKNOWN : index( $ip, ':' ) >= 0 ? SMFIA_INET6 : SMFIA_INET;
    my $host   = $env->{client_host} // ( $ip ? "[$ip]" : 'localhost' );

    return (
        [@OPTNEG],
        [ SMFIC_CONNECT, $host, $family, 25, $ip // '' ],
        [ SMFIC_HELO, $env->{helo} // 'unknown' ],
        ( defined $queue_id ? [ SMFIC_MACRO, SMFIC_MAIL, i => $queue_id ] : () ),
        [ SMFIC_MAIL, '<' . ( $env->{mail_from} // '' ) . '>' ],
        [ SMFIC_RCPT, '<' . ( $env->{rcpt_to}   // '' ) . '>' ],
        [SMFIC_DATA],
        ( map { [ SMFIC_HEADER, @$_ ] } @$fields ),
        [SMFIC_EOH],
        Milter::Client::body_chunks($body),
        [SMFIC_BODYEOB],
        [SMFIC_QUIT],
    );
}

1;
