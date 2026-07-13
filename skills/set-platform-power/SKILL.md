---
# SPDX-FileCopyrightText: (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
name: set-platform-power
description: Set how much power your Intel Core Ultra system is allowed to use. Pick a sustained wattage (in steps of 5 W, up to the chip's maximum), optionally allow short bursts above it, and optionally cap the whole platform's power. Runs locally with tools/power-tuning/set_power_profile.sh.
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
| RAPL | Running Average Power Limit — the Intel hardware feature this skill uses to read and enforce power limits. |
| MSR | Model-Specific Register — low-level CPU registers the script reads/writes to apply the limits (needs the `msr` kernel module and `msr-tools`). |
| psys | The platform (SysWatt) power domain exposed by RAPL. Some chips don't populate it, so its reading can show `0.00`. |
| intel_lpmd | The Intel Low Power Mode daemon the script configures and restarts to apply the CPU tuning. |
| dry_run | Preview mode: show the planned changes without applying anything. |

## BIOS Settings
> **Note:** For the platform firmware (BIOS) settings required and recommended
> for this power tuning to take effect (HWP/Speed Shift, HFI/ITD, Turbo Boost,
> C-states, and settings that must be disabled such as HWP Lock and firmware
> DBPM), see the **BIOS Settings (Mandatory)** and **BIOS Settings (Optional)**
> sections in [`skills/set-power-profile/SKILL.md`](../set-power-profile/SKILL.md).
> The same requirements apply to this skill because both drive the same
> `intel_lpmd` / RAPL controls.

## Trigger Phrases
- set platform power
- set package power limit
- set pkgwatt / set syswatt
- cap cpu package power
- set PL1 and PL2
- set platform power to N watts
- change power envelope
- tune tdp / set tdp
- set power to <N>W with burst ratio <R>

## Required Inputs
- enib_home: absolute path to this repository root (default: current workspace root)
- pkg_watt: PkgWatt (PL1 sustained) target in watts. Must be a **multiple of 5**, from `5` up to the platform's cTDP Level 2 maximum (read from the CPU at runtime). Required.
- burst_ratio: burst ratio (`>= 1.0`, default `1.25`). PL2 = pkg_watt * burst_ratio, clamped to cTDP Level 2.
- sys_watt: SysWatt (psys/platform) PL1 cap in watts (optional). When supplied, must be a **multiple of 5** in `[5, cTDP Level 2]`. Defaults to `pkg_watt` when omitted.
- pl1_tau: PL1 time window (tau) in seconds (optional, default `28`).
- dry_run: `true` | `false` (default: `false`). When `true`, only the resolved plan is shown; the script is not run.
- auto_confirm: `true` | `false` (default: `false`). When `true`, skip the confirmation gate.

## Examples
Concrete invocations of the underlying script (the skill builds these for you
after the confirmation gate):

```bash
# Sustained 20 W with the default 1.25 burst ratio (PL2 = 25 W)
sudo tools/power-tuning/set_power_profile.sh --pkgWatt 20

# Strict cap — no burst (PL1 = PL2 = 30 W)
sudo tools/power-tuning/set_power_profile.sh --pkgWatt 30 --burstRatio 1.0

# Independent platform cap: PkgWatt 25 W, SysWatt 35 W
sudo tools/power-tuning/set_power_profile.sh --pkgWatt 25 --sysWatt 35

# Custom PL1 time window (tau) of 10 s
sudo tools/power-tuning/set_power_profile.sh --pkgWatt 15 --pl1Tau 10
```

For a preview without applying anything, run the skill with `dry_run=true` — it
renders the Planned Changes summary and does **not** invoke the script.

## Preconditions
Run silently without user prompts:
- [ ] Skill file exists and is readable:
  - `test -f <enib_home>/skills/set-platform-power/SKILL.md`
- [ ] The power script exists and is executable:
  - `test -x <enib_home>/tools/power-tuning/set_power_profile.sh`
- [ ] Host is x86_64 with an Intel CPU (sanity check; non-fatal warning if not):
  - `uname -m` and `grep -m1 -o 'GenuineIntel' /proc/cpuinfo`
- [ ] `msr-tools` and the `msr` module are available (needed to read cTDP levels and program RAPL MSRs):
  - `command -v rdmsr && command -v wrmsr`
  - if missing, warn that the script will fall back to Panther Lake defaults (Nominal 25 W / Level 2 65 W) and the cTDP maximum may be inaccurate.
- [ ] **Probe sudo before any privileged step** (the script re-runs itself with `sudo`):
  - Run `sudo -n true` and capture the exit code.
  - Exit `0` → proceed.
  - Non-zero → do NOT run the script. Tell the user to run `sudo -v` in their own terminal (or add a scoped NOPASSWD entry for the absolute path `<enib_home>/tools/power-tuning/set_power_profile.sh`), then re-trigger the skill. Never collect a password via prompts, env vars, scripts, or logs.
- [ ] Determine the cTDP Level 2 maximum (upper bound for `pkg_watt` / `sys_watt`):
  - If `sudo -n true` succeeded and `rdmsr` exists:
    - `sudo modprobe msr 2>/dev/null || true`
    - power unit exponent: `PU=$(( $(sudo rdmsr -0 0x606) & 0xF ))`
    - `CTDP_MAX=$(awk -v r=$(( $(sudo rdmsr -0 0x64A) & 0x7FFF )) -v b="$PU" 'BEGIN{printf "%d", r/(2^b)+0.5}')`
  - If the MSR is unreadable, set `CTDP_MAX=65` (documented fallback) and note it is an assumption.

Prompt only for missing required inputs:
- [ ] Ask for `pkg_watt` if not provided. Present the valid set: multiples of 5 in `[5, CTDP_MAX]`.
- [ ] Do not prompt for `burst_ratio`, `sys_watt`, or `pl1_tau`; use defaults unless the user supplied them.

Input validation (fail closed before running the script):
- [ ] `pkg_watt` is an integer, a multiple of 5, and `5 <= pkg_watt <= CTDP_MAX`. Otherwise stop and report the valid range/step. Do not silently round.
- [ ] If `sys_watt` is supplied: integer, multiple of 5, `5 <= sys_watt <= CTDP_MAX`.
- [ ] `burst_ratio` is a number `>= 1.0`.
- [ ] `pl1_tau` (if supplied) is a positive number of seconds.

## Steps
1. Compute the resolved plan (no writes yet):
   - `PL1 = pkg_watt`
   - `PL2 = min(pkg_watt * burst_ratio, CTDP_MAX)`
   - `SYS_PL1 = sys_watt or pkg_watt`; `SYS_PL2 = min(SYS_PL1 * burst_ratio, CTDP_MAX)`
   - Note whether PL2 was clamped by the cTDP Level 2 ceiling (effective ratio may be < requested).
2. Capture a pre-change RAPL snapshot for the report (read-only):
   - `for d in /sys/class/powercap/intel-rapl:*; do n=$(cat "$d/name" 2>/dev/null); echo "$n PL1=$(cat "$d/constraint_0_power_limit_uw" 2>/dev/null) PL2=$(cat "$d/constraint_1_power_limit_uw" 2>/dev/null) enabled=$(cat "$d/enabled" 2>/dev/null)"; done`
3. **Render the Planned Changes summary** to the user (PkgWatt PL1/PL2, SysWatt PL1/PL2, tau, effective ratio, cTDP max).
4. **Confirmation gate** — pause before any write:
   - If `dry_run=true`: report "dry-run only — no changes applied" and stop. Do not proceed.
   - Else if `auto_confirm=true`: log `AUTO_CONFIRM=true` and continue.
   - Else: ask "Apply PkgWatt PL1=<PL1>W/PL2=<PL2>W (ratio <R>) on this host? (yes/no)". On anything other than `yes`/`y` (case-insensitive), stop and record `CONFIRMATION=declined`.
5. Apply (only after confirmation). Build the argument list from the inputs:
   - Base: `sudo <enib_home>/tools/power-tuning/set_power_profile.sh --pkgWatt <pkg_watt> --burstRatio <burst_ratio>`
   - Append `--sysWatt <sys_watt>` only when `sys_watt` was supplied.
   - Append `--pl1Tau <pl1_tau>` (default `28`).
   - Capture stdout/stderr verbatim and record the exit code.
6. Capture a post-change RAPL snapshot using the same read command as Step 2.

## Validation
Validation section is criteria-only. Do not render the pass/fail results table here.
- Preconditions passed (script executable; sudo probe = 0 when a write is intended).
- `pkg_watt` (and `sys_watt` if given) validated as multiples of 5 within `[5, CTDP_MAX]`.
- Planned Changes summary was rendered before any write.
- Confirmation gate outcome recorded as one of: `confirmed`, `auto_confirm`, `declined`, `dry_run_only`.
- Apply phase only executed when the outcome is `confirmed` or `auto_confirm`.
- When applied, the script exited with code `0`.
- Post-change package RAPL PL1/PL2 reflect the request (allowing for firmware/cTDP clamping):
  - `constraint_0_power_limit_uw` ≈ `pkg_watt * 1e6` (or the firmware-enforced ceiling, which the script reports and advises raising via BIOS Config-TDP Level 2).
  - `constraint_1_power_limit_uw` ≈ `PL2 * 1e6`.
- Note: on platforms where the psys counter is frozen/unavailable, the SysWatt cap is written to the register but turbostat will still read `SysWatt=0.00`; this is a firmware limitation, not a failure.

## Rollback
- Changes are runtime-only and do NOT persist across reboot; rebooting restores firmware defaults.
- To revert immediately, re-run the skill with the default `pkg_watt` equal to the platform Nominal TDP (reported in the script output as `Config-TDP levels: Nominal=…`) and `burst_ratio 1.25`.
- The script keeps a one-time `.orig` backup of any model-specific intel_lpmd config it overrides (e.g. `intel_lpmd_config_F6_M204.xml.orig`); restore it and restart `intel_lpmd.service` to return the daemon config to stock.

## Safety Rules
- Never collect a sudo password via prompts, env vars, scripts, or logs. Only `sudo -v` (by the user) or a scoped NOPASSWD entry for the script's absolute path.
- Do not exceed the cTDP Level 2 maximum; the skill fails closed rather than letting the user request an unsupported wattage.
- Warn before applying a high `pkg_watt`/`burst_ratio` on thermally constrained (e.g. fanless) enclosures; report package temperature via `turbostat` when available.
- The skill restarts `intel_lpmd.service` (via the script) to load the new profile; note the brief (~2 s) management gap to the user.
- Do not modify anything outside `tools/power-tuning/` and the intel_lpmd config directory the script manages.

## Side Effects
> **Note:** For the trade-offs of each power setting (`pkg_watt`, `burst_ratio`,
> `pl1_tau`, `sys_watt`, and raising cTDP) — thermals/acoustics, throttling,
> battery/energy, responsiveness vs. throughput, and the runtime-only behavior —
> see the **Side Effects** section in
> [`skills/set-power-profile/SKILL.md`](../set-power-profile/SKILL.md).
> The same effects apply to this skill because both drive the same `intel_lpmd`
> / RAPL controls.

## Expected Result Summary
Render the report as the following tables.

### Run Metadata

| Field | Value |
|---|---|
| Preconditions | PASS/FAIL |
| Host | `<uname -m>` + CPU model name |
| cTDP Level 2 max | `<CTDP_MAX>W` (msr / fallback) |
| PkgWatt (PL1) | `<pkg_watt>W` |
| Burst ratio | `<burst_ratio>` (effective `<eff_ratio>`) |
| SysWatt (PL1) | `<sys_watt or 'same as PkgWatt'>` |
| PL1 tau | `<pl1_tau>s` |
| Dry run only | `true` / `false` |
| Confirmation | `confirmed` / `auto_confirm` / `declined` / `dry_run_only` |

### Planned Changes

| Domain | PL1 | PL2 | Notes |
|---|---|---|---|
| Package (PkgWatt) | `<PL1>W` | `<PL2>W` | clamped? effective ratio |
| psys (SysWatt) | `<SYS_PL1>W` | `<SYS_PL2>W` | frozen-counter note if applicable |

### RAPL Snapshot (pre → post)

(omit when the outcome is `declined` or `dry_run_only`)

| Domain | PL1 before | PL1 after | PL2 before | PL2 after | enabled |
|---|---|---|---|---|---|
| `package-0` | `<uw>` | `<uw>` | `<uw>` | `<uw>` | `<0/1>` |
| `psys` (if present) | `<uw>` | `<uw>` | `<uw>` | `<uw>` | `<0/1>` |

### Validation Results

| Check Area | Status | Evidence | Notes |
|---|---|---|---|
| script executable | PASS/FAIL | `test -x` result | |
| sudo availability | PASS/FAIL/SKIP | `sudo -n true` exit code | SKIP when `dry_run=true` |
| input range/step | PASS/FAIL | pkg_watt/sys_watt vs `[5, CTDP_MAX]` step 5 | |
| script apply | PASS/FAIL/N/A | exit code | N/A when not applied |
| package PL enforced | PASS/FAIL/N/A | post RAPL uw vs request | note firmware clamp |

### Failures and Troubleshooting

| Failed Check | Raw Evidence | Troubleshooting Note |
|---|---|---|
| `<check area>` | `<snippet>` | `<action>` |

## Troubleshooting Notes
- If `sudo -n true` fails: run `sudo -v` in your own terminal, or add a scoped entry via `sudo visudo -f /etc/sudoers.d/set-platform-power`:
  ```
  <user> ALL=(root) NOPASSWD: /home/<user>/enib/tools/power-tuning/set_power_profile.sh
  ```
  Never use `NOPASSWD: ALL`.
- If the script reports "firmware clamped PL1 to <lower>W": the sustained package limit is bounded by the active cTDP level. Set Config-TDP Level 2 in BIOS to raise the ceiling; the runtime cTDP switch is best-effort and may be locked (`cTDP control locked`).
- If `rdmsr`/`wrmsr` are missing: `sudo apt-get install -y msr-tools` and `sudo modprobe msr`. Without them the script uses Panther Lake defaults and `CTDP_MAX` may be wrong.
- If `SysWatt` still reads `0.00` in turbostat after applying: the platform (psys) RAPL energy counter (MSR 0x65C) is frozen/unpopulated on some Core Ultra platforms (e.g. Core Ultra 5 335 / F6_M204). This is a firmware limitation; use PkgWatt as the effective figure.
- If `intel_lpmd.service` fails to restart ("start-limit-hit"): run `sudo systemctl reset-failed intel_lpmd.service` and re-trigger.
- Changes do not persist across reboot; to persist, wrap the invocation in a systemd unit (out of scope for this skill).

## Related Skills
- **set-power-profile** ([`skills/set-power-profile/SKILL.md`](../set-power-profile/SKILL.md)) — apply a named preset (LowPower … MaxPerformance) by SysWatt budget instead of choosing exact wattages. Use it when you want a ready-made profile; use **this** skill for fine-grained PkgWatt/SysWatt control.
- **monitor-platform-power** — watch PkgWatt/SysWatt and package temperature (turbostat) while validating a change.
- **generate-platform-stress** — apply CPU/iGPU load to exercise the power limit under stress.
