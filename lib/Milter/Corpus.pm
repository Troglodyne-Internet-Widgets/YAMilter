package Milter::Corpus;

# ABSTRACT: SQLite index of a pile of mail, and what the milter thought of each piece

use 5.014;
use strict;
use warnings FATAL => 'all';
use re '/aa';

use DBI;
use Digest::SHA qw{sha256_hex};
use Encode      ();
use Fcntl       qw{SEEK_SET};
use File::Find  ();
use File::Spec;
use List::Util qw{any};
use Mail::Address;
use Mail::Box::Manager;

use Exporter 'import';
our @EXPORT_OK = qw{split_message};

=head1 SYNOPSIS

    my $corpus = Milter::Corpus->new( db => 'corpus.db' );
    $corpus->index_source('/path/to/Maildir');

    my ($first) = @{ $corpus->messages( limit => 1 ) };
    my $raw = $corpus->raw( $first->{id} );
    my ( $fields, $body ) = Milter::Corpus::split_message($raw);

=head1 DESCRIPTION

Indexes mail so that recipes can be replayed against it (see L<Milter::Corpus::Replay>),
and so the mail which gets through can be picked apart for patterns (see L</REPORTS>).

Mail is not copied into the database.
Each message is stored as a pointer to the file (and byte range therein) it came from,
along with its headers, what its SMTP envelope most likely was, and the verdicts of every replay.

Messages are deduplicated by the SHA-256 of their content, so the same mail in two folders is one message with two locations.

The schema is meant to be queried directly with C<sqlite3> for anything the canned reports do not cover:

=over 4

=item C<messages>

One row per unique message.

=item C<locations>

Where each message can be found: C<folder> (path relative to the source, C<.> being the root Maildir), C<kind> (maildir or mbox), C<path>, C<offset>, C<length>, and the Maildir C<flags> (C<S>een, C<T>rashed and so forth).

=item C<headers>

Every header of every message, in order. C<name> is lowercased, C<value> is unfolded, and C<decoded> has RFC 2047 encoded words decoded (as UTF-8) when there were any.

=item C<envelope>

The SMTP envelope and connection a message most likely arrived with, derived from its headers.
C<derived> lists the fields which had to be guessed from the From/To headers rather than read from Return-Path, Delivered-To and Received.

=item C<runs> and C<results>

One C<runs> row per replay, one C<results> row per message per replay.
Runs made together by C<--each> share a C<batch>.

=back

The reports in L</REPORTS> are views, which can be queried the same way.
Every view about verdicts has a C<scope> column (C<batch> or C<run>) and a C<scope_id> column (the batch or run id), so pick one with, for example, C<WHERE scope = 'batch' AND scope_id = 3>.

=over 4

=item C<verdicts>

Each message's verdict (C<accept>, C<blocked> or C<error>) in each batch and run.
In a batch, a message is C<blocked> if any run rejected, deferred, discarded or quarantined it, C<error> if any run timed out or lost the milter, and C<accept> otherwise.

=item C<verdict_counts>, C<run_actions>

Messages per verdict, and per action in each run.

=item C<header_rates>

For each header name, how many messages of each verdict have it (C<accept>, C<blocked>, C<error>), and what percentage of that verdict's messages that is (C<pct_accept> and so forth).

=item C<header_values>, C<sender_domains>, C<helo_names>, C<client_ips>, C<folder_verdicts>, C<reply_counts>

Message counts by header value, envelope sender domain, HELO name, client IP, folder, and milter reply.

=item C<message_summary>, C<verdict_list>

Each message's first folder, From and Subject; and the same with its verdicts.

=item C<action_changes>

Messages whose action differs between two runs (C<before_run>, C<after_run>).

=back

=cut

