use 5.014;
use strict;
use warnings FATAL => 'all';
use re '/aa';

use FindBin::libs;
use Test2::V0;
use Test2::Plugin::NoWarnings;

use Milter::Corpus qw{split_message};
use CorpusTest     qw{fixture_corpus};

my $fx     = fixture_corpus();
my $corpus = $fx->{corpus};
my $source = $fx->{source};

subtest 'split_message' => sub {
    my ( $fields, $body ) = split_message("A: one\r\nB:  two\r\n\tfolded\r\nnot a header\r\nC:\r\n\r\nbody\r\n\r\nmore");
    is( $fields, [ [ 'A', 'one' ], [ 'B', " two\n\tfolded" ], [ 'C', '' ] ], 'fields split, folding kept, junk dropped' );
    is( $body,   "body\r\n\r\nmore",                                         'body is everything after the first blank line' );

    ( $fields, $body ) = split_message("A: headers only\n");
    is( [ $fields, $body ], [ [ [ 'A', 'headers only' ] ], '' ], 'a message with no body has an empty one' );
};

subtest 'index_source' => sub {
    like( dies { $corpus->index_source("$source/bogus") }, qr/No such directory/, 'a missing source dies' );

    my $stats = $corpus->index_source($source);
    is( $stats->{files},      6, 'every message file and mbox message counted, placeholder skipped' );
    is( $stats->{new},        5, 'duplicate copies collapse to one message' );
    is( $stats->{duplicates}, 1, 'the copy in the spam folder is a duplicate' );

    my ( undef, $rows ) = $corpus->query('SELECT folder, kind, flags FROM locations ORDER BY folder, key');
    is(
        $rows,
        [ [qw{. maildir S}], [ qw{. maildir}, '' ], [qw{.INBOX.spam maildir ST}], [qw{.INBOX.spam maildir S}], [qw{Trash mbox S}], [ qw{Trash mbox}, '' ] ],
        'folders, kinds and flags recorded'
    );

    $stats = $corpus->index_source($source);
    is( $stats->{skipped}, 6, 'nothing is read again when nothing changed' );
    is( $stats->{new},     0, 'no new messages the second time' );

    my ($spam) = glob("'$source/.INBOX.spam/cur/1700000003*'");
    rename( $spam, "$source/.INBOX.spam/cur/1700000003.M4P4.test:2,RS" ) or die "rename: $!";
    $stats = $corpus->index_source($source);
    is( $stats->{skipped}, 6, 'a flag change rename is not read again' );
    is( $stats->{gone},    0, '... nor seen as a deletion' );
    my ($flags) = $corpus->dbh->selectrow_array(q{SELECT flags FROM locations WHERE key = '1700000003.M4P4.test'});
    is( $flags, 'RS', '... but its flags are updated' );
};

subtest 'raw' => sub {
    my ($id) = $corpus->dbh->selectrow_array(q{SELECT message_id FROM headers WHERE name = 'subject' AND value = 'Trash one'});
    my $raw = $corpus->raw($id);
    like( $raw, qr/\AReturn-Path: <sender\@test.test>\n/, 'mbox message starts after the From_ line' );
    like( $raw, qr/^>From the start/m,                    'quoted From lines are kept as they are' );
    like( $raw, qr/as mbox requires\.\n\z/,               'the separating blank line is not part of the message' );
    unlike( $raw, qr/Trash two/, 'nor is the next message' );

    is( $corpus->raw(99999), undef, 'no such message' );
};

subtest 'headers & envelope' => sub {
    my ( undef, $rows ) = $corpus->query(q{SELECT decoded FROM headers WHERE name = 'subject' AND decoded IS NOT NULL});
    is( $rows, [ ["Best deals \x{e2}\x{9c}\x{85}"] ], 'encoded words decoded, as UTF-8' );

    ( undef, $rows ) = $corpus->query(
        q{SELECT e.mail_from, e.rcpt_to, e.helo, e.client_ip, e.client_host, e.derived
          FROM envelope e JOIN headers h ON h.message_id = e.message_id AND h.name = 'message-id'
          ORDER BY h.value}
    );
    is(
        $rows,
        [
            [ qw{sender@test.test rcpt@test.test mail.test.test 192.0.2.10 relay.test.test}, '' ],
            [ qw{absender@test.test empfaenger@test.test unknown}, undef, undef, 'mail_from,rcpt_to,helo,client_ip' ],
            [ qw{bulk@test.test rcpt@test.test bulk.test.test 198.51.100.7 unknown}, '' ],
        ],
        'envelope from Return-Path, Delivered-To and the first public Received hop, else guessed and flagged'
    );

    my $env = Milter::Corpus::derive_envelope( [ [ 'Return-Path', '<>' ], [ 'Received', 'from a (b [10.1.2.3]) by c' ], [ 'Received', "from d\n\t(e [IPv6:2001:db8::1]) by f" ] ] );
    is( [ @$env{qw{mail_from helo client_ip client_host}} ], [ '', qw{d 2001:db8::1 e} ], 'null sender kept, private hops skipped, IPv6 and folded Received read' );
};

