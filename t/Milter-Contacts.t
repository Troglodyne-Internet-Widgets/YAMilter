use 5.014;
use strict;
use warnings FATAL => 'all';
use re '/aa';

use FindBin::libs;
use File::Path qw{make_path};
use File::Temp;
use Test2::V0;
use Test2::Plugin::NoWarnings;

use Milter::Contacts;
use CorpusTest qw{write_file};

my $tmp = File::Temp->newdir();

subtest 'domain' => sub {
    is( Milter::Contacts::domain('Someone@Mail.Example.Test'), 'example.test',  'last two labels, lowercased' );
    is( Milter::Contacts::domain('a@shop.example.co.uk'),      'example.co.uk', 'three under a second level suffix' );
    is( Milter::Contacts::domain('<a@test.test>'),             'test.test',     'angle brackets ignored' );
    is( Milter::Contacts::domain('no-at-sign'),                '',              'nothing without a domain' );
};

subtest 'learn, known, sent' => sub {
    my $contacts = Milter::Contacts->new( file => "$tmp/contacts.db" );
    ok( !$contacts->known('bob@acme.test'), 'nobody is known to begin with' );

    $contacts->learn( addresses => [ qw{<Bob@Acme.Test> friend@gmail.com colleague@ours.test}, 'not an address' ], message_ids => ['<ABC@ours.test>'] );
    ok( $contacts->known('bob@acme.test'),     'an address written to is known, whatever its case' );
    ok( $contacts->known('alice@acme.test'),   'so is anyone else at its domain' );
    ok( $contacts->known('x@sales.acme.test'), '... or under it' );
    ok( $contacts->known('friend@gmail.com'),  'an address at a shared domain is known' );
    ok( !$contacts->known('other@gmail.com'),  '... but nobody else there' );

    ok( $contacts->known('colleague@ours.test'), 'our own domain\'s addresses are known by address' );
    ok( !$contacts->known( 'forged@ours.test',   'mx.ours.test' ), '... but not by domain when told it is ours' );
    ok( $contacts->known( 'colleague@ours.test', 'mx.ours.test' ), '... even then, by exact address' );

    ok( $contacts->sent('abc@ours.test'),  'a sent Message-ID, brackets and case aside' );
    ok( !$contacts->sent('xyz@ours.test'), 'an unknown one' );

    my $again = Milter::Contacts->new( file => "$tmp/contacts.db", shared_domains => ['acme.test'] );
    ok( !$again->known('alice@acme.test'), 'shared_domains can be set' );

    my ( $cols, $rows ) = $contacts->list();
    is( [ sort map { $_->[0] } @$rows ], [qw{bob@acme.test colleague@ours.test friend@gmail.com}], 'list' );
    ok( $contacts->forget('bob@acme.test'),   'forget' );
    ok( !$contacts->known('alice@acme.test'), '... takes the domain with it when nobody else there is known' );
    ok( !$contacts->forget('bob@acme.test'),  '... once' );
};

subtest 'seed' => sub {
    my $sent = "$tmp/Maildir/.Sent";
    make_path( map { "$sent/$_" } qw{cur new tmp} );
    write_file( "$sent/cur/1.test:2,S", "From: me\@ours.test\nTo: One <one\@first.test>\nCc: two\@second.test\nMessage-ID: <sent1\@ours.test>\nSubject: hi\n\nhello\n" );
    write_file( "$sent/cur/2.test:2,S", "From: me\@ours.test\nTo: three\@third.test\nBcc: hidden\@fourth.test\nMessage-ID: <sent2\@ours.test>\nSubject: hi\n\nhello\n" );

    my $contacts = Milter::Contacts->new( file => "$tmp/seeded.db" );
    is( $contacts->seed($sent), 2, 'reads every message in the folder' );
    ok( $contacts->known($_), "$_ is a contact" ) for qw{one@first.test two@second.test three@third.test hidden@fourth.test};
    ok( $contacts->sent($_),  "$_ was sent" )     for qw{sent1@ours.test sent2@ours.test};
    like( dies { $contacts->seed("$tmp/bogus") }, qr/Could not open/, 'a folder which is not one dies' );
};

done_testing();

__END__

=head1 DESCRIPTION

L<Milter::Contacts>: organization domains, learning and recognizing contacts and sent Message-IDs, and seeding from a Maildir of sent mail.

=cut
