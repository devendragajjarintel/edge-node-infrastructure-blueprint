#!/usr/bin/env bash
# SPDX-FileCopyrightText: (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
#
# set_power_profile.sh - Apply a named platform power profile by SysWatt target.
#
# The profiles below are expressed as SysWatt (psys / whole-platform) budgets:
#
#     Profile               SysWatt
#     -------               -------
#     LowPower               10 W
#     BalancedLow            15 W
#     BalancedHigh           20 W
#     Performance            25 W
#     MaxPerformance         45 W
#
# It drives the existing tools/power-tuning/set_platform_power.sh, which reads
# the silicon's Config-TDP levels and programs the RAPL PL1/PL2 limits.
#
# psys (SysWatt) support:
#   * The script probes whether the silicon exposes a platform (psys) RAPL power
#     domain. If it does, the profile is enforced as a SysWatt cap.
#   * If psys is NOT supported, the platform budget cannot be capped directly.
#     The package (PkgWatt) target is then estimated from the SysWatt budget by
#     subtracting the estimated uncore/rest-of-platform power:
#         PkgWatt = SysWatt - uncoreWatt
#     uncoreWatt defaults to 5 W (override with --uncoreWatt) and represents the
#     non-package platform draw (VRs, DRAM, PHYs, board rails).
#
# Each profile carries a default burst ratio:
#
#     Profile               SysWatt   Default burst ratio
#     -------               -------   ------------------
#     LowPower               10 W     1.25
#     BalancedLow            15 W     1.25
#     BalancedHigh           20 W     1.18
#     Performance            25 W     1.19
#     MaxPerformance         45 W     1.18
#
# Usage:
#   sudo ./set_power_profile.sh <profile> [--burstRatio R] [--uncoreWatt W]
#                                         [--dry-run]
#   ./set_power_profile.sh --list
#
#   <profile>        one of: LowPower BalancedLow BalancedHigh Performance
#                    MaxPerformance (case-insensitive)
#   --burstRatio R   burst ratio (>= 1.0); passed through to
#                    set_platform_power.sh. Overrides the profile's default
#                    (see table above).
#   --uncoreWatt W   estimated uncore/rest-of-platform power in watts used to
#                    derive PkgWatt from the SysWatt budget when psys is not
#                    supported (default 5).
#   --dry-run        resolve and print the plan; do not apply anything.
#   --list           list the available profiles and their SysWatt targets.
#
# Note: the underlying RAPL cap is applied at runtime and does not persist
# across reboot.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SET_PLATFORM_POWER="$SCRIPT_DIR/set_platform_power.sh"

# ---- Profile table (name -> SysWatt, default burst ratio) -----------------
# Ordered lowest-to-highest platform budget. The default burst ratio for each
# profile can be overridden with --burstRatio.
PROFILE_NAMES=(LowPower BalancedLow BalancedHigh Performance MaxPerformance)
PROFILE_WATTS=(10 15 20 25 45)
PROFILE_RATIOS=(1.25 1.25 1.18 1.19 1.18)

# ---- Defaults --------------------------------------------------------------
# RATIO stays empty until resolved: an explicit --burstRatio wins, otherwise the
# selected profile's default (PROFILE_RATIOS) is used.
RATIO=""
UNCORE_W="5"
DRY_RUN=0

usage() {
	cat <<EOF
Usage: $0 <profile> [--burstRatio R] [--uncoreWatt W] [--dry-run]
       $0 --list
       $0 --help

Apply a named platform power profile expressed as a SysWatt (whole-platform)
budget, using tools/power-tuning/set_platform_power.sh.

Profiles (SysWatt target):
  LowPower              10 W
  BalancedLow           15 W
  BalancedHigh          20 W
  Performance           25 W
  MaxPerformance        45 W

Options:
  --burstRatio R   burst ratio (>= 1.0). Overrides the profile default
                   (LowPower 1.25, BalancedLow 1.25, BalancedHigh 1.18,
                   Performance 1.19, MaxPerformance 1.18).
  --uncoreWatt W   Estimated uncore/rest-of-platform power in watts (default 5),
                   used to derive PkgWatt = SysWatt - uncoreWatt when the silicon
                   does not support a psys (SysWatt) power domain.
  --dry-run        Resolve and print the plan without applying anything.
  --list           List the available profiles and exit.
  -h, --help       Show this help and exit.

Examples:
  sudo $0 Performance
  sudo $0 MaxPerformance --burstRatio 1.4
  sudo $0 BalancedLow --uncoreWatt 6
  $0 Performance --dry-run

Note: needs root (re-runs itself with sudo) to program the RAPL MSRs. The cap is
applied at runtime and does not persist across reboot.
EOF
}

list_profiles() {
	echo "Available power profiles:"
	local i
	for i in "${!PROFILE_NAMES[@]}"; do
		printf "  %-20s %sW (SysWatt)   default burst ratio %s\n" \
			"${PROFILE_NAMES[$i]}" "${PROFILE_WATTS[$i]}" "${PROFILE_RATIOS[$i]}"
	done
}

# profile_index <name>: echo the array index for a case-insensitive profile
# name, or return non-zero if the name is unknown.
profile_index() {
	local want i
	want="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
	for i in "${!PROFILE_NAMES[@]}"; do
		if [[ "$(printf '%s' "${PROFILE_NAMES[$i]}" | tr '[:upper:]' '[:lower:]')" == "$want" ]]; then
			echo "$i"
			return 0
		fi
	done
	return 1
}