subtest 'messages' => sub {
    is( scalar( @{ $corpus->messages() } ), 5, 'all messages' );
    is( scalar( @{ $corpus->messages( folder => '*spam*' ) } ), 2, 'filtered by folder glob' );
    is( scalar( @{ $corpus->messages( limit  => 2 ) } ),        2, 'limited' );
};

subtest 'reports' => sub {
    like( dies { $corpus->report('summary') }, qr/No runs to report on/, 'nothing to report before any run' );

    my %id     = map { $_->[1] => $_->[0] } @{ $corpus->dbh->selectall_arrayref(q{SELECT message_id, COALESCE(decoded, value) FROM headers WHERE name = 'subject'}) };
    my $deals  = "Best deals \x{e2}\x{9c}\x{85}";
    my $record = sub {
        my ( $run, %action ) = @_;
        $corpus->record_results( $run, map { { message_id => $id{$_}, code => 'x', action => $action{$_} // 'accept', reply => ( $action{$_} ? "no $_" : undef ) } } keys(%id) );
    };

    my $first = $corpus->start_run( label => 'one', config => '', recipes => '{}' );
    $record->( $first, 'Ihre Bestellung' => 'tempfail' );
    my $second = $corpus->start_run( label => 'two', batch => $first, config => '', recipes => '{}' );
    $record->( $second, $deals => 'reject', 'Trash two' => 'timeout' );

    my ( $cols, $rows ) = $corpus->report('summary');
    my %batch = map { $_->[2] => $_->[3] } grep { $_->[0] eq 'batch' } @$rows;
    is( \%batch, { accept => 2, blocked => 2, error => 1 }, 'a batch blocks what any run blocked, and errors what any run could not finish' );

    ( undef, $rows ) = $corpus->query( q{SELECT verdict, messages FROM verdict_counts WHERE scope = 'batch' AND scope_id = ? ORDER BY verdict}, $first );
    is( $rows, [ [ 'accept', 2 ], [ 'blocked', 2 ], [ 'error', 1 ] ], 'the views can be queried directly' );
    like( dies { $corpus->report( 'summary', verdict => 'bogus' ) }, qr/No such verdict 'bogus'/, 'unknown verdict dies' );

    ( $cols, $rows ) = $corpus->report( 'summary', run => $first );
    %batch = map { $_->[2] => $_->[3] } grep { $_->[0] eq 'batch' } @$rows;
    is( \%batch, { accept => 4, blocked => 1 }, 'one run on its own' );

    ( $cols, $rows ) = $corpus->report( 'headers', limit => 100 );
    my %headers = map { $_->[0] => $_ } @$rows;
    is( $headers{'return-path'}[1], 2, 'headers counts accepted messages with the header' );
    ok( !$headers{'list-unsubscribe'}, '... and leaves out headers only blocked mail had' );

    ( $cols, $rows ) = $corpus->report( 'values', header => 'Subject', verdict => 'blocked' );
    is( [ sort map { $_->[0] } @$rows ], [ $deals, 'Ihre Bestellung' ], 'values of a header for a verdict, decoded' );
    like( dies { $corpus->report('values') }, qr/needs a header/, 'values without a header dies' );

    ( $cols, $rows ) = $corpus->report('folders');
    my ($trash) = grep { $_->[0] eq 'Trash' } @$rows;
    is( $trash, [ 'Trash', 2, 1, 0, 1 ], 'folders report' );

    ( $cols, $rows ) = $corpus->report( 'senders', verdict => 'blocked' );
    is( [ map { $_->[0] } @$rows ], ['test.test'], 'senders by domain' );

    ( $cols, $rows ) = $corpus->report('replies');
    is( [ sort map { $_->[1] } @$rows ], [ "no $deals", 'no Ihre Bestellung', 'no Trash two' ], 'replies of everything not accepted' );

    ( $cols, $rows ) = $corpus->report('list');
    is( $cols,          [qw{id folder from subject}], 'list columns' );
    is( scalar(@$rows), 2,                            'list of accepted mail' );

    like( dies { $corpus->report('bogus') }, qr/No such report 'bogus'/, 'unknown report dies' );

    my $third = $corpus->start_run( label => 'three', config => '', recipes => '{}' );
    $record->( $third, 'Quarterly report' => 'reject' );
    ( $cols, $rows ) = $corpus->report( 'diff', runs => [ $first, $third ] );
    is( [ sort { $a->[0] cmp $b->[0] } map { [ @$_[ 2, 3, 4 ] ] } @$rows ], [ [ 'Ihre Bestellung', 'tempfail', 'accept' ], [ 'Quarterly report', 'accept', 'reject' ] ], 'diff lists changed actions' );
    like( dies { $corpus->report( 'diff', runs => [$first] ) }, qr/two run ids/, 'diff needs two runs' );

    ( $cols, $rows ) = $corpus->report('summary');
    is( scalar( grep { $_->[0] eq $third } @$rows ), 2, 'the latest batch is reported by default' );

    is( [ $corpus->verdict_messages( run => $third ) ], [ grep { $_ != $id{'Quarterly report'} } sort { $a <=> $b } values(%id) ], 'verdict_messages gives ids of the accepted mail' );
};

done_testing();

__END__

=head1 DESCRIPTION

L<Milter::Corpus>: indexing the fixture mail in F<t/corpus>, reading it back, envelope derivation, and the reports over recorded results.

=cut
