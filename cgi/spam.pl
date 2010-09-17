#!/usr/bin/perl
#
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
use CGI::Carp qw(fatalsToBrowser);
use Carp qw(confess);
use lib '..';
use CGI;
use Config::File;
use Data::Dumper;
use HTML::Template;
use lib '../lib';
use IrcLog qw(get_dbh);
use IrcLog::WWW 'http_header';

my $q = CGI->new();

my @range =  sort $q->param("range");
my @single =  $q->param("single");

my $dbh = get_dbh();

my $range_count = scalar @range;

my $d1 = $dbh->prepare("UPDATE irclog SET spam = 1 WHERE id >= ? AND id <= ?");
my $d2 = $dbh->prepare("UPDATE irclog SET spam = 1 WHERE id = ?");

my $count = 0;

if ($range_count == 2){
    $count += $d1->execute($range[0], $range[1]);
}
elsif ($range_count == 0){
    # do nothing
}
else {
    confess "Select $range_count 'range' checkboxes, for security reasons only "
        . "two (or zero) are allowed";
}

for my $id (@single){
    $count += $d2->execute($id);
}

my $t = HTML::Template->new(
        filename => 'template/spam.tmpl',
        die_on_bad_params => 0,
);

my $conf = Config::File::read_config_file("cgi.conf");
my $base_url = $conf->{BASE_URL} || "/";
my $channel = $q->url_param('channel');
$channel =~ s/^\#//x;

$t->param(DATE      => $q->url_param('date'));
$t->param(COUNT     => $count);
$t->param(BASE_URL  => $base_url);
$t->param(CHANNEL   => $channel);


print http_header({no_xhtml => 1});

print $t->output;

# vim: expandtab sw=4 ts=4