my @SCHEMA = (
    q{CREATE TABLE IF NOT EXISTS messages (
        id          INTEGER PRIMARY KEY,
        sha256      TEXT    NOT NULL UNIQUE,
        size        INTEGER NOT NULL,
        header_size INTEGER NOT NULL,
        first_seen  INTEGER NOT NULL
    )},
    q{CREATE TABLE IF NOT EXISTS scans (
        id       INTEGER PRIMARY KEY,
        source   TEXT    NOT NULL,
        started  INTEGER NOT NULL,
        finished INTEGER
    )},
    q{CREATE TABLE IF NOT EXISTS locations (
        id         INTEGER PRIMARY KEY,
        message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
        source     TEXT    NOT NULL,
        folder     TEXT    NOT NULL,
        kind       TEXT    NOT NULL,
        path       TEXT    NOT NULL,
        key        TEXT    NOT NULL,
        offset     INTEGER NOT NULL,
        length     INTEGER NOT NULL,
        flags      TEXT    NOT NULL DEFAULT '',
        mtime      INTEGER NOT NULL,
        scan       INTEGER NOT NULL,
        UNIQUE (source, folder, key)
    )},
    q{CREATE INDEX IF NOT EXISTS locations_message ON locations(message_id)},
    q{CREATE TABLE IF NOT EXISTS mbox_files (
        source TEXT    NOT NULL,
        folder TEXT    NOT NULL,
        size   INTEGER NOT NULL,
        mtime  INTEGER NOT NULL,
        PRIMARY KEY (source, folder)
    )},
    q{CREATE TABLE IF NOT EXISTS headers (
        message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
        pos        INTEGER NOT NULL,
        name       TEXT    NOT NULL,
        value      TEXT    NOT NULL,
        decoded    TEXT,
        PRIMARY KEY (message_id, pos)
    ) WITHOUT ROWID},
    q{CREATE INDEX IF NOT EXISTS headers_name ON headers(name)},
    q{CREATE TABLE IF NOT EXISTS envelope (
        message_id  INTEGER PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
        mail_from   TEXT,
        rcpt_to     TEXT,
        helo        TEXT,
        client_ip   TEXT,
        client_host TEXT,
        derived     TEXT NOT NULL DEFAULT ''
    )},
    q{CREATE TABLE IF NOT EXISTS runs (
        id         INTEGER PRIMARY KEY,
        batch      INTEGER,
        label      TEXT,
        config     TEXT    NOT NULL,
        recipes    TEXT    NOT NULL,
        started    INTEGER NOT NULL,
        finished   INTEGER,
        milter_log TEXT
    )},
    q{CREATE TABLE IF NOT EXISTS results (
        run_id        INTEGER NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
        message_id    INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
        code          TEXT    NOT NULL,
        action        TEXT    NOT NULL,
        reply         TEXT,
        modifications TEXT,
        elapsed_ms    INTEGER,
        PRIMARY KEY (run_id, message_id)
    ) WITHOUT ROWID},
    q{CREATE INDEX IF NOT EXISTS results_action ON results(run_id, action)},
);

