#!/opt/local/bin/perl -w
#
# Nagios probe for checking a NetApp filer
#
# Copyright (c) 2014 Piotr Kasprzak
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Installation:
#
# 1.) perl module dependencies:
#
# - lwp-useragent
# - xml-parser
# - Nagios::Plugin
# - Log::Log4perl
#
# e.g.:
#
# port istall p5.16-lwp-useragent-determined
# port install p5.16-xml-parser
#
# perl -MCPAN -e shell
# cpan> install Nagios::Plugin
# cpan> install Log::Log4perl
# cpan> install JSON
# cpan> install File::Slurp
# cpan> install Switch                 (CHORNY/Switch-2.17.tar.gz)
#
# 2.) Get NetApp perl SDK
#
# - Download netapp-manageability-sdk-5.3 from http://support.netapp.com/NOW/cgi-bin/software
# - Copy lib/perl/NetApp directory with the perl modules to somewhere where it can be found by perl
#

use strict;
use warnings;
use locale;

use Data::Dumper;
use Switch;

# Need to be installed from CPAN
use File::Slurp;
use Nagios::Plugin;
use Log::Log4perl;
use JSON;

# NetApp SDK
use lib "./NetApp";
use NaServer;
use NaElement;

# Standard variables used in Nagios::Plugin constructor
my $PROGNAME	= 'check_netapp';
my $VERSION		= '0.1';
my $DESCRIPTION	= 'Probe for checking a NetApp filer';
my $EXTRA_DESC	= '';
my $SHORTNAME	= 'CHECK_NETAPP';
my $LICENSE		= 'This nagios plugin is free software, and comes with ABSOLUTELY NO WARRANTY.
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
http://www.apache.org/licenses/LICENSE-2.0
Copyright 2014 Piotr Kasprzak';

# ---------------------------------------------------------------------------------------------------------------------
# Initialize logger

my $log4j_conf = q(

	log4perl.category.GWDG.NetApp = DEBUG, Screen

# 	log4perl.appender.Logfile = Log::Log4perl::Appender::File
# 	log4perl.appender.Logfile.filename = test.log
# 	log4perl.appender.Logfile.layout = Log::Log4perl::Layout::PatternLayout
# 	log4perl.appender.Logfile.layout.ConversionPattern = [%r] %F %L %m%n

	log4perl.appender.Screen = Log::Log4perl::Appender::Screen
	log4perl.appender.Screen.stderr = 0
	log4perl.appender.Screen.layout = Log::Log4perl::Layout::PatternLayout
	log4perl.appender.Screen.layout.ConversionPattern = [%d %F:%M:%L] %m%n
);

Log::Log4perl::init(\$log4j_conf);

our $log = Log::Log4perl::get_logger("GWDG::NetApp");

# ---------------------------------------------------------------------------------------------------------------------
# Print list of perf objects (perf-object-list-info)

sub call_api {

	my $request = shift;

	$log->info("API request: " . $request->{name});

	if ($log->is_debug()) {
		$log->debug("API request content:\n" . $request->sprintf());
	}
	
	my $result = $main::filer->invoke_elem($request);

	if ($log->is_debug()) {
		$log->debug("API response content:\n" . $result->sprintf())
	}

	# Check for error
	if ($result->results_status() eq 'failed') {
		$log->error("API request failed: " . $result->results_reason());
	}

	return $result;
}


# ---------------------------------------------------------------------------------------------------------------------
# Print list of perf objects (perf-object-list-info)

sub list_perf_objects {

	$log->info("Listing performance objects...");

	my $request	= NaElement->new('perf-object-list-info');
	my $result 	= call_api($request);

	foreach ($result->child_get('objects')->children_get()) {
		my $name 	= $_->child_get_string('name');
		my $level 	= $_->child_get_string('privilege-level');

		$log->info(sprintf("%30s: %10s", $name, $level));
	}

}


# ---------------------------------------------------------------------------------------------------------------------
# Print list of perf objects (perf-object-list-info)

