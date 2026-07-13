---
# SPDX-FileCopyrightText: (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
name: set-power-profile
description: Pick a ready-made power profile for your Intel Core Ultra system — from LowPower (10 W) for the longest battery and quietest, coolest operation, up to MaxPerformance (45 W) for the most speed. Choose LowPower, BalancedLow (15 W), BalancedHigh (20 W), Performance (25 W), or MaxPerformance, and the system is tuned to that power level. Runs locally with tools/power-tuning/set_power_profile.sh.
---


## Terminology
Acronyms and terms used throughout this skill.

| Term | Meaning |
|---|---|
| PkgWatt | "Package" power — the power used by the CPU package (the processor cores plus the built-in graphics). This is the main thing the skill limits. |
| SysWatt | "System / platform" power — the power of the whole platform (CPU package plus memory, voltage regulators, and other board rails). |
| PL1 | Power Limit 1 — the **sustained** power the chip is allowed to draw over the long term. Set by `pkg_watt`. |
| PL2 | Power Limit 2 — the **short burst** power the chip may briefly exceed PL1 to reach, for snappier response. Set by `burst_ratio`. |
| burst_ratio | How much higher the burst (PL2) is than the sustained limit (PL1): `PL2 = pkg_watt × burst_ratio`. `1.0` means no burst; `1.25` allows 25% higher bursts. |
| tau (PL1 tau) | The time window (in seconds) over which the sustained PL1 limit is averaged — how long a burst can last before the chip settles back to PL1. |
| TDP | Thermal Design Power — the processor's rated sustained power (its "normal" power level). |
| Nominal TDP | The processor's default rated sustained power, used as the fallback when no target is given. |
| cTDP | Configurable TDP — power levels the processor can be tuned to. **cTDP Level 2** is the chip's highest allowed sustained power (the maximum you can request). |
| uncore | The parts of the platform outside the CPU cores (memory controller, graphics fabric, I/O) whose power is included in SysWatt but not fully in PkgWatt. |
| RAPL | Running Average Power Limit — the Intel hardware feature this skill uses to read and enforce power limits. |
| MSR | Model-Specific Register — low-level CPU registers the script reads/writes to apply the limits (needs the `msr` kernel module and `msr-tools`). |
| psys | The platform (SysWatt) power domain exposed by RAPL. Some chips don't populate it, so its reading can show `0.00`. |
| EPP / EPB | Energy Performance Preference / Bias — hints that steer the CPU toward performance or power saving; the script sets these to match the chosen wattage. |
| HWP | Hardware P-States (Intel Speed Shift) — the feature that lets the OS request CPU performance levels; EPP/EPB are delivered through it. |
| Autonomous HWP | HWP "native" mode where the OS/lpmd programs HWP requests directly (rather than firmware). |
| HFI / ITD | Hardware Feedback Interface / Intel Thread Director — tells the OS which cores are most efficient right now, guiding low-power transitions. |
| DTT / DPTF | Dynamic Tuning Technology / Dynamic Platform and Thermal Framework — Intel's thermal/power framework that exposes the workload-hint interface. |
| SST / ISST | (Intel) Speed Select Technology — platform control of per-core performance / EPP classes on newer platforms. |
| EIST | Enhanced Intel SpeedStep — the classic feature that scales CPU frequency/voltage with load; a companion to Speed Shift. |
| WLT | Workload Type hint — a signal about the current workload used to bias power vs. performance. |
| SMT | Simultaneous Multi-Threading (Hyper-Threading) — two logical CPUs per physical core; lpmd selects efficient CPUs including SMT siblings. |
| C-states | CPU idle power states — deeper states (e.g. C1E, package C-states) save more power when idle. |
| DBPM | Demand-Based Power Management — firmware-driven frequency control; must be OFF so the OS/lpmd stays in charge. |
| OOB / PECI | Out-of-Band management / Platform Environment Control Interface — a side channel that can control P-states outside the OS; must be OFF. |
| intel_lpmd | The Intel Low Power Mode daemon the script configures and restarts to apply the CPU tuning. |
| ITMT | Intel Turbo Boost Max — a feature that favors the fastest cores; the script enables or disables it based on the target power. |
| NPU / VPU | Neural / Vision Processing Unit — the on-chip AI accelerator; capped too when it exposes a power domain. |
| dry_run | Preview mode: show the planned changes without applying anything. |


## BIOS Settings (Mandatory)
These platform firmware (BIOS) settings are **required** for the power tuning
in this skill to work. The Intel Low Power Mode daemon (`intel_lpmd`) needs the
OS to own the CPU's power/frequency controls; the settings below hand that
control to the OS. Verify them **before** running the skill — if they are wrong,
the script may run without error yet the limits or EPP/EPB tuning will not take
effect.