# The canned reports, as views anyone can query from sqlite3 too.  They are recreated on every connect, so they always match this code.
# Every report view carries scope ('batch' or 'run') and scope_id, so a report is a WHERE on those columns.
my %VIEWS = (

    # A message's verdict in a batch is the worst of its actions across the runs; in a run, its action.
    verdicts => q{
        SELECT 'batch' AS scope, u.batch AS scope_id, r.message_id,
               CASE WHEN SUM(r.action IN ('reject', 'tempfail', 'discard', 'quarantine')) > 0 THEN 'blocked'
                    WHEN SUM(r.action != 'accept') > 0 THEN 'error'
                    ELSE 'accept' END AS verdict
        FROM results r JOIN runs u ON u.id = r.run_id
        GROUP BY u.batch, r.message_id
        UNION ALL
        SELECT 'run', r.run_id, r.message_id,
               CASE WHEN r.action IN ('reject', 'tempfail', 'discard', 'quarantine') THEN 'blocked'
                    WHEN r.action != 'accept' THEN 'error'
                    ELSE 'accept' END
        FROM results r
    },
    message_summary => q{
        SELECT m.id AS message_id,
               (SELECT folder FROM locations WHERE message_id = m.id ORDER BY id LIMIT 1) AS folder,
               (SELECT COALESCE(decoded, value) FROM headers WHERE message_id = m.id AND name = 'from' ORDER BY pos LIMIT 1) AS "from",
               (SELECT COALESCE(decoded, value) FROM headers WHERE message_id = m.id AND name = 'subject' ORDER BY pos LIMIT 1) AS subject
        FROM messages m
    },
    verdict_counts => q{
        SELECT scope, scope_id, verdict, COUNT(*) AS messages FROM verdicts GROUP BY scope, scope_id, verdict
    },
    run_actions => q{
        SELECT u.batch, r.run_id, u.label, r.action, COUNT(*) AS messages
        FROM results r JOIN runs u ON u.id = r.run_id
        GROUP BY u.batch, r.run_id, r.action
    },
    folder_verdicts => q{
        SELECT v.scope, v.scope_id, l.folder, COUNT(DISTINCT v.message_id) AS messages,
               COUNT(DISTINCT CASE WHEN v.verdict = 'accept'  THEN v.message_id END) AS accepted,
               COUNT(DISTINCT CASE WHEN v.verdict = 'blocked' THEN v.message_id END) AS blocked,
               COUNT(DISTINCT CASE WHEN v.verdict = 'error'   THEN v.message_id END) AS errors
        FROM verdicts v JOIN locations l ON l.message_id = v.message_id
        GROUP BY v.scope, v.scope_id, l.folder
    },

    # How many messages of each verdict have each header, and what share of all messages of that verdict that is
    header_rates => q{
        WITH hv AS (SELECT DISTINCT v.scope, v.scope_id, v.verdict, v.message_id, h.name FROM verdicts v JOIN headers h ON h.message_id = v.message_id),
             counts AS (
                SELECT scope, scope_id, name,
                       SUM(verdict = 'accept') AS accept, SUM(verdict = 'blocked') AS blocked, SUM(verdict = 'error') AS error
                FROM hv GROUP BY scope, scope_id, name)
        SELECT c.scope, c.scope_id, c.name, c.accept, c.blocked, c.error,
               ROUND(100.0 * c.accept  / MAX(1, (SELECT messages FROM verdict_counts t WHERE t.scope = c.scope AND t.scope_id = c.scope_id AND t.verdict = 'accept')), 1)  AS pct_accept,
               ROUND(100.0 * c.blocked / MAX(1, (SELECT messages FROM verdict_counts t WHERE t.scope = c.scope AND t.scope_id = c.scope_id AND t.verdict = 'blocked')), 1) AS pct_blocked,
               ROUND(100.0 * c.error   / MAX(1, (SELECT messages FROM verdict_counts t WHERE t.scope = c.scope AND t.scope_id = c.scope_id AND t.verdict = 'error')), 1)   AS pct_error
        FROM counts c
    },
    header_values => q{
        SELECT v.scope, v.scope_id, v.verdict, h.name, COALESCE(h.decoded, h.value) AS value, COUNT(DISTINCT h.message_id) AS messages
        FROM verdicts v JOIN headers h ON h.message_id = v.message_id
        GROUP BY v.scope, v.scope_id, v.verdict, h.name, 5
    },
    sender_domains => q{
        SELECT v.scope, v.scope_id, v.verdict, lower(substr(e.mail_from, instr(e.mail_from, '@') + 1)) AS domain, COUNT(*) AS messages
        FROM verdicts v JOIN envelope e ON e.message_id = v.message_id
        WHERE e.mail_from LIKE '%@%'
        GROUP BY v.scope, v.scope_id, v.verdict, 4
    },
    helo_names => q{
        SELECT v.scope, v.scope_id, v.verdict, lower(e.helo) AS helo, COUNT(*) AS messages
        FROM verdicts v JOIN envelope e ON e.message_id = v.message_id
        GROUP BY v.scope, v.scope_id, v.verdict, 4
    },
    client_ips => q{
        SELECT v.scope, v.scope_id, v.verdict, e.client_ip, e.client_host, COUNT(*) AS messages
        FROM verdicts v JOIN envelope e ON e.message_id = v.message_id
        WHERE e.client_ip IS NOT NULL
        GROUP BY v.scope, v.scope_id, v.verdict, e.client_ip
    },
    reply_counts => q{
        SELECT 'batch' AS scope, u.batch AS scope_id, r.action, r.reply, COUNT(*) AS messages
        FROM results r JOIN runs u ON u.id = r.run_id
        WHERE r.action != 'accept'
        GROUP BY u.batch, r.action, r.reply
        UNION ALL
        SELECT 'run', r.run_id, r.action, r.reply, COUNT(*)
        FROM results r
        WHERE r.action != 'accept'
        GROUP BY r.run_id, r.action, r.reply
    },
    verdict_list => q{
        SELECT v.scope, v.scope_id, v.verdict, v.message_id AS id, s.folder, s."from", s.subject
        FROM verdicts v JOIN message_summary s ON s.message_id = v.message_id
    },
    action_changes => q{
        SELECT a.run_id AS before_run, b.run_id AS after_run, a.message_id AS id, s.folder, s.subject, a.action AS before, b.action AS after, b.reply
        FROM results a
        JOIN results b ON b.message_id = a.message_id AND b.action != a.action
        JOIN message_summary s ON s.message_id = a.message_id
    },
);

# Views which others are built on must be created first
my @VIEW_ORDER = ( qw{verdicts message_summary verdict_counts}, grep { !m/^(?:verdicts|message_summary|verdict_counts)\z/ } sort keys %VIEWS );

# Commit this often while indexing, so an interrupted index keeps most of its work
my $COMMIT_EVERY = 1000;

=head1 CONSTRUCTOR

=head2 new( db => $path )

Opens (creating if need be) the corpus database.

=cut

sub new {
    my ( $class, %args ) = @_;
    die "db is required" unless $args{db};

    my $dbh = DBI->connect(
        "dbi:SQLite:dbname=$args{db}",
        '', '',
        {
            RaiseError => 1,
            PrintError => 0,
            AutoCommit => 1,

            # Replay forks workers, which must not tear down our handle on exit
            AutoInactiveDestroy => 1,
        }
    );
    $dbh->do('PRAGMA journal_mode = WAL');
    $dbh->do('PRAGMA synchronous = NORMAL');
    $dbh->do('PRAGMA foreign_keys = ON');
    $dbh->do($_) for @SCHEMA;

    # View names and bodies are the constants in %VIEWS; identifiers cannot be bound
    $dbh->do("DROP VIEW IF EXISTS $_")       for reverse @VIEW_ORDER;    ## no critic (ValuesAndExpressions::PreventSQLInjection)
    $dbh->do("CREATE VIEW $_ AS $VIEWS{$_}") for @VIEW_ORDER;            ## no critic (ValuesAndExpressions::PreventSQLInjection)

    return bless( { %args, dbh => $dbh }, $class );
}

