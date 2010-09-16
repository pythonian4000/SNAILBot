#!/usr/bin/perl
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
use IrcLog qw(get_dbh gmt_today);

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
    my $conf     = Config::File::read_config_file('cgi.conf');
    my $base_url = $conf->{BASE_URL} || q{/};

    my $t = HTML::Template->new(
            filename            => 'template/channel-index.tmpl',
            die_on_bad_params   => 0,
    );

    # we are evil and create a calendar entry for month between the first
    # and last date
    my $dbh       = get_dbh();
    my $get_dates = 'SELECT DISTINCT day FROM irclog WHERE server = ? AND channel = ? ORDER BY day';
    my $dates     = $dbh->selectcol_arrayref($get_dates, undef, ($server, '#' . $channel));

    $t->param(SERVER   => $server);
    $t->param(CHANNEL  => $channel);
    $t->param(BASE_URL => $base_url);
    $t->param(CALENDAR => calendar_for_channel($server, $channel, $dates, $base_url));
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
    $channel =~ s/\A\#//smx;

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

# vim: syn=perl sw=4 ts=4 expandtab