sub load_perf_object_counter_descriptions {

	my $perf_object = shift;
	our $perf_object_counter_descriptions;

	$log->info("Loading performance counter descriptions for object: $perf_object");

	# Try to load from file first
	my $cache_file = "/tmp/check_netapp.perf_object_counter_descriptions.$perf_object.json";
	my $counter_descriptions = read_hash_from_file($cache_file, 0);

	if (! %$counter_descriptions) {

		# No cache file yet -> load data from API and persist in file for later.
		$log->info("No cache file found, loading from API...");

		my $request	= NaElement->new('perf-object-counter-list-info');
		$request->child_add_string('objectname', $perf_object);

		my $result 	= call_api($request);

		foreach ($result->child_get('counters')->children_get()) {

			my $counter_description = {};

			$counter_description->{'name'} 				= $_->child_get_string('name');
			$counter_description->{'privilege_level'} 	= $_->child_get_string('privilege-level');
			$counter_description->{'desc'} 				= $_->child_get_string('desc');
			$counter_description->{'properties'} 		= $_->child_get_string('properties');
			$counter_description->{'unit'} 				= $_->child_get_string('unit');
			$counter_description->{'base_counter'}		= $_->child_get_string('base-counter');

			$counter_descriptions->{$counter_description->{'name'}} = $counter_description;
		}

		# Persist to file
		write_hash_to_file($cache_file, $counter_descriptions);
	}

	# Make descriptions available for later
	$perf_object_counter_descriptions->{$perf_object} = $counter_descriptions;
}

# ---------------------------------------------------------------------------------------------------------------------
# Calc counter value based on it's description and values at times t-1 and t

sub calc_counter_value {

	my $counter_name		= shift;
	my $perf_object 		= shift;
	my $current_perf_data 	= shift;
	my $old_perf_data 		= shift;

	our $perf_object_counter_descriptions;

	$log->debug("Calculating value of counter '$counter_name' of perf object '$perf_object'");

	# Get counter descriptions. If no descriptions available yet, load them!
	if (! $perf_object_counter_descriptions->{$perf_object}) {
		load_perf_object_counter_descriptions($perf_object);
	} 

	my $counter_descriptions 	= $perf_object_counter_descriptions->{$perf_object};
	my $counter_description 	= $counter_descriptions->{$counter_name};

	# Check, if there is a description for the selected counter
	if (! %$counter_description) {
		$log->error("No description found for counter '$counter_name' of perf object '$perf_object'!");
		return;
	} else {
		$log->debug("Using description:\n" . Dumper($counter_description));
	}

	# Finally, calculate the value depending on the description
	switch (lc($counter_description->{'properties'})) {

		case 'raw' {
			# Just return raw value
			return $current_perf_data->{$counter_name};
		}

		case 'rate' {
			# (c2 - c1) / (t2 - t1)
			my $time_delta 		= $current_perf_data->{'timestamp'} - $old_perf_data->{'timestamp'};
			my $counter_value 	= ($current_perf_data->{$counter_name} - $old_perf_data->{$counter_name}) / $time_delta;

			return $counter_value;
		}

		case 'delta' {
			# c2 - c1
			my $counter_value 	= $current_perf_data->{$counter_name} - $old_perf_data->{$counter_name};

			return $counter_value;
		}

		case 'average' {
			# (c2 - c1) / (b2 - b1)
			my $base_counter_name = $counter_description->{'base_counter'};
			$log->debug("Using base counter '$base_counter_name' for calculations.");

			unless ($current_perf_data->{$base_counter_name} and $old_perf_data->{$base_counter_name}) {
				$log->error("Base counter not available in perf data!");
				return 0;
			}

			my $current_base_counter_data	= $current_perf_data->{$base_counter_name};
			my $old_base_counter_data 		= $old_perf_data->{$base_counter_name};

			my $counter_value = ($current_perf_data->{$counter_name} - $old_perf_data->{$counter_name}) /
								($current_base_counter_data - $old_base_counter_data);

			return $counter_value;
		}

		case 'percent' {
			# 100 * (c2 - c1) / (b2 - b1)
			my $base_counter_name = $counter_description->{'base_counter'};
			$log->debug("Using base counter '$base_counter_name' for calculations.");

			unless ($current_perf_data->{$base_counter_name} and $old_perf_data->{$base_counter_name}) {
				$log->error("Base counter not available in perf data!");
				return 0;
			}

			my $current_base_counter_data	= $current_perf_data->{$base_counter_name};
			my $old_base_counter_data 		= $old_perf_data->{$base_counter_name};

			my $counter_value = ($current_perf_data->{$counter_name} - $old_perf_data->{$counter_name}) /
								($current_base_counter_data - $old_base_counter_data);

			return 100 * $counter_value;
		}

		case 'text' {
			# Just text
			return $current_perf_data->{$counter_name};
		}

		case 'nodisp' {
			# Used for calculations (average, percent), should not be displayed directly
			$log->warn("This counter has the 'nodisp' property and should not be displayed directly!");
			return $current_perf_data->{$counter_name};
		}

		else {
			# Unknown properties value
			$log->error("Unkown properties value, just returning the current counter value!");
			return $current_perf_data->{$counter_name};
		}

	}

}

