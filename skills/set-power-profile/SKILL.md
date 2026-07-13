---
# SPDX-FileCopyrightText: (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
name: set-power-profile
description: Apply a named platform power profile (LowPower 10 W, BalancedLow 15 W, BalancedHigh 20 W, Performance 25 W, MaxPerformance 45 W) expressed as a SysWatt budget locally on an Intel Core Ultra host using tools/power-tuning/set_power_profile.sh. Each profile has a default PL2/PL1 burst ratio (overridable), and the package (PkgWatt) target is estimated from the SysWatt budget minus an estimated uncore power when the silicon does not support a psys (SysWatt) domain.
---

## Trigger Phrases
- set power profile
- apply power profile
- set profile to LowPower / BalancedLow / BalancedHigh / Performance / MaxPerformance
- switch to <profile> power profile
- set platform profile <N>W
- use the low power / max performance profile
- list power profiles

## Required Inputs
- enib_home: absolute path to this repository root (default: current workspace root).
- profile: one of `LowPower`, `BalancedLow`, `BalancedHigh`, `Performance`, `MaxPerformance` (case-insensitive). Required.
- burst_ratio: PL2/PL1 burst ratio (`>= 1.0`, optional). When omitted, the profile's default is used (LowPower `1.25`, BalancedLow `1.25`, BalancedHigh `1.18`, Performance `1.19`, MaxPerformance `1.18`). Overrides the profile default when supplied.
- uncore_watt: estimated uncore/rest-of-platform power in watts (optional, default `5`). Used to derive `PkgWatt = SysWatt - uncore_watt` when the silicon does not support a psys (SysWatt) power domain.
- dry_run: `true` | `false` (default: `false`). When `true`, only the resolved plan is shown; nothing is applied.
- auto_confirm: `true` | `false` (default: `false`). When `true`, skip the confirmation gate.

## Profile Table

| Profile | SysWatt | Default burstRatio |
|---|---|---|
| LowPower | 10 W | 1.25 |
| BalancedLow | 15 W | 1.25 |
| BalancedHigh | 20 W | 1.18 |
| Performance | 25 W | 1.19 |
| MaxPerformance | 45 W | 1.18 |

## Preconditions
Run silently without user prompts:
- [ ] Skill file exists and is readable:
  - `test -f <enib_home>/skills/set-power-profile/SKILL.md`
- [ ] The profile script exists and is executable:
  - `test -x <enib_home>/tools/power-tuning/set_power_profile.sh`
- [ ] The underlying helper the script drives exists and is executable:
  - `test -x <enib_home>/tools/power-tuning/set_platform_power.sh`
- [ ] Host is x86_64 with an Intel CPU (sanity check; non-fatal warning if not):
  - `uname -m` and `grep -m1 -o 'GenuineIntel' /proc/cpuinfo`
- [ ] `msr-tools` and the `msr` module are available (needed to probe psys support, read cTDP levels, and program RAPL MSRs):
  - `command -v rdmsr && command -v wrmsr`
  - if missing, warn that psys support cannot be probed reliably and the underlying script will fall back to Panther Lake defaults; the PkgWatt estimate path may be used.
- [ ] **Probe sudo before any privileged step** (the script re-runs itself with `sudo` when applying):
  - Run `sudo -n true` and capture the exit code.
  - Exit `0` → proceed.
  - Non-zero → do NOT run the script in apply mode. Tell the user to run `sudo -v` in their own terminal (or add a scoped NOPASSWD entry for the absolute path `<enib_home>/tools/power-tuning/set_power_profile.sh` **and** `<enib_home>/tools/power-tuning/set_platform_power.sh`), then re-trigger the skill. Never collect a password via prompts, env vars, scripts, or logs.
  - `dry_run=true` does not require sudo (it is read-only); SKIP this gate for a dry run.

Prompt only for missing required inputs:
- [ ] Ask for `profile` if not provided. Present the valid set from the Profile Table.
- [ ] Do not prompt for `burst_ratio`, `uncore_watt`, `dry_run`, or `auto_confirm`; use defaults unless the user supplied them.

