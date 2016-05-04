# NetApp-probes

Nagios / Graphite probe(s) for monitoring of NetApp filers.

## Features

- Support for different groups of perf. metrics available through the NetApp SDK
    - Available: aggregates, volumes, nfsv3, cifs, processor, system, interfaces
    - Not difficult to add new ones
- Uses meta-information APIs from NetApp SDK to process metrics auto-magically (i.e. deltas, rates, averages, etc.)
- Caching of metric descriptions / metrics necessary for calculations in JSON files to reduce load on the filers
- Used in production for NetApp FAS6240 filers 
- Support for exploration of the perf. monitoring APIs of the NetApp SDK (e.g. list available metrics)
- Works under Linux / Windows (tested with Microsoft Server 2012 with Cygwin)
- Optimized NetApp SDK API calls for high performance / low load on the filers
- Extensive logging capabilities
- Can be used as Nagios support
    - Generate alerts based on performance metrics (ranges, etc.)
    - Use multiple metrics in one call to alert on
    - Return metrics to generate graphs in Nagios
- Graphite mode (compatible with InfluxDB, etc.)
    - Collect perf. metrics continuesly and write them into a metrics database of choice via graphite protocol

## Limitations

- Currently only compatible with NetApp 7-Mode APIs
- One probe per filer model

## Installation

### Linux: install perl modules available directly in most distros

- lwp-useragent
- xml-parser
- Monitoring::Plugin
- Log::Log4perl
- Net::SSLeay

### Linux: install missing perl modules directly from CPAN

For some modules dev packages may need to be installed

perl -MCPAN -e shell
cpan> install Monitoring::Plugin        (For Nagios stuff)
cpan> install Log::Log4perl             (For logging)
cpan> install JSON                      (For json rendering in caching files)
cpan> install File::Slurp
cpan> install Switch                    (CHORNY/Switch-2.17.tar.gz)
cpan> install Clone                     (GARU/Clone-0.37.tar.gz)
cpan> install Net::Graphite             (v0.16)
cpan> install IO::Async                 (For Timer loop: IO::Async::Timer::Periodic, v0.70)
cpan> install Time::HiRes               (For high resolution (ms) times, v1.9732)

### Windows

A list of packages installed for a working Cygwin deployment under Windows Server 2012 is commited into the repository (packagelist.cygwin)

This list can be reinstalled with the following command (untested ;)):

setup-x86_64 -P `awk 'NR==1{printf \$1}{printf ",%s", \$1}' packagelist.cygwin`

## Examples

Get system stats as metrics and write them out via graphite protocol, every 5s:
check_netapp.pl -H <filer-ip> -U <user> -P <password> -o graphite -w 5 -s system

Get nfsv3 and processorr stats and write them out via graphite protocol, every 5s:
check_netapp.pl -H <filer-ip> -U <user> -P <password> -o graphite -w 5 -s nfsv3,processor

A more complex example (graphite, every 5s, all interfaces, two volumes, two aggregates):
./check_netapp.pl -H <filer-ip> -U <user> -P <pwd> -o graphite -w 5 -s cifs,nfsv3,processor,system,interface=all,aggregate=<aggregate1>,aggregate=<aggregate2>,volume=<volume1>,volume=<volume2>

## Screenshots

The followinig screenshots are from an InfluxDB / Grafana deployment utilizing / visualizing the data collected by this probe.

### Overview Dashboard

The following screenshots show the overview dashboard in with different time scales

Overview 1h

[![netapp overview](https://github.com/pkasprzak/NetApp-probes/raw/master/docs/screenshots/netapp_overview_1h.png)](#netappoverview1h)

Overview 5m

[![netapp overview](https://github.com/pkasprzak/NetApp-probes/raw/master/docs/screenshots/netapp_overview_5m.png)](#netappoverview5m)

Overview 24h

[![netapp overview](https://github.com/pkasprzak/NetApp-probes/raw/master/docs/screenshots/netapp_overview_24h.png)](#netappoverview24h)

### Aggregate Dashboard

Aggregate 1h

[![netapp aggregate](https://github.com/pkasprzak/NetApp-probes/raw/master/docs/screenshots/netapp_aggregate_1h.png)](#netappaggregate1h)

Aggregate 30d

[![netapp aggregate](https://github.com/pkasprzak/NetApp-probes/raw/master/docs/screenshots/netapp_aggregate_30d.png)](#netappaggregate30d)

### Interfaces Dashboard

Interfaces 1h

[![netapp interfaces](https://github.com/pkasprzak/NetApp-probes/raw/master/docs/screenshots/netapp_interfaces.png)](#netappinterfaces1h)

Interfaces graph configuration in Grafana (note the regexps / variables :))

[![netapp interfaces](https://github.com/pkasprzak/NetApp-probes/raw/master/docs/screenshots/netapp_interfaces_configuration.png)](#netappinterfacesconfiguration)

Interfaces time range selection in Grafana

[![netapp interfaces](https://github.com/pkasprzak/NetApp-probes/raw/master/docs/screenshots/netapp_interfaces_time_ranges.png)](#netappinterfacestimeranges)

### Volume Dashboard

[![netapp volume](https://github.com/pkasprzak/NetApp-probes/raw/master/docs/screenshots/netapp_volume.png)](#netappvolume)