# ---------------------------------------------------------------------------------------------------------------------
# Read hash from file (in JSON format)

sub read_hash_from_file {

	my $file 						= shift;
	my $delete_file_after_reading 	= shift;

	our $json_parser;
	my $hash_data = {};

	if (-f $file) {

		$log->debug("Loading data from file: $file");
		my $hash_data_json = read_file($file);

		# Convert JSON to array
		$hash_data = $json_parser->decode($hash_data_json);

		if ($log->is_debug()) {
			$log->debug(Dumper($hash_data));
		}

		# Delete old file
		if ($delete_file_after_reading) {
			unlink $file;
		}
	}

	return $hash_data;
}

# ---------------------------------------------------------------------------------------------------------------------
# Write perf data to file (in JSON format)

sub write_hash_to_file {

	my $file 		= shift;
	my $hash_data 	= shift;

	our $json_parser;

	# Encode hash in JSON string
	my $hash_data_json = $json_parser->pretty->encode($hash_data);

	# Write to file
	write_file($file, $hash_data_json);
}

# ---------------------------------------------------------------------------------------------------------------------
# Render perf metrics in hash to something nagios can understand

sub render_perf_data {

	my $perf_data 		= shift;
	my $perf_data_count = scalar @$perf_data;
	my $rendered_output = '';

	$log->info("Rendering [$perf_data_count] perf metrics for nagios...");

	for my $counter (@$perf_data) {
		$log->debug(sprintf("%-20s: %10s", $counter->{'name'}, $counter->{'value'}));
		$rendered_output .= $counter->{'name'} . "=" . $counter->{'value'} . ",";
	}

	$log->debug("Rendered text:\n$rendered_output");

	return $rendered_output;
}

# ---------------------------------------------------------------------------------------------------------------------
# Get nfs v3 performance stats

sub get_nfsv3_perf_stats {

	$log->info("Getting performance performance stats for nfs v3...");

	my $tmp_file = "/tmp/check_netapp.get_nfsv3_perf_stats.json";

	my $request	= NaElement->new('perf-object-get-instances');
	$request->child_add_string('objectname', 'nfsv3');

	my $counters = NaElement->new('counters');

	$counters->child_add_string('counter', 'nfsv3_ops');

	#  ----- nfs v3 reads -----

	$counters->child_add_string('counter', 'nfsv3_read_latency');
	$counters->child_add_string('counter', 'nfsv3_avg_read_latency_base');
	$counters->child_add_string('counter', 'nfsv3_read_ops');

	#  ----- nfs v3 writes -----

	$counters->child_add_string('counter', 'nfsv3_write_latency');
	$counters->child_add_string('counter', 'nfsv3_avg_write_latency_base');
	$counters->child_add_string('counter', 'nfsv3_write_ops');

	$request->child_add($counters);

	my $result 				= call_api($request);
	my $current_perf_data 	= {};

	$current_perf_data->{'timestamp'} = $result->child_get_int('timestamp');

	foreach ($result->child_get('instances')->child_get('instance-data')->child_get('counters')->children_get()) {

		my $counter_name 	= $_->child_get_string('name');
		my $counter_value 	= $_->child_get_string('value');

		$current_perf_data->{$counter_name} = $counter_value;
	}

	# Load old counters from file and persist new ones insted

	my $old_perf_data = read_hash_from_file($tmp_file, 1);

	write_hash_to_file($tmp_file, $current_perf_data);

	# Calculate latencies / op rates
	if (%$old_perf_data) {

		my @derived_perf_data = ();

		push (@derived_perf_data,	{	'name' 	=> 'read_latency', 
										'value' => calc_counter_value('nfsv3_read_latency', 	'nfsv3', $current_perf_data, $old_perf_data)});

		push (@derived_perf_data,	{	'name'	=> 'write_latency',
										'value' => calc_counter_value('nfsv3_write_latency', 	'nfsv3', $current_perf_data, $old_perf_data)});

		push (@derived_perf_data,	{	'name'	=> 'ops_rate',
										'value' => calc_counter_value('nfsv3_ops', 				'nfsv3', $current_perf_data, $old_perf_data)});

		push (@derived_perf_data,	{	'name'	=> 'read_ops_rate',
										'value' => calc_counter_value('nfsv3_read_ops', 		'nfsv3', $current_perf_data, $old_perf_data)});

		push (@derived_perf_data,	{	'name'	=> 'write_ops_rate',
										'value' => calc_counter_value('nfsv3_write_ops', 		'nfsv3', $current_perf_data, $old_perf_data)});

		render_perf_data(\@derived_perf_data);
	}
}

