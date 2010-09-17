#!/usr/bin/perl
# Outputs a day log in plain text format.
# Copyright (C) 2010 Jack Grigg <me@jackgrigg.com>
#
# This file is part of SNAILBot.
#
# SNAILBot is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# SNAILBot is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with SNAILBot.  If not, see <http://www.gnu.org/licenses/>.

use warnings;
use strict;
use Carp qw(confess);
use CGI::Carp qw(fatalsToBrowser);
use CGI;
use Encode;
use HTML::Entities;
# evil hack: Text::Table lies somewhere near /irclog/ on the server...
use lib '../lib';
use lib 'lib';
use IrcLog qw(get_dbh gmt_today);
use IrcLog::WWW qw(my_encode my_decode);
use Text::Table;

my $default_server = 'irc.freenode.net';
my $default_channel = 'perl6';

# End of config

my $q = new CGI;
my $dbh = get_dbh();
my $server = $q->param('server') || $default_server;
my $channel = $q->param('channel') || $default_channel;

my $reverse = $q->param('reverse') || 0;

my $date = $q->param('date') || gmt_today;

if ($channel !~ m/^\w+(?:-\w+)*\z/sx){
    # guard against channel=../../../etc/passwd or so
    confess 'Invalid channel name';
}

#Check for reverse
my $statement = 'SELECT nick, timestamp, line FROM irclog '
        . 'WHERE day = ? AND channel = ? AND server = ? AND NOT spam ORDER BY id';

$statement .= ' DESC' if $reverse;

my $db = $dbh->prepare($statement);
$db->execute($date, '#' . $channel, $server);


print "Content-Type: text/html;charset=utf-8\n\n";
print <<HTML_HEADER;
<html>
<head>
<title>IRC Logs</title>
</head>
<body>
<pre>
HTML_HEADER

my $table = Text::Table->new(qw(Time Nick Message));

while (my $row = $db->fetchrow_hashref){
    next unless length($row->{nick});
    my ($hour, $minute) =(gmtime $row->{timestamp})[2,1];  
    $table->add(
            sprintf("%02d:%02d", $hour, $minute),
            $row->{nick},
            my_decode($row->{line}),
            );
}
my $text = encode_entities($table, '<>&');

# Text::Table will add trailing whitespace to pad messages to the
# longest message. I (avar) wasn't able to find out how to make it
# stop doing that so I'm hacking around it with regex! 
$text =~ s/ +$//gm;

print encode("utf-8", $text);
print "</pre></body></html>\n";




# vim: sw=4 ts=4 expandtab