### Required — must be ENABLED

| BIOS setting (common names) | Setting | Reason |
|---|---|---|
| Intel Hardware Feedback Interface (HFI) / Intel Thread Director (ITD) | Enable | Provides HFI LPM/SUV hints that drive lpmd's opportunistic low-power transitions |
| Intel Speed Shift Technology / HWP (Hardware P-States) | Enable | lpmd sets EPP/EPB via HWP during LP enter/exit |
| Intel Dynamic Tuning Technology (DTT) / DPTF | Enable | Exposes the workload_hint interface (PCI 00:04.0) used for WLT hints |
| Intel SST / ISST (Speed Select) support | Enable | Backing for workload-hint / EPP class control on newer platforms |
| Intel Turbo Boost Technology | Enable | Normal operating range so lpmd's EPP/frequency management is meaningful |
| Intel Turbo Boost Max 3.0 / ITMT (favored cores) | Enable | lpmd toggles the scheduler ITMT flag on transitions (or set IgnoreITMT if unavailable) |
| Hyper-Threading / SMT | Enable | lpmd selects efficient CPUs including SMT siblings from topology |
| Above 4G / normal C-states (C1E, package C-states) | Enable | Idle power savings that lpmd's low-power mode relies on |

### Required — must be DISABLED

| BIOS setting (common names) | Setting | Reason |
|---|---|---|
| HWP Lock / Lock HWP configuration | Disable | A locked HWP prevents lpmd/OS from writing HWP_REQUEST (EPP/limits) |
| Legacy / firmware-controlled power management ("BIOS/Firmware DBPM") | Disable | Firmware would override lpmd's decisions |
| Fixed / High-Performance power profile forcing max frequency | Disable | Prevents entering low-power mode |
| CPU frequency / EPP overrides fixed in firmware | Disable | Would conflict with lpmd EPP management |
| Out-of-Band (OOB) / PECI-based P-state control | Disable | OOB agent would take HWP control away from the OS |

## BIOS Settings (Optional)
Not strictly required, but **recommended** — these improve idle power savings
and make sure the OS/`intel_lpmd` (not firmware) drives frequency and EPP.

### Recommended — ENABLED

| BIOS setting (common names) | Setting | Reason |
|---|---|---|
| Enhanced Intel SpeedStep (EIST) | Enable | Prerequisite/companion to Speed Shift on many BIOSes |
| CPU C-States / Enhanced C-States | Enable | Deeper idle states improve active-idle power |
| Power/Performance policy or OS DBPM ("OS controls") | OS / Enable | Hands frequency/EPP control to the OS + lpmd, not firmware |
| Autonomous HWP (native mode) | Enable | Lets OS/lpmd program HWP requests directly |



## How to Use This in Your Workloads
Pick the profile whose SysWatt budget matches what your workload needs — trading
battery life, heat, and fan noise against sustained speed. Each profile ships a
sensible default burst ratio; override it only if you need more or less burst
headroom.

- **Profile (SysWatt budget)** — from `LowPower` (10 W) for the coolest, quietest,
  longest-battery operation up to `MaxPerformance` (45 W) for the most speed.
- **burst_ratio (short bursts)** — extra headroom for brief spikes so the system
  stays responsive without raising the sustained budget.

### Pick a profile for your workload

| Your workload | Goal | Suggested profile |
|---|---|---|
| Battery / fanless, mostly idle (kiosk, digital signage, edge sensor) | Longest battery, coolest, silent | `LowPower` (10 W) |
| Light interactive (basic UI, web browsing) | Efficient but responsive | `BalancedLow` (15 W) |
| Interactive / mixed (UI apps, light editing) | Balanced | `BalancedHigh` (20 W) |
| Steady general compute | Good throughput | `Performance` (25 W) |
| Sustained heavy compute (AI inference, video transcode, builds) | Max sustained throughput | `MaxPerformance` (45 W) |
| Thermally constrained enclosure (sealed / fanless) | Avoid throttling & heat | Highest profile the chassis can cool continuously; watch package temp with `turbostat` |

### Example commands