=head2 dbh

The L<DBI> handle on the corpus database.

=cut

sub dbh { $_[0]->{dbh} }

=head1 FUNCTIONS

=head2 ($fields, $body) = split_message($raw)

Split a raw message the way an MTA would before handing it to a milter.

C<$fields> is an arrayref of C<[ $name, $value ]> in the order they appear.
The value has the single space after the colon removed, and keeps any folding (with CR removed) as a milter would see it.
Lines in the header which are not a header field are dropped.

C<$body> is everything after the blank line which ends the header.

=cut

sub split_message {
    my ($raw) = @_;
    my ( $head, $body ) = split( /\r?\n\r?\n/, $raw, 2 );
    $body //= '';

    my @fields;
    foreach my $line ( split( /\r?\n(?![ \t])/, $head ) ) {
        my ( $name, $value ) = $line =~ m/^([^:\s]+):[ \t]?(.*)\z/s or next;
        $value =~ s/\r\n/\n/g;
        push @fields, [ $name, $value ];
    }
    return ( \@fields, $body );
}

=head1 METHODS

=head2 index_source($root, [$progress])

Index every Maildir folder and mbox file under C<$root>.

A directory with a C<cur> directory in it is a Maildir.
Any other regular file which starts with C<From > is an mbox.

Indexing is incremental.
A Maildir file whose path, size and mtime have not changed is not read again, and neither is an unchanged mbox file.
A Maildir file which was only renamed (because its flags changed) is recognized as the same message.
Locations which are no longer under C<$root> are dropped, and so are messages left with no location.

C<$progress>, if given, is called with a hashref of counts every so often.

Returns a hashref of counts: C<files> seen, C<read>, C<new> messages, C<duplicates>, C<skipped> (unchanged), C<gone>.

=cut

sub index_source {
    my ( $self, $root, $progress ) = @_;
    $root = File::Spec->rel2abs($root);
    die "No such directory $root" unless -d $root;

    my $dbh = $self->dbh();
    $dbh->do( 'INSERT INTO scans (source, started) VALUES (?, ?)', undef, $root, time );
    my $scan = $dbh->last_insert_id( '', '', 'scans', 'id' );

    my %stats = map { $_ => 0 } qw{files read new duplicates skipped gone};
    $self->{stats}    = \%stats;
    $self->{progress} = $progress;
    $self->{pending}  = 0;
    $self->{scan}     = $scan;
    $self->{source}   = $root;

    # Everything we already know about this source, so unchanged files cost one stat()
    $self->{known} = $dbh->selectall_hashref(
        q{SELECT folder || char(0) || key AS k, id, path, length, mtime FROM locations WHERE source = ?},
        'k', undef, $root
    );

    $dbh->begin_work();
    File::Find::find(
        {
            no_chdir   => 1,
            preprocess => sub { sort @_ },
            wanted     => sub { $self->_found( $root, $File::Find::name ) },
        },
        $root
    );

    $stats{gone} = $dbh->do( 'DELETE FROM locations WHERE source = ? AND scan < ?', undef, $root, $scan ) + 0;
    $dbh->do('DELETE FROM messages WHERE id NOT IN (SELECT message_id FROM locations)');
    $dbh->do( 'UPDATE scans SET finished = ? WHERE id = ?', undef, time, $scan );
    $dbh->commit();

    delete @$self{qw{known stats progress pending scan source}};
    return \%stats;
}

sub _found {
    my ( $self, $root, $path ) = @_;

    if ( -d $path ) {
        my ($leaf) = $path =~ m{([^/]+)\z};

        # Maildir internals, and dovecot's index directories, are never folders themselves
        if ( $path ne $root && ( any { $leaf eq $_ } qw{cur new tmp .imap} ) ) {
            $File::Find::prune = 1;
            return;
        }
        $self->_index_maildir( $root, $path ) if -d "$path/cur";
        return;
    }

    # Empty files are skipped, and so are FIFOs and devices, whose size is 0 too; reading a FIFO would hang
    return unless -s $path;
    open( my $fh, '<', $path ) or return;
    read( $fh, my $magic, 5 );
    close $fh;
    return unless defined $magic && $magic eq 'From ';
    $self->_index_mbox( $root, $path );
}

sub _folder_name {
    my ( $root, $path ) = @_;
    return '.' if $path eq $root;
    return File::Spec->abs2rel( $path, $root );
}

