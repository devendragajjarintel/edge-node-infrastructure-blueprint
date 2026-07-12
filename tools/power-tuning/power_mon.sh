#!/bin/bash
#
# power_mon.sh - Live power/thermal monitor for the CPU package and platform.
#
# Uses Intel's turbostat to print a periodic summary of package temperature and
# the RAPL power domains, so you can watch the effect of a power profile (e.g.
# one applied by set_platform_power.sh) under load.
#
# Usage: ./power_mon.sh          # sample every 2 s until Ctrl-C
#
# Columns shown (all powers in watts, temp in degrees C):
#   PkgTmp   - package temperature
#   SysWatt  - whole-platform (psys) power         [RAPL psys / MSR 0x65C]
#   Package  - package power counter
#   PkgWatt  - package power: CPU + iGPU + uncore   [RAPL package / MSR 0x610]
#   CorWatt  - CPU cores power
#   GFXWatt  - integrated GPU power
#   RAMWatt  - DRAM / memory controller power
#
# Notes:
#   * -S / --Summary prints one aggregate row per interval (no per-CPU rows).
#   * Requires root (turbostat reads MSRs); hence sudo below.
#   * SysWatt may be blank if the platform (psys) RAPL domain is not populated.

set -x
# --interval 2  : refresh every 2 seconds
# --show ...    : restrict output to the temperature + power columns of interest
sudo turbostat -S --interval 2 --show PkgTmp,SysWatt,Package,PkgWatt,CorWatt,GFXWatt,RAMWatt | tee power_mon.txt
