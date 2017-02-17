package RP::API::VK;

use utf8;
use strict;
use warnings;
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

my $api_inited = 0;
my $api_cfg    = {};

my $def_api_url    = 'https://api.vk.com/method/';
my $def_api_method = 'GET';

sub new
{
	my $class = shift;
	return bless { @_ }, $class;
}

sub default_timeout    { 60 }
sub default_user_agent { __PACKAGE__ . ' HTTP Client, v' . $VERSION }

sub get_result      { $_[0]->{result} }
sub get_status      { $_[0]->{status} }
sub get_error       { $_[0]->{error} }
sub get_request     { $_[0]->{request} }
sub get_response    { $_[0]->{response} }
sub get_timeout     { $_[0]->{timeout} || default_timeout }
sub get_user_agent  { $_[0]->{user_agent} || default_user_agent }

sub set_timeout
{
	my ($self, $value) = @_;
	$self->{timeout} = $value if $value;
}

sub set_user_agent
{
	my ($self, $value) = @_;
	$self->{user_agent} = $value if $value;
}

sub get_http_client
{
	my $self = shift;

	if (!defined $self->{http_client}) {
		$self->{http_client} = LWP::UserAgent->new(
			timeout  => $self->get_timeout,
			agent    => $self->get_user_agent,
			ssl_opts => { verify_hostname => 0 },
		)
	}

	return $self->{http_client};
}

sub set_http_client
{
	my ($self, $value) = @_;
	if ($value && ref $value eq 'LWP::UserAgent') {
		$self->{http_client} = $value;
	}
}

sub get_api_method_info
{
	my ($self, $api_method) = @_;
	$self->_api_methods_init();
	unless (defined($api_cfg->{$api_method})) {
		print "Warning: API method $api_method does not exists.\n" .
		      "Try 'get_api_methods_list' to get allowed methods names\n";
	}
	return $api_cfg->{$api_method} || '';
}

sub get_api_methods_list
{
	my ($self, $substr) = @_;
	$self->_api_methods_init();
	my @methods = sort
	              grep { !$substr || index(lc($_), lc($substr)) >= 0 }
	              keys %$api_cfg;
	return wantarray ? @methods : \@methods;
}

sub AUTOLOAD
{
	my $self = shift;
	my $method = $AUTOLOAD;
	$method =~ s/.*:://;
	$self->call($method, @_);
}

