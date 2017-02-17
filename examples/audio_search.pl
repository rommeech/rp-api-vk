=cut

https://oauth.vk.com/authorize?client_id=3087106&redirect_uri=https://oauth.vk.com/blank.html&display=mobile&scope=31&response_type=token&revoke=1


=cut

use utf8;
use strict;
use warnings;
use RP::API::VK;
use Data::Dumper;
use Carp;

my $api = RP::API::VK->new(debug => 1);

my $res = $api->call('AudioSearch', {
	q => 'Leila K',
	count => 10,
	v => '5.53',
	auto_complete => 0,
	sort => 2,
	access_token => '1fc9499c44046adebd6515da0c399956b089af773577fca4d3b6f3ff195c07544a4b6196d27abe105fa62',
});

printf("[AudioSearch API call]\n%s\n\n", Dumper($res));