sub _index_maildir {
    my ( $self, $root, $dir ) = @_;
    my $folder = _folder_name( $root, $dir );

    foreach my $sub (qw{cur new}) {
        opendir( my $dh, "$dir/$sub" ) or next;
        foreach my $file ( sort grep { !m/^\./ } readdir($dh) ) {
            my $path = "$dir/$sub/$file";
            my ( $size, $mtime ) = ( stat($path) )[ 7, 9 ];
            next if !defined $size || -d _;
            $self->{stats}{files}++;

            # The unique part of a Maildir name survives the renames that flag changes make
            my ( $key, $flags ) = $file =~ m/^([^:]+)(?::2,(.*))?\z/;
            $flags //= '';

            my $known = $self->{known}{"$folder\0$key"};
            if ( $known && $known->{length} == $size && $known->{mtime} == $mtime ) {
                $self->dbh->do( 'UPDATE locations SET path = ?, flags = ?, scan = ? WHERE id = ?', undef, $path, $flags, $self->{scan}, $known->{id} );
                $self->{stats}{skipped}++;
                $self->_tick();
                next;
            }

            my $raw = read_bytes( $path, 0, $size ) // next;
            $self->_store(
                $raw,
                {
                    folder => $folder,
                    kind   => 'maildir',
                    path   => $path,
                    key    => $key,
                    offset => 0,
                    length => $size,
                    flags  => $flags,
                    mtime  => $mtime,
                }
            );
        }
    }
    return;
}

sub _index_mbox {
    my ( $self, $root, $path ) = @_;
    my $folder = _folder_name( $root, $path );
    my ( $size, $mtime ) = ( stat($path) )[ 7, 9 ];
    my $dbh = $self->dbh();

    my ($known) = $dbh->selectrow_array( 'SELECT 1 FROM mbox_files WHERE source = ? AND folder = ? AND size = ? AND mtime = ?', undef, $self->{source}, $folder, $size, $mtime );
    if ($known) {
        my $n = $dbh->do( 'UPDATE locations SET scan = ? WHERE source = ? AND folder = ?', undef, $self->{scan}, $self->{source}, $folder );
        $self->{stats}{files}   += $n;
        $self->{stats}{skipped} += $n;
        $self->_tick();
        return;
    }

    my $mgr  = Mail::Box::Manager->new();
    my $mbox = $mgr->open(
        folder    => $path,
        type      => 'mbox',
        access    => 'r',
        lock_type => 'NONE',
        extract   => 'LAZY',
      )
      or do {
        warn "Could not open $path as an mbox, skipping\n";
        return;
      };

    foreach my $message ( $mbox->messages ) {
        my ( $begin, $end ) = $message->fileLocation;
        my $raw = read_bytes( $path, $begin, $end - $begin ) // next;

        # The range includes the From_ separator line, and the blank line before the next one
        my $offset = $begin;
        if ( $raw =~ s/\AFrom [^\n]*\n// ) {
            $offset += $+[0];
        }
        $raw =~ s/\n\n\z/\n/;

        # UW-IMAP keeps folder metadata in a fake first message
        next if $raw =~ m/^X-IMAP(?:base)?:/mi && index( $raw, 'FOLDER INTERNAL DATA' ) >= 0;

        $self->{stats}{files}++;
        $self->_store(
            $raw,
            {
                folder => $folder,
                kind   => 'mbox',
                path   => $path,
                key    => $offset,
                offset => $offset,
                length => length($raw),
                flags  => ( $message->label('seen') ? 'S' : '' ) . ( $message->label('deleted') ? 'T' : '' ),
                mtime  => $mtime,
            }
        );
    }
    $mbox->close( write => 'NEVER' );

    $dbh->do( 'INSERT OR REPLACE INTO mbox_files (source, folder, size, mtime) VALUES (?, ?, ?, ?)', undef, $self->{source}, $folder, $size, $mtime );
    return;
}

# Add a message (if we do not already have it) and where we found it
sub _store {
    my ( $self, $raw, $loc ) = @_;
    my $dbh = $self->dbh();
    $self->{stats}{read}++;

    my $sha = sha256_hex($raw);
    my ( $fields, $body ) = split_message($raw);

    my $inserted = $dbh->do( 'INSERT OR IGNORE INTO messages (sha256, size, header_size, first_seen) VALUES (?, ?, ?, ?)', undef, $sha, length($raw), length($raw) - length($body), time );
    my ($id) = $dbh->selectrow_array( 'SELECT id FROM messages WHERE sha256 = ?', undef, $sha );

    if ( $inserted > 0 ) {
        $self->{stats}{new}++;
        $self->_store_headers( $id, $fields );
    }
    else {
        $self->{stats}{duplicates}++;
    }

    $dbh->do(
        q{INSERT INTO locations (message_id, source, folder, kind, path, key, offset, length, flags, mtime, scan)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (source, folder, key) DO UPDATE SET
            message_id = excluded.message_id, path = excluded.path, offset = excluded.offset, length = excluded.length,
            flags = excluded.flags, mtime = excluded.mtime, scan = excluded.scan},
        undef, $id, $self->{source}, @$loc{qw{folder kind path key offset length flags mtime}}, $self->{scan}
    );
    $self->_tick();
    return $id;
}

