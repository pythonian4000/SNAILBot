#!/usr/bin/perl
# Generates custom Atom feeds.
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
use CGI;
use Encode;
use File::Slurp;
use Config::File;
use lib '../lib';
use IrcLog qw(get_dbh gmt_cdtf);
use IrcLog::WWW qw(http_header message_line my_encode my_decode);
use utf8;

my $default_server = 'irc.freenode.net';
my $default_channel = 'openhatch';

my $conf       = Config::File::read_config_file("cgi.conf");
my $site_name  = $conf->{SITE_NAME} || q{SNAILBot};
my $site_host  = $conf->{SITE_HOST} || q{http://irclogs.jackgrigg.com};
my $site_admin = $conf->{SITE_ADMIN} || q{Jack Grigg};
my $base_url   = $conf->{BASE_URL} || "/";

my $q = new CGI;
my $dbh = get_dbh();

my $server = $q->param('server') || $default_server;
my $short_channel = decode('utf8', $q->param('channel') || $default_channel);
my $channel = '#' . $short_channel;
my $nick = decode('utf8', $q->param('nick') || '');
my $qs = $q->param('q') || '';
$qs = my_decode($qs);
my $feed_length = $q->param('num') || 200;

if (length($nick) or length($qs)){
    # parameters supplied so generate Atom feed

    # first set up condition for SQL query
    my @sql_conds = ('server = ? AND channel = ? AND NOT spam');
    my @args = ($server, $channel);
    if (length $nick){
        push @sql_conds, '(nick = ? OR nick = ?)';
        push @args, $nick, "* $nick";
    }
    if (length $qs) {
        push @sql_conds, 'MATCH(line) AGAINST(?)';
        push @args, $qs;
    }
    my $sql_cond = 'WHERE ' . join(' AND ', @sql_conds);

    # create the base Atom feed
    use XML::Atom::SimpleFeed;
    my $feed = XML::Atom::SimpleFeed->new(
        title   => $site_name . ' Atom Feed',
        link    => "$site_host$base_url$server/$short_channel/",
        link    => {
                    rel => 'self',
                    href => CGI::self_url(),
                },
        updated => gmt_cdtf(time),
        author  => $site_admin,
    );

    # create and run the query to fetch the required data
    my $q0 = $dbh->prepare("SELECT id, day, timestamp, nick, line FROM irclog $sql_cond ORDER BY id DESC LIMIT ?");
    push @args, $feed_length;
    $q0->execute(@args);

    # from each row of the SQL results, add an entry to the feed
    while (my @row = $q0->fetchrow_array){
        my $entry_title = $row[3] . ' - ' . $row[4];
        if (length($entry_title) > 60) {
            $entry_title = (substr $entry_title, 0, 57) . '...';
        }
        $feed->add_entry(
            title     => $entry_title,
            link      => "$site_host$base_url$server/$short_channel/$row[1]#i_$row[0]",
            summary   => $row[4],
            updated   => gmt_cdtf($row[2]),
            author    => $row[3],
        );
    }

    # output the resultant feed
    print "Content-type: application/atom+xml; charset=utf-8\n\n";
    $feed->print;
} else {
    use HTML::Entities;
    use HTML::Template;
    print http_header();
    my $t = HTML::Template->new(
            filename => "template/atom.tmpl",
            global_vars => 1,
            die_on_bad_params => 0,
    );
    $t->param(SITE_NAME => $site_name);
    $t->param(BASE_URL  => $base_url);
    {
        # Determine if browser is an iPhone/iPod Touch
        my $user_agent_string = $ENV{HTTP_USER_AGENT} || '';
        my $iPhone_check = index $user_agent_string,'iPhone';
        my $iPod_check = index $user_agent_string,'iPod';
        if ($iPhone_check >= 0 || $iPod_check >= 0) {
            $t->param(IOS => 1);
        }
    }
    # Set this to 1 if you want to include extras in the atom gen page (e.g. analytics code)
    my $insert_extras_into_atom_page = 1;
    if ($insert_extras_into_atom_page){
        # Find and insert extras into search page
        my $analytics_header = "extras/analytics-header.tmpl";
        if (-e $analytics_header) {
            $t->param(ANALYTICS_HEADER => q{} . read_file($analytics_header));
        }
        my $analytics_footer = "extras/analytics-footer.tmpl";
        if (-e $analytics_footer) {
            $t->param(ANALYTICS_FOOTER => q{} . read_file($analytics_footer));
        }
    }

    {
        # populate the select box with possible servers to generate from
        my @servers;
        my $q1 = $dbh->prepare("SELECT DISTINCT server FROM irclog ORDER BY server");
        $q1->execute();
        my $svr = $q->param('server') || $default_server;
        $t->param(CURRENT_SERVER => $svr, SERVER => $svr);
        while (my @row = $q1->fetchrow_array){
            if ($svr eq $row[0]){
                push @servers, {SERVER => $row[0], SELECTED => 1};
            } else {
                push @servers, {SERVER => $row[0]};
            }
        }
        # populate the select box with possible channel names to generate from
        my @all_channels;
        my @cur_channels;
        my $ch = $q->param('channel') || $default_channel;
        $ch =~ s/^\#//;
        $t->param(CURRENT_CHANNEL => $ch, CHANNEL => $ch);
        # server_int is required for the automatic Javascript updating of the channel list
        # (since list box options are referenced by index, not value)
        my $server_int = 0;
        for my $server_row (@servers) {
            my $server = $server_row->{'SERVER'};
            my @channels;
            my $q2 = $dbh->prepare("SELECT DISTINCT channel FROM irclog WHERE server = '$server' ORDER BY channel");
            $q2->execute();
            while (my @row = $q2->fetchrow_array){
                $row[0] =~ s/^\#//;
                if ($ch eq $row[0]){
                    push @channels, {CHANNEL => $row[0], SELECTED => 1};
                } else {
                    push @channels, {CHANNEL => $row[0]};
                }
            }
            if ($server eq $svr){
                @cur_channels = @channels;
            }
            push @all_channels, {SERVER_INT => $server_int, CHANNELS => \@channels};
            $server_int++;
        }

        # populate the size of the select box with server names
        $t->param(SERVERS => \@servers);
        if (@servers >= 5 ){
            $t->param(SVR_COUNT => 5);
        } else {
            $t->param(SVR_COUNT => scalar @servers);
        }
        # populate the size of the select box with channel names
        $t->param(CHANNELS => \@cur_channels);
        if (@cur_channels >= 5 ){
            $t->param(CH_COUNT => 5);
        } else {
            $t->param(CH_COUNT => scalar @cur_channels);
        }
        $t->param(ALL_CHANNELS => \@all_channels);
    }

    print my_encode($t->output);
}
