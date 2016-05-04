# NetApp-probes

Nagios / Graphite probe(s) for monitoring of NetApp filers.

## Features

- Support for various groups of perf. metrics (not difficult to add new ones): aggregates, volumes, nfsv3, cifs, processor, system, interfaces
- Uses meta-information APIs from NetApp SDK to process metrics automagically
- Used in production for NetApp FAS6240 filers 
- Support for exploration of the perf. monitoring APIs of the NetApp SDK
- Works under Linux / Windows (tested with Microsoft Server 2012 with Cygwin)
- Optimized NetApp SDK API calls for high performance / low load on the filers
- Nagios support
    - Generate alerts based on performance metrics (ranges, etc.)
    - Use multiple metrics
    - Return metrics to generate graphs in Nagios
- Graphite mode (compatible with InfluxDB, etc.)
    - Collect perf. metrics continuesly and write them into a metrics database of choice via graphite protocol

## Limitation

- Currently only compatible with NetApp 7-Mode APIs
- One probe per filer model

## Installation

### Windows

## Examples


## Screenshots

The followinig screenshots are from an InfluxDB / Grafana deployment utilizing / visualizing the data collected by this probe.

### Overview dashboard

The following screenshots show the overview dashboard in with different time scales

[![netapp overview](https://github.com/pkasprzak/NetApp-probes/raw/master/docs/screenshots/netapp_overview_1h.png)](#netappoverview1h)
[![netapp overview](https://github.com/pkasprzak/NetApp-probes/raw/master/docs/screenshots/netapp_overview_5m.png)](#netappoverview5m)
[![netapp overview](https://github.com/pkasprzak/NetApp-probes/raw/master/docs/screenshots/netapp_overview_24h.png)](#netappoverview24h)


