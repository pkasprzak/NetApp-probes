#!/usr/bin/env perl -X
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
# -------------
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
# cpan> install Switch                 	(CHORNY/Switch-2.17.tar.gz)
# cpan> install Clone 					(GARU/Clone-0.37.tar.gz)
#
# 2.) Get NetApp perl SDK
#
# - Download netapp-manageability-sdk-5.3 from http://support.netapp.com/NOW/cgi-bin/software
# - Copy lib/perl/NetApp directory with the perl modules to somewhere where it can be found by perl
#
# ToDo:
# -----
#
# - Fix Perl interpreter call
# - Make it possible to select various stat groups at the same time => new way to pass parameter for parameter groups (use "="?)
# - Make it possible to filter counter (white list)
#


use strict;
use warnings;
#no warnings;
use locale;

use Data::Dumper;
use Switch;
use Clone qw(clone);

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
my $DESCRIPTION	= 'Probe for checking a NetApp filer. Examples:\n'													.
					'check_netapp.pl -H <filer-ip> -U <user> -P <password> -s aggregate -i <aggregate-name>\n'		.
					'check_netapp.pl -H <filer-ip> -U <user> -P <password> -s processor\n'							.
					'check_netapp.pl -H <filer-ip> -U <user> -P <password> -s nfsv3\n'								.
					'check_netapp.pl -H <filer-ip> -U <user> -P <password> -s system';
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

