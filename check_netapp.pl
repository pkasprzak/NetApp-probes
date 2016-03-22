#!/usr/bin/perl -X
#
# Nagios probe for checking a NetApp filer
#
# Copyright (c) 2016 Piotr Kasprzak
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
# - Monitoring::Plugin
# - Log::Log4perl
# - Net::SSLeay
#
# e.g.:
#
# port install p5.16-lwp-useragent-determined
# port install p5.16-xml-parser
#
# perl -MCPAN -e shell
# cpan> install Monitoring::Plugin      (For Nagios stuff)
# cpan> install Log::Log4perl           (For logging)
# cpan> install JSON                    (For json rendering in caching files)
# cpan> install File::Slurp
# cpan> install Switch                  (CHORNY/Switch-2.17.tar.gz)
# cpan> install Clone                   (GARU/Clone-0.37.tar.gz)
# cpan> install Net::Graphite           (v0.16)
# cpan> install IO::Async               (For Timer loop: IO::Async::Timer::Periodic, v0.70)
# cpan> install Time::HiRes             (For high resolution (ms) times, v1.9732)
#
# 2.) Get NetApp perl SDK
#
# - Download netapp-manageability-sdk-5.3 from http://support.netapp.com/NOW/cgi-bin/software
# - Copy lib/perl/NetApp directory with the perl modules to somewhere where it can be found by perl
#
# - Find API documentation here:
#   ./netapp-manageability-sdk-5.4P1/doc/perldoc/Ontap7ModeAPI.html#perf_object_get_instances
#
#
# Range format (for -w or -c):
# ----------------------------
#
# Generate an alert if x...
# 10        < 0 or > 10, (outside the range of {0 .. 10})
# 10:       < 10, (outside {10 .. ∞})
# ~:10      > 10, (outside the range of {-∞ .. 10})
# 10:20     < 10 or > 20, (outside the range of {10 .. 20})
# @10:20    ≥ 10 and ≤ 20, (inside the range of {10 .. 20})
#
# To do:
# -----
#
# - 
# - Make it possible to filter counter (white list)
# - Set units for processor performance counter and equivalent definitions
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
use Monitoring::Plugin;
use Log::Log4perl;
use JSON;
use Net::Graphite;

use IO::Async::Timer::Periodic;
use IO::Async::Loop;

use Time::HiRes;

# NetApp SDK
use lib "./NetApp";
use NaServer;
use NaElement;

# Standard variables used in Monitoring::Plugin constructor
my $PROGNAME    = 'check_netapp';
my $VERSION     = '1.1';
my $DESCRIPTION = 'Probe for checking a NetApp filer. Examples:\n'                                                  .
                    'check_netapp.pl -H <filer-ip> -U <user> -P <password> -s aggregate=<aggregate-name>\n'         .
                    'check_netapp.pl -H <filer-ip> -U <user> -P <password> -s processor\n'                          .
                    'check_netapp.pl -H <filer-ip> -U <user> -P <password> -s nfsv3\n'                              .
                    'check_netapp.pl -H <filer-ip> -U <user> -P <password> -s system';
my $EXTRA_DESC  = '';
my $SHORTNAME   = 'CHECK_NETAPP';
my $LICENSE     = 'This nagios plugin is free software, and comes with ABSOLUTELY NO WARRANTY.
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
http://www.apache.org/licenses/LICENSE-2.0
Copyright 2016 Piotr Kasprzak';

# ---------------------------------------------------------------------------------------------------------------------
# Initialize logger

