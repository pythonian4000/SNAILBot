#!/usr/bin/perl
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