Input validation (fail closed before running the script):
- [ ] `profile` matches one of the five names (case-insensitive). Otherwise stop and list the valid profiles.
- [ ] `burst_ratio` (if supplied) is a number `>= 1.0`.
- [ ] `uncore_watt` (if supplied) is a non-negative number.

## Steps
1. Resolve the plan (no writes yet):
   - `SysWatt = profile target` (from the Profile Table).
   - `burst_ratio = supplied value or the profile default`.
   - `PkgWatt = SysWatt - uncore_watt` (floored at 1 W).
2. Determine psys (SysWatt) support (read-only best effort):
   - Supported when a powercap domain named `psys` exists under `/sys/class/powercap/intel-rapl:*/name`, or `MSR_PLATFORM_POWER_LIMIT` (0x65C) reads non-zero.
   - When supported, the script enforces both `--sysWatt <SysWatt>` and `--pkgWatt <PkgWatt>`.
   - When not supported, only `--pkgWatt <PkgWatt>` is enforced (the SysWatt budget cannot be capped directly).
3. Capture a pre-change RAPL snapshot for the report (read-only):
   - `for d in /sys/class/powercap/intel-rapl:*; do n=$(cat "$d/name" 2>/dev/null); echo "$n PL1=$(cat "$d/constraint_0_power_limit_uw" 2>/dev/null) PL2=$(cat "$d/constraint_1_power_limit_uw" 2>/dev/null) enabled=$(cat "$d/enabled" 2>/dev/null)"; done`
4. **Render the Planned Changes summary** (profile, SysWatt, resolved burst ratio, uncore estimate, derived PkgWatt, psys-supported yes/no).
5. **Confirmation gate** — pause before any write:
   - If `dry_run=true`: run `set_power_profile.sh <profile> [--burstRatio R] [--uncoreWatt W] --dry-run`, show the resolved plan, and stop. Do not apply.
   - Else if `auto_confirm=true`: log `AUTO_CONFIRM=true` and continue.
   - Else: ask "Apply the <profile> profile (SysWatt <N>W, burstRatio <R>) on this host? (yes/no)". On anything other than `yes`/`y` (case-insensitive), stop and record `CONFIRMATION=declined`.
6. Apply (only after confirmation). Build the argument list from the inputs:
   - Base: `sudo <enib_home>/tools/power-tuning/set_power_profile.sh <profile>`
   - Append `--burstRatio <burst_ratio>` only when the user supplied one (otherwise the script uses the profile default).
   - Append `--uncoreWatt <uncore_watt>` only when the user supplied one.
   - Capture stdout/stderr verbatim and record the exit code.
7. Capture a post-change RAPL snapshot using the same read command as Step 3.

## Validation
Validation section is criteria-only. Do not render the pass/fail results table here.
- Preconditions passed (both scripts executable; sudo probe = 0 when a write is intended).
- `profile` validated against the five names; `burst_ratio`/`uncore_watt` validated when supplied.
- Planned Changes summary rendered before any write.
- Confirmation gate outcome recorded as one of: `confirmed`, `auto_confirm`, `declined`, `dry_run_only`.
- Apply phase only executed when the outcome is `confirmed` or `auto_confirm`.
- When applied, the script exited with code `0`.
- Post-change package RAPL PL1/PL2 reflect the derived PkgWatt (allowing for firmware/cTDP clamping); when psys is supported the psys domain reflects the SysWatt request.
- Note: on platforms where the psys counter is frozen/unavailable, the SysWatt cap is written to the register but turbostat still reads `SysWatt=0.00`; this is a firmware limitation, not a failure.

## Rollback
- Changes are runtime-only and do NOT persist across reboot; rebooting restores firmware defaults.
- To revert immediately, re-run with a lower profile (e.g. `LowPower`) or use the `set-platform-power` skill with the platform Nominal TDP.
- The underlying `set_platform_power.sh` keeps a one-time `.orig` backup of any model-specific intel_lpmd config it overrides; restore it and restart `intel_lpmd.service` to return the daemon config to stock.

