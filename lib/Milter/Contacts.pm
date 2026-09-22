package Milter::Contacts;

# ABSTRACT: Who the users of this mail server have written to, and the Message-IDs of what they sent

use 5.014;
use strict;
use warnings FATAL => 'all';
use re '/aa';

use DBI;
use Mail::Box::Manager;

=head1 SYNOPSIS

    my $contacts = Milter::Contacts->new( file => '/var/lib/yamilter/contacts.db' );
    $contacts->seed('/home/someone/Maildir/.Sent');
    $contacts->learn( addresses => [ 'them@example.com' ], message_ids => [ 'abc@example.org' ] );

    print "writes to us, and we write back\n" if $contacts->known('them@example.com');
    print "a reply to something we sent\n"    if $contacts->sent('abc@example.org');

=head1 DESCRIPTION

A small SQLite file which the milter's worker processes share: the addresses and domains mail has been sent to,
and the Message-IDs of mail sent from here.  Recipes use it to tell a correspondent from a stranger.

A domain counts as known when someone at it has been written to, except for the domains in L</shared_domains>,
where one address says nothing about the next.

=cut

my @SCHEMA = (
    q{CREATE TABLE IF NOT EXISTS contacts (
        address    TEXT    PRIMARY KEY,
        domain     TEXT    NOT NULL,
        first_seen INTEGER NOT NULL,
        last_seen  INTEGER NOT NULL
    ) WITHOUT ROWID},
    q{CREATE INDEX IF NOT EXISTS contacts_domain ON contacts(domain)},
    q{CREATE TABLE IF NOT EXISTS sent_ids (
        message_id TEXT    PRIMARY KEY,
        seen       INTEGER NOT NULL
    ) WITHOUT ROWID},
);

=head1 CONSTRUCTOR

=head2 new( file => $path, [shared_domains => \@domains] )

Opens (creating if need be) the contacts file.

=cut