sub _store_headers {
    my ( $self, $id, $fields ) = @_;
    my $dbh = $self->dbh();
    my $sth = $dbh->prepare_cached('INSERT INTO headers (message_id, pos, name, value, decoded) VALUES (?, ?, ?, ?, ?)');

    my $pos = 0;
    foreach my $field (@$fields) {
        my ( $name, $value ) = @$field;
        $value =~ s/\n(?=[ \t])//g;
        my $decoded;
        if ( $value =~ m/=\?[^?]+\?[bqBQ]\?/ ) {
            $decoded = eval { Encode::encode( 'UTF-8', Encode::decode( 'MIME-Header', $value ) ) };
        }
        $sth->execute( $id, $pos++, lc($name), $value, $decoded );
    }

    my $env = derive_envelope($fields);
    $dbh->do( 'INSERT OR REPLACE INTO envelope (message_id, mail_from, rcpt_to, helo, client_ip, client_host, derived) VALUES (?, ?, ?, ?, ?, ?, ?)', undef, $id, @$env{qw{mail_from rcpt_to helo client_ip client_host derived}} );
    return;
}

# Commit in batches and tell the caller how it is going
sub _tick {
    my $self = shift;
    return if ++$self->{pending} < $COMMIT_EVERY;
    $self->{pending} = 0;
    $self->dbh->commit();
    $self->dbh->begin_work();
    $self->{progress}->( $self->{stats} ) if $self->{progress};
    return;
}

=head2 read_bytes($path, $offset, $length)

Read a byte range from a file, as stored in C<locations>.  Returns undef (with a warning) if it cannot.

=cut

sub read_bytes {
    my ( $path, $offset, $length ) = @_;
    open( my $fh, '<:raw', $path ) or do {
        warn "Could not read $path: $!\n";
        return;
    };
    seek( $fh, $offset, SEEK_SET );
    my $got = read( $fh, my $buf, $length );
    return unless defined $got && $got == $length;
    return $buf;
}

=head2 derive_envelope(\@fields)

Work out the SMTP envelope and connection a message most likely arrived with, given its fields as from C<split_message>.

=over 4

=item C<mail_from>

From Return-Path.  An empty Return-Path (a bounce) is kept as the empty string.

=item C<rcpt_to>

From Delivered-To, else X-Original-To.

=item C<helo>, C<client_ip>, C<client_host>

From the topmost Received header which says it came from a public IP address.
That is the hop where the mail entered our MX, and so what the milter would have seen.

=back

Fields which could not be found are guessed (From, To, 'unknown') and named in C<derived>.

=cut