## Safety Rules
- Never collect a sudo password via prompts, env vars, scripts, or logs. Only `sudo -v` (by the user) or a scoped NOPASSWD entry for the scripts' absolute paths.
- Warn before applying a high profile (`MaxPerformance`) or a high `burst_ratio` on thermally constrained (e.g. fanless) enclosures; report package temperature via `turbostat` when available.
- The underlying script restarts `intel_lpmd.service` to load the new profile; note the brief (~2 s) management gap to the user.
- Do not modify anything outside `tools/power-tuning/` and the intel_lpmd config directory the underlying script manages.

## Expected Result Summary
Render the report as the following tables.

### Run Metadata

| Field | Value |
|---|---|
| Preconditions | PASS/FAIL |
| Host | `<uname -m>` + CPU model name |
| Profile | `<profile>` |
| SysWatt target | `<N>W` |
| Burst ratio | `<burst_ratio>` (profile default or overridden) |
| Uncore estimate | `<uncore_watt>W` |
| Derived PkgWatt | `<SysWatt - uncore_watt>W` |
| psys (SysWatt) supported | `yes` / `no` |
| Dry run only | `true` / `false` |
| Confirmation | `confirmed` / `auto_confirm` / `declined` / `dry_run_only` |

### Planned Changes

| Domain | Target | Notes |
|---|---|---|
| Package (PkgWatt) | `<PkgWatt>W` | always enforced (MSR 0x610) |
| psys (SysWatt) | `<SysWatt>W` | enforced only when psys is supported |

### RAPL Snapshot (pre → post)

(omit when the outcome is `declined` or `dry_run_only`)

| Domain | PL1 before | PL1 after | PL2 before | PL2 after | enabled |
|---|---|---|---|---|---|
| `package-0` | `<uw>` | `<uw>` | `<uw>` | `<uw>` | `<0/1>` |
| `psys` (if present) | `<uw>` | `<uw>` | `<uw>` | `<uw>` | `<0/1>` |

### Validation Results

| Check Area | Status | Evidence | Notes |
|---|---|---|---|
| scripts executable | PASS/FAIL | `test -x` result | both scripts |
| sudo availability | PASS/FAIL/SKIP | `sudo -n true` exit code | SKIP when `dry_run=true` |
| profile/inputs valid | PASS/FAIL | profile name + numeric options | |
| psys support probe | INFO | `yes` / `no` | selects enforcement path |
| script apply | PASS/FAIL/N/A | exit code | N/A when not applied |
| package PL enforced | PASS/FAIL/N/A | post RAPL uw vs PkgWatt | note firmware clamp |

### Failures and Troubleshooting

| Failed Check | Raw Evidence | Troubleshooting Note |
|---|---|---|
| `<check area>` | `<snippet>` | `<action>` |

## Troubleshooting Notes
- List the available profiles at any time with `<enib_home>/tools/power-tuning/set_power_profile.sh --list`.
- If `sudo -n true` fails: run `sudo -v` in your own terminal, or add a scoped entry via `sudo visudo -f /etc/sudoers.d/set-power-profile`:
  ```
  <user> ALL=(root) NOPASSWD: /home/<user>/enib/tools/power-tuning/set_power_profile.sh
  <user> ALL=(root) NOPASSWD: /home/<user>/enib/tools/power-tuning/set_platform_power.sh
  ```
  Never use `NOPASSWD: ALL`.
- If `rdmsr`/`wrmsr` are missing: `sudo apt-get install -y msr-tools` and `sudo modprobe msr`. Without them psys support cannot be probed and the underlying script uses Panther Lake defaults.
- If psys is reported "not supported": the profile is enforced as a PkgWatt cap of `SysWatt - uncore_watt`. Adjust the estimate with `--uncoreWatt` to better match the platform's non-package draw.
- If `SysWatt` still reads `0.00` in turbostat after applying: the platform (psys) RAPL counter is frozen/unpopulated on some Core Ultra platforms. This is a firmware limitation; use PkgWatt as the effective figure.
- If the underlying script reports "firmware clamped PL1 to <lower>W": set Config-TDP Level 2 in BIOS to raise the ceiling.
- Changes do not persist across reboot; to persist, wrap the invocation in a systemd unit (out of scope for this skill).
