package RP::API::VK;

use utf8;
use strict;
use warnings;
use base qw/RP::API/;
use Encode qw/decode encode/;
use File::Spec::Functions qw/catfile catdir tmpdir/;
use Digest::MD5 qw/md5_hex/;
use Cwd qw/abs_path/;
use File::Basename;
use LWP::UserAgent;
use HTTP::Request;
use Scalar::Util;
use Data::Dumper;
use File::Slurp;
use URI::Escape;
use JSON::XS;
use Carp;

our $VERSION = 0.01;
our $AUTOLOAD;

my $api_inited;
my $api_cfg;

sub new
{
	my $class = shift;
	return bless { @_ }, $class;
}

sub AUTOLOAD
{
	my $self = shift;
	my $method = $AUTOLOAD;
	$method =~ s/.*:://;
	$self->call($method, @_);
}

sub get_api_method_info
{
	my ($self, $api_method) = @_;
	return $self->_get_api_method_cfg($api_method);
}

sub _get_api_method_cfg
{
	my ($self, $api_method) = @_;

	unless ($api_inited)
	{

		my $json_dir  = catdir(dirname(abs_path($0)), '../../vk-api-schema/');
		my $json_file = catfile($json_dir, 'methods.json');

		$api_inited = 1;

=cut	
		my $cfg = RP::API::Dirty::Schema->$api_method();
		
		$cfg->{request}  = $cfg->{request_schema}
			? decode_json(encode('utf8', $cfg->{request_schema}))
			: {};
		#$cfg->{response} = $cfg->{response_schema}
		#	? decode_json(encode('utf8', $cfg->{response_schema}))
		#	: {};

		if (defined $cfg->{required} && ref $cfg->{required} eq 'ARRAY') {
			$cfg->{request}->{required} = $cfg->{required};
		}
		
		$cfg->{method}    ||= RP::API::Dirty::Schema::method;
		$cfg->{mime_type} ||= RP::API::Dirty::Schema::mime_type;

		$cfg->{request}->{mandatory} = { map { $_ => 1 }
										 @{ $cfg->{request}->{required} } };

		$self->{cfg}->{$api_method} = $cfg;
=cut

	}

	return $api_cfg->{$api_method} || '';
}

1;

__END__

sub call
{
	my ($self, $api_method, $api_data, $callback) = @_;



	# Check whether an api_method exists
	#
	#croak qq/API method "$api_method" not exists!/
	#	unless RP::API::Dirty::Schema->can($api_method);

	


	# Init
	#
	$self->{result}   = '';
	$self->{status}   = '';
	$self->{error}    = '';
	$self->{request}  = '';
	$self->{response} = '';

	my $res;
	my $use_cache = $api_data->{use_cache} // 0;

	# Try to get from cache
	#
	if ($use_cache) {
		$res = $self->_read_from_cache_file($api_method, $api_data);
		if ($res) {
			$self->{result} ||= $res;

			# Call callback (TBD, for async requests)
			#
			if ($callback && ref $callback eq 'CODE') {
				$callback->($res, $self);
			}

			# Return
			#
			return $res;
		}
	}

	# Get action config
	#
	my $cfg = $self->_get_api_method_cfg($api_method);

	## Check mandaroty parameters
	##
	#foreach my $param (@{$cfg->{request}->{required}}) {
	#	if (!defined $api_data->{$param} &&
	#	    !$cfg->{request}->{properties}->{$param}->{default}
	#	) {
	#		return _return_error(sprintf(
	#			'Parameter %s is required, got no value, no default found',
	#			$param,
	#		));
	#	}
	#}

	# Build request data
	#
	my $url    = $api_data->{url}    || $cfg->{url};
	my $method = $api_data->{method} || $cfg->{method};
	
	my $param  = {};
	while (my ($key, $prop) = each %{ $cfg->{request}->{properties} })
	{
		if (defined $api_data->{$key})
		{
			# Check type
			if (defined $prop->{enum}) {
				if (!_in_array($api_data->{$key}, @{ $prop->{enum} })) {
					return _return_error(sprintf(
						'%s: invalid enum-value %s=%s (allowed: %s)',
						$api_method,
						$key,
						$api_data->{$key},
						join(', ',  @{ $prop->{enum} })
					));
				}
			}
			elsif (defined $prop->{type} && (
				($prop->{type} eq 'string' && !_is_string($api_data->{$key}))
			 || ($prop->{type} eq 'integer' && !_is_int($api_data->{$key}))
			)) {
				return _return_error(sprintf(
					'%s: invalid type %s value %s=%s',
					$api_method,
					$prop->{type},
					$key,
					$api_data->{$key},
				));
			}

			$param->{$key} = $api_data->{$key};
		}
		elsif (defined $prop->{default}) {
			$param->{$key} = $prop->{default};
		}
		elsif (defined $cfg->{request}->{mandatory}->{$key}) {
			return _return_error(sprintf(
				'%s: parameter %s is required',
				$api_method,
				$key,
			));
		}
	}

	# URL's placeholders
	#
	if (my @placeholders = ($url =~ m/\{(.*?)\}/g)) {
		foreach my $key (@placeholders) {
			if (!defined $api_data->{$key}) {
				return _return_error(sprintf(
					'%s: parameter %s is required',
					$api_method,
					$key,
				));
			}
			$url =~ s/\{$key\}/$api_data->{$key}/g;
		}
	}

	# Using sort here for generating of cache file name later.
	#
	my $qs = join('&',
				map { sprintf('%s=%s', $_, uri_escape($param->{$_})) }
				sort keys %$param);

	# Build request
	#
	if ($method eq 'POST') {
		my $headers = HTTP::Headers->new(
			Content_Type   => 'application/x-www-form-urlencoded',
			Content_Length => length($qs),
		);
		$self->{request} = HTTP::Request->new(POST => $url, $headers, $qs);
	}

	elsif ($method eq 'DELETE' || $method eq 'PATCH') {
		$url .= (index($url, '?') ? '?' : '&') . $qs;
		$self->{request} = HTTP::Request->new($method => $url);
	}

	elsif (!$method || $method eq 'GET') {
		$url .= (index($url, '?') ? '?' : '&') . $qs;
		$self->{request} = HTTP::Request->new(GET => $url);
	}

	else {
		return _return_error(sprintf('Unsopported HTTP method=%s', $method));
	}

	# Set up custom HTTP headers
	#
	if ($cfg->{http_headers}) {
		foreach my $hdr (keys %{ $cfg->{http_headers} }) {
			if (!defined $api_data->{$hdr}) {
				return _return_error(sprintf(
					'Header %s is required, got no value of parameter %s',
					$cfg->{http_headers}->{$hdr},
					$hdr,
				));
			}
			$self->{request}->header(
				$cfg->{http_headers}->{$hdr},
				$api_data->{$hdr}
			);
		}
	}

	# Call API action request
	#
	$self->{response} = $self->get_http_client->request($self->{request});
	
	if ($self->{debug}) {
		print "Request:\n";
		print $self->{request}->as_string();
		print "Response:\n";
		print $self->{response}->as_string();
	}

	# Parse and check response
	#
	if ($self->{response}->content
	 && $self->{response}->content ne 'null'
	 && index(
			$self->{response}->header('Content-Type'),
			'application/json'
		) == 0
	) {
		$res = decode_json($self->{response}->content);
	}

	elsif ($self->{response}->code > 200) {
		$res->{status} = 'http_error';
		$res->{error}  = sprintf(
			'%s %s',
			$self->{response}->code,
			$self->{response}->message,
		);
	}

	else {
		$res->{status} = 'server_error';
		$res->{error}  = 'Invalid response format';
	}

	# Make human-readable error string
	#
	if (defined $res->{errors} && ref $res->{errors} eq 'ARRAY') {
		$res->{error} = join(
			"; ",
			map { sprintf('%s: %s', $_->{name}, $_->{description}->{code}) }
				@{ $res->{errors} }
		);
	}
	elsif (defined $res->{errors}) {
		$self->{error} = $res->{errors};
	}

	$res->{status} ||= 'ok';

	if ($use_cache) {
		$self->_write_to_cache_file($api_method, $api_data, $res);
	}
	
	$self->{result} ||= $res;

	# Call callback (TBD, for async requests)
	#
	if ($callback && ref $callback eq 'CODE') {
		$callback->($res, $self);
	}

	# Return
	#
	return $res;
}