# ---- Argument handling -----------------------------------------------------
PROFILE=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		-h|--help) usage; exit 0 ;;
		--list) list_profiles; exit 0 ;;
		--dry-run) DRY_RUN=1; shift ;;
		--burstRatio|--uncoreWatt)
			if [[ $# -lt 2 ]]; then
				echo "Error: $1 requires a value" >&2
				exit 1
			fi
			case "$1" in
				--burstRatio) RATIO="$2" ;;
				--uncoreWatt) UNCORE_W="$2" ;;
			esac
			shift 2 ;;
		--burstRatio=*) RATIO="${1#*=}"; shift ;;
		--uncoreWatt=*) UNCORE_W="${1#*=}"; shift ;;
		-*) echo "Error: unknown option '$1'" >&2; usage >&2; exit 1 ;;
		*)
			if [[ -n "$PROFILE" ]]; then
				echo "Error: unexpected extra argument '$1'" >&2; usage >&2; exit 1
			fi
			PROFILE="$1"; shift ;;
	esac
done

if [[ -z "$PROFILE" ]]; then
	echo "Error: a profile name is required." >&2
	list_profiles >&2
	exit 1
fi

if ! PROFILE_IDX="$(profile_index "$PROFILE")"; then
	echo "Error: unknown profile '$PROFILE'." >&2
	list_profiles >&2
	exit 1
fi
SYS_W="${PROFILE_WATTS[$PROFILE_IDX]}"

# Resolve the burst ratio: an explicit --burstRatio overrides the profile's
# default.
if [[ -z "$RATIO" ]]; then
	RATIO="${PROFILE_RATIOS[$PROFILE_IDX]}"
fi

# Validate the numeric options.
if ! [[ "$RATIO" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
	echo "Error: '--burstRatio' must be a positive number (got '$RATIO')" >&2
	exit 1
fi
if ! [[ "$UNCORE_W" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
	echo "Error: '--uncoreWatt' must be a non-negative number (got '$UNCORE_W')" >&2
	exit 1
fi

if [[ ! -x "$SET_PLATFORM_POWER" ]]; then
	echo "Error: required helper not found or not executable: $SET_PLATFORM_POWER" >&2
	exit 1
fi

# ---- Root handling ---------------------------------------------------------
# MSR probing and programming need root. A dry run stays read-only and does not
# require elevation.
if [[ "$DRY_RUN" -eq 0 && $EUID -ne 0 ]]; then
	echo "This script needs root; re-running with sudo..." >&2
	exec sudo -E "$0" "$PROFILE" --burstRatio "$RATIO" --uncoreWatt "$UNCORE_W"
fi

# ---- Probe MSR availability ------------------------------------------------
HAVE_MSR=0
if command -v rdmsr >/dev/null 2>&1; then
	modprobe msr 2>/dev/null || true
	if rdmsr -0 0x606 >/dev/null 2>&1; then
		HAVE_MSR=1
	fi
fi

# ---- Detect psys (SysWatt) support -----------------------------------------
# The platform is considered to support SysWatt when the kernel RAPL driver has
# registered a "psys" powercap domain, or when the MSR_PLATFORM_POWER_LIMIT
# register (0x65C) is present and populated (non-zero). Either indicates that a
# platform-level power limit can be programmed.
psys_supported() {
	local d v
	for d in /sys/class/powercap/intel-rapl:* ; do
		[[ -r "$d/name" ]] || continue
		if [[ "$(cat "$d/name" 2>/dev/null)" == "psys" ]]; then
			return 0
		fi
	done
	if [[ "$HAVE_MSR" -eq 1 ]]; then
		if v=$(rdmsr -0 0x65C 2>/dev/null); then
			# A genuine platform power-limit register is populated with firmware
			# defaults; an all-zero read means psys is not implemented here.
			[[ "$(( 0x$v ))" -ne 0 ]] && return 0
		fi
	fi
	return 1
}

SYS_SUPPORTED=0
SYS_METHOD="unsupported"
if psys_supported; then
	SYS_SUPPORTED=1
	SYS_METHOD="psys RAPL domain / MSR 0x65C"
elif [[ "$HAVE_MSR" -eq 0 ]]; then
	SYS_METHOD="undetermined (msr-tools/msr module unavailable)"
fi

# ---- Derive the PkgWatt estimate from the SysWatt budget -------------------
# PkgWatt = SysWatt - uncoreWatt. The package limit is what set_platform_power.sh
# can always enforce (via MSR 0x610), so it is estimated here and passed in both
# the supported and unsupported cases; when psys is supported the SysWatt cap is
# added on top so the whole-platform budget is bounded too.
PKG_W=$(awk -v s="$SYS_W" -v u="$UNCORE_W" 'BEGIN{ v=s-u; if(v<1)v=1; printf "%g", v }')

echo "Profile          : $PROFILE"
echo "SysWatt target   : ${SYS_W}W"
echo "Uncore estimate  : ${UNCORE_W}W  ->  PkgWatt estimate ${PKG_W}W"
echo "Burst ratio      : ${RATIO}"
if [[ "$SYS_SUPPORTED" -eq 1 ]]; then
	echo "SysWatt support  : yes ($SYS_METHOD)"
else
	echo "SysWatt support  : no ($SYS_METHOD)"
	echo "                   -> capping PkgWatt at ${PKG_W}W (SysWatt = ${SYS_W}W - uncore ${UNCORE_W}W)"
fi

# ---- Build the set_platform_power.sh argument list -------------------------
ARGS=(--pkgWatt "$PKG_W" --burstRatio "$RATIO")
if [[ "$SYS_SUPPORTED" -eq 1 ]]; then
	ARGS+=(--sysWatt "$SYS_W")
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
	echo
	echo "Dry run - would execute:"
	echo "  $SET_PLATFORM_POWER ${ARGS[*]}"
	echo "(no changes applied)"
	exit 0
fi

echo
echo "Applying profile via: $SET_PLATFORM_POWER ${ARGS[*]}"
echo
exec "$SET_PLATFORM_POWER" "${ARGS[@]}"
