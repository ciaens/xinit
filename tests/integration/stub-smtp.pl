#!/usr/bin/perl
# A mail server for the notification scenarios: it keeps each mail it is given. It needs nothing
# but perl, and speaks no TLS.
#
# Usage: stub-smtp.pl <port> <directory> [<login>:<password>]
#   <directory>/mail-N.eml   the Nth mail, as it was sent (lines ending with CR LF)
#   <directory>/mail-N.env   its envelope: "from <address>" and "to <address>" lines
#   <directory>/logins       one line per login: "accepted <name>" or "refused <name>"
# With a login, the server takes no mail before it was given (AUTH PLAIN).
use strict;
use warnings;
use IO::Socket::INET;
use MIME::Base64;

my ($port, $dir, $account) = @ARGV;
umask 077;
my $server = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1', LocalPort => $port, Listen => 5, ReuseAddr => 1
) or die "cannot listen on $port: $!\n";
$SIG{TERM} = sub { exit 0 };
my $count = 0;

sub note {
    my ($file, $line) = @_;
    open(my $out, '>>', "$dir/$file") or die "cannot write $dir/$file: $!\n";
    print $out "$line\n";
    close $out;
}

while (my $client = $server->accept) {
    my ($from, @to, $logged_in);
    print $client "220 xinit-test ESMTP\r\n";
    while (my $line = <$client>) {
        $line =~ s/\r?\n$//;
        if ($line =~ /^(EHLO|HELO) /i) {
            note('hello', $line);
            print $client "250-xinit-test\r\n", ($account ? "250-AUTH PLAIN\r\n" : ''),
                "250 SIZE 52428800\r\n";
        } elsif ($line =~ /^AUTH PLAIN ?(.*)$/i) {
            my $answer = $1;
            if ($answer eq '') {
                print $client "334 \r\n";
                $answer = <$client> // '';
                $answer =~ s/\r?\n$//;
            }
            my (undef, $name, $password) = split /\0/, decode_base64($answer);
            if ($account && "$name:$password" eq $account) {
                $logged_in = 1;
                note('logins', "accepted $name");
                print $client "235 2.7.0 welcome\r\n";
            } else {
                note('logins', "refused " . ($name // ''));
                print $client "535 5.7.8 no\r\n";
            }
        } elsif ($account && !$logged_in && $line =~ /^(MAIL|RCPT|DATA)/i) {
            print $client "530 5.7.0 log in first\r\n";
        } elsif ($line =~ /^MAIL FROM:<([^>]*)>/i) {
            ($from, @to) = ($1);
            print $client "250 ok\r\n";
        } elsif ($line =~ /^RCPT TO:<([^>]*)>/i) {
            push @to, $1;
            print $client "250 ok\r\n";
        } elsif ($line =~ /^DATA$/i) {
            print $client "354 go on\r\n";
            $count++;
            open(my $mail, '>', "$dir/mail-$count.eml.part") or die "cannot write in $dir: $!\n";
            binmode $mail;
            while (my $data = <$client>) {
                last if $data =~ /^\.\r?\n$/;
                # A line that starts with a dot was sent with one more.
                $data =~ s/^\.//;
                print $mail $data;
            }
            close $mail;
            note("mail-$count.env", "from $from");
            note("mail-$count.env", "to $_") for @to;
            # Whole, or not there: a test may be waiting for it.
            rename "$dir/mail-$count.eml.part", "$dir/mail-$count.eml";
            print $client "250 kept\r\n";
        } elsif ($line =~ /^QUIT$/i) {
            print $client "221 bye\r\n";
            last;
        } else {
            print $client "502 not here\r\n";
        }
    }
    close $client;
}
