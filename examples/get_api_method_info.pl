use utf8;
use strict;
use warnings;
use RP::API::VK;
use Data::Dumper;
use Carp;

my $method = shift || 'WallGet';

my $api = RP::API::VK->new();

# Get all methods
#
my $method_info = $api->get_api_method_info($method);
printf(
	"[API method $method info]\n%s\n\n",
	Dumper($method_info),
);