sub new {
    my ( $class, %args ) = @_;
    die "file is required" unless $args{file};
    my $self = bless( {%args}, $class );
    $self->{shared} = { map { lc($_) => 1 } @{ $args{shared_domains} // [ shared_domains() ] } };
    $self->dbh();
    return $self;
}

=head2 dbh

The L<DBI> handle on the contacts file.  Each process gets its own, as the milter's workers are forked and an SQLite handle must not cross a fork.

=cut

sub dbh {
    my $self = shift;
    return $self->{dbh} if $self->{dbh} && $self->{pid} == $$;

    my $dbh = DBI->connect( "dbi:SQLite:dbname=$self->{file}", '', '', { RaiseError => 1, PrintError => 0, AutoCommit => 1, AutoInactiveDestroy => 1 } );
    $dbh->do('PRAGMA journal_mode = WAL');
    $dbh->do('PRAGMA busy_timeout = 5000');
    $dbh->do($_) for @SCHEMA;
    @$self{qw{dbh pid}} = ( $dbh, $$ );
    return $dbh;
}

=head1 FUNCTIONS

=head2 shared_domains

The default list of domains many unrelated people have addresses at (gmail.com, outlook.com and so on).

=cut

sub shared_domains {
    return qw{gmail.com googlemail.com outlook.com hotmail.com live.com msn.com yahoo.com ymail.com aol.com icloud.com me.com mac.com protonmail.com proton.me gmx.com gmx.net mail.com zoho.com yandex.com fastmail.com};
}

=head2 domain($address)

The part of an address's domain that names the organization: its last two labels, or three under the likes of co.uk.
Lowercased.

=cut

my %SECOND_LEVEL = map { $_ => 1 } qw{co.uk org.uk ac.uk gov.uk com.au net.au org.au co.nz co.jp co.za com.br com.mx co.in};

sub domain {
    my ($address) = @_;
    my ($host)    = _bare($address) =~ m/\@([^\s\@]+)\z/ or return '';
    my @labels    = split( qr/\./, $host );
    my $keep      = ( @labels >= 3 && $SECOND_LEVEL{ join( '.', @labels[ -2, -1 ] ) } ) ? 3 : 2;
    return join( '.', @labels[ -( $keep < @labels ? $keep : @labels ) .. -1 ] );
}

=head1 METHODS

=head2 learn( addresses => \@addresses, message_ids => \@ids )

Remember addresses mail was sent to, and the Message-IDs of mail sent.  Angle brackets are removed, and case is ignored.

=cut

sub learn {
    my ( $self, %what ) = @_;
    my $dbh = $self->dbh();
    my $now = time;
    $dbh->begin_work();
    foreach my $address ( @{ $what{addresses} || [] } ) {
        my $a = _bare($address);
        next unless index( $a, '@' ) > 0;
        $dbh->do( 'INSERT INTO contacts (address, domain, first_seen, last_seen) VALUES (?, ?, ?, ?) ON CONFLICT (address) DO UPDATE SET last_seen = excluded.last_seen', undef, $a, domain($a), $now, $now );
    }
    foreach my $id ( @{ $what{message_ids} || [] } ) {
        my $i = _bare($id);
        next unless length $i;
        $dbh->do( 'INSERT OR IGNORE INTO sent_ids (message_id, seen) VALUES (?, ?)', undef, $i, $now );
    }
    $dbh->commit();
    return;
}

=head2 known($address, [@not_by_domain])

True if the address has been written to, or anyone at its domain has (shared domains aside).
Domains in C<@not_by_domain> only count by exact address; recipes pass the recipient's own domain,
since writing to a colleague says nothing about everything else claiming to be from your domain.

=cut

sub known {
    my ( $self, $address, @not_by_domain ) = @_;
    my $a   = _bare($address);
    my $dbh = $self->dbh();
    return 1 if $dbh->selectrow_array( 'SELECT 1 FROM contacts WHERE address = ?', undef, $a );
    my $domain = domain($a);
    return 0 if !length $domain || $self->{shared}{$domain} || grep { domain( '@' . $_ ) eq $domain || domain($_) eq $domain } @not_by_domain;
    return $dbh->selectrow_array( 'SELECT 1 FROM contacts WHERE domain = ? LIMIT 1', undef, $domain ) ? 1 : 0;
}

=head2 sent($message_id)

True if a message with this Message-ID was sent from here.

=cut

sub sent {
    my ( $self, $id ) = @_;
    return $self->dbh->selectrow_array( 'SELECT 1 FROM sent_ids WHERE message_id = ?', undef, _bare($id) ) ? 1 : 0;
}

=head2 seed(@folders)

Learn from folders of sent mail: every To, Cc and Bcc address, and every Message-ID.
Each folder is a Maildir directory or an mbox file.  Returns how many messages were read.

=cut

sub seed {
    my ( $self, @folders ) = @_;
    my $mgr = Mail::Box::Manager->new( log => 'NONE', trace => 'NONE' );
    my $n   = 0;
    foreach my $path (@folders) {
        my $folder = eval { $mgr->open( folder => $path, access => 'r', lock_type => 'NONE', extract => 'LAZY' ) } or die "Could not open $path as a mail folder: " . ( ( $@ || 'not a folder Mail::Box recognizes' ) =~ s/\s+\z//r ) . "\n";
        my ( @addresses, @ids );
        foreach my $message ( $folder->messages ) {
            push @addresses, map { $_->address } map { $message->head->get($_) ? $message->head->get($_)->addresses : () } qw{To Cc Bcc};
            push @ids,       $message->messageId if $message->head->get('Message-ID');
            $n++;
        }
        $folder->close( write => 'NEVER' );
        $self->learn( addresses => \@addresses, message_ids => \@ids );
    }
    return $n;
}

=head2 ($columns, $rows) = list()

Every contact, most recently written to first.

=cut

sub list {
    my ($self) = @_;
    my $sth = $self->dbh->prepare(q{SELECT address, domain, datetime(first_seen, 'unixepoch') AS first_seen, datetime(last_seen, 'unixepoch') AS last_seen FROM contacts ORDER BY last_seen DESC, address});
    $sth->execute();
    return ( $sth->{NAME}, $sth->fetchall_arrayref() );
}

=head2 forget($address)

Returns true if the address was known.

=cut

sub forget {
    my ( $self, $address ) = @_;
    return $self->dbh->do( 'DELETE FROM contacts WHERE address = ?', undef, _bare($address) ) > 0;
}

sub _bare {
    my ($value) = @_;
    my $v = lc( $value // '' );
    $v =~ s/\A\s*<?|>?\s*\z//g;
    return $v;
}

1;
