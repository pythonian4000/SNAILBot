#!/usr/bin/perl
# Displays a channel-specific page with a calendar inteface to day logs.
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

use strict;
use warnings;
use Calendar::Simple;
use CGI::Carp qw(fatalsToBrowser);
use CGI;
use Config::File;
use File::Slurp;
use HTML::Template;
use Cache::FileCache;
use lib '../lib';
use IrcLog qw(get_dbh gmt_today gmt_datetime);

# test_calendar();
go();

sub go {
    my $q = new CGI;
    my $server = $q->url_param('server');
    my $channel = $q->url_param('channel');
    print "Content-Type: text/html; charset=utf-8\n\n";

    my $cache_name = $channel . '|' . gmt_today();
    my $cache      = new Cache::FileCache({ namespace => 'irclog' });
    my $data       = $cache->get($cache_name);

    if (! defined $data) {
        $data = get_channel_index($server, $channel);
        $cache->set($data, '2 hours');
    }

    print $data;
}

sub test_calendar {
    my $server   = 'irc.freenode.net';
    my $channel  = '#parrotsketch';
    my $base_url = '/';
    my $dates    = [qw( 2009-09-28 2009-09-30
                        2009-10-01 2009-10-02 2009-10-05 2009-10-12 )];

    print calendar_for_channel($server, $channel, $dates, $base_url);
}

sub get_channel_index {
    my ($server, $channel) = @_;
    my $conf      = Config::File::read_config_file('cgi.conf');
    my $site_name = $conf->{SITE_NAME} || q{SNAILBot};
    my $base_url  = $conf->{BASE_URL} || q{/};

    my $t = HTML::Template->new(
            filename            => 'template/channel-index.tmpl',
            die_on_bad_params   => 0,
    );

    # we are evil and create a calendar entry for month between the first
    # and last date
    my $dbh       = get_dbh();
    my $get_dates = 'SELECT DISTINCT day FROM irclog WHERE server = ? AND channel = ? ORDER BY day';
    my $dates     = $dbh->selectcol_arrayref($get_dates, undef, ($server, '#' . $channel));

    $t->param(SERVER    => $server);
    $t->param(CHANNEL   => $channel);
    $t->param(SITE_NAME => $site_name);
    $t->param(BASE_URL  => $base_url);
    $t->param(CALENDAR  => calendar_for_channel($server, $channel, $dates, $base_url));
    {
        # Insert usercount chart if present
        my $clf = "channels/$server/$channel/usercount.tmpl";
        if (-e $clf) {
            my @usercount_data = usercount_chart_for_channel($server, '#' . $channel, $dbh);
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
            $t->param(CHANNEL_LINKS => q{} . read_file($clf));
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
    return $t->output;
}

sub calendar_for_channel {
    my ($server, $channel, $dates, $base_url)  = @_;
    #$channel =~ s/\A\#//smx;
    # Encode channel in case it starts with #
    $channel =~ s/([^A-Za-z0-9])/sprintf("%%%02X", ord($1))/seg;

    my (%months, %link);
    for my $date (@$dates) {
        my ($Y, $M, $D) = split '-', $date;
        $link{$date}    = "$base_url$server/$channel/$date";
        $months{"$Y-$M"}++;
    }

    my @months  = qw( Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec );
    my @days    = qw( S M T W T F S );
    my $dayhead = join '' => map "<th>$_</th>" => @days;
    my $html    = qq{<div class="calendars">\n};

    my %cals;
    for my $month (reverse sort keys %months) {
        my  ($Y, $M) = split '-', $month;
        my   $title  = $months[$M - 1] . ' ' . $Y;
        my   @weeks  = calendar($M, $Y);
        push @weeks, [] while @weeks < 6;

        $html .= qq{<table class="calendar">\n<thead>\n<tr class="calendar_title"><th colspan="7">$title</th></tr>\n<tr class="day_names">$dayhead</tr>\n</thead>\n<tbody>\n};

        for my $week (@weeks) {
            $html .= qq{<tr>};

            for my $day_num (0 .. 6) {
                my $day     = $week->[$day_num];
                my $content = '';

                if ($day) {
                    my $D    = sprintf '%02d', $day;
                    my $link = $link{"$Y-$M-$D"};
                    $content = $link ? qq{<a href="$link">$day</a>}
                                     : $day;
                }

                $html .= qq{<td>$content</td>};
            }

            $html .= qq{</tr>\n};
        }

        $html .= qq{</tbody>\n</table>\n};
    }

    $html .= qq{</div>\n};

    return $html;
}

# Returns the data for creating a usercount chart for all available data.
sub usercount_chart_for_channel {
    my ($server, $channel, $dbh) = @_;
    my @usercount_data;
    # Prepare the query that will fetch all the usercounts.
    my $q = $dbh->prepare('SELECT timestamp, count FROM usercount '
        . 'WHERE server = ? AND channel = ?');
    # Execute the query.
    $q->execute($server, $channel);
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
# vim: syn=perl sw=4 ts=4 expandtab