```bash
# List the available profiles and their SysWatt budgets
tools/power-tuning/set_power_profile.sh --list

# Longest battery / coolest, silent operation
sudo tools/power-tuning/set_power_profile.sh LowPower

# Balanced interactive use
sudo tools/power-tuning/set_power_profile.sh BalancedHigh

# Max sustained throughput (AI inference / transcode / builds)
sudo tools/power-tuning/set_power_profile.sh MaxPerformance

# Override the default burst ratio for a snappier feel
sudo tools/power-tuning/set_power_profile.sh Performance --burstRatio 1.4

# Tune the uncore estimate (used when the silicon has no psys/SysWatt domain)
sudo tools/power-tuning/set_power_profile.sh BalancedHigh --uncoreWatt 6

# Preview only — see the plan without changing anything
tools/power-tuning/set_power_profile.sh Performance --dry-run
```

### Tips for choosing a profile
- **Start with the profile** whose SysWatt budget fits your power/thermal
  envelope, then step up one profile at a time until throughput stops improving.
- Each profile's **default burst ratio** is tuned for its budget; override with
  `--burstRatio` only if you need more responsiveness (higher) or a flatter, more
  predictable power/temperature (closer to `1.0`).
- On silicon **without a psys (SysWatt) domain**, the profile is enforced as a
  PkgWatt cap of `SysWatt − uncore_watt`; adjust `--uncoreWatt` to match your
  platform's non-package draw.
- **Measure** while tuning: run `turbostat` (or the `monitor-platform-power`
  skill) under your real workload to see PkgWatt/SysWatt and package temperature.
- Changes are **runtime-only** and reset on reboot, so it is safe to experiment.
  Re-run a lower profile (or reboot) to go back.
- For fine-grained control of exact PkgWatt/SysWatt values (instead of named
  profiles), use the `set-platform-power` skill.



## Side Effects
Every profile is a trade-off. Use this to understand what changes — for better
and worse — when you pick one, so there are no surprises in production.

### By choice

| Choice | Positive effect | Possible side effect / cost |
|---|---|---|
| **Lower profile** (`LowPower` / `BalancedLow`) | Cooler, quieter/fanless, longer battery, lower energy cost | Lower sustained throughput; heavy jobs run slower or take longer |
| **Higher profile** (`Performance` / `MaxPerformance`) | More sustained performance | More heat and fan noise, higher power draw; can hit thermal throttling in small enclosures |
| **Higher `burst_ratio`** override | Snappier response to short spikes; good for interactive/latency-sensitive apps | Brief power/thermal/current spikes; on weak power delivery or cooling the burst is cut short (effective ratio drops) |
| **`burst_ratio` = 1.0** override | Flat, predictable power and temperature; easier thermal/PSU budgeting | Less responsive to sudden load; peak performance is capped at the sustained level |
| **Larger `uncore_watt`** estimate | More conservative PkgWatt when psys is unsupported | May under-power the package; throughput lower than the profile implies |
| **Smaller `uncore_watt`** estimate | Package gets closer to the full SysWatt budget | On psys-less silicon may exceed the intended platform budget |

### General side effects to expect
- **Thermals & acoustics:** higher profiles raise package temperature and fan
  speed/noise; lower profiles run cooler and quieter (or fanless).
- **Throttling:** if cooling can't keep up, the firmware clamps sustained power
  below the profile's target — you'll see the "firmware clamped PL1" note and the
  effective (enforced) value in the report.
- **Battery & energy:** higher profiles shorten battery runtime and increase
  energy consumption; lower profiles extend both.
- **Perceived responsiveness vs. throughput:** burst headroom helps *feel* fast;
  the profile's SysWatt budget drives *long-running* throughput.
- **Brief management gap:** applying a profile restarts `intel_lpmd.service`
  (~2 s) during which the daemon isn't actively managing CPU states.
- **SysWatt reads 0.00:** on some Core Ultra silicon the psys counter is frozen;
  the cap is still written but not observable via turbostat — use PkgWatt as the
  effective figure. This is a firmware limitation, not a failure.
- **Not persistent:** all effects are runtime-only and revert on reboot — a
  built-in safety net if a profile turns out too aggressive.




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
- burst_ratio: burst ratio (`>= 1.0`, optional). When omitted, the profile's default is used (LowPower `1.25`, BalancedLow `1.25`, BalancedHigh `1.18`, Performance `1.19`, MaxPerformance `1.18`). Overrides the profile default when supplied.
- uncore_watt: estimated uncore/rest-of-platform power in watts (optional, default `5`). Used to derive `PkgWatt = SysWatt - uncore_watt` when the silicon does not support a psys (SysWatt) power domain.
- dry_run: `true` | `false` (default: `false`). When `true`, only the resolved plan is shown; nothing is applied.
- auto_confirm: `true` | `false` (default: `false`). When `true`, skip the confirmation gate.

## Profile Table

| Profile | SysWatt | Default burst ratio |
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
