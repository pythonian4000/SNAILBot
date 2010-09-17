#!/usr/bin/perl
# Displays a list of servers that have channels with available day logs.
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

use CGI::Carp qw(fatalsToBrowser);
use strict;
use warnings;
use Config::File;
use File::Slurp;
use HTML::Template;
use lib '../lib';
use IrcLog qw(get_dbh);
use IrcLog::WWW qw(http_header);

use Cache::FileCache;

print http_header();
my $cache = new Cache::FileCache( { 
		namespace 		=> 'irclog',
		} );

my $data;
$data = $cache->get('index');
if ( ! defined $data){
	$data = get_index();
	$cache->set('index', $data, '5 hours');
}
print $data;

sub get_index {

	my $dbh = get_dbh();

	my $conf = Config::File::read_config_file('cgi.conf');
	my $base_url = $conf->{BASE_URL} || q{/};

	my $sth = $dbh->prepare("SELECT DISTINCT server FROM irclog");
	$sth->execute();

	my @servers;

	while (my @row = $sth->fetchrow_array()){
		$row[0] =~ s/^\#//;
		push @servers, { server => $row[0] };
	}

	my $template = HTML::Template->new(
			filename => 'template/index.tmpl',
			loop_context_vars   => 1,
			global_vars         => 1,
            die_on_bad_params   => 0,
    );
	$template->param(BASE_URL => $base_url);
	$template->param( servers => \@servers );
    {
        # Find and insert extras
        my $analytics_header = "extras/analytics-header.tmpl";
        if (-e $analytics_header) {
            $template->param(ANALYTICS_HEADER => q{} . read_file($analytics_header));
        }
        my $analytics_footer = "extras/analytics-footer.tmpl";
        if (-e $analytics_footer) {
            $template->param(ANALYTICS_FOOTER => q{} . read_file($analytics_footer));
        }
    }


	return $template->output;
}