my $log4j_conf = q(

   log4perl.category.GWDG.NetApp = INFO, Screen, Logfile
#    log4perl.category.GWDG.NetApp = DEBUG, Logfile

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
# Unit map

our %unit_map = (   'none'          => '',
                    'per_sec'       => 'op/s',
                    'millisec'      => 'ms',
                    'microsec'      => 'us',
                    'percent'       => '%',
                    'kb_per_sec'    => 'KB/s',
                    'sec'           => 's'
    );

# ---------------------------------------------------------------------------------------------------------------------
# Helper functions

sub trim { 
    my $s = shift;
    if ($s) { 
        $s =~ s/^\s+|\s+$//g;
    } 
    return $s
};

# ---------------------------------------------------------------------------------------------------------------------
# Create tmp file name from some identifiers

sub get_tmp_file {

    our $plugin;

    # Array of identifiers to be concatenated in the file name
    my $identifiers = shift;

    # Instance to use (i.e. aggregate / volume name, etc.)
    my $instance    = shift;

    my $prefix      = 'check_netapp_fas';
    my $postfix     = '.json';
    my $separator   = '_';

    my $tmp_file    = $plugin->opts->tmp_dir . '/' . $prefix . '.' . $plugin->opts->hostname . '.';

    foreach my $identifier (@$identifiers) {
        $tmp_file .= $identifier . $separator;
    }

    # Remove last separator
    $tmp_file = substr($tmp_file, 0, length($tmp_file) - 1);

    if ($instance) {
        $tmp_file .= '.' . $instance;
    }

    $tmp_file .= $postfix;

    $log->debug("Created tmp file name: $tmp_file");
    return $tmp_file;
}

# ---------------------------------------------------------------------------------------------------------------------
# Establish connection to filer

sub connect_to_filer {

    # Get server context
    our $plugin;
    our $filer = NaServer->new($plugin->opts->hostname, 1, 15);

    $filer->set_admin_user($plugin->opts->user, $plugin->opts->password);
    $filer->set_bindings_family('7-Mode');
    $filer->set_transport_type($plugin->opts->protocol);
}

# ---------------------------------------------------------------------------------------------------------------------
# Print list of perf objects (perf-object-list-info)

sub call_api {

    my $request = shift;

    $log->info("API request: " . $request->{name});

    if ($log->is_debug()) {
        $log->debug("API request content:\n" . $request->sprintf());
    }
    
    my $i = 1;
    my $max_retries = 3;
    my $sleep_on_error_ms = 500;

    while ($i <= $max_retries) {
        my $result = $main::filer->invoke_elem($request);

        if ($log->is_debug()) {
            $log->debug("API response content:\n" . $result->sprintf())
        }

        # Check for error
        if ($result->results_status() eq 'failed') {

            $log->error("API request failed: " . $result->results_reason());
            $log->error("=> Reconnecting and retrying (try $i of $max_retries)");
            Time::HiRes::usleep($sleep_on_error_ms);
            connect_to_filer();
            $i++;

        } else {
            # Success
            return $result;
        }
    }

    # Nothing we can do
    return;
}

# ---------------------------------------------------------------------------------------------------------------------
# Print list of perf objects (perf-object-list-info)

sub list_perf_objects {

    $log->info("Listing all performance objects:");

    my $request = NaElement->new('perf-object-list-info');
    my $result  = call_api($request) || return;

    foreach ($result->child_get('objects')->children_get()) {
        my $name    = $_->child_get_string('name');
        my $level   = $_->child_get_string('privilege-level');

        $log->info(sprintf("%30s: %10s", $name, $level));
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Print list of perf objects instances (perf_object_instance_list_info)

sub list_perf_objects_instances {

    # Perf. object to list all instances of
    my $perf_object = shift;

    $log->info("Listing all instances of performance object [$perf_object]:");

    my $request = NaElement->new('perf-object-instance-list-info');
    $request->child_add_string('objectname', $perf_object);

    my $result  = call_api($request) || return;

    foreach ($result->child_get('instances')->children_get()) {
        my $name    = $_->child_get_string('name');

        $log->info(sprintf("%30s", $name));
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Print list of perf objects (perf-object-list-info)

sub load_perf_object_counter_descriptions {

    my $perf_object = shift;
    our $perf_object_counter_descriptions;

    $log->info("Loading performance counter descriptions for object: $perf_object");

    # Try to load from file first

    my @identifiers = ('perf', 'object', 'counter', 'descriptions');
    my $cache_file = get_tmp_file (\@identifiers, $perf_object);

    my $counter_descriptions = read_hash_from_file($cache_file, 0);

    if (! %$counter_descriptions) {

        # No cache file yet -> load data from API and persist in file for later.
        $log->info("No cache file found, loading from API...");

        my $request = NaElement->new('perf-object-counter-list-info');
        $request->child_add_string('objectname', $perf_object);

        my $result  = call_api($request) || return;

        foreach my $na_element ($result->child_get('counters')->children_get()) {

            my $counter_description = {};

            $counter_description->{'name'}              = $na_element->child_get_string('name');
            $counter_description->{'privilege_level'}   = $na_element->child_get_string('privilege-level');
            $counter_description->{'desc'}              = $na_element->child_get_string('desc');
            $counter_description->{'properties'}        = $na_element->child_get_string('properties');
            $counter_description->{'unit'}              = $na_element->child_get_string('unit');
            $counter_description->{'base_counter'}      = $na_element->child_get_string('base-counter');
            $counter_description->{'type'}              = $na_element->child_get_string('type');

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

                        my $new_counter_name        = 'processor' . $processor . '_' . $counter_description->{'name'};
                        my $new_counter_description = clone($counter_description);

                        $new_counter_description->{'name'} = $new_counter_name;
                        $counter_descriptions->{$new_counter_description->{'name'}} = $new_counter_description;

                    } else {
                        # For type == array we need to process the labels
                        my @labels = split(',', $na_element->child_get('labels')->child_get_string('label-info'));
                        foreach my $label (@labels) {

                            my $new_counter_name        = 'processor' . $processor . '_' . $counter_description->{'name'} . '_' . $label;
                            my $new_base_counter        = 'processor' . $processor . '_' . $counter_description->{'base_counter'};
                            my $new_counter_description = clone($counter_description);

                            $new_counter_description->{'name'}          = $new_counter_name;
                            $new_counter_description->{'base_counter'}  = $new_base_counter;

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

    my $counter_name        = shift;
    my $perf_object         = shift;
    my $current_perf_data   = shift;
    my $old_perf_data       = shift;

    our $perf_object_counter_descriptions;

    $log->debug("Calculating value of counter '$counter_name' of perf object '$perf_object'");

    # Get counter descriptions. If no descriptions available yet, load them!
    if (! $perf_object_counter_descriptions->{$perf_object}) {
        load_perf_object_counter_descriptions($perf_object);
    } 

    my $counter_descriptions    = $perf_object_counter_descriptions->{$perf_object};
    my $counter_description     = $counter_descriptions->{$counter_name};

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
            my $time_delta      = $current_perf_data->{'timestamp'} - $old_perf_data->{'timestamp'};
            my $counter_value   = ($current_perf_data->{$counter_name} - $old_perf_data->{$counter_name}) / $time_delta;

            return $counter_value;
        }

        case 'delta' {
            # c2 - c1
            my $counter_value   = $current_perf_data->{$counter_name} - $old_perf_data->{$counter_name};

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

            my $current_base_counter_data   = $current_perf_data->{$base_counter_name};
            my $old_base_counter_data       = $old_perf_data->{$base_counter_name};

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

            my $current_base_counter_data   = $current_perf_data->{$base_counter_name};
            my $old_base_counter_data       = $old_perf_data->{$base_counter_name};

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
# Get unit of a counter value based on it's description

sub get_unit {

    our $perf_object_counter_descriptions;
    our %unit_map;

    my $counter_name    = shift;
    my $perf_object     = shift;
    
    my $orig_unit_name          = $perf_object_counter_descriptions->{$perf_object}->{$counter_name}->{'unit'};
    my $transformed_unit_name   = '?';

    if (exists($unit_map{$orig_unit_name})) {
        $transformed_unit_name = $unit_map{$orig_unit_name};
    }

    return $transformed_unit_name;
}

# ---------------------------------------------------------------------------------------------------------------------
# Read hash from file (in JSON format)

sub read_hash_from_file {

    my $file                        = shift;
    my $delete_file_after_reading   = shift;

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

    my $file        = shift;
    my $hash_data   = shift;

    our $json_parser;

    # Encode hash in JSON string
    my $hash_data_json = $json_parser->pretty->encode($hash_data);

    # Write to file
    write_file($file, $hash_data_json);
}

# ---------------------------------------------------------------------------------------------------------------------
# Check perf metrics in hash for warning / critical ranges

sub check_perf_data {

    our $probe_status_output;
    our $plugin;
    our (%warning_defs, %critical_defs);
    our (@warning, @critical);

    my $perf_data       = shift;
    my $perf_data_count = scalar @$perf_data;

    $log->info("Checking [$perf_data_count] perf counter metrics for critical / warning ranges...");

    foreach my $counter (@$perf_data) {
        # Check for warning ranges
        if (exists($warning_defs{$counter->{'name'}})) {

            $plugin->set_thresholds(warning => $warning_defs{$counter->{'name'}});
            my $check_result = $plugin->check_threshold($counter->{'value'});
            if ($check_result == WARNING) {
                my $message = $counter->{'name'} . ' (' . $counter->{'value'} . ') in range "' . $warning_defs{$counter->{'name'}} . '"';
                $log->debug('Warning: ' . $message);
                push(@warning, $message);
            }
        }
        # Check for critical ranges
        if (exists($critical_defs{$counter->{'name'}})) {

            $plugin->set_thresholds(critical => $critical_defs{$counter->{'name'}});
            my $check_result = $plugin->check_threshold($counter->{'value'});
            if ($check_result == CRITICAL) {
                my $message = $counter->{'name'} . ' (' . $counter->{'value'} . ') in range "' . $critical_defs{$counter->{'name'}} . '"';
                $log->debug('Critical: ' . $message);
                push(@critical, $message);
            }
        }

    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Get basic system stats

sub get_static_system_stats {

    $log->info("Getting basic system stats...");

    my @identifiers = ('static', 'system', 'stats');
    my $tmp_file = get_tmp_file (\@identifiers);

    # Try to load old counters from file and persist new ones insted
    my $static_system_stats = read_hash_from_file($tmp_file, 0);

    if (%$static_system_stats) {
        return $static_system_stats;
    }

    # No cache file -> get data from API

    my $request = NaElement->new('perf-object-get-instances');
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

    my $result              = call_api($request) || return;
    $static_system_stats    = {};

    $static_system_stats->{'timestamp'} = $result->child_get_int('timestamp');

    foreach ($result->child_get('instances')->child_get('instance-data')->child_get('counters')->children_get()) {

        my $counter_name    = $_->child_get_string('name');
        my $counter_value   = $_->child_get_string('value');

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

    my @identifiers = ('system', 'perf', 'stats');
    my $tmp_file = get_tmp_file (\@identifiers);

    my $request = NaElement->new('perf-object-get-instances');
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

    my $result              = call_api($request) || return;
    my $current_perf_data   = {};

    $current_perf_data->{'timestamp'} = $result->child_get_int('timestamp');

    foreach ($result->child_get('instances')->child_get('instance-data')->child_get('counters')->children_get()) {

        my $counter_name    = $_->child_get_string('name');
        my $counter_value   = $_->child_get_string('value');

        $current_perf_data->{$counter_name} = $counter_value;
    }

    # Load old counters from file and persist new ones insted

    my $old_perf_data = read_hash_from_file($tmp_file, 1);

    write_hash_to_file($tmp_file, $current_perf_data);

    # Calculate latencies / op rates
    if (%$old_perf_data) {

        my @derived_perf_data = ();

        # ----- Global system counter -----

        push (@derived_perf_data,   {   'name'  => 'uptime', 
                                        'value' => calc_counter_value('uptime', 'system', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('uptime', 'system')});

        push (@derived_perf_data,   {   'name'  => 'time', 
                                        'value' => calc_counter_value('time',   'system', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('time', 'system')});

        # ----- Global CPU stats -----


        push (@derived_perf_data,   {   'name'  => 'total_processor_busy', 
                                        'value' => calc_counter_value('total_processor_busy',   'system', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('total_processor_busy', 'system')});

        push (@derived_perf_data,   {   'name'  => 'cpu_busy', 
                                        'value' => calc_counter_value('cpu_busy',               'system', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('cpu_busy', 'system')});

        push (@derived_perf_data,   {   'name'  => 'cpu_elapsed_time', 
                                        'value' => calc_counter_value('cpu_elapsed_time',       'system', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('cpu_elapsed_time', 'system')});

        push (@derived_perf_data,   {   'name'  => 'cpu_elapsed_time1', 
                                        'value' => calc_counter_value('cpu_elapsed_time1',      'system', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('cpu_elapsed_time1', 'system')});

        push (@derived_perf_data,   {   'name'  => 'cpu_elapsed_time2', 
                                        'value' => calc_counter_value('cpu_elapsed_time2',      'system', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('cpu_elapsed_time2', 'system')});

        push (@derived_perf_data,   {   'name'  => 'avg_processor_busy', 
                                        'value' => calc_counter_value('avg_processor_busy',     'system', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('avg_processor_busy', 'system')});

        # ----- Global HDD stats -----

        push (@derived_perf_data,   {   'name'  => 'hdd_data_written', 
                                        'value' => calc_counter_value('hdd_data_written',       'system', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('hdd_data_written', 'system')});

        push (@derived_perf_data,   {   'name'  => 'hdd_data_read', 
                                        'value' => calc_counter_value('hdd_data_read',          'system', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('hdd_data_read', 'system')});

        push (@derived_perf_data,   {   'name'  => 'total_processor_busy', 
                                        'value' => calc_counter_value('total_processor_busy',   'system', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('total_processor_busy', 'system')});

        push (@derived_perf_data,   {   'name'  => 'sys_read_latency', 
                                        'value' => calc_counter_value('sys_read_latency',       'system', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('sys_read_latency', 'system')});

        push (@derived_perf_data,   {   'name'  => 'sys_write_latency', 
                                        'value' => calc_counter_value('sys_write_latency',      'system', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('sys_write_latency', 'system')});

        push (@derived_perf_data,   {   'name'  => 'disk_data_written', 
                                        'value' => calc_counter_value('disk_data_written',      'system', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('disk_data_written', 'system')});

        push (@derived_perf_data,   {   'name'  => 'disk_data_read', 
                                        'value' => calc_counter_value('disk_data_read',         'system', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('disk_data_read', 'system')});

        # ----- Global network stats -----

        push (@derived_perf_data,   {   'name'  => 'net_data_sent', 
                                        'value' => calc_counter_value('net_data_sent',  'system', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('net_data_sent', 'system')});

        push (@derived_perf_data,   {   'name'  => 'net_data_recv', 
                                        'value' => calc_counter_value('net_data_recv',  'system', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('net_data_recv', 'system')});

        # ----- Global protocol ops -----

        push (@derived_perf_data,   {   'name'  => 'total_ops', 
                                        'value' => calc_counter_value('total_ops',      'system', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('total_ops', 'system')});

        push (@derived_perf_data,   {   'name'  => 'cifs_ops', 
                                        'value' => calc_counter_value('cifs_ops',       'system', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('cifs_ops', 'system')});

        push (@derived_perf_data,   {   'name'  => 'nfs_ops', 
                                        'value' => calc_counter_value('nfs_ops',        'system', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('nfs_ops', 'system')});

        push (@derived_perf_data,   {   'name'  => 'write_ops', 
                                        'value' => calc_counter_value('write_ops',      'system', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('write_ops', 'system')});

        push (@derived_perf_data,   {   'name'  => 'iscsi_ops', 
                                        'value' => calc_counter_value('iscsi_ops',      'system', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('iscsi_ops', 'system')});

        push (@derived_perf_data,   {   'name'  => 'read_ops', 
                                        'value' => calc_counter_value('read_ops',       'system', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('read_ops', 'system')});
        
#        render_perf_data(\@derived_perf_data);

        our %probe_metric_hash;
        $probe_metric_hash{'system'} = \@derived_perf_data;
    }
}


# ---------------------------------------------------------------------------------------------------------------------
# Get nfs v3 performance stats

sub get_nfsv3_perf_stats {

    $log->info("Getting performance stats for nfsv3...");

    my @identifiers = ('nfsv3', 'perf', 'stats');
    my $tmp_file = get_tmp_file (\@identifiers);

    my $request = NaElement->new('perf-object-get-instances');
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

    my $result              = call_api($request) || return;
    my $current_perf_data   = {};

    $current_perf_data->{'timestamp'} = $result->child_get_int('timestamp');

    foreach ($result->child_get('instances')->child_get('instance-data')->child_get('counters')->children_get()) {

        my $counter_name    = $_->child_get_string('name');
        my $counter_value   = $_->child_get_string('value');

        $current_perf_data->{$counter_name} = $counter_value;
    }

    # Load old counters from file and persist new ones insted

    my $old_perf_data = read_hash_from_file($tmp_file, 1);

    write_hash_to_file($tmp_file, $current_perf_data);

    # Calculate latencies / op rates
    if (%$old_perf_data) {

        my @derived_perf_data = ();

        push (@derived_perf_data,   {   'name'  => 'read_latency', 
                                        'value' => calc_counter_value('nfsv3_read_latency',     'nfsv3', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('nfsv3_read_latency', 'nfsv3')});

        push (@derived_perf_data,   {   'name'  => 'write_latency',
                                        'value' => calc_counter_value('nfsv3_write_latency',    'nfsv3', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('nfsv3_write_latency', 'nfsv3')});

        push (@derived_perf_data,   {   'name'  => 'ops_rate',
                                        'value' => calc_counter_value('nfsv3_ops',              'nfsv3', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('nfsv3_ops', 'nfsv3')});

        push (@derived_perf_data,   {   'name'  => 'read_ops_rate',
                                        'value' => calc_counter_value('nfsv3_read_ops',         'nfsv3', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('nfsv3_read_ops', 'nfsv3')});

        push (@derived_perf_data,   {   'name'  => 'write_ops_rate',
                                        'value' => calc_counter_value('nfsv3_write_ops',        'nfsv3', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('nfsv3_write_ops', 'nfsv3')});

 #       render_perf_data(\@derived_perf_data);
 
        our %probe_metric_hash;
        $probe_metric_hash{'nfsv3'} = \@derived_perf_data;
    }
}


# ---------------------------------------------------------------------------------------------------------------------
# Get cifs performance stats

sub get_cifs_perf_stats {

    $log->info("Getting performance stats for cifs...");

    my @identifiers = ('cifs', 'perf', 'stats');
    my $tmp_file = get_tmp_file (\@identifiers);

    my $request = NaElement->new('perf-object-get-instances');
    $request->child_add_string('objectname', 'cifs');

    my $counters = NaElement->new('counters');

    $counters->child_add_string('counter', 'cifs_ops');

    #  ----- nfs v3 reads -----

    $counters->child_add_string('counter', 'cifs_read_latency');
#   $counters->child_add_string('counter', 'cifs_avg_read_latency_base');
    $counters->child_add_string('counter', 'cifs_read_ops');

    #  ----- nfs v3 writes -----

    $counters->child_add_string('counter', 'cifs_write_latency');
#   $counters->child_add_string('counter', 'cifs_avg_write_latency_base');
    $counters->child_add_string('counter', 'cifs_write_ops');

    $request->child_add($counters);

    my $result              = call_api($request) || return;
    my $current_perf_data   = {};

    $current_perf_data->{'timestamp'} = $result->child_get_int('timestamp');

    foreach ($result->child_get('instances')->child_get('instance-data')->child_get('counters')->children_get()) {

        my $counter_name    = $_->child_get_string('name');
        my $counter_value   = $_->child_get_string('value');

        $current_perf_data->{$counter_name} = $counter_value;
    }

    # Load old counters from file and persist new ones insted

    my $old_perf_data = read_hash_from_file($tmp_file, 1);

    write_hash_to_file($tmp_file, $current_perf_data);

    # Calculate latencies / op rates
    if (%$old_perf_data) {

        my @derived_perf_data = ();

        push (@derived_perf_data,   {   'name'  => 'read_latency', 
                                        'value' => calc_counter_value('cifs_read_latency',      'cifs', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('cifs_read_latency', 'cifs')});

        push (@derived_perf_data,   {   'name'  => 'write_latency',
                                        'value' => calc_counter_value('cifs_write_latency',     'cifs', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('cifs_write_latency', 'cifs')});

        push (@derived_perf_data,   {   'name'  => 'ops_rate',
                                        'value' => calc_counter_value('cifs_ops',               'cifs', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('cifs_ops', 'cifs')});

        push (@derived_perf_data,   {   'name'  => 'read_ops_rate',
                                        'value' => calc_counter_value('cifs_read_ops',          'cifs', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('cifs_read_ops', 'cifs')});

        push (@derived_perf_data,   {   'name'  => 'write_ops_rate',
                                        'value' => calc_counter_value('cifs_write_ops',         'cifs', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('cifs_write_ops', 'cifs')});

#       render_perf_data(\@derived_perf_data);
 
        our %probe_metric_hash;
        $probe_metric_hash{'cifs'} = \@derived_perf_data;
   }
}


# ---------------------------------------------------------------------------------------------------------------------
# Get cifs_stats performance stats (sessions, etc. in contrast to ops / latencies) above

sub get_cifs_stats_perf_stats {

    $log->info("Getting stats from cifs_stats...");

    our %probe_metric_hash;

    my @identifiers = ('cifs_stats', 'perf', 'stats');
    my $tmp_file = get_tmp_file (\@identifiers);

    my $request = NaElement->new('perf-object-get-instances');
    $request->child_add_string('objectname', 'cifs_stats');

    my $counters = NaElement->new('counters');

    #  ----- Cifs sessions -----

    $counters->child_add_string('counter', 'curr_sess_cnt');
    $counters->child_add_string('counter', 'multi_user_sess_cn');
    $counters->child_add_string('counter', 'curr_conn_user_cnt');
    $counters->child_add_string('counter', 'logon_cnt');
    $counters->child_add_string('counter', 'pdc_auth_cnt');

    #  ----- Cifs shares / open files / dir / locks -----

    $counters->child_add_string('counter', 'curr_share_cnt');
    $counters->child_add_string('counter', 'curr_tree_cnt');
    $counters->child_add_string('counter', 'curr_open_file_cnt');
    $counters->child_add_string('counter', 'curr_open_dir_cnt');
    $counters->child_add_string('counter', 'curr_watch_dir_cnt');
    $counters->child_add_string('counter', 'curr_lock_cnt');

    $request->child_add($counters);

    my $result              = call_api($request) || return;
    my $current_perf_data   = {};

    $current_perf_data->{'timestamp'} = $result->child_get_int('timestamp');

    foreach ($result->child_get('instances')->child_get('instance-data')->child_get('counters')->children_get()) {

        my $counter_name    = $_->child_get_string('name');
        my $counter_value   = $_->child_get_string('value');

        $current_perf_data->{$counter_name} = $counter_value;
    }

    # Load old counters from file and persist new ones insted
    my $old_perf_data = read_hash_from_file($tmp_file, 1);
    write_hash_to_file($tmp_file, $current_perf_data);

    # Calculate latencies / op rates
    if (%$old_perf_data) {

        my @derived_perf_data = ();

        #  ----- Cifs sessions -----

        push (@derived_perf_data,   {   'name'  => 'curr_sess_cnt', 
                                        'value' => calc_counter_value('curr_sess_cnt',          'cifs', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('curr_sess_cnt', 'cifs')});

        push (@derived_perf_data,   {   'name'  => 'multi_user_sess_cn', 
                                        'value' => calc_counter_value('multi_user_sess_cn',     'cifs', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('multi_user_sess_cn', 'cifs')});

        push (@derived_perf_data,   {   'name'  => 'curr_conn_user_cnt', 
                                        'value' => calc_counter_value('curr_conn_user_cnt',     'cifs', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('curr_conn_user_cnt', 'cifs')});

        push (@derived_perf_data,   {   'name'  => 'logon_cnt', 
                                        'value' => calc_counter_value('logon_cnt',              'cifs', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('logon_cnt', 'cifs')});

        push (@derived_perf_data,   {   'name'  => 'pdc_auth_cnt', 
                                        'value' => calc_counter_value('pdc_auth_cnt',           'cifs', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('pdc_auth_cnt', 'cifs')});

        #  ----- Cifs shares / open files / dir / locks -----

        push (@derived_perf_data,   {   'name'  => 'curr_share_cnt', 
                                        'value' => calc_counter_value('curr_share_cnt',         'cifs', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('curr_share_cnt', 'cifs')});

        push (@derived_perf_data,   {   'name'  => 'curr_tree_cnt', 
                                        'value' => calc_counter_value('curr_tree_cnt',          'cifs', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('curr_tree_cnt', 'cifs')});

        push (@derived_perf_data,   {   'name'  => 'curr_open_file_cnt', 
                                        'value' => calc_counter_value('curr_open_file_cnt',     'cifs', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('curr_open_file_cnt', 'cifs')});

        push (@derived_perf_data,   {   'name'  => 'curr_open_dir_cnt', 
                                        'value' => calc_counter_value('curr_open_dir_cnt',      'cifs', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('curr_open_dir_cnt', 'cifs')});

        push (@derived_perf_data,   {   'name'  => 'curr_watch_dir_cnt', 
                                        'value' => calc_counter_value('curr_watch_dir_cnt',     'cifs', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('curr_watch_dir_cnt', 'cifs')});

        push (@derived_perf_data,   {   'name'  => 'curr_lock_cnt', 
                                        'value' => calc_counter_value('curr_lock_cnt',          'cifs', $current_perf_data, $old_perf_data),
                                        'unit'  => get_unit('curr_lock_cnt', 'cifs')});

        $probe_metric_hash{'cifs_stats'} = \@derived_perf_data;
   }
}


# ---------------------------------------------------------------------------------------------------------------------
# Get aggregate performance stats

sub get_aggregate_perf_stats {

    my $aggregate_instances = shift;

    our %probe_metric_hash;

    $log->info("Getting performance stats for aggregate instances: @$aggregate_instances");

    my @identifiers = ('aggregate', 'perf', 'stats');
    my $tmp_file = get_tmp_file (\@identifiers);

    my $request = NaElement->new('perf-object-get-instances');
    $request->child_add_string('objectname', 'aggregate');

    my $instances = NaElement->new('instances');
    foreach my $aggregate_instance (@$aggregate_instances) {
        $instances->child_add_string('instance', $aggregate_instance);
    }
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

    # ----- Capacity data -----

    $counters->child_add_string('counter', 'wv_fsinfo_blks_total');
    $counters->child_add_string('counter', 'wv_fsinfo_blks_reserve');
    $counters->child_add_string('counter', 'wv_fsinfo_blks_used');
    $counters->child_add_string('counter', 'wv_fsinfo_blks_snap_reserve_pct');
    $counters->child_add_string('counter', 'wvblk_snap_reserve');

    # ----- Inode data -----

    $counters->child_add_string('counter', 'wv_fsinfo_inos_total');
    $counters->child_add_string('counter', 'wv_fsinfo_inos_reserve');
    $counters->child_add_string('counter', 'wv_fsinfo_inos_used');

 
    $request->child_add($counters);

    my $result              = call_api($request) || return;
    my $current_perf_data   = {};

    # Build hash of hashes indexed by the aggregate instances
    foreach my $instance_data ($result->child_get('instances')->children_get()) {

        my $aggregate_instance = $instance_data->child_get_string('name');

        $current_perf_data->{$aggregate_instance} = {};
        # Timestamp needed per instance for calc_counter_value()
        $current_perf_data->{$aggregate_instance}->{'timestamp'} = $result->child_get_int('timestamp');
       
        foreach ($instance_data->child_get('counters')->children_get()) {

            my $counter_name        = $_->child_get_string('name');
            my $counter_value       = $_->child_get_string('value');

            $current_perf_data->{$aggregate_instance}->{$counter_name} = $counter_value;
        }
    }

    # Load old counters from file and persist new ones insted
    my $old_perf_data = read_hash_from_file($tmp_file, 1);
    write_hash_to_file($tmp_file, $current_perf_data);

    # Calculate latencies / op rates
    if (%$old_perf_data) {
        foreach my $aggregate_instance (keys(%$old_perf_data)) {

            my @derived_perf_data = ();

            push (@derived_perf_data,   {   'name'  => 'total_transfers', 
                                            'value' => calc_counter_value('total_transfers',    'aggregate', $current_perf_data->{$aggregate_instance}, $old_perf_data->{$aggregate_instance}),
                                            'unit'  => get_unit('total_transfers', 'aggregate')});

            # 4K block size, in MB/s
            push (@derived_perf_data,   {   'name'  => 'user_read_blocks', 
                                            'value' => calc_counter_value('user_read_blocks',   'aggregate', $current_perf_data->{$aggregate_instance}, $old_perf_data->{$aggregate_instance}) * 4 / 1024,
                                            'unit'  => 'MB/s'});

            # 4K block size, in MB/s
            push (@derived_perf_data,   {   'name'  => 'user_write_blocks', 
                                            'value' => calc_counter_value('user_write_blocks',  'aggregate', $current_perf_data->{$aggregate_instance}, $old_perf_data->{$aggregate_instance}) * 4 / 1024,
                                            'unit'  => 'MB/s'});
            
            # ----- Capacity data -----

            push (@derived_perf_data,   {   'name'  => 'wv_fsinfo_blks_total', 
                                            'value' => calc_counter_value('wv_fsinfo_blks_total',               'aggregate', $current_perf_data->{$aggregate_instance}, $old_perf_data->{$aggregate_instance}),
                                            'unit'  => get_unit('wv_fsinfo_blks_total', 'aggregate')});

            push (@derived_perf_data,   {   'name'  => 'wv_fsinfo_blks_reserve', 
                                            'value' => calc_counter_value('wv_fsinfo_blks_reserve',             'aggregate', $current_perf_data->{$aggregate_instance}, $old_perf_data->{$aggregate_instance}),
                                            'unit'  => get_unit('wv_fsinfo_blks_reserve', 'aggregate')});

            push (@derived_perf_data,   {   'name'  => 'wv_fsinfo_blks_used', 
                                            'value' => calc_counter_value('wv_fsinfo_blks_used',                'aggregate', $current_perf_data->{$aggregate_instance}, $old_perf_data->{$aggregate_instance}),
                                            'unit'  => get_unit('wv_fsinfo_blks_used', 'aggregate')});

            push (@derived_perf_data,   {   'name'  => 'wv_fsinfo_blks_snap_reserve_pct', 
                                            'value' => calc_counter_value('wv_fsinfo_blks_snap_reserve_pct',    'aggregate', $current_perf_data->{$aggregate_instance}, $old_perf_data->{$aggregate_instance}),
                                            'unit'  => get_unit('wv_fsinfo_blks_snap_reserve_pct', 'aggregate')});

            push (@derived_perf_data,   {   'name'  => 'wvblk_snap_reserve', 
                                            'value' => calc_counter_value('wvblk_snap_reserve',                 'aggregate', $current_perf_data->{$aggregate_instance}, $old_perf_data->{$aggregate_instance}),
                                            'unit'  => get_unit('wvblk_snap_reserve', 'aggregate')});

            # ----- Inode data -----

            push (@derived_perf_data,   {   'name'  => 'wv_fsinfo_inos_total', 
                                            'value' => calc_counter_value('wv_fsinfo_inos_total',               'aggregate', $current_perf_data->{$aggregate_instance}, $old_perf_data->{$aggregate_instance}),
                                            'unit'  => get_unit('wv_fsinfo_inos_total', 'aggregate')});

            push (@derived_perf_data,   {   'name'  => 'wv_fsinfo_inos_reserve', 
                                            'value' => calc_counter_value('wv_fsinfo_inos_reserve',             'aggregate', $current_perf_data->{$aggregate_instance}, $old_perf_data->{$aggregate_instance}),
                                            'unit'  => get_unit('wv_fsinfo_inos_reserve', 'aggregate')});

            push (@derived_perf_data,   {   'name'  => 'wv_fsinfo_inos_used', 
                                            'value' => calc_counter_value('wv_fsinfo_inos_used',                'aggregate', $current_perf_data->{$aggregate_instance}, $old_perf_data->{$aggregate_instance}),
                                            'unit'  => get_unit('wv_fsinfo_inos_used', 'aggregate')});

            $probe_metric_hash{'aggregate-' . $aggregate_instance} = \@derived_perf_data;
        }
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Get volume performance stats

sub get_volume_perf_stats {

    my $volume_instances = shift;

    our %probe_metric_hash;

    $log->info("Getting performance stats for volume instances: @$volume_instances");

    my @identifiers = ('volume', 'perf', 'stats');
    my $tmp_file = get_tmp_file (\@identifiers);

    my $request = NaElement->new('perf-object-get-instances');
    $request->child_add_string('objectname', 'volume');

    my $instances = NaElement->new('instances');
    foreach my $volume_instance (@$volume_instances) {
        $instances->child_add_string('instance', $volume_instance);
    }
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

    my $result              = call_api($request) || return;
    my $current_perf_data   = {};

    # Build hash of hashes indexed by the volume instances
    foreach my $instance_data ($result->child_get('instances')->children_get()) {

        my $volume_instance = $instance_data->child_get_string('name');

        $current_perf_data->{$volume_instance} = {};
        # Timestamp needed per instance for calc_counter_value()
        $current_perf_data->{$volume_instance}->{'timestamp'} = $result->child_get_int('timestamp');
       
        foreach ($instance_data->child_get('counters')->children_get()) {

            my $counter_name        = $_->child_get_string('name');
            my $counter_value       = $_->child_get_string('value');

            $current_perf_data->{$volume_instance}->{$counter_name} = $counter_value;
        }
    }

    # Load old counters from file and persist new ones insted
    my $old_perf_data = read_hash_from_file($tmp_file, 1);
    write_hash_to_file($tmp_file, $current_perf_data);

    # Calculate latencies / op rates
    if (%$old_perf_data) {
        foreach my $volume_instance (keys(%$old_perf_data)) {

            my @derived_perf_data = ();

            #  ----- Global stats -----

            # Convert to ms
            push (@derived_perf_data,   {   'name'  => 'avg_latency', 
                                            'value' => calc_counter_value('avg_latency',    'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}) / 1000,
                                            'unit'  => 'ms'});

            push (@derived_perf_data,   {   'name'  => 'total_ops', 
                                            'value' => calc_counter_value('total_ops',      'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}),
                                            'unit'  => get_unit('total_ops', 'volume')});

            #  ----- Volume reads -----

            # Convert to MB/s
            push (@derived_perf_data,   {   'name'  => 'read_data', 
                                            'value' => calc_counter_value('read_data',      'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}) / (1024 * 1024),
                                            'unit'  => 'MB/s'});

            # Convert to ms
            push (@derived_perf_data,   {   'name'  => 'read_latency',
                                            'value' => calc_counter_value('read_latency',   'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}) / 1000,
                                            'unit'  => 'ms'});

            push (@derived_perf_data,   {   'name'  => 'read_ops', 
                                            'value' => calc_counter_value('read_ops',       'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}),
                                            'unit'  => get_unit('read_ops', 'volume')});

            push (@derived_perf_data,   {   'name'  => 'read_blocks', 
                                            'value' => calc_counter_value('read_blocks',    'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}),
                                            'unit'  => get_unit('read_blocks', 'volume')});

            #  ----- Volume writes -----

            # Convert to MB/s
            push (@derived_perf_data,   {   'name'  => 'write_data', 
                                            'value' => calc_counter_value('write_data',     'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}) / (1024 * 1024),
                                            'unit'  => 'MB/s'});

            # Convert to ms
            push (@derived_perf_data,   {   'name'  => 'write_latency', 
                                            'value' => calc_counter_value('write_latency',  'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}) / 1000,
                                            'unit'  => 'ms'});

            push (@derived_perf_data,   {   'name'  => 'write_ops', 
                                            'value' => calc_counter_value('write_ops',      'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}),
                                            'unit'  => get_unit('write_ops', 'volume')});

            push (@derived_perf_data,   {   'name'  => 'write_blocks', 
                                            'value' => calc_counter_value('write_blocks',   'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}),
                                            'unit'  => get_unit('write_blocks', 'volume')});

            #  ----- Volume other ops -----

            # Convert to ms
            push (@derived_perf_data,   {   'name'  => 'other_latency', 
                                            'value' => calc_counter_value('other_latency',  'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}) / 1000,
                                            'unit'  => 'ms'});

            push (@derived_perf_data,   {   'name'  => 'other_ops', 
                                            'value' => calc_counter_value('other_ops',      'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}),
                                            'unit'  => get_unit('other_ops', 'volume')});

            #  ----- Volume nfs -----
        
            # Convert to MB/s
            push (@derived_perf_data,   {   'name'  => 'nfs_read_data', 
                                            'value' => calc_counter_value('nfs_read_data',      'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}) / (1024 * 1024),
                                            'unit'  => 'MB/s'});

            # Convert to ms
            push (@derived_perf_data,   {   'name'  => 'nfs_read_latency', 
                                            'value' => calc_counter_value('nfs_read_latency',   'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}) / 1000,
                                            'unit'  => 'ms'});

            push (@derived_perf_data,   {   'name'  => 'nfs_read_ops', 
                                            'value' => calc_counter_value('nfs_read_ops',       'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}),
                                            'unit'  => get_unit('nfs_read_ops', 'volume')});


            # Convert to MB/s
            push (@derived_perf_data,   {   'name'  => 'nfs_write_data', 
                                            'value' => calc_counter_value('nfs_write_data',     'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}) / (1024 * 1024),
                                            'unit'  => 'MB/s'});

            # Convert to ms
            push (@derived_perf_data,   {   'name'  => 'nfs_write_latency', 
                                            'value' => calc_counter_value('nfs_write_latency',  'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}) / 1000,
                                            'unit'  => 'ms'});

            push (@derived_perf_data,   {   'name'  => 'nfs_write_ops', 
                                            'value' => calc_counter_value('nfs_write_ops',      'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}),
                                            'unit'  => get_unit('nfs_write_ops', 'volume')});

            # Convert to ms
            push (@derived_perf_data,   {   'name'  => 'nfs_other_latency', 
                                            'value' => calc_counter_value('nfs_other_latency',  'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}) / 1000,
                                            'unit'  => 'ms'});

            push (@derived_perf_data,   {   'name'  => 'nfs_other_ops', 
                                            'value' => calc_counter_value('nfs_other_ops',      'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}),
                                            'unit'  => get_unit('nfs_other_ops', 'volume')});

            #  ----- Volume cifs -----

            # Convert to MB/s
            push (@derived_perf_data,   {   'name'  => 'cifs_read_data', 
                                            'value' => calc_counter_value('cifs_read_data',     'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}) / (1024 * 1024),
                                            'unit'  => 'MB/s'});

            # Convert to ms
            push (@derived_perf_data,   {   'name'  => 'cifs_read_latency', 
                                            'value' => calc_counter_value('cifs_read_latency',  'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}) / 1000,
                                            'unit'  => 'ms'});

            push (@derived_perf_data,   {   'name'  => 'cifs_read_ops', 
                                            'value' => calc_counter_value('cifs_read_ops',      'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}),
                                            'unit'  => get_unit('cifs_read_ops', 'volume')});


            # Convert to MB/s
            push (@derived_perf_data,   {   'name'  => 'cifs_write_data', 
                                            'value' => calc_counter_value('cifs_write_data',    'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}) / (1024 * 1024),
                                            'unit'  => 'MB/s'});

            # Convert to ms
            push (@derived_perf_data,   {   'name'  => 'cifs_write_latency', 
                                            'value' => calc_counter_value('cifs_write_latency', 'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}) / 1000,
                                            'unit'  => 'ms'});

            push (@derived_perf_data,   {   'name'  => 'cifs_write_ops', 
                                            'value' => calc_counter_value('cifs_write_ops',     'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}),
                                            'unit'  => get_unit('cifs_write_ops', 'volume')});


            # Convert to ms
            push (@derived_perf_data,   {   'name'  => 'cifs_other_latency', 
                                            'value' => calc_counter_value('cifs_other_latency', 'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}) / 1000,
                                            'unit'  => 'ms'});

            push (@derived_perf_data,   {   'name'  => 'cifs_other_ops', 
                                            'value' => calc_counter_value('cifs_other_ops',     'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}),
                                            'unit'  => get_unit('cifs_other_ops', 'volume')});

            #  ----- Volume iSCSI -----

            # Convert to MB/s
            push (@derived_perf_data,   {   'name'  => 'iscsi_read_data', 
                                            'value' => calc_counter_value('iscsi_read_data',    'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}) / (1024 * 1024),
                                            'unit'  => 'MB/s'});

            # Convert to ms
            push (@derived_perf_data,   {   'name'  => 'iscsi_read_latency', 
                                            'value' => calc_counter_value('iscsi_read_latency', 'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}) / 1000,
                                            'unit'  => 'ms'});

            push (@derived_perf_data,   {   'name'  => 'iscsi_read_ops', 
                                            'value' => calc_counter_value('iscsi_read_ops',     'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}),
                                            'unit'  => get_unit('iscsi_read_ops', 'volume')});

            # Convert to MB/s
            push (@derived_perf_data,   {   'name'  => 'iscsi_write_data', 
                                            'value' => calc_counter_value('iscsi_write_data',   'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}) / (1024 * 1024),
                                            'unit'  => 'MB/s'});

            # Convert to ms
            push (@derived_perf_data,   {   'name'  => 'iscsi_write_latency', 
                                            'value' => calc_counter_value('iscsi_write_latency','volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}) / 1000,
                                            'unit'  => 'ms'});

            push (@derived_perf_data,   {   'name'  => 'iscsi_write_ops', 
                                            'value' => calc_counter_value('iscsi_write_ops',    'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}),
                                            'unit'  => get_unit('iscsi_write_ops', 'volume')});


            # Convert to ms
            push (@derived_perf_data,   {   'name'  => 'iscsi_other_latency', 
                                            'value' => calc_counter_value('iscsi_other_latency','volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}) / 1000,
                                            'unit'  => 'ms'});

            push (@derived_perf_data,   {   'name'  => 'iscsi_other_ops', 
                                            'value' => calc_counter_value('iscsi_other_ops',    'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}),
                                            'unit'  => get_unit('iscsi_other_ops', 'volume')});

            #  ----- Volume inodes -----

            push (@derived_perf_data,   {   'name'  => 'wv_fsinfo_public_inos_total', 
                                            'value' => calc_counter_value('wv_fsinfo_public_inos_total',    'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}),
                                            'unit'  => get_unit('wv_fsinfo_public_inos_total', 'volume')});

            push (@derived_perf_data,   {   'name'  => 'wv_fsinfo_public_inos_reserve', 
                                            'value' => calc_counter_value('wv_fsinfo_public_inos_reserve',  'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}),
                                            'unit'  => get_unit('wv_fsinfo_public_inos_reserve', 'volume')});

            push (@derived_perf_data,   {   'name'  => 'wv_fsinfo_public_inos_used', 
                                            'value' => calc_counter_value('wv_fsinfo_public_inos_used',     'volume', $current_perf_data->{$volume_instance}, $old_perf_data->{$volume_instance}),
                                            'unit'  => get_unit('wv_fsinfo_public_inos_used', 'volume')});

            $probe_metric_hash{'volume-' . $volume_instance} = \@derived_perf_data;
        }
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Get processor performance stats

sub get_processor_perf_stats {

    $log->info("Getting performance stats for processors...");

    my @identifiers = ('processor', 'perf', 'stats');
    my $tmp_file = get_tmp_file (\@identifiers);

    my $request = NaElement->new('perf-object-get-instances');
    $request->child_add_string('objectname', 'processor');

    my $counters = NaElement->new('counters');

    $counters->child_add_string('counter', 'processor_busy');
    $counters->child_add_string('counter', 'processor_elapsed_time');
    $counters->child_add_string('counter', 'domain_busy');

    $request->child_add($counters);

    my $result              = call_api($request) || return;
    my $current_perf_data   = {};

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

            my $counter_name    = $counter->child_get_string('name');
            my $counter_value   = $counter->child_get_string('value');

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

#       push (@derived_perf_data,   {   'name'  => 'processor_busy', 
#                                       'value' => calc_counter_value('processor_busy',         'processor', $current_perf_data, $old_perf_data)});


        # Add generated domain busy counters
        $log->debug("counter names: " . Dumper(@domain_busy_counters));
        foreach my $domain_busy_counter_name (@domain_busy_counters) {
            push (@derived_perf_data,   {   'name'  => $domain_busy_counter_name, 
                                            'value' => calc_counter_value($domain_busy_counter_name, 'processor', $current_perf_data, $old_perf_data)});
        }

  #       render_perf_data(\@derived_perf_data);
 
        our %probe_metric_hash;
        $probe_metric_hash{'processor'} = \@derived_perf_data;
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Get all user selected stats

sub get_user_selected_perf_stats {

    $log->info("Getting user selected perf stats ...");

    our $plugin;

    my (@aggregate_instances, @volume_instances) = ((), ());
    my @selected_stats = split(',', $plugin->opts->stats);

    foreach my $stat (@selected_stats) {
        switch ($stat) {

            case /^aggr/i {
                my ($name, $instance) = split('=', $stat);
                push(@aggregate_instances, $instance);
            }

            case /^nfsv3/i {
                get_nfsv3_perf_stats();
            }

            case /^cifs/i {
                get_cifs_perf_stats();
            }

            case /^processor/i {
                get_processor_perf_stats();
            }

            case /^system/i {
                get_system_perf_stats();
            }

            case /^vol/i {
                my ($name, $instance) = split('=', $stat);
                push(@volume_instances, $instance);
            }

            else {
                # Unknown / unsupported format
                $log->error("Unknown stat name [$stat] => ignoring!");
            }
        }
    }

    # Process aggregate instances
    if (@aggregate_instances) {
        get_aggregate_perf_stats(\@aggregate_instances);
    }

    # Process volume instances
    if (@volume_instances) {
        get_volume_perf_stats(\@volume_instances);
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# List selected meta information from the api

sub list_user_selected_meta_data {

    $log->info("Listing user selected meta information from the api...");

    our $plugin;
    my $list = $plugin->opts->list;

    switch ($list) {

        case /^objects/i {
            list_perf_objects();
        }

        case /^counters/i {
            my ($name, $object) = split('=', $list);
            load_perf_object_counter_descriptions($object);
        }

        case /^instances/i {
            my ($name, $object) = split('=', $list);
            list_perf_objects_instances($object);
        }

        else {
            # Unknown / unsupported
            $log->error("Unknown metadata information request [$list] => ignoring!");
        }
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Get all user selected stats

sub main_loop {

    # Get iteration start time
    my $iteration_start_time = Time::HiRes::gettimeofday();

    # Hash with all perf. counters in the format { 'stat_group' => array of perf. counters };
    # This will be then rendered to requested output format (e.g. nagios / graphite)
    our %probe_metric_hash = ();

    # Basic system stats, like verions, number of processors, etc. (needed for some calculations)
    our $static_system_stats;

    # Iteration counter
    our $iteration;

    # Plugin ref.
    our $plugin;

    # Warning / chritical / standard messages from check_perf_data()
    our (@warning, @critical, @standard);

    # Returned probe output (e.g. nagios)
    my $probe_output_string = '';

    # Returned probe output (e.g. graphite)
    my %probe_output_hash = ();

    # Get the user selected stats objects
    get_user_selected_perf_stats();

    while (my ($perf_counter_group, $perf_counters) = each %probe_metric_hash) {

        # Filter list of counters based on cli selection
        my @filtered_perf_counters = ();
        my @counter_names = split(',', $plugin->opts->filter);
        if ($plugin->opts->filter eq 'all') {
            @filtered_perf_counters = @$perf_counters;
        } else {
            foreach my $counter (@$perf_counters) {
                if ($counter->{'name'} ~~ @counter_names) {
                    push(@filtered_perf_counters, $counter);
                }
            }
        }
        my $filtered_counter_num = scalar(@$perf_counters) - scalar(@filtered_perf_counters);
        $log->info("Filtered [$filtered_counter_num] counter due to cli selection");

        # Check perf data for warnings / criticals
        check_perf_data(\@filtered_perf_counters);

        my $filtered_perf_counters_num = scalar @filtered_perf_counters;
        $log->info("Rendering [$filtered_perf_counters_num] perf counter metrics for output format [$plugin->opts->output]...");

        # Process a group of filtered perf counters according to selected format
        switch (lc($plugin->opts->output)) {

            case 'nagios' {

               for my $counter (@filtered_perf_counters) {
                    $log->debug(sprintf("%-20s: %10s", $counter->{'name'}, $counter->{'value'}));
                    $probe_output_string .= $counter->{'name'} . "=" . $counter->{'value'};
                    # Check for unit
                    if (lc($plugin->opts->units) eq 'yes' and exists($counter->{'unit'})) {
                        $probe_output_string .= $counter->{'unit'};
                    }
                    $probe_output_string .= " ";
                }
            }

            case 'graphite' {

                # Create hash for sending to graphite later on
                my %perf_counter_group_hash = ();
                for my $counter (@filtered_perf_counters) {
                    $log->debug(sprintf("%-20s: %10s", $counter->{'name'}, $counter->{'value'}));
                    $perf_counter_group_hash{$counter->{'name'}} = $counter->{'value'};
                }

                $probe_output_hash{$perf_counter_group} = \%perf_counter_group_hash;
            }

            else {
                # Unknown / unsupoorted format
                $log->error("Unkown output format => returning nothing!");
                exit(0);
            }
        }
    }

    # Finish probe iteration depending on output kind
    switch (lc($plugin->opts->output)) {

        case 'nagios' {

            $log->info("Sending output to nagios...");

            my $probe_status_output = '';
            my $status_code = OK;

            # Remove last two characters
            $probe_output_string = substr($probe_output_string, 0, length($probe_output_string) - 2);
            
            if (@warning) {
                $probe_status_output .= 'Warning: ' . join(', ', @warning);
                $status_code = WARNING;
            }

            if (@critical) {
                if (@warning) {
                    $probe_status_output .= ', ';
                }
                $probe_status_output .= 'Critical: ' . join(', ', @critical);
                $status_code = CRITICAL;
            }

            # Print string and exit
            $plugin->plugin_exit($status_code, $probe_status_output . ' | ' . $probe_output_string);
        }

        case 'graphite' {

            $log->info("Sending output to graphite...");

            my $graphite_endpoint = 'muendung.gwdg.de';

            my $graphite = Net::Graphite->new(
                 # except for host, these hopefully have reasonable defaults, so are optional
                 host                  => $graphite_endpoint,
                 port                  => 2003,
                 trace                 => 0,                # if true, copy what's sent to STDERR
                 proto                 => 'tcp',            # can be 'udp'
                 timeout               => 1,                # timeout of socket connect in seconds
                 fire_and_forget       => 0,                # if true, ignore sending errors
                 return_connect_error  => 0,                # if true, forward connect error to caller
             );
 
            # Send metrics to graphite endpoint
            if (not $plugin->opts->debug) {
                if ($graphite->connect) {
                    # Send metrics
                    my %hash_to_send = (time() => \%probe_output_hash);
                    $graphite->send(path => $static_system_stats->{'hostname'}, data => \%hash_to_send);
                } else {
                    $log->error("Could not connect to graphite endpoint: $graphite_endpoint => not sending metrics!");
                }
            }
        }
    }

    # Get iteration end time
    my $iteration_end_time = Time::HiRes::gettimeofday();
    my $iteration_duration_string = sprintf("%.4f", $iteration_end_time - $iteration_start_time);

    # Wait
    $iteration++;
    $log->info("Finished iteration [$iteration] in [$iteration_duration_string] seconds => waiting...");
}

# ---------------------------------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------------------------------

$log->info('-' x 120);
$log->info("Starting probe '$PROGNAME'...");

# Create Monitoring::Plugin instance
our $plugin = Monitoring::Plugin->new ( usage       => "Usage: %s -H <hostname> -U <user> -P <password> -s <stats1[=instance1],...> [-f <perf_counter1>,<perf_counter2>,...] [-w <perf_counter1>=<range1>,...] [-c <perf_counter1>=<range1>,...]",
                                        shortname   => $SHORTNAME,
                                        version     => $VERSION,
                                        blurb       => $DESCRIPTION,
                                        extra       => $EXTRA_DESC,
                                        license     => $LICENSE,
                                        plugin      => $PROGNAME
                                    );


# Define additional arguments
$plugin->add_arg(
    spec        => 'hostname|H=s',
    help        => "Hostname or IP address of the NetApp filer to check (default: localhost).\n",
    required    => 1,
);

$plugin->add_arg(
    spec        => 'user|U=s',
    help        => "User name for login (default: none).\n",
    required    => 1,
);

$plugin->add_arg(
    spec        => 'password|P=s',
    help        => "Password for login (default: none).\n",
    required    => 1,
);

$plugin->add_arg(
    spec        => 'protocol|p=s',
    help        => "Protocol to use for communication (default: HTTPS).\n",
    required    => 0,
    default     => 'HTTPS'
);

$plugin->add_arg(
    spec        => 'stats|s=s',
    help        => "Type of stats to retrieve (default: system). Multiple stats can be selected, separated by a column. Valid values are:\n"    .
                    "     aggregate=aggr_name\n"    .
                    "     nfsv3\n"                  .
                    "     processor\n"              .
                    "     system\n"                 .
                    "     volume=vol_name\n"        ,
    required    => 0,
    default     => 'system'
);

$plugin->add_arg(
    spec        => 'list|l=s',
    help        => "List meta information from the api (available objects, instances, counters, etc.). Aborts all further actions after listing. Valid values are:\n"    .
                    "     objects\n"                    .
                    "     counters=<object_name>\n"                   .
                    "     instances=<object_name>\n"    ,
    required    => 0,
    default     => ''
);

$plugin->add_arg(
    spec        => 'filter|f=s',
    help        => "Select the performance counter(s) to use by providing a column separated list of their names (default: all).\n",
    required    => 0,
    default     => 'all'
);

$plugin->add_arg(
    spec        => 'tmp_dir|T=s',
    help        => "Location of directory for temporary files (default: /tmp).\n",
    required    => 0,
    default     => '/tmp'
);

$plugin->add_arg(
    spec        => 'output|o=s',
    help        => "Define output format for the probe to use (default: nagios).\n",
    required    => 0,
    default     => 'nagios'
);

$plugin->add_arg(
    spec        => 'units|u=s',
    help        => "Append units to metrics (default: yes).\n",
    required    => 0,
    default     => 'yes'
);

$plugin->add_arg(
    spec        => 'warn|W=s',
    help        => "Define performance counters and ranges to warn on (default: none).\n",
    required    => 0,
    default     => undef
);

$plugin->add_arg(
    spec        => 'critical|C=s',
    help        => "Define performance counters and ranges to critical on (default: none).\n",
    required    => 0,
    default     => undef
);

$plugin->add_arg(
    spec        => 'wait|w=i',
    help        => "For output plugins that loop indefinitely (e.g. graphite) the number of seconds to wait before gathering metrics again (default: 10).\n",
    required    => 0,
    default     => 10
);

$plugin->add_arg(
    spec        => 'debug|d',
    help        => "Debug mode: do not write any output if possible / sensible (default: false).\n",
    required    => 0,
    default     => 0,
);

$plugin->getopts;

# Signal handler - TERM

local $SIG{ALRM} = sub {
    local $SIG{TERM} = 'IGNORE';
    kill TERM => -$$;
    $plugin->plugin_exit(CRITICAL, "Data could not be collected in the allocated time (" . $plugin->opts->timeout . "s)");
};

local $SIG{TERM} = sub {
    local $SIG{TERM} = 'IGNORE';
    kill TERM => -$$;
    $plugin->plugin_die("Plugin received TERM signal.");
};

alarm($plugin->opts->timeout);

# Print tmp directory
our $tmp_dir = $plugin->opts->tmp_dir;
$log->info("Using '$tmp_dir' as directory for temp files.");

# Create hash of performance counters to warn on

our %warning_defs = ();

if ($plugin->opts->warn) {
    foreach my $counter_def (split(',', $plugin->opts->warn)) {
        my ($counter_name, $counter_range) = split('=', $counter_def);
        $warning_defs{trim($counter_name)} = trim($counter_range);
    }
}

# Create hash of performance counters to critical on

our %critical_defs = ();

if ($plugin->opts->critical) {
    foreach my $counter_def (split(',', $plugin->opts->critical)) {
        my ($counter_name, $counter_range) = split('=', $counter_def);
        $critical_defs{trim($counter_name)} = trim($counter_range);
    }
}

# Warning / chritical / standard messages from check_perf_data()
our (@warning, @critical, @standard) = ((), (), ());

# Get filer connection
our $filer;
connect_to_filer();

# Get perf object list
our $json_parser = JSON->new->allow_nonref;

# Array of counter descriptions for various objects. Persisted into files.
our $perf_object_counter_descriptions = {};

# Get basic system stats, like verions, number of processors, etc. (needed for some calculations)
our $static_system_stats = get_static_system_stats();
$log->info("Probe targeting filer: $static_system_stats->{'hostname'} (ONTAP: $static_system_stats->{'ontap_version'}, serial: $static_system_stats->{'serial_no'})");

# ---- Main loop

if (defined $plugin->opts->list and $plugin->opts->list ne '') {
    # List metainformation from the api mode: list data as requested by --list and exit
    list_user_selected_meta_data();
    exit(0);
}

our $iteration = 0;

if (lc($plugin->opts->output) eq 'graphite') {

    my $loop = IO::Async::Loop->new;
     
    my $timer = IO::Async::Timer::Periodic->new(
       interval => $plugin->opts->wait,
       on_tick  => \&main_loop,
    );
     
    $timer->start;
    $loop->add( $timer );
    $loop->run;

} else {
    main_loop();
}