#	log4perl.category.GWDG.NetApp = DEBUG, Screen, Logfile
	log4perl.category.GWDG.NetApp = DEBUG, Logfile


 	log4perl.appender.Logfile = Log::Log4perl::Appender::File
 	log4perl.appender.Logfile.filename = /var/log/check_netapp.log
 	log4perl.appender.Logfile.layout = Log::Log4perl::Layout::PatternLayout
 	log4perl.appender.Logfile.layout.ConversionPattern = [%d %F:%M:%L] %m%n

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
	our $tmp_dir;
	my $cache_file = "$tmp_dir/" . "check_netapp.perf_object_counter_descriptions.$perf_object.json";
	my $counter_descriptions = read_hash_from_file($cache_file, 0);

	if (! %$counter_descriptions) {

		# No cache file yet -> load data from API and persist in file for later.
		$log->info("No cache file found, loading from API...");

		my $request	= NaElement->new('perf-object-counter-list-info');
		$request->child_add_string('objectname', $perf_object);

		my $result 	= call_api($request);

		foreach my $na_element ($result->child_get('counters')->children_get()) {

			my $counter_description = {};

			$counter_description->{'name'} 				= $na_element->child_get_string('name');
			$counter_description->{'privilege_level'} 	= $na_element->child_get_string('privilege-level');
			$counter_description->{'desc'} 				= $na_element->child_get_string('desc');
			$counter_description->{'properties'} 		= $na_element->child_get_string('properties');
			$counter_description->{'unit'} 				= $na_element->child_get_string('unit');
			$counter_description->{'base_counter'}		= $na_element->child_get_string('base-counter');
			$counter_description->{'type'}				= $na_element->child_get_string('type');

			# Need special processing stuff for processor objects
			if (! ($perf_object eq 'processor')) {
				# Standard counter description
				$counter_descriptions->{$counter_description->{'name'}} = $counter_description;
			} else {
				# Get number of processors
				our $static_system_stats;
				my $processor_count = $static_system_stats->{'num_processors'};

				# Create for each processor instance a set of counter descriptions
				foreach my $processor (0 .. $processor_count - 1) {

					unless (defined $counter_description->{'type'} and $counter_description->{'type'} eq 'array') {

						my $new_counter_name 		= 'processor' . $processor . '_' . $counter_description->{'name'};
						my $new_counter_description	= clone($counter_description);

						$new_counter_description->{'name'} = $new_counter_name;
						$counter_descriptions->{$new_counter_description->{'name'}} = $new_counter_description;

					} else {
						# For type == array we need to process the labels
						my @labels = split(',', $na_element->child_get('labels')->child_get_string('label-info'));
						foreach my $label (@labels) {

							my $new_counter_name 		= 'processor' . $processor . '_' . $counter_description->{'name'} . '_' . $label;
							my $new_base_counter		= 'processor' . $processor . '_' . $counter_description->{'base_counter'};
							my $new_counter_description	= clone($counter_description);

							$new_counter_description->{'name'} 			= $new_counter_name;
							$new_counter_description->{'base_counter'}	= $new_base_counter;

							delete $new_counter_description->{'type'};
							$counter_descriptions->{$new_counter_description->{'name'}} = $new_counter_description;
						}
					}
				}
			}
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
	if (! defined $counter_description or ! %$counter_description) {
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

			if ($current_base_counter_data == $old_base_counter_data) {
				$log->warn("Old and new base counter equal -> returning 0 to prevent division by zero.");
				return 0;
			}

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

		case 'string' {
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

	our $probe_output;
	our $plugin;

	my $perf_data 		= shift;
	my $perf_data_count = scalar @$perf_data;

	$log->info("Rendering [$perf_data_count] perf metrics for output format [$plugin->opts->output]...");

	# Render metrics according to seleced format
	switch (lc($plugin->opts->output)) {

		case 'nagios' {
			for my $counter (@$perf_data) {
				$log->debug(sprintf("%-20s: %10s", $counter->{'name'}, $counter->{'value'}));
				$probe_output .= $counter->{'name'} . "=" . $counter->{'value'} . ", ";
			}

			# Remove last two characters
			$probe_output = substr($probe_output, 0, length($probe_output) - 2);
		}

		else {
			# Unknown / unsupoorted format
			$log->error("Unkown format => not rendering!");
		}
	}

	$log->debug("Current rendered text:\n$probe_output");

#	return $probe_output;
}

# ---------------------------------------------------------------------------------------------------------------------
# Get basic system stats

sub get_static_system_stats {

	$log->info("Getting basic system stats...");

	our $tmp_dir;
	my $tmp_file = "$tmp_dir/" . "check_netapp.get_static_system_stats.json";

	# Try to load old counters from file and persist new ones insted
	my $static_system_stats = read_hash_from_file($tmp_file, 0);

	if (%$static_system_stats) {
		return $static_system_stats;
	}

	# No cache file -> get data from API

	my $request	= NaElement->new('perf-object-get-instances');
	$request->child_add_string('objectname', 'system');

	my $counters = NaElement->new('counters');

	# ----- Static system description information -----

	$counters->child_add_string('counter', 'hostname');
	$counters->child_add_string('counter', 'instance_name');
	$counters->child_add_string('counter', 'instance_uuid');
	$counters->child_add_string('counter', 'node_name');
	$counters->child_add_string('counter', 'num_processors');
	$counters->child_add_string('counter', 'ontap_version');
	$counters->child_add_string('counter', 'serial_no');
	$counters->child_add_string('counter', 'system_id');
	$counters->child_add_string('counter', 'system_model');

	$request->child_add($counters);

	my $result 				= call_api($request);
	$static_system_stats	= {};

	$static_system_stats->{'timestamp'} = $result->child_get_int('timestamp');

	foreach ($result->child_get('instances')->child_get('instance-data')->child_get('counters')->children_get()) {

		my $counter_name 	= $_->child_get_string('name');
		my $counter_value 	= $_->child_get_string('value');

		$static_system_stats->{$counter_name} = $counter_value;
	}

	# Persits data for next time
	write_hash_to_file($tmp_file, $static_system_stats);

	return $static_system_stats;
}

# ---------------------------------------------------------------------------------------------------------------------
# Get nfs v3 performance stats

sub get_system_perf_stats {

	$log->info("Getting performance stats for system...");

	our $tmp_dir;
	my $tmp_file = "$tmp_dir/" . "check_netapp.get_system_perf_stats.json";

	my $request	= NaElement->new('perf-object-get-instances');
	$request->child_add_string('objectname', 'system');

	my $counters = NaElement->new('counters');

	# ----- Global system counter -----

	$counters->child_add_string('counter', 'uptime');
	$counters->child_add_string('counter', 'time');

	# ----- Global CPU stats -----

	$counters->child_add_string('counter', 'total_processor_busy');
	$counters->child_add_string('counter', 'cpu_busy');
	$counters->child_add_string('counter', 'cpu_elapsed_time');
	$counters->child_add_string('counter', 'cpu_elapsed_time1');
	$counters->child_add_string('counter', 'cpu_elapsed_time2');
	$counters->child_add_string('counter', 'avg_processor_busy');

	# ----- Global HDD stats -----

	$counters->child_add_string('counter', 'hdd_data_written');
	$counters->child_add_string('counter', 'hdd_data_read');

	$counters->child_add_string('counter', 'sys_read_latency');
	$counters->child_add_string('counter', 'sys_avg_latency');
	$counters->child_add_string('counter', 'sys_write_latency');

	$counters->child_add_string('counter', 'disk_data_written');
	$counters->child_add_string('counter', 'disk_data_read');

	# ----- Global network stats -----

	$counters->child_add_string('counter', 'net_data_sent');
	$counters->child_add_string('counter', 'net_data_recv');

	# ----- Global protocol ops -----

	$counters->child_add_string('counter', 'total_ops');
	$counters->child_add_string('counter', 'cifs_ops');
	$counters->child_add_string('counter', 'nfs_ops');
	$counters->child_add_string('counter', 'write_ops');
	$counters->child_add_string('counter', 'iscsi_ops');
	$counters->child_add_string('counter', 'read_ops');

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


		# ----- Global system counter -----

		push (@derived_perf_data,	{	'name' 	=> 'uptime', 
										'value' => calc_counter_value('uptime', 'system', $current_perf_data, $old_perf_data)});

		push (@derived_perf_data,	{	'name' 	=> 'time', 
										'value' => calc_counter_value('time', 	'system', $current_perf_data, $old_perf_data)});

		# ----- Global CPU stats -----


		push (@derived_perf_data,	{	'name' 	=> 'total_processor_busy', 
										'value' => calc_counter_value('total_processor_busy', 	'system', $current_perf_data, $old_perf_data)});

		push (@derived_perf_data,	{	'name' 	=> 'cpu_busy', 
										'value' => calc_counter_value('cpu_busy', 				'system', $current_perf_data, $old_perf_data)});

		push (@derived_perf_data,	{	'name' 	=> 'cpu_elapsed_time', 
										'value' => calc_counter_value('cpu_elapsed_time', 		'system', $current_perf_data, $old_perf_data)});

		push (@derived_perf_data,	{	'name' 	=> 'cpu_elapsed_time1', 
										'value' => calc_counter_value('cpu_elapsed_time1', 		'system', $current_perf_data, $old_perf_data)});

		push (@derived_perf_data,	{	'name' 	=> 'cpu_elapsed_time2', 
										'value' => calc_counter_value('cpu_elapsed_time2', 		'system', $current_perf_data, $old_perf_data)});

		push (@derived_perf_data,	{	'name' 	=> 'avg_processor_busy', 
										'value' => calc_counter_value('avg_processor_busy', 	'system', $current_perf_data, $old_perf_data)});

		# ----- Global HDD stats -----

		push (@derived_perf_data,	{	'name' 	=> 'hdd_data_written', 
										'value' => calc_counter_value('hdd_data_written', 		'system', $current_perf_data, $old_perf_data)});

		push (@derived_perf_data,	{	'name' 	=> 'hdd_data_read', 
										'value' => calc_counter_value('hdd_data_read', 			'system', $current_perf_data, $old_perf_data)});

		push (@derived_perf_data,	{	'name' 	=> 'total_processor_busy', 
										'value' => calc_counter_value('total_processor_busy', 	'system', $current_perf_data, $old_perf_data)});

		push (@derived_perf_data,	{	'name' 	=> 'sys_read_latency', 
										'value' => calc_counter_value('sys_read_latency', 		'system', $current_perf_data, $old_perf_data)});

		push (@derived_perf_data,	{	'name' 	=> 'sys_write_latency', 
										'value' => calc_counter_value('sys_write_latency', 		'system', $current_perf_data, $old_perf_data)});

		push (@derived_perf_data,	{	'name' 	=> 'disk_data_written', 
										'value' => calc_counter_value('disk_data_written', 		'system', $current_perf_data, $old_perf_data)});

		push (@derived_perf_data,	{	'name' 	=> 'disk_data_read', 
										'value' => calc_counter_value('disk_data_read', 		'system', $current_perf_data, $old_perf_data)});

		# ----- Global network stats -----

		push (@derived_perf_data,	{	'name' 	=> 'net_data_sent', 
										'value' => calc_counter_value('net_data_sent', 	'system', $current_perf_data, $old_perf_data)});

		push (@derived_perf_data,	{	'name' 	=> 'net_data_recv', 
										'value' => calc_counter_value('net_data_recv',	'system', $current_perf_data, $old_perf_data)});

		# ----- Global protocol ops -----

		push (@derived_perf_data,	{	'name' 	=> 'total_ops', 
										'value' => calc_counter_value('total_ops', 		'system', $current_perf_data, $old_perf_data)});

		push (@derived_perf_data,	{	'name' 	=> 'cifs_ops', 
										'value' => calc_counter_value('cifs_ops', 		'system', $current_perf_data, $old_perf_data)});

		push (@derived_perf_data,	{	'name' 	=> 'nfs_ops', 
										'value' => calc_counter_value('nfs_ops', 		'system', $current_perf_data, $old_perf_data)});

		push (@derived_perf_data,	{	'name' 	=> 'write_ops', 
										'value' => calc_counter_value('write_ops', 		'system', $current_perf_data, $old_perf_data)});

		push (@derived_perf_data,	{	'name' 	=> 'iscsi_ops', 
										'value' => calc_counter_value('iscsi_ops', 		'system', $current_perf_data, $old_perf_data)});

		push (@derived_perf_data,	{	'name' 	=> 'read_ops', 
										'value' => calc_counter_value('read_ops', 		'system', $current_perf_data, $old_perf_data)});
		
		render_perf_data(\@derived_perf_data);
	}
}


# ---------------------------------------------------------------------------------------------------------------------
# Get nfs v3 performance stats

sub get_nfsv3_perf_stats {

	$log->info("Getting performance stats for nfs v3...");

	our $tmp_dir;
	my $tmp_file = "$tmp_dir/" . "check_netapp.get_nfsv3_perf_stats.json";

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

	our $tmp_dir;
	my $tmp_file = "$tmp_dir/" . "check_netapp.get_aggregate_perf_stats.$aggregate.json";

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

		render_perf_data(\@derived_perf_data);	
	}
}

# ---------------------------------------------------------------------------------------------------------------------
# Get volume performance stats

sub get_volume_perf_stats {

	my $volume = shift;

	$log->info("Getting performance stats for volume: $volume");

	our $tmp_dir;
	my $tmp_file = "$tmp_dir/" . "check_netapp.get_volume_perf_stats.$volume.json";

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


		my @derived_perf_data = ();

		#  ----- Global stats -----

		# Convert to ms
		push (@derived_perf_data,	{	'name' 	=> 'avg_latency', 
										'value' => calc_counter_value('avg_latency', 	'volume', $current_perf_data, $old_perf_data) / 1000});

		push (@derived_perf_data,	{	'name' 	=> 'total_ops', 
										'value' => calc_counter_value('total_ops', 		'volume', $current_perf_data, $old_perf_data)});

		#  ----- Volume reads -----

		# Convert to MB
		push (@derived_perf_data,	{	'name' 	=> 'read_data', 
										'value' => calc_counter_value('read_data', 		'volume', $current_perf_data, $old_perf_data) / (1024 * 1024)});

		# Convert to ms
		push (@derived_perf_data,	{	'name' 	=> 'read_latency',
										'value' => calc_counter_value('read_latency', 	'volume', $current_perf_data, $old_perf_data) / 1000});

		push (@derived_perf_data,	{	'name' 	=> 'read_ops', 
										'value' => calc_counter_value('read_ops', 		'volume', $current_perf_data, $old_perf_data)});

		push (@derived_perf_data,	{	'name' 	=> 'read_blocks', 
										'value' => calc_counter_value('read_blocks', 	'volume', $current_perf_data, $old_perf_data)});

		#  ----- Volume writes -----

		# Convert to MB
		push (@derived_perf_data,	{	'name' 	=> 'write_data', 
										'value' => calc_counter_value('write_data', 	'volume', $current_perf_data, $old_perf_data) / (1024 * 1024)});

		# Convert to ms
		push (@derived_perf_data,	{	'name' 	=> 'write_latency', 
										'value' => calc_counter_value('write_latency', 	'volume', $current_perf_data, $old_perf_data) / 1000});

		push (@derived_perf_data,	{	'name' 	=> 'write_ops', 
										'value' => calc_counter_value('write_ops', 		'volume', $current_perf_data, $old_perf_data)});

		push (@derived_perf_data,	{	'name' 	=> 'write_blocks', 
										'value' => calc_counter_value('write_blocks', 	'volume', $current_perf_data, $old_perf_data)});

		#  ----- Volume other ops -----

		# Convert to ms
		push (@derived_perf_data,	{	'name' 	=> 'other_latency', 
										'value' => calc_counter_value('other_latency', 	'volume', $current_perf_data, $old_perf_data) / 1000});

		push (@derived_perf_data,	{	'name' 	=> 'other_ops', 
										'value' => calc_counter_value('other_ops', 		'volume', $current_perf_data, $old_perf_data)});

		#  ----- Volume nfs -----
	
		# Convert to MB
		push (@derived_perf_data,	{	'name' 	=> 'nfs_read_data', 
										'value' => calc_counter_value('nfs_read_data', 		'volume', $current_perf_data, $old_perf_data) / (1024 * 1024)});

		# Convert to ms
		push (@derived_perf_data,	{	'name' 	=> 'nfs_read_latency', 
										'value' => calc_counter_value('nfs_read_latency', 	'volume', $current_perf_data, $old_perf_data) / 1000});

		push (@derived_perf_data,	{	'name' 	=> 'nfs_read_ops', 
										'value' => calc_counter_value('nfs_read_ops', 		'volume', $current_perf_data, $old_perf_data)});


		# Convert to MB
		push (@derived_perf_data,	{	'name' 	=> 'nfs_write_data', 
										'value' => calc_counter_value('nfs_write_data', 	'volume', $current_perf_data, $old_perf_data) / (1024 * 1024)});

		# Convert to ms
		push (@derived_perf_data,	{	'name' 	=> 'nfs_write_latency', 
										'value' => calc_counter_value('nfs_write_latency', 	'volume', $current_perf_data, $old_perf_data) / 1000});

		push (@derived_perf_data,	{	'name' 	=> 'nfs_write_ops', 
										'value' => calc_counter_value('nfs_write_ops', 		'volume', $current_perf_data, $old_perf_data)});

		# Convert to ms
		push (@derived_perf_data,	{	'name' 	=> 'nfs_other_latency', 
										'value' => calc_counter_value('nfs_other_latency', 	'volume', $current_perf_data, $old_perf_data) / 1000});

		push (@derived_perf_data,	{	'name' 	=> 'nfs_other_ops', 
										'value' => calc_counter_value('nfs_other_ops', 		'volume', $current_perf_data, $old_perf_data)});

		#  ----- Volume cifs -----

		# Convert to MB
		push (@derived_perf_data,	{	'name' 	=> 'cifs_read_data', 
										'value' => calc_counter_value('cifs_read_data', 	'volume', $current_perf_data, $old_perf_data) / (1024 * 1024)});

		# Convert to ms
		push (@derived_perf_data,	{	'name' 	=> 'cifs_read_latency', 
										'value' => calc_counter_value('cifs_read_latency', 	'volume', $current_perf_data, $old_perf_data) / 1000});

		push (@derived_perf_data,	{	'name' 	=> 'cifs_read_ops', 
										'value' => calc_counter_value('cifs_read_ops', 		'volume', $current_perf_data, $old_perf_data)});


		# Convert to MB
		push (@derived_perf_data,	{	'name' 	=> 'cifs_write_data', 
										'value' => calc_counter_value('cifs_write_data', 	'volume', $current_perf_data, $old_perf_data) / (1024 * 1024)});

		# Convert to ms
		push (@derived_perf_data,	{	'name' 	=> 'cifs_write_latency', 
										'value' => calc_counter_value('cifs_write_latency', 'volume', $current_perf_data, $old_perf_data) / 1000});

		push (@derived_perf_data,	{	'name' 	=> 'cifs_write_ops', 
										'value' => calc_counter_value('cifs_write_ops', 	'volume', $current_perf_data, $old_perf_data)});


		# Convert to ms
		push (@derived_perf_data,	{	'name' 	=> 'cifs_other_latency', 
										'value' => calc_counter_value('cifs_other_latency', 'volume', $current_perf_data, $old_perf_data) / 1000});

		push (@derived_perf_data,	{	'name' 	=> 'cifs_other_ops', 
										'value' => calc_counter_value('cifs_other_ops', 	'volume', $current_perf_data, $old_perf_data)});

		#  ----- Volume iSCSI -----

		# Convert to MB
		push (@derived_perf_data,	{	'name' 	=> 'iscsi_read_data', 
										'value' => calc_counter_value('iscsi_read_data', 	'volume', $current_perf_data, $old_perf_data) / (1024 * 1024)});

		# Convert to ms
		push (@derived_perf_data,	{	'name' 	=> 'iscsi_read_latency', 
										'value' => calc_counter_value('iscsi_read_latency', 'volume', $current_perf_data, $old_perf_data) / 1000});

		push (@derived_perf_data,	{	'name' 	=> 'iscsi_read_ops', 
										'value' => calc_counter_value('iscsi_read_ops', 	'volume', $current_perf_data, $old_perf_data)});

		# Convert to MB
		push (@derived_perf_data,	{	'name' 	=> 'iscsi_write_data', 
										'value' => calc_counter_value('iscsi_write_data', 	'volume', $current_perf_data, $old_perf_data) / (1024 * 1024)});

		# Convert to ms
		push (@derived_perf_data,	{	'name' 	=> 'iscsi_write_latency', 
										'value' => calc_counter_value('iscsi_write_latency','volume', $current_perf_data, $old_perf_data) / 1000});

		push (@derived_perf_data,	{	'name' 	=> 'iscsi_write_ops', 
										'value' => calc_counter_value('iscsi_write_ops', 	'volume', $current_perf_data, $old_perf_data)});


		# Convert to ms
		push (@derived_perf_data,	{	'name' 	=> 'iscsi_other_latency', 
										'value' => calc_counter_value('iscsi_other_latency','volume', $current_perf_data, $old_perf_data) / 1000});

		push (@derived_perf_data,	{	'name' 	=> 'iscsi_other_ops', 
										'value' => calc_counter_value('iscsi_other_ops', 	'volume', $current_perf_data, $old_perf_data)});

		#  ----- Volume inodes -----


		push (@derived_perf_data,	{	'name' 	=> 'wv_fsinfo_public_inos_total', 
										'value' => calc_counter_value('wv_fsinfo_public_inos_total', 	'volume', $current_perf_data, $old_perf_data)});

		push (@derived_perf_data,	{	'name' 	=> 'wv_fsinfo_public_inos_reserve', 
										'value' => calc_counter_value('wv_fsinfo_public_inos_reserve', 	'volume', $current_perf_data, $old_perf_data)});

		push (@derived_perf_data,	{	'name' 	=> 'wv_fsinfo_public_inos_used', 
										'value' => calc_counter_value('wv_fsinfo_public_inos_used', 	'volume', $current_perf_data, $old_perf_data)});

		render_perf_data(\@derived_perf_data);	
	}
}