sub derive_envelope {
    my ($fields) = @_;
    my %first;
    my @received;
    foreach my $field (@$fields) {
        my $name  = lc( $field->[0] );
        my $value = $field->[1];
        $value =~ s/\n(?=[ \t])//g;
        push @received, $value if $name eq 'received';
        $first{$name} //= $value;
    }

    my ( %env, @derived );

    if ( defined $first{'return-path'} ) {
        ( $env{mail_from} ) = $first{'return-path'} =~ m/<([^>]*)>/;
        $env{mail_from} //= _first_address( $first{'return-path'} ) // '';
    }
    else {
        $env{mail_from} = _first_address( $first{from} );
        push @derived, 'mail_from';
    }

    $env{rcpt_to} = _first_address( $first{'delivered-to'} // $first{'x-original-to'} );
    if ( !defined $env{rcpt_to} ) {
        $env{rcpt_to} = _first_address( $first{to} );
        push @derived, 'rcpt_to';
    }

    foreach my $received (@received) {
        my ( $helo, $comment ) = $received          =~ m/^\s*from\s+(\S+)\s*(?:\(([^)]*)\))?/i        or next;
        my ( $host, $ip )      = ( $comment // '' ) =~ m/([^\s\[]*)\s*\[(?:IPv6:)?([0-9A-Fa-f:.]+)\]/ or next;
        next unless _is_public_ip($ip);
        @env{qw{helo client_ip client_host}} = ( $helo, $ip, $host || undef );
        last;
    }
    if ( !defined $env{client_ip} ) {
        $env{helo} = 'unknown';
        push @derived, 'helo', 'client_ip';
    }

    $env{derived} = join( ',', @derived );
    return \%env;
}

sub _first_address {
    my ($value) = @_;
    return unless defined $value;
    my ($addr) = Mail::Address->parse($value);
    return $addr ? $addr->address : undef;
}

sub _is_public_ip {
    my ($ip) = @_;
    if ( $ip =~ m/^(\d+)\.(\d+)\.\d+\.\d+\z/ ) {
        my ( $x, $y ) = ( $1, $2 );
        return 0 if $x == 0 || $x == 10 || $x == 127;
        return 0 if $x == 169 && $y == 254;
        return 0 if $x == 172 && $y >= 16 && $y <= 31;
        return 0 if $x == 192 && $y == 168;
        return 0 if $x == 100 && $y >= 64 && $y <= 127;
        return 1;
    }
    return 0 if index( $ip, ':' ) < 0;
    return 0 if $ip eq '::1' || $ip =~ m/^(?:fe[89ab]|f[cd])/i;
    return 1;
}

=head2 raw($message_id)

The raw content of a message, read from the first place it was found.

=cut

sub raw {
    my ( $self, $id ) = @_;
    my ( $path, $offset, $length ) = $self->dbh->selectrow_array( 'SELECT path, offset, length FROM locations WHERE message_id = ? ORDER BY id LIMIT 1', undef, $id );
    return unless defined $path;
    return read_bytes( $path, $offset, $length );
}

=head2 messages(%filter)

Returns an arrayref of hashrefs, one per message to replay, ordered by id:
C<id>, C<path>, C<offset>, C<length>, and the C<envelope> columns.

=over 4

=item C<folder>

Only messages with a location whose folder matches this SQLite GLOB, e.g. C<*spam*>.

=item C<limit>

At most this many.

=back

=cut

sub messages {
    my ( $self, %filter ) = @_;

    # SQLite reads a negative LIMIT as no limit
    return $self->dbh->selectall_arrayref(
        q{SELECT m.id, l.path, l.offset, l.length, e.mail_from, e.rcpt_to, e.helo, e.client_ip, e.client_host
          FROM messages m
          JOIN locations l ON l.id = (SELECT MIN(id) FROM locations WHERE message_id = m.id)
          LEFT JOIN envelope e ON e.message_id = m.id
          WHERE :folder IS NULL OR EXISTS (SELECT 1 FROM locations f WHERE f.message_id = m.id AND f.folder GLOB :folder)
          ORDER BY m.id LIMIT :limit},
        { Slice => {} }, $filter{folder}, $filter{limit} || -1
    );
}

=head2 start_run(%args)

Record the start of a replay.  Takes C<label>, C<config> (the text of the configuration), C<recipes> (a JSON description of them), and C<batch>.
Returns the run id.  A run with no batch is its own batch.

=cut

sub start_run {
    my ( $self, %args ) = @_;
    my $dbh = $self->dbh();
    $dbh->do( 'INSERT INTO runs (batch, label, config, recipes, started) VALUES (?, ?, ?, ?, ?)', undef, $args{batch}, $args{label}, $args{config}, $args{recipes}, time );
    my $id = $dbh->last_insert_id( '', '', 'runs', 'id' );
    $dbh->do( 'UPDATE runs SET batch = ? WHERE id = ?', undef, $id, $id ) unless $args{batch};
    return $id;
}

=head2 record_results($run_id, @results)

Store replay results, each a hashref of C<message_id>, C<code>, C<action>, C<reply>, C<modifications>, C<elapsed_ms>.

=cut

sub record_results {
    my ( $self, $run, @results ) = @_;
    my $dbh = $self->dbh();
    my $sth = $dbh->prepare_cached('INSERT OR REPLACE INTO results (run_id, message_id, code, action, reply, modifications, elapsed_ms) VALUES (?, ?, ?, ?, ?, ?, ?)');
    $dbh->begin_work();
    $sth->execute( $run, @$_{qw{message_id code action reply modifications elapsed_ms}} ) for @results;
    $dbh->commit();
    return scalar(@results);
}

=head2 finish_run($run_id, $milter_log)

=cut

sub finish_run {
    my ( $self, $run, $log ) = @_;
    $self->dbh->do( 'UPDATE runs SET finished = ?, milter_log = ? WHERE id = ?', undef, time, $log, $run );
    return;
}

# Each report is a view, the columns shown from it, and whether it is filtered by verdict
my %REPORTS = (
    folders => { view => 'folder_verdicts', columns => [qw{folder messages accepted blocked errors}] },
    values  => { view => 'header_values',   columns => [qw{value messages}],                 verdict => 1 },
    senders => { view => 'sender_domains',  columns => [qw{domain messages}],                verdict => 1 },
    helo    => { view => 'helo_names',      columns => [qw{helo messages}],                  verdict => 1 },
    ips     => { view => 'client_ips',      columns => [qw{client_ip client_host messages}], verdict => 1 },
    replies => { view => 'reply_counts',    columns => [qw{action reply messages}] },
    list    => { view => 'verdict_list',    columns => [ qw{id folder}, '"from"', 'subject' ], verdict => 1, order => 'id' },
);
my %VERDICTS = map { $_ => 1 } qw{accept blocked error};

=head1 REPORTS

=head2 ($columns, $rows) = report($name, %opts)

Run one of the canned reports.

Every report is about one set of verdicts (see C<verdicts> above): by default the latest batch of runs, or C<run> or C<batch> to pick another.

Options: C<run>, C<batch>, C<limit> (default 25), C<verdict> (default C<accept>) for the reports that list mail of one verdict, C<header> for C<values>, and C<runs> (two run ids) for C<diff>.

=over 4

=item C<summary>

Verdict counts for the batch, and action counts for each run in it.

=item C<folders>

Verdicts by folder.

=item C<headers>

Header names by how many messages of the verdict have them, against how many blocked messages do.
Headers that are common in what got through but rare in what was blocked are good recipe material.

=item C<values>

The most common values of one header (C<header> option) for the verdict.

=item C<senders>

Envelope sender domains for the verdict.

=item C<helo>

HELO names for the verdict.

=item C<ips>

Client IPs for the verdict.

=item C<replies>

What the milter said when it blocked mail, with counts.

=item C<list>

Messages of the verdict: id, folder, From, Subject.

=item C<diff>

Messages whose action differs between two runs (C<runs> option).

=back

=cut

sub report {
    my ( $self, $name, %opts ) = @_;
    $opts{limit}   ||= 25;
    $opts{verdict} ||= 'accept';
    die "No such verdict '$opts{verdict}'.  Try one of: " . join( ', ', sort keys %VERDICTS ) . "\n" unless $VERDICTS{ $opts{verdict} };

    if ( $name eq 'diff' ) {
        die "diff needs two run ids\n" unless ref $opts{runs} eq 'ARRAY' && @{ $opts{runs} } == 2;
        return $self->query( 'SELECT id, folder, subject, before, after, reply FROM action_changes WHERE before_run = ? AND after_run = ? ORDER BY id LIMIT ?', @{ $opts{runs} }, $opts{limit} );
    }

    my ( $scope, $scope_id ) = $self->_scope(%opts);
    die "No runs to report on.  Replay something first.\n" unless $scope_id;

    if ( $name eq 'summary' ) {
        return $self->query(
            q{SELECT 'batch' AS run, NULL AS label, verdict AS action, messages FROM verdict_counts WHERE scope = ? AND scope_id = ?
              UNION ALL
              SELECT run_id, label, action, messages FROM run_actions WHERE } . ( $scope eq 'batch' ? 'batch' : 'run_id' ) . ' = ?',
            $scope, $scope_id, $scope_id
        );
    }

    if ( $name eq 'headers' ) {

        # The verdict names a column, and has been checked against %VERDICTS above; identifiers cannot be bound
        my $v = $opts{verdict};
        return $self->query(    ## no critic (ValuesAndExpressions::PreventSQLInjection)
            "SELECT name, $v AS messages, pct_$v AS pct, pct_blocked FROM header_rates WHERE scope = ? AND scope_id = ? AND $v > 0 ORDER BY $v DESC, name LIMIT ?", $scope, $scope_id, $opts{limit}
        );
    }

    my $report = $REPORTS{$name} or die "No such report '$name'.  Try one of: " . join( ', ', sort( qw{summary headers diff}, keys(%REPORTS) ) ) . "\n";
    die "The values report needs a header\n" if $name eq 'values' && !$opts{header};

    my @where = ( 'scope = ?', 'scope_id = ?' );
    my @bind  = ( $scope, $scope_id );
    if ( $report->{verdict} ) {
        push @where, 'verdict = ?';
        push @bind,  $opts{verdict};
    }
    if ( $name eq 'values' ) {
        push @where, 'name = lower(?)';
        push @bind,  $opts{header};
    }
    my $sql = sprintf( 'SELECT %s FROM %s WHERE %s ORDER BY %s LIMIT ?', join( ', ', @{ $report->{columns} } ), $report->{view}, join( ' AND ', @where ), $report->{order} // 'messages DESC' );
    return $self->query( $sql, @bind, $opts{limit} );
}

# Which verdicts a report is about: the run asked for, the batch asked for, or the latest batch
sub _scope {
    my ( $self, %opts ) = @_;
    return ( run   => $opts{run} ) if $opts{run};
    return ( batch => $opts{batch} // scalar $self->dbh->selectrow_array('SELECT batch FROM runs ORDER BY id DESC LIMIT 1') );
}

=head2 ($columns, $rows) = query($sql, @bind)

Run any query against the corpus.  A single hashref of bind values binds by name (C<:name>).

=cut

sub query {
    my ( $self, $sql, @bind ) = @_;
    my $sth = $self->dbh->prepare($sql);
    if ( @bind == 1 && ref $bind[0] eq 'HASH' ) {
        $sth->bind_param( $_, $bind[0]{$_} ) for keys( %{ $bind[0] } );
        $sth->execute();
    }
    else {
        $sth->execute(@bind);
    }
    return ( $sth->{NAME}, $sth->fetchall_arrayref() );
}

=head2 verdict_messages(%opts)

The ids of the messages with a verdict (default C<accept>) in the chosen runs.  Takes the same options as C<report>.

=cut

sub verdict_messages {
    my ( $self, %opts ) = @_;
    my ( undef, $rows ) = $self->report( 'list', %opts, limit => -1 );
    return map { $_->[0] } @$rows;
}

1;
