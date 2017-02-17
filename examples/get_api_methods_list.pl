use utf8;
use strict;
use warnings;
use RP::API::VK;
use Data::Dumper;
use Carp;

my $api = RP::API::VK->new();

# Get all methods
#
my @all_methods = $api->get_api_methods_list();
printf(
	"[All API methods: %s]\n%s\n\n",
	scalar(@all_methods),
	join(', ', @all_methods)
);

# Using get_api_methods_list with search
#
my $audio_methods = $api->get_api_methods_list('audio');
printf(
	"[All API audio-methods: %s]\n%s\n\n",
	scalar(@$audio_methods),
	join(', ', @$audio_methods)
);