=cut
sub auth_register           { shift->call('auth_register',          @_) }
sub auth_login              { shift->call('auth_login',             @_) }
sub auth_password_change    { shift->call('auth_password_change',   @_) }
sub auth_password_reset     { shift->call('auth_password_reset',    @_) }
sub auth_social_login       { shift->call('auth_social_login',      @_) }
sub auth_social_register    { shift->call('auth_social_register',   @_) }
sub auth_social_connect     { shift->call('auth_social_connect',    @_) }
sub auth_social_disconnect  { shift->call('auth_social_disconnect', @_) }

sub get_posts               { shift->call('get_posts',              @_) }
sub create_post             { shift->call('create_post',            @_) }
sub get_post                { shift->call('get_post',               @_) }
sub get_post_votes          { shift->call('get_post_votes',         @_) }
sub vote_post               { shift->call('vote_post',              @_) }

sub posts_subscriptions     { shift->call('posts_subscriptions',    @_) }
=cut



sub _in_array
{
	my ($value, @list) = @_;
	foreach my $item (@list) {
		return 1 if $item eq $value;
	}
	return 0;
}

sub _is_int { $_[0] eq int($_[0]) }
sub _is_string { 1 }



sub _return_error
{
	my $error_msg    = shift;
	my $error_status = shift || 'error';
	carp $error_msg;
	return({
		status	=> $error_status,
		error	=> $error_msg,
	});
}

sub _write_to_cache_file
{
	my ($self, $api_method, $api_data, $api_res) = @_;
	my $file_name = $self->_get_cache_file_name($api_method, $api_data);
print "Try to write to $file_name...\n";
	return write_file($file_name, encode_json($api_res));
}

sub _read_from_cache_file
{
	my ($self, $api_method, $api_data) = @_;
	my $file_name = $self->_get_cache_file_name($api_method, $api_data);
print "Try to read from $file_name...\n";
	my $json_text = $file_name && -e $file_name ? read_file($file_name) : '';
	return $json_text ? decode_json($json_text) : '';
}

sub _get_cache_dir_name
{
	my $self = shift;
	unless (defined $self->{cache_dir}) {
		my $dir_name = lc __PACKAGE__;
		$dir_name =~ s/:+/./g;
		$dir_name = catdir(tmpdir(), $dir_name);
		mkdir $dir_name unless -d $dir_name;
		$self->{cache_dir} = -d $dir_name ? $dir_name : '';
	}
	return $self->{cache_dir};
}

sub _get_cache_file_name
{
	my ($self, $api_method, $api_data) = @_;
	my $file_name;
	my $dir_name = $self->_get_cache_dir_name();
	if ($dir_name) {
		$file_name = md5_hex(
			$api_method,
			map { $_, $api_data->{$_} } sort keys %$api_data
		);
		$file_name = catfile($dir_name, $file_name);
	}
	return $file_name;
}

1;

__END__

1;

