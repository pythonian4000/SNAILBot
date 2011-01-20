#!/usr/bin/perl
# Formats and displays a particular day log for a channel, with nick
# highlighting and filtering.
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
use Date::Simple qw(date);
use Encode::Guess;
use CGI;
use Encode;
use HTML::Template;
use Config::File;
use File::Slurp;
use lib '../lib';
use IrcLog qw(get_dbh gmt_today gmt_datetime);
use IrcLog::WWW qw(http_header message_line my_encode);
use Cache::SizeAwareFileCache;
#use Data::Dumper;


# Configuration
# $base_url is the absoulte URL to the directoy where index.pl and out.pl live
# If they live in the root of their own virtual host, set it to "/".
my $conf      = Config::File::read_config_file('cgi.conf');
my $site_name = $conf->{SITE_NAME} || q{SNAILBot};
my $base_url  = $conf->{BASE_URL} || q{/};

# I'm too lazy right to move this to  a config file, because Config::File seems
# unable to handle arrays, just hashes.

# map nicks to CSS classes.
my @colors = (
        ['TimToady',    'nick_timtoady'],
        ['audreyt',     'nick_audreyt'],
        ['evalbot',     'bots'],
        ['exp_evalbot', 'bots'],
        ['p6eval',      'bots'],
        ['lambdabot',   'bots'],
        ['pugs_svnbot', 'bots'],
        ['pugs_svn',    'bots'],
        ['specbot',     'bots'],
        ['speckbot',    'bots'],
        ['pasteling',   'bots'],
        ['rakudo_svn',  'bots'],
        ['purl',        'bots'],
        ['svnbotlt',    'bots'],
        ['dalek',       'bots'],
        ['hugme',       'bots'],
        ['garfield',    'bots'],
    );
# additional classes for nicks, sorted by frequency of speech:
my @nick_classes = map { "nick$_" } (1 .. 9);

# Default channel: this channel will be shown if no channel=... arg is given
my $default_server = 'irc.freenode.net';
my $default_channel = 'perl6';

# End of config

my $q = new CGI;
my $dbh = get_dbh();
my $server = $q->param('server') || $default_server;
my $channel = $q->param('channel') || $default_channel;
# Unescape channel string in case it begins with #
$channel =~ s/\%([A-Fa-f0-9]{2})/pack('C', hex($1))/seg;
my $date = $q->param('date') || gmt_today();
if ($date eq 'today') {
    $date = gmt_today();
} elsif ($date eq 'yesterday') {
    $date = date(gmt_today()) - 1;
}

if ($date eq gmt_today()) {
    print http_header({ nocache => 1});
} else {
    print http_header();
}


if ($channel !~ m/\A#?[.\w-]+\z/smx){
    # guard against channel=../../../etc/passwd or so
    confess 'Invalid channel name';
}

my $count;
{
    my $sth = $dbh->prepare_cached('SELECT COUNT(*) FROM irclog WHERE day = ?');
    $sth->execute($date);
    $sth->bind_columns(\$count);
    $sth->fetch();
    $sth->finish();
}

# Determine if browser is an iPhone/iPod Touch
my $ios;
my $user_agent_string = $ENV{HTTP_USER_AGENT} || '';
my $iPhone_check = index $user_agent_string,'iPhone';
my $iPod_check = index $user_agent_string,'iPod';
if ($iPhone_check >= 0 || $iPod_check >= 0) {
    $ios = 1;
}

{
    my $cache_key = $server . '|' . $channel . '|' . $date . '|' . $count;
    if ($ios) {
        $cache_key = $cache_key . '|iOS';
    }
    # the average #perl6 day produces 100k to 400k of HTML, so with
    # 50MB we have about 150 pages in the cache. Since most hits are
    # the "today" page and those of the last 7 days, we still get a very
    # decent speedup
    # btw a cache hit is about 10 times faster than generating the page anew
    my $cache = new Cache::SizeAwareFileCache( {
            namespace       => 'irclog',
            max_size        => 150 * 1048576,
            } );
    my $data;
    # Comment out the next line to disable the cache
    $data = $cache->get($cache_key);
    if (defined $data){
        print $data;
    } else {
        $data = irclog_output($date, $server, $channel, $ios);
        $cache->set($cache_key, $data);
        print $data;
    }
}

