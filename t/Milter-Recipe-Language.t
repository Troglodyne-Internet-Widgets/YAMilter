use strict;
use warnings;

use FindBin;
use FindBin::libs;
use Cwd;
use Test2::V0;

use YAMilterTest qw{:all};

my $run_dir = Cwd::abs_path("$FindBin::Bin/..");
my $config = getconfig("$run_dir/t/yamilter.cfg");
my @args = ("$run_dir/bin/yamilter", '--config', $config->param('service.f'));

my $hdr = "localhost 127.0.0.1
HELO test.test
Subject: Test
From: test\@test.test
To:   testy\@test.test

";
my $email = "$hdr
Ich bin ein berliner
";

# Now to test the milters specifically

$config->param('Language.langs', 'en');
$config->param('Language.action', 'defer');
writeconfig();
like(fork_and_term(sub { print { getsock() } $email }, @args), qr/DEFER/i, "Marked message as DEFER when in incorrect language");

$email = "$hdr
I am a donut
";

like(fork_and_term(sub { print { getsock() } $email }, @args), qr/ACCEPT/i, "Marked message as ACCEPT when in correct language");

done_testing();