sub call
{
	my ($self, $api_method, $api_data, $callback) = @_;

	# Check whether an api_method exists
	#
	my $api_method_info = $self->get_api_method_info($api_method);
	croak qq/API method "$api_method" not exists!/ unless $api_method_info;

	# Init
	#
	my $res;
	my $use_cache = $api_data->{use_cache} // 0;

	$self->{result}   = '';
	$self->{status}   = '';
	$self->{error}    = '';
	$self->{request}  = '';
	$self->{response} = '';

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

	# Build request data
	#
	my $url    = $api_data->{api_url} || $self->{api_url} || $def_api_url;
	my $method = $api_data->{method}  || $self->{method}  || $def_api_method;
	$url .= $api_method_info->{name};

	# Fill method parameters
	#
	my $param  = {};
	L_PROP: foreach my $prop (@{ $api_method_info->{parameters} })
	{
		# Check value
		# 
		# Not defined, but found default? Use default
		# Not defined, no default, but required? Throw exception
		# Not defined, no default, not required? Go to next param
		#
		my $val;
		my $key = $prop->{name};
		if (!defined $api_data->{$key}) {
			if (defined $prop->{default}) {
				$val = $prop->{default};
			}
			elsif ($prop->{required} // 0) {
				return _return_error(sprintf(
					'%s: %s is required (%s)',
					$api_method,
					$key,
					$prop->{description} // '',
				));
			}
			else {
				next L_PROP;
			}
		}
		else {
			$val = $api_data->{$key};
		}

		if ($prop->{type} eq 'integer')
		{
			# Please note: silent convert value to integer.
			# No warnings yet if format is not valid.
			# In future this behaviour may be changed.
			$val = int($val);
			my $error = _check_integer($val, $api_method, $prop);
			return _return_error($error) if $error;
			$param->{$key} = $val;
		}

		elsif ($prop->{type} eq 'string')
		{
			my $error = _check_string($val, $api_method, $prop);
			return _return_error($error) if $error;
			$param->{$key} = $val;
		}

		elsif ($prop->{type} eq 'boolean')
		{
			$param->{$key} = $val && lc($val) ne 'false' ? 1 : 0;
		}

		elsif ($prop->{type} eq 'number')
		{

			# Please note: silent convert value to number.
			# No warnings yet if format is not valid.
			# In future this behaviour may be changed.
			$val += 0;
			my $error = _check_number($val, $api_method, $prop);
			return _return_error($error) if $error;
			$param->{$key} = $val;
		}

		elsif ($prop->{type} eq 'array')
		{
			return _return_error(sprintf(
				'%s: %s should be ARRAY or comma-separated string (%s)',
				$api_method,
				$key,
				$prop->{description} // '',
			)) if ref $val && ref $val ne 'ARRAY';
			
			my $vals = ref $val ? $val : [ split(m/\s*[,;]\s*/, $val) ];

			return _return_error(sprintf(
				'%s: %s should have %s or less items, you try %s',
				$api_method,
				$key,
				$prop->{maxItems},
				scalar(@$vals),
			)) if $prop->{maxItems} && scalar(@$vals) > $prop->{maxItems};

			for (my $i = 0, my $l = scalar(@$vals); $i < $l; $i++)
			{
				if ($prop->{items}->{type} eq 'integer')
				{
					$vals->[$i] = int($vals->[$i]);
					my $error = _check_integer($vals->[$i], $api_method, $prop);
					return _return_error($error) if $error;
				}
				elsif ($prop->{items}->{type} eq 'string')
				{
					my $error = _check_string($vals->[$i], $api_method, $prop);
					return _return_error($error) if $error;
				}
			}

			$param->{$key} = join(',', @$vals);
		}
	}

	# Add "access_token", "v" to data hashref
	#
	if (defined($api_data->{access_token})) {
		$param->{access_token} = $api_data->{access_token};
	}
	if (defined($api_data->{v})) {
		$param->{v} = $api_data->{v};
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

	else {
		$url .= (index($url, '?') > 0 ? '&' : '?') . $qs;
		$self->{request} = HTTP::Request->new($method => $url);
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

	$res->{status} ||= 'ok';

	if ($use_cache) {
		$self->_write_to_cache_file($api_method, $api_data, $res);
	}
	
	$self->{result} = $res;

	# Call callback (TBD, for async requests)
	#
	if ($callback && ref $callback eq 'CODE') {
		$callback->($res, $self);
	}

	# Return
	#
	return $res;
}

=head2 _check_integer

Return error message unless all right, otherwise return null.

=cut

sub _check_integer
{
	my $val        = shift;
	my $api_method = shift;
	my $prop       = shift;

	if ((defined $prop->{minimum} && $prop->{minimum} > $val)
	 || (defined $prop->{maximum} && $prop->{maximum} < $val)
	 || (defined $prop->{item}->{minimum} && $prop->{item}->{minimum} > $val)
	 || (defined $prop->{item}->{maximum} && $prop->{item}->{maximum} < $val)
	) {
		return sprintf(
			'%s: %s=%s is not in range %s-%s (%s)',
			$api_method,
			$prop->{name},
			$val,
			$prop->{item}->{minimum}     // $prop->{minimum}     // 'undef',
			$prop->{item}->{maximum}     // $prop->{maximum}     // 'undef',
			$prop->{item}->{description} // $prop->{description} // '',
		);
	}

	# Check enum-value
	#
	if (defined $prop->{enum}
	 && ref $prop->{enum} eq 'ARRAY'
	 && !_in_array($val, @{ $prop->{enum} })
	) {
		return sprintf(
			'%s: illegal enum-value %s=%s (%s)',
			$api_method,
			$prop->{name},
			$val,
			$prop->{description},
		);
	}

	# All right
	#
	return 0;
}

sub _check_number
{
	my $val        = shift;
	my $api_method = shift;
	my $prop       = shift;

	if ((defined $prop->{minimum} && $prop->{minimum} > $val)
	 || (defined $prop->{maximum} && $prop->{maximum} < $val)
	 || (defined $prop->{item}->{minimum} && $prop->{item}->{minimum} > $val)
	 || (defined $prop->{item}->{maximum} && $prop->{item}->{maximum} < $val)
	) {
		return sprintf(
			'%s: %s=%s is not in range %s-%s (%s)',
			$api_method,
			$prop->{name},
			$val,
			$prop->{item}->{minimum}     // $prop->{minimum}     // 'undef',
			$prop->{item}->{maximum}     // $prop->{maximum}     // 'undef',
			$prop->{item}->{description} // $prop->{description} // '',
		);
	}

	# All right
	#
	return 0;
}

sub _check_string
{
	my $val        = shift;
	my $api_method = shift;
	my $prop       = shift;
	
	if ((defined $prop->{minLength} && $prop->{minLength} > length($val))
	 || (defined $prop->{maxLength} && $prop->{maxLength} < length($val))
	 || (defined $prop->{item}->{minLength} && $prop->{item}->{minLength} > length($val))
	 || (defined $prop->{item}->{maxLength} && $prop->{item}->{maxLength} < length($val))
	) {
		return sprintf(
			'%s: length of %s=%s is not in range %s-%s (%s)',
			$api_method,
			$prop->{name},
			$val,
			$prop->{item}->{minLength}   // $prop->{minLength}   // 'undef',
			$prop->{item}->{maxLength}   // $prop->{maxLength}   // 'undef',
			$prop->{item}->{description} // $prop->{description} // '',
		);
	}

	# Check enum-value
	#
	if (defined $prop->{enum}
	 && ref $prop->{enum} eq 'ARRAY'
	 && !_in_array($val, @{ $prop->{enum} })
	) {
		return sprintf(
			'%s: illegal enum-value %s=%s (%s)',
			$api_method,
			$prop->{name},
			$val,
			$prop->{description},
		);
	}
}

sub _read_file
{
	my $filename = shift;
	croak "$filename does not exists" unless -e $filename;
	local $/ = undef;
	open my $fh, $filename or carp "Couldn't open file: $!";
	binmode $fh;
	my $content = <$fh>;
  	close $fh;
  	return $content;
}

sub _api_methods_init
{
	my $self = shift;

	unless ($api_inited)
	{
		my $json_file = catfile(
			substr(abs_path(__FILE__), 0, -3),
			'vk-api-schema/methods.json'
		);

		my $json = decode_json(_read_file($json_file));

		if (!defined($json->{methods}) || ref $json->{methods} ne 'ARRAY') {
			carp 'Invalid methods.json, methods not found!';
		}

		foreach my $method (@{$json->{methods}}) {
			my $method_name = ucfirst($method->{name});
			$method_name =~ s/\.(.)/\u$1/;
			$api_cfg->{ $method_name } = $method;
		}

		$api_inited = 1;
	}

	return $api_inited;
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

sub _in_array
{
	my ($value, @list) = @_;
	foreach my $item (@list) {
		return 1 if $item eq $value;
	}
	return 0;
}

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

1;

__END__



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











1;

__END__

1;

