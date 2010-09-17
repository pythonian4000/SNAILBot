#!/usr/bin/perl
# The actual IRC bot that collects data from channels on servers as defined
# in bot.conf and logs it to the database specified in database.conf.
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
use lib 'lib';
use Config::Scoped;
use Bot::BasicBot 0.81;
use Carp qw(confess);

# this s based on ilbot. It uses Bot::BasicBot which 
# in turn is based POE::* stuff
package IrcLogBot;
use IrcLog qw(get_dbh gmt_today);
use Data::Dumper;

{

    my $dbh = get_dbh();

    sub prepare {
        my $dbh = shift;
        return $dbh->prepare("INSERT INTO irclog (server, channel, day, nick, timestamp, line) VALUES(?, ?, ?, ?, ?, ?)");
    }
    my $q = prepare($dbh);
    sub dbwrite {
        my ($server, $channel, $who, $line) = @_;
        # mncharity aka putter has an IRC client that prepends some lines with
        # a BOM. Remove that:
        $line =~ s/\A\x{ffef}//;
        my @sql_args = ($server, $channel, gmt_today(), $who, time, $line);
        if ($dbh->ping){
            $q->execute(@sql_args);
        } else {
            $q = prepare(get_dbh());
            $q->execute(@sql_args);
        }
        return;
    }

    use base 'Bot::BasicBot';

    sub said {
        my $self = shift;
        my $e = shift;
        dbwrite($self->{server}, $e->{channel}, $e->{who}, $e->{body});
        return undef;
    }

    sub emoted {
        my $self = shift;
        my $e = shift;
        dbwrite($self->{server}, $e->{channel}, '* ' . $e->{who}, $e->{body});
        return undef;

    }

    sub chanjoin {
        my $self = shift;
        my $e = shift;
        dbwrite($self->{server}, $e->{channel}, '',  $e->{who} . ' joined ' . $e->{channel});
        return undef;
    }

    sub chanquit {
        my $self = shift;
        my $e = shift;
        dbwrite($self->{server}, $e->{channel}, '', $e->{who} . ' left ' . $e->{channel});
        return undef;
    }

    sub chanpart {
        my $self = shift;
        my $e = shift;
        dbwrite($self->{server}, $e->{channel}, '',  $e->{who} . ' left ' . $e->{channel});
        return undef;
    }

    sub _channels_for_nick {
        my $self = shift;
        my $nick = shift;

        return grep { $self->{channel_data}{$_}{$nick} } keys( %{ $self->{channel_data} } );
    }

    sub userquit {
        my $self = shift;
        my $e = shift;
        my $nick = $e->{who};

        foreach my $channel ($self->_channels_for_nick($nick)) {
            $self->chanpart({ who => $nick, channel => $channel });
        }
    }

    sub topic {
        my $self = shift;
        my $e = shift;
        dbwrite($self->{server}, $e->{channel}, "", 'Topic for ' . $e->{channel} . ' is now ' . $e->{topic});
        return undef;
    }

    sub nick_change {
        my $self = shift;
        my($old, $new) = @_;

        foreach my $channel ($self->_channels_for_nick($new)) {
            dbwrite($self->{server}, $channel, "", $old . ' is now known as ' . $new);
        }
        
        return undef;
    }

    sub kicked {
        my $self = shift;
        my $e = shift;
        dbwrite($self->{server}, $e->{channel}, "", $e->{kicked} . ' was kicked by ' . $e->{who} . ': ' . $e->{reason});
        return undef;
    }

    sub help {
        my $self = shift;
        return "This is a passive irc logging bot. View the logs at http://irclogs.jackgrigg.com/";
    }
}


package main;
my $conf = Config::Scoped->new( file => shift @ARGV || "bot.conf")->parse;
die "Could not read config!\n" unless ref $conf;
my $servers = $conf->{'servers'};
foreach my $server (keys %$servers)
{
    my $nick = $servers->{$server}->{'NICK'} || "SNAILBot";
    my $address = $servers->{$server}->{'SERVER'} || "irc.freenode.net";
    my $port = $servers->{$server}->{'PORT'} || 6667;
    my $channels = [ split m/\s+/, $servers->{$server}->{'CHANNEL'}];

    my $bot = IrcLogBot->new(
        server    => $address,
        port      => $port,
        channels  => $channels,
        nick      => $nick,
        alt_nicks => ["irclogbot", "logbot"],
        username  => "bot",
        name      => "irc log bot, http://www.jackgrigg.com/projects/snailbot",
        charset   => "utf-8", 
        no_run    => 1,
        );
    $bot->run();
}
use POE;
$poe_kernel->run();

# vim: ts=4 sw=4 expandtab