# ---------------------------------------------------------------------------------------------------------------------
# Get nfs v3 performance stats

sub get_processor_perf_stats {

	$log->info("Getting performance stats for processors...");

	our $tmp_dir;
	my $tmp_file = "$tmp_dir/" . "check_netapp.get_processor_perf_stats.json";

	my $request	= NaElement->new('perf-object-get-instances');
	$request->child_add_string('objectname', 'processor');

	my $counters = NaElement->new('counters');

	$counters->child_add_string('counter', 'processor_busy');
	$counters->child_add_string('counter', 'processor_elapsed_time');
	$counters->child_add_string('counter', 'domain_busy');

	$request->child_add($counters);

	my $result 				= call_api($request);
	my $current_perf_data 	= {};

	$current_perf_data->{'timestamp'} = $result->child_get_int('timestamp');

	#
	# By not specifing processor we get data for all processors => create counters of all processors
	# Also, 'domain_busy' provides values for the different domains as an array. Transform that to individual counters for each domain and
	# also provide an aggregate counter for each domain
	#
	my @domain_busy_counters = ();
	my @domain_busy_labels = split(',', "idle,kahuna,storage,exempt,raid,target,dnscache,cifs,wafl_exempt,wafl_xcleaner,sm_exempt,cluster,protocol,nwk_exclusive,nwk_exempt,nwk_legacy,hostOS");
	foreach my $instance ($result->child_get('instances')->children_get()) {

		my $instance_name = $instance->child_get_string('name');

		foreach my $counter ($instance->child_get('counters')->children_get()) {

			my $counter_name 	= $counter->child_get_string('name');
			my $counter_value 	= $counter->child_get_string('value');

			unless ($counter_name eq 'domain_busy') {
				$current_perf_data->{$instance_name . '_' . $counter_name} = $counter_value;
			} else {
				$log->debug("$counter_name : $counter_value");
				my @domain_busy_values = split(',', $counter_value);
				foreach my $i (0 .. (@domain_busy_values - 1)) {
					my $domain_name = $instance_name . '_' . $counter_name . '_' . $domain_busy_labels[$i];
					$current_perf_data->{$domain_name} = $domain_busy_values[$i];
					# Keep track of generated counters for later
					push (@domain_busy_counters, $domain_name);
				}
			}
		}
	}

	# Load old counters from file and persist new ones insted

	my $old_perf_data = read_hash_from_file($tmp_file, 1);

	write_hash_to_file($tmp_file, $current_perf_data);

	# Calculate latencies / op rates
	if (%$old_perf_data) {

		my @derived_perf_data = ();

#		push (@derived_perf_data,	{	'name' 	=> 'processor_busy', 
#										'value' => calc_counter_value('processor_busy', 		'processor', $current_perf_data, $old_perf_data)});


		# Add generated domain busy counters
		$log->debug("counter names: " . Dumper(@domain_busy_counters));
		foreach my $domain_busy_counter_name (@domain_busy_counters) {
			push (@derived_perf_data,	{	'name' 	=> $domain_busy_counter_name, 
											'value' => calc_counter_value($domain_busy_counter_name, 'processor', $current_perf_data, $old_perf_data)});
		}

		render_perf_data(\@derived_perf_data);
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
	help 		=> "Hostname or IP address of the NetApp filer to check (default: localhost).\n",
	required 	=> 0,
	default 	=> 'localhost'
);

$plugin->add_arg(
	spec 		=> 'user|U=s',
	help 		=> "User name for login (default: none).\n",
	required 	=> 0,
	default		=> ''
);

$plugin->add_arg(
	spec 		=> 'password|P=s',
	help 		=> "Password for login (default: none).\n",
	required 	=> 0,
	default 	=> ''
);

$plugin->add_arg(
	spec 		=> 'protocol|p=s',
	help 		=> "Protocol to use for communication (default: HTTPS).\n",
	required 	=> 0,
	default 	=> 'HTTPS'
);

$plugin->add_arg(
	spec 		=> 'stats|s=s',
	help 		=> "Type of stats to retrieve (default: system). Valid values are:\n"	.
					"     aggregate\n"			.
					"     nfsv3\n"				.
					"     processor\n"			.
					"     system\n"				.
					"     volume\n",
	required 	=> 0,
	default 	=> 'system'
);

$plugin->add_arg(
	spec 		=> 'instance|i=s',
	help 		=> "Select the instance for performance counter retrievel, where appropriate (i.e. aggregate / volume name).\n",
	required 	=> 0,
	default 	=> ''
);

$plugin->add_arg(
	spec 		=> 'counters|c=s',
	help 		=> "Select the performance counter(s) to use for communication (default: all).\n",
	required 	=> 0,
	default 	=> 'all'
);

$plugin->add_arg(
	spec 		=> 'tmp_dir|T=s',
	help 		=> "Location of directory for temporary files (default: /tmp).\n",
	required 	=> 0,
	default 	=> '/tmp'
);

$plugin->add_arg(
	spec 		=> 'output|o=s',
	help 		=> "Define output format for the probe to use (default: nagios).\n",
	required 	=> 0,
	default 	=> 'nagios'
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

# tmp directory
our $tmp_dir = $plugin->opts->tmp_dir;
$log->info("Using '$tmp_dir' as directory form temp files.");

# Returned probe output
our $probe_output = '';

# Initialize the probe output string according to selected format
switch (lc($plugin->opts->output)) {

	case 'nagios' {
		$probe_output = '| ';
	}

	else {
		# Unknown / unsupoorted format
		$log->error("Unkown format => not initializing rendering!");
	}
}

# Get server context

our $filer = NaServer->new($plugin->opts->hostname, 1, 15);

$filer->set_admin_user($plugin->opts->user, $plugin->opts->password);
$filer->set_bindings_family('7-Mode');
$filer->set_transport_type($plugin->opts->protocol);

# Get perf object list
our $json_parser = JSON->new->allow_nonref;

# Array of counter descriptions for various objects. Persisted into files.
our $perf_object_counter_descriptions = {};

# Get basic system stats, like verions, number of processors, etc. (needed for some calculations)
our $static_system_stats = get_static_system_stats();
$log->info("Probe targeting filer: $static_system_stats->{'hostname'} (ONTAP: $static_system_stats->{'ontap_version'}, serial: $static_system_stats->{'serial_no'})");

# Create counter filter hash
#our %counter_filter = {};
#foreach my $selected_counter_name (split(',', $plugin->opts->counters)) {
#	%counter_filter{''}
#}

#list_perf_objects();

#load_perf_object_counter_descriptions('nfsv3');
#load_perf_object_counter_descriptions('vfiler');
#load_perf_object_counter_descriptions('volume');
#load_perf_object_counter_descriptions('aggregate');
#load_perf_object_counter_descriptions('processor');
#load_perf_object_counter_descriptions('system');


# Select the stats object
switch (lc($plugin->opts->stats)) {

	case 'aggregate' {
		# aggr_SUBSAS01
		get_aggregate_perf_stats($plugin->opts->instance);
	}

	case 'nfsv3' {
		get_nfsv3_perf_stats();
	}

	case 'processor' {
		get_processor_perf_stats();
	}

	case 'system' {
		get_system_perf_stats();
	}

	case 'volume' {
		get_volume_perf_stats('vol_GWDG_ESX_SUB01_silber01');
	}
}

if ($plugin->opts->output eq 'nagios') {
	$plugin->nagios_exit(OK, $probe_output);
}

