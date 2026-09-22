use 5.014;
use strict;
use warnings FATAL => 'all';
use re '/aa';

use FindBin::libs;
use Cwd;
use File::Temp;
use MIME::Base64 qw{encode_base64};
use Test2::V0;
use Test2::Plugin::NoWarnings;

use Milter::Client qw{:constants};
use Milter::Harness;
use Milter::Recipe::Language;
use CorpusTest qw{write_file};

my $run_dir = Cwd::abs_path("$FindBin::Bin/..");
my $tmp     = File::Temp->newdir();

my $english = join ' ', ("I am writing to you about the quarterly report which we discussed at the meeting last week, and the numbers are looking better than we expected.") x 4;
my $german  = join ' ', ("Sehr geehrte Damen und Herren, wir freuen uns Ihnen mitteilen zu koennen, dass Ihre Bestellung heute versandt wurde und bald bei Ihnen ist.") x 4;

subtest 'word_count' => sub {
    is( Milter::Recipe::Language::word_count('hello world, this is a test'),                                      5, 'words of two letters or more' );
    is( Milter::Recipe::Language::word_count("\x{41f}\x{440}\x{438}\x{432}\x{435}\x{442} \x{43c}\x{438}\x{440}"), 2, 'in any script, whatever use re /aa says' );
    is( Milter::Recipe::Language::word_count("caf\x{e9} cr\x{e8}me"),                                             2, 'accented letters are letters' );
    is( Milter::Recipe::Language::word_count("\x{4f60}\x{597d}\x{4e16}\x{754c}"),                                 4, 'each ideograph is a word' );
    is( Milter::Recipe::Language::word_count('a b 12 34 --'),                                                     0, 'single letters, digits and punctuation are not' );
};

subtest 'own_text' => sub {
    my $text = Milter::Recipe::Language::own_text(
        [ "Thanks, see https://x.test/a or write to a\@x.test.\nOrder 12345 ref ab12cd34.\nOn Monday someone wrote:\n> quoted\nmore quoted\n", 0 ],
        [ "<style>p { color: red }</style><p>Hello&nbsp;there</p>\n-- \nsignature",                                                            1 ],
    );
    like( $text, qr/Thanks, see/, 'the sender\'s own words stay' );
    unlike( $text, qr/https|\@/,       'URLs and addresses go' );
    unlike( $text, qr/12345|ab12cd34/, 'anything with a digit goes' );
    unlike( $text, qr/quoted/,         'a reply\'s attribution and all below it go' );
    like( $text, qr/Hello there/, 'every part is read, each cleaned on its own: one part\'s reply cut does not take the next part with it' );
    unlike( $text, qr/color|signature/, 'HTML is reduced to text, without styles, and signatures go' );
};

subtest 'foreign_language' => sub {
    my %opt = ( langs => [qw{en es}], min_words => 50, confidence => 2 );
    is( [ Milter::Recipe::Language::foreign_language( $german, %opt ) ],                        [ 'de', 'looks like de' ],                    'German is foreign' );
    is( [ Milter::Recipe::Language::foreign_language( $english, %opt ) ],                       [ undef, 'looks like en, which is allowed' ], 'English is not' );
    is( ( Milter::Recipe::Language::foreign_language( 'Ich bin ein Berliner', %opt ) )[1],      'only 4 words, too few to judge',             'too little text to judge' );
    is( ( Milter::Recipe::Language::foreign_language( $german, %opt, confidence => 1000 ) )[0], undef,                                        'not foreign unless confidently so' );
    is( ( Milter::Recipe::Language::foreign_language( $german, %opt, langs => ['de'] ) )[0],    undef,                                        'langs decides what is foreign' );
};

subtest 'in yamilter' => sub {
    my $milter = Milter::Harness->new( script => "$run_dir/bin/yamilter", config => write_file( "$tmp/yamilter.cfg", "[service]\nsock=$tmp/yamilter.sock\npidfile=$tmp/yamilter.pid\nworkers=1\n[Language]\nlangs=en, es\naction=defer\n" ) );
    $milter->start();
    my $send = sub {
        my ( $body, @headers ) = @_;
        my ( $code, $reply )   = Milter::Client::sendmail(
            $milter->connect(),
            { timeout => 5 },
            [ SMFIC_OPTNEG, 6, 0x1FF, 0x1FFFFF ],
            [ SMFIC_HELO,   'client.test.test' ],
            [ SMFIC_MAIL,   '<a@test.test>' ],
            [ SMFIC_RCPT,   '<b@test.test>' ],
            [SMFIC_DATA],
            ( map { [ SMFIC_HEADER, @$_ ] } [ 'Subject', 'hi' ], @headers ),
            [SMFIC_EOH],
            Milter::Client::body_chunks($body),
            [SMFIC_BODYEOB],
            [SMFIC_QUIT],
        );
        return [ $code, $reply ];
    };

    is( $send->("$english\r\n"),                                                                                                            [ SMFIR_ACCEPT, q{} ],                                                                        'English is accepted' );
    is( $send->("$german\r\n"),                                                                                                             [ SMFIR_REPLYCODE, '450 4.7.1 Language used in mail body is incomprehensible to our users' ], 'German is deferred' );
    is( $send->("Ich bin ein Berliner\r\n"),                                                                                                [ SMFIR_ACCEPT, q{} ],                                                                        'a few words of German are too few to judge' );
    is( $send->( "$german\r\n", [ 'Auto-Submitted', 'auto-generated' ] ),                                                                   [ SMFIR_ACCEPT, q{} ],                                                                        'automated mail is not judged' );
    is( $send->( encode_base64("$english\n"), [ 'Content-Type', 'text/plain; charset=utf-8' ], [ 'Content-Transfer-Encoding', 'base64' ] ), [ SMFIR_ACCEPT, q{} ],                                                                        'base64 English is decoded, not judged as gibberish' );
    my $log = $milter->stop();
};

done_testing();

__END__

=head1 DESCRIPTION

L<Milter::Recipe::Language>: word counting in any script, taking out the sender's own text, the confidence rule,
and the recipe in yamilter with English, German, short, automated and base64 encoded mail.

=cut
