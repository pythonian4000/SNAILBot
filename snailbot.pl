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

    sub prepare_irclog {
        my $dbh = shift;
        return $dbh->prepare("INSERT INTO irclog (server, channel, day, nick, timestamp, line) VALUES(?, ?, ?, ?, ?, ?)");
    }
    sub prepare_usercount {
        my $dbh = shift;
        return $dbh->prepare("INSERT INTO usercount (server, channel, day, timestamp, count) VALUES(?, ?, ?, ?, ?)");
    }
    my $q1 = prepare_irclog($dbh);
    my $q2 = prepare_usercount($dbh);
    sub dbwrite_irclog {
        my ($server, $channel, $who, $line) = @_;
        # mncharity aka putter has an IRC client that prepends some lines with
        # a BOM. Remove that:
        $line =~ s/\A\x{ffef}//;
        my @sql_args = ($server, $channel, gmt_today(), $who, time, $line);
        if ($dbh->ping){
            $q1->execute(@sql_args);
        } else {
            $q1 = prepare_irclog(get_dbh());
            $q1->execute(@sql_args);
        }
        return;
    }
    sub dbwrite_usercount {
        my ($server, $channel, $count) = @_;
        my @sql_args = ($server, $channel, gmt_today(), time, $count);
        if ($dbh->ping){
            $q2->execute(@sql_args);
        } else {
            $q2 = prepare_usercount(get_dbh());
            $q2->execute(@sql_args);
        }
        return;
    }

    use base 'Bot::BasicBot';

    sub _get_channel_names_count {
        my $self = shift;
        my $channel = shift;
        $self->names($channel);
        my $names = $self->channel_data ($channel);
        if (defined $self->{building_channel_data}->{$channel}) {
            $names = $self->{building_channel_data}->{$channel};
        }
        return scalar(keys(%$names));
    }

    sub said {
        my $self = shift;
        my $e = shift;
        dbwrite_irclog($self->{server}, $e->{channel}, $e->{who}, $e->{body});
        return undef;
    }

    sub emoted {
        my $self = shift;
        my $e = shift;
        dbwrite_irclog($self->{server}, $e->{channel}, '* ' . $e->{who}, $e->{body});
        return undef;

    }

    sub chanjoin {
        my $self = shift;
        my $e = shift;
        dbwrite_irclog($self->{server}, $e->{channel}, '',  $e->{who} . ' joined ' . $e->{channel});
        # For some reason the usercount when the bot joins returns 1.
        # So for now do not add datapoints when the bot joins the channel.
        # (The discrepancy will be included in the next datapoint.)
        if ($e->{who} ne $self->{nick}) {
            my $count = $self->_get_channel_names_count($e->{channel});
            dbwrite_usercount($self->{server}, $e->{channel}, $count);
        }
        return undef;
    }

    sub chanpart {
        my $self = shift;
        my $e = shift;
        # An integer difference that can be applied to the count - see userquit.
        my $diff = shift || 0;
        dbwrite_irclog($self->{server}, $e->{channel}, '',  $e->{who} . ' left ' . $e->{channel});
        my $count = $self->_get_channel_names_count($e->{channel}) + $diff;
        dbwrite_usercount($self->{server}, $e->{channel}, $count);
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
            # For some reason userquit results in one too large a usercount. So add a -1 diff.
            $self->chanpart({ who => $nick, channel => $channel }, -1);
        }
    }

    sub topic {
        my $self = shift;
        my $e = shift;
        dbwrite_irclog($self->{server}, $e->{channel}, "", 'Topic for ' . $e->{channel} . ' is now ' . $e->{topic});
        return undef;
    }

    sub nick_change {
        my $self = shift;
        my($old, $new) = @_;

        foreach my $channel ($self->_channels_for_nick($new)) {
            dbwrite_irclog($self->{server}, $channel, "", $old . ' is now known as ' . $new);
        }
        
        return undef;
    }

    sub kicked {
        my $self = shift;
        my $e = shift;
        dbwrite_irclog($self->{server}, $e->{channel}, "", $e->{kicked} . ' was kicked by ' . $e->{who} . ': ' . $e->{reason});
        my $count = $self->_get_channel_names_count($e->{channel});
        dbwrite_usercount($self->{server}, $e->{channel}, $count);
        return undef;
    }

    sub help {
        my $self = shift;
        return "This is a passive irc logging bot. Lines beginning in [off] are not logged. View the logs at http://irclogs.jackgrigg.com/";
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
