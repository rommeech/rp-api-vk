use utf8;
use strict;
use warnings;
use RP::API::VK;
use Data::Dumper;
use Carp;

my $api = RP::API::VK->new();

my $res = $api->call('UsersGet', {
	user_ids => '1,2,3,4',
});

printf("[AudioSearch API call]\n%s\n\n", Dumper($res));
