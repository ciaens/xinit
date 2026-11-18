#!/usr/bin/perl
# A stand-in for a second XWiki on the same host, for the multi-instance scenarios: an HTTP
# server that answers 200, or 503 while a flag file exists. It needs nothing but perl-base.
#
# Usage: stub-wiki.pl <port> <flag file>
use strict;
use warnings;
use IO::Socket::INET;

my ($port, $flag) = @ARGV;
my $server = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1', LocalPort => $port, Listen => 5, ReuseAddr => 1
) or die "cannot listen on $port: $!\n";
$SIG{TERM} = sub { exit 0 };
while (my $client = $server->accept) {
    # The request line and the headers, which are not looked at.
    while (my $line = <$client>) {
        last if $line =~ /^\r?\n$/;
    }
    my $status = -e $flag ? '503 Service Unavailable' : '200 OK';
    print $client "HTTP/1.1 $status\r\nContent-Type: text/plain\r\nContent-Length: 5\r\n",
        "Connection: close\r\n\r\nstub\n";
    close $client;
}