sub irclog_output {
    my ($date, $server, $channel, $ios) = @_;

    my $full_channel = q{#} . $channel;
    my $t = HTML::Template->new(
            filename            => 'template/day.tmpl',
            loop_context_vars   => 1,
            global_vars         => 1,
            die_on_bad_params   => 0,
            );

    $t->param(ADMIN => 1) if ($q->param('admin'));

    if ($ios) {
            $t->param(IOS => 1);
    }
    {
        # Insert usercount chart if present
        my $clf = "channels/$server/$channel/usercount.tmpl";
        if (-e $clf) {
            my @usercount_data = usercount_chart_for_channel_day($server, $full_channel, $date);
            $t->param(USERCOUNT_CHART => q{} . read_file($clf));
            $t->param(USERCOUNT_DATA => \@usercount_data);
        }
    }
    {
        # Insert channel logo if present
        my $clf = "channels/$server/$channel/logo.tmpl";
        if (-e $clf) {
            $t->param(CHANNEL_LOGO => q{} . read_file($clf));
        }
    }
    {
        # Insert channel-specific links if present
        my $clf = "channels/$server/$channel/links.tmpl";
        if (-e $clf) {
            my $links = q{} . read_file($clf);
            if ($t->param('IOS')) {
                $links =~ s/\|//g;
            }
            $t->param(CHANNEL_LINKS => $links);
        }
    }
    {
        # Find and insert extras
        my $analytics_header = "extras/analytics-header.tmpl";
        if (-e $analytics_header) {
            $t->param(ANALYTICS_HEADER => q{} . read_file($analytics_header));
        }
        my $analytics_footer = "extras/analytics-footer.tmpl";
        if (-e $analytics_footer) {
            $t->param(ANALYTICS_FOOTER => q{} . read_file($analytics_footer));
        }
    }
    $t->param(SITE_NAME => $site_name);
    $t->param(BASE_URL  => $base_url);
    my $self_url = $base_url . "/$server/$channel/$date";
    my $db = $dbh->prepare('SELECT id, nick, timestamp, line FROM irclog '
            . 'WHERE day = ? AND channel = ? AND server = ? AND NOT spam '
            . 'ORDER BY id');
    $db->execute($date, $full_channel, $server);


# determine which colors to use for which nick:
    {
        my $count = scalar @nick_classes + scalar @colors + 1;
        my $q1 = $dbh->prepare('SELECT nick, COUNT(nick) AS c FROM irclog'
                . ' WHERE day = ? AND channel = ? AND server = ? AND not spam'
                . " GROUP BY nick ORDER BY c DESC LIMIT $count");
        $q1->execute($date, $full_channel, $server);
        while (my @row = $q1->fetchrow_array and @nick_classes){
            next unless length $row[0];
            my $n = quotemeta $row[0];
            unless (grep { $_->[0] =~ m/\A$n/smx } @colors){
                push @colors, [$row[0], shift @nick_classes];
            }
        }
#    $t->param(DEBUG => Dumper(\@colors));
    }

    my @msg;

    my $line = 1;
    my $prev_nick = q{};
    my $c = 0;

# populate the template
    my $line_number = 0;
    while (my @row = $db->fetchrow_array){
        my $id = $row[0];
        my $nick = decode('utf8', ($row[1]));
        my $timestamp = $row[2];
        my $message = $row[3];
        next if $message =~ m/^\s*\[off\]/i;

        push @msg, message_line( {
                id           => $id,
                nick        => $nick,
                timestamp   => $timestamp,
                message     => $message,
                line_number =>  ++$line_number,
                prev_nick   => $prev_nick,
                colors      => \@colors,
                self_url    => $self_url,
                channel     => $channel,
                server      => $server,
                },
                \$c,
                $ios,
                );
        $prev_nick = $nick;
    }

    $t->param(
            SERVER      => $server,
            CHANNEL     => $channel,
            MESSAGES    => \@msg,
            DATE        => $date,
        );

# check if previous/next date exists in database
    {
        # Escape channel string in case it begins with #
        my $enc_channel = $channel;
        $enc_channel =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg;

        my $q1 = $dbh->prepare('SELECT COUNT(*) FROM irclog '
                . 'WHERE server = ? AND channel = ? AND day = ? AND NOT spam');
        # Date::Simple magic ;)
        my $tomorrow = date($date) + 1;
        $q1->execute($server, $full_channel, $tomorrow);
        my ($res) = $q1->fetchrow_array();
        if ($res){
            my $next_url = $base_url . "$server/$enc_channel/$tomorrow";
            # where the hell does the leading double slash come from?
            $next_url =~ s{^//+}{/};
            $t->param(NEXT_URL => $next_url);
        }

        my $yesterday = date($date) - 1;
        $q1->execute($server, $full_channel, $yesterday);
        ($res) = $q1->fetchrow_array();
        if ($res){
            my $prev_url = $base_url . "$server/$enc_channel/$yesterday";
            $prev_url =~ s{^//+}{/};
            $t->param(PREV_URL => $prev_url);
        }

    }

    return my_encode($t->output);
}

# Returns the data for creating a one-day usercount chart.
sub usercount_chart_for_channel_day {
    my ($server, $channel, $date) = @_;
    my @usercount_data;
    # Prepare the query that will fetch the one day's usercounts.
    my $q = $dbh->prepare('SELECT timestamp, count FROM usercount '
        . 'WHERE server = ? AND channel = ? AND day = ?');
    # Execute the query.
    $q->execute($server, $channel, $date);
    my $id = 0;
    while (my @row = $q->fetchrow_array) {
        my $timestamp = $row[0];
        my $count = $row[1];
        # Create array items that HTML::Template will use.
        my %usercount_point = (
            ID => $id,
            DATETIME => gmt_datetime($timestamp),
            COUNT => $count
        );
        push(@usercount_data, \%usercount_point);
        $id += 1;
    }
    return @usercount_data;
}

# vim: sw=4 ts=4 expandtab