# ---------------------------------------------------------------------------------------------------------------------
# Get aggregate performance stats

sub get_aggregate_perf_stats {

	my $aggregate = shift;

	$log->info("Getting performance stats for aggregate: $aggregate");

	my $tmp_file = "/tmp/check_netapp.get_aggregate_perf_stats.$aggregate.json";

	my $request	= NaElement->new('perf-object-get-instances');
	$request->child_add_string('objectname', 'aggregate');

	my $instances = NaElement->new('instances');
	$instances->child_add_string('instance', $aggregate);
	$request->child_add($instances);

	my $counters = NaElement->new('counters');

	$counters->child_add_string('counter', 'total_transfers');

	$counters->child_add_string('counter', 'user_reads');
	$counters->child_add_string('counter', 'user_writes');
	$counters->child_add_string('counter', 'user_read_blocks');
	$counters->child_add_string('counter', 'user_write_blocks');

	# ----- *_hdd version of counters are equal to normal as there are only hdds in the aggregates (no ssds) -----

	$counters->child_add_string('counter', 'total_transfers_hdd');

	$counters->child_add_string('counter', 'user_reads_hdd');
	$counters->child_add_string('counter', 'user_writes_hdd');
	$counters->child_add_string('counter', 'user_read_blocks_hdd');
	$counters->child_add_string('counter', 'user_write_blocks_hdd');

	$request->child_add($counters);

	my $result 				= call_api($request);
	my $current_perf_data 	= {};

	$current_perf_data->{'timestamp'} = $result->child_get_int('timestamp');

	foreach ($result->child_get('instances')->child_get('instance-data')->child_get('counters')->children_get()) {

		my $counter_name 	= $_->child_get_string('name');
		my $counter_value 	= $_->child_get_string('value');

		$current_perf_data->{$counter_name} = $counter_value;
	}

	# Load old counters from file and persist new ones insted

	my $old_perf_data = read_hash_from_file($tmp_file, 1);

	write_hash_to_file($tmp_file, $current_perf_data);

	# Calculate latencies / op rates
	if (%$old_perf_data) {

		my @derived_perf_data = ();

		push (@derived_perf_data,	{	'name' 	=> 'total_transfers', 
										'value' => calc_counter_value('total_transfers', 	'aggregate', $current_perf_data, $old_perf_data)});

		# 4K block size, in MB/s
		push (@derived_perf_data,	{	'name' 	=> 'user_read_blocks', 
										'value' => calc_counter_value('user_read_blocks', 	'aggregate', $current_perf_data, $old_perf_data) * 4 / 1024});

		# 4K block size, in MB/s
		push (@derived_perf_data,	{	'name' 	=> 'user_write_blocks', 
										'value' => calc_counter_value('user_write_blocks', 	'aggregate', $current_perf_data, $old_perf_data) * 4 / 1024});

		render_perf_data(\@derived_perf_data);	}
}

