use utf8;
use strict;
use warnings;
use File::Spec::Functions qw/catfile catdir tmpdir/;
use Cwd qw/abs_path getcwd/;
use File::Basename;
use JSON::XS;
use Carp;

my $s_fields = {};
my $s_types  = {};
my $s_f2t    = {};

my $json_file = catfile(getcwd(), '../vk-api-schema/methods.json');

my $json = decode_json(_read_file($json_file));

foreach my $method (@{$json->{methods}}) {
	foreach my $param (@{$method->{parameters}}) {
		_stat_fields($param);
	}
}

printf "[Types]\n%s\n\n", join("\n", map { $_ . ' / ' . $s_types->{$_} } sort keys %$s_types);
printf "[All fields]\n%s\n\n", join("\n", sort keys %$s_fields);
printf "[All fields by type]\n%s\n\n", join("\n", sort keys %$s_f2t);


sub _stat_fields
{
	my $param  = shift;
	my $parent = shift;

	$parent ||= '';
	$parent .= '/' if $parent;

	my $type = defined $param->{enum} ? 'enum:'.$param->{type} : $param->{type};
	$s_types->{$parent . $type}++;

	foreach my $field (keys %$param)
	{
		
		if (ref $param->{$field} eq 'HASH') {
			_stat_fields($param->{$field}, $parent . $field);
		}
		elsif (ref $param->{$field} eq 'ARRAY') {
			$s_fields->{$parent . $field . '[ARRAY]'}++;
			$s_f2t->{$parent . $type . '::' . $field . '[ARRAY]'}++;
		}
		else {
			$s_fields->{$parent . $field}++;
			$s_f2t->{$parent . $type . '::' . $field}++;
		}
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