# ---------------------------------------------------------------------------------------------------------------------
# Get volume performance stats

sub get_volume_perf_stats {

	my $volume = shift;

	$log->info("Getting performance stats for volume: $volume");

	my $tmp_file = "/tmp/check_netapp.get_volume_perf_stats.$volume.json";

	my $request	= NaElement->new('perf-object-get-instances');
	$request->child_add_string('objectname', 'volume');

	my $instances = NaElement->new('instances');
	$instances->child_add_string('instance', $volume);
	$request->child_add($instances);

	my $counters = NaElement->new('counters');

	#  ----- Global stats -----

	$counters->child_add_string('counter', 'parent_aggr');
	$counters->child_add_string('counter', 'avg_latency');
	$counters->child_add_string('counter', 'total_ops');


	#  ----- Volume reads -----

	$counters->child_add_string('counter', 'read_data');
	$counters->child_add_string('counter', 'read_latency');
	$counters->child_add_string('counter', 'read_ops');
	$counters->child_add_string('counter', 'read_blocks');

	#  ----- Volume writes -----

	$counters->child_add_string('counter', 'write_data');
	$counters->child_add_string('counter', 'write_latency');
	$counters->child_add_string('counter', 'write_ops');
	$counters->child_add_string('counter', 'write_blocks');

	#  ----- Volume other ops -----

	$counters->child_add_string('counter', 'other_latency');
	$counters->child_add_string('counter', 'other_ops');

	#  ----- Volume nfs -----
	
	$counters->child_add_string('counter', 'nfs_read_data');
	$counters->child_add_string('counter', 'nfs_read_latency');
	$counters->child_add_string('counter', 'nfs_read_ops');

	$counters->child_add_string('counter', 'nfs_write_data');
	$counters->child_add_string('counter', 'nfs_write_latency');
	$counters->child_add_string('counter', 'nfs_write_ops');

	$counters->child_add_string('counter', 'nfs_other_latency');
	$counters->child_add_string('counter', 'nfs_other_ops');

	#  ----- Volume cifs -----

	$counters->child_add_string('counter', 'cifs_read_data');
	$counters->child_add_string('counter', 'cifs_read_latency');
	$counters->child_add_string('counter', 'cifs_read_ops');

	$counters->child_add_string('counter', 'cifs_write_data');
	$counters->child_add_string('counter', 'cifs_write_latency');
	$counters->child_add_string('counter', 'cifs_write_ops');

	$counters->child_add_string('counter', 'cifs_other_latency');
	$counters->child_add_string('counter', 'cifs_other_ops');

	#  ----- Volume iSCSI -----

	$counters->child_add_string('counter', 'iscsi_read_data');
	$counters->child_add_string('counter', 'iscsi_read_latency');
	$counters->child_add_string('counter', 'iscsi_read_ops');

	$counters->child_add_string('counter', 'iscsi_write_data');
	$counters->child_add_string('counter', 'iscsi_write_latency');
	$counters->child_add_string('counter', 'iscsi_write_ops');

	$counters->child_add_string('counter', 'iscsi_other_latency');
	$counters->child_add_string('counter', 'iscsi_other_ops');

	#  ----- Volume inodes -----

	$counters->child_add_string('counter', 'wv_fsinfo_public_inos_total');
	$counters->child_add_string('counter', 'wv_fsinfo_public_inos_reserve');
	$counters->child_add_string('counter', 'wv_fsinfo_public_inos_used');

	$request->child_add($counters);

	my $result 				= call_api($request);
	my $current_perf_data 	= {};

	$current_perf_data->{'timestamp'} = $result->child_get_int('timestamp');

	foreach ($result->child_get('instances')->child_get('instance-data')->child_get('counters')->children_get()) {

		my $counter_name 	= $_->child_get_string('name');
		my $counter_value 	= $_->child_get_string('value');

		$current_perf_data->{$counter_name} = $counter_value;
	}

	# Load old counters from file and persist new ones insted

	my $old_perf_data = read_hash_from_file($tmp_file, 1);

	write_hash_to_file($tmp_file, $current_perf_data);

	# Calculate latencies / op rates
	if (%$old_perf_data) {

		my $time_delta = 	$current_perf_data->{'timestamp'} - $old_perf_data->{'timestamp'};

		my $total_transfers_rate	= ($current_perf_data->{'total_transfers'} - $old_perf_data->{'total_transfers'}) / $time_delta;

		$log->info("total transfers rate: $total_transfers_rate");

		# 64K block size
		my $user_read_throughput	=  ($current_perf_data->{'user_read_blocks'}	- $old_perf_data->{'user_read_blocks'})  * 4 / ($time_delta * 1024);
		my $user_write_throughput	=  ($current_perf_data->{'user_write_blocks'}	- $old_perf_data->{'user_write_blocks'}) * 4 / ($time_delta * 1024);

		$log->info("aggr read  throughput (MB/s): $user_read_throughput");
		$log->info("aggr write throughput (MB/s): $user_write_throughput");
	}
}

# ---------------------------------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------------------------------

$log->info("Starting probe '$PROGNAME'...");

# Create Nagios::Plugin instance
our $plugin = Nagios::Plugin->new (	usage 		=> "Usage: %s <-H <hostname> -p <port>>|<-f <file>>",
									shortname	=> $SHORTNAME,
									version		=> $VERSION,
									blurb		=> $DESCRIPTION,
									extra		=> $EXTRA_DESC,
									license		=> $LICENSE,
									plugin 		=> $PROGNAME
								);


# Define additional arguments
$plugin->add_arg(
	spec 		=> 'hostname|H=s',
	help 		=> "H|hostname\n Hostname or IP address of the NetApp filer to check.\n (default: localhost)",
	required 	=> 0,
	default 	=> 'localhost'
);

$plugin->add_arg(
	spec 		=> 'user|U=s',
	help 		=> "u|user\n User name for login.\n (default: none)",
	required 	=> 0,
	default		=> ''
);

$plugin->add_arg(
	spec 		=> 'password|P=s',
	help 		=> "P|password\n Password for login.\n (default: none)",
	required 	=> 0,
	default 	=> ''
);

$plugin->add_arg(
	spec 		=> 'protocol|p=s',
	help 		=> "p|protocol\n Protocol to use for communication.\n (default: HTTPS)",
	required 	=> 0,
	default 	=> 'HTTPS'
);


$plugin->getopts;

# Signal handler - TERM

local $SIG{ALRM} = sub {
	local $SIG{TERM} = 'IGNORE';
	kill TERM => -$$;
	$plugin->nagios_exit(CRITICAL, "Data could not be collected in the allocated time (" . $plugin->opts->timeout . "s)");
};

local $SIG{TERM} = sub {
	local $SIG{TERM} = 'IGNORE';
	kill TERM => -$$;
	$plugin->nagios_die("Plugin received TERM signal.");
};

alarm($plugin->opts->timeout);

# Get server context

our $filer = NaServer->new($plugin->opts->hostname, 1, 15);

$filer->set_admin_user($plugin->opts->user, $plugin->opts->password);
$filer->set_bindings_family('7-Mode');
$filer->set_transport_type($plugin->opts->protocol);

eval { 
	my $filer_version = $filer->system_get_version();
   	$log->info("Data ONTAP version: $filer_version->{version}");
 };

if($@) { # check for any exception
	my ($error_reason, $error_code) = $@ =~ /(.+)\s\((\d+)\)/;
   	$log->error("Error Reason: $error_reason, Code: $error_code");
}

# Get perf object list

our $json_parser = JSON->new->allow_nonref;

# Array of counter descriptions for various objects. Persisted into files.
our $perf_object_counter_descriptions = {};


#list_perf_objects();

#load_perf_object_counter_descriptions('nfsv3');

#load_perf_object_counter_descriptions('vfiler');

#load_perf_object_counter_descriptions('volume');

#load_perf_object_counter_descriptions('aggregate');

#load_perf_object_counter_descriptions('processor');

#aggregate, cifs, cifs_ops, cifs_stats, disk, ifnet, iscsi, perf, processor, raid, sis, system, 

#get_nfsv3_perf_stats();
get_aggregate_perf_stats('aggr_SUBSAS01');
#get_aggregate_perf_stats('aggr_SUBBSAS01');




$plugin->nagios_exit(OK, "Probe finished!");