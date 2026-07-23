# Plan: Remove Docker Build Method from PR #81

## Context

Commit `bad7d3c1ce42f0853501fc1601e9af6237749d8f` ("Optimization changes for build and final base image #81")
introduced:

1. **Docker-based build method** — Dockerfiles, build-in-docker wrappers, Docker-dependent Makefile
2. **Package list optimization** — trimmed bloated package list in `curate-host-packages.sh`
   (old: single mega `apt install` with ~200+ packages including full QEMU, libvirt, dev headers;
   new: categorized, minimal set without dev libraries, QEMU/libvirt/SPICE, unused GStreamer plugins)
3. **Non-Docker script improvements** — `set -euo pipefail`, proxy handling, audio firmware, chrony/ssh services, etc.

This branch removes (1) while preserving (2) and (3).

---

## Known Regressions from PR #81 (addressed in this plan)

| Regression | PR/Ticket | Root Cause | Resolution in this branch |
|-----------|-----------|------------|---------------------------|
| Hotfix kernel could not be cherry-picked | PR #124 | Fixed kernel already available (6.18-260713T060441Z++) | Already resolved on main; not re-introduced |
| Developer directory not posted to target host | PR #125 | `tar -I pigz` used in `install-os.sh` but `pigz` not available on Alpine micro-OS | Already rolled back on main (uses `tar -xzf`) |
| ICT build broken with Docker-based build | PR #110 | Docker container needed bind-mount logic for ICT image path | Reverted to direct path access (no container indirection) |
| CDI generator not built | PR #122 | Docker-based CDI build (`build-in-docker.sh`) needed `CGO_ENABLED=0` | Reverted to Go-based host build; the `CGO_ENABLED=0` fix is kept in `build-gpu-generator.sh` |
| Swap partition missing | ITEP-94767 | `custom-image-setup.sh` creates only EFI+root (no swap); old ISO approach and ICT both include swap | Fixed: swap partition added to `custom-image-setup.sh` |
| Dockerfile vulnerabilities need attention | — | Docker images pull ubuntu:24.04 base with unpatched CVEs | Eliminated: no Dockerfiles remain |

---

## Commit Plan

### Commit 1: Remove Docker infrastructure files
Delete all Dockerfiles and Docker wrapper scripts.

Files removed:
- `infrastructure/host-os/Dockerfile`
- `infrastructure/enib-base-container/` (entire directory)
- `infrastructure/build-artifacts/Dockerfile`
- `infrastructure/micro-os/Dockerfile`
- `infrastructure/micro-os/build-in-docker.sh`
- `infrastructure/installation-scripts/cdi/Dockerfile`
- `infrastructure/installation-scripts/cdi/build-in-docker.sh`

**Why:** These serve only the Docker build path and introduce vulnerability surface.
The underlying scripts remain intact.

### Commit 2: Rewrite Makefile — remove Docker orchestration, restore direct execution
- Remove `check-docker`, `build-base`, Docker image variables
- Restore `build-cdi-generator` target (Go-based, host execution)
- `build` target calls `build-installation-artifacts.sh` directly with sudo
- `clean` target uses direct `rm -rf` (no Docker container for cleanup)
- Keep improved `check-proxy` (|| true fixes, read -p, printf)

**Why:** Build must work on host without Docker. Fixes ICT regression (PR #110)
by removing container indirection for paths.

### Commit 3: Adapt build-installation-artifacts.sh for host execution
- Call `build-alpine-os.sh` directly (not `build-in-docker.sh`)
- CDI build uses `build-gpu-generator.sh` (Go on host, not Docker)
- Remove `container-file-permissions()` (Docker UID mapping)
- Remove Docker-specific error messages
- Keep: `set -euo pipefail`, `pigz` compression, simplified partition check

**Why:** Fixes CDI regression (PR #122) — Go-based build works directly.
Fixes ICT regression (PR #110) — `use-ict-image()` reads path directly.

### Commit 4: Rewrite custom-image-setup.sh — debootstrap/chroot instead of Docker
- Replace Docker build+export with `debootstrap` + `chroot` to populate rootfs
- Add swap partition (fixes ITEP-94767): GPT layout becomes EFI + swap + root
- Continue using `curate-host-packages.sh` for package installation inside chroot
- Keep all post-rootfs steps (fstab, GRUB, hostname, initramfs, compression)

**Why:** Core requirement (remove Docker method) + fixes swap regression.

### Commit 5: Adapt build-alpine-os.sh — remove Docker-only helpers
- Remove `fix_output_permissions()` (Docker UID mapping not needed)
- Keep: proxy pass-through, SCRIPT_DIR paths, CDI verification, pigz compression

**Why:** Minor cleanup; script already works on host when called directly.

### Commit 6: Update documentation — reflect non-Docker prerequisites
- Remove Docker setup prerequisites from README.md and system-requirements.md
- Restore Go toolchain requirement (needed for CDI binary compilation)
- Update build instructions (no `check-docker`, direct execution)
- Keep: troubleshooting additions, boot-override tip
- Update `skills/update-install-packages/SKILL.md`

**Why:** Docs must match actual build flow.

---

## What is KEPT (package optimization + non-Docker improvements)

### Package List Optimization (from PR #81 diff L68)

**Removed from old list (justified):**
- QEMU system emulators (`qemu-system-*`, `qemu-user*`, `ovmf*`) — not needed on edge node
- Full libvirt stack (`libvirt-*`, `libnss-libvirt`, `virt-viewer`, `spice-client-gtk`) — removed
- Unused dev libraries (`libgstreamer*-dev`, `libigfxcmrt-dev`, `libigdgmm-dev`, `libvpl-dev`, etc.)
- Heavy desktop apps (`terminator`, `gnuplot`, `python3-pandas`, `python3-seaborn`)
- Legacy/duplicate packages (`bmap-tools`, `adb`, `autoconf`, `automake`, `libtool`)
- Unused tools (`wmctrl`, `xdotool`, `lbzip2`, `default-jre`, `powertop`, `iperf3`, `gdbserver`)
- TPM tools (`tpm2-tools`, `tpm2-abrmd`, `swtpm*`) — separate provisioning handles these
- GStreamer extras (`gstreamer1.0-alsa`, `1.0-gl`, `1.0-gtk3`, `1.0-opencv`, `1.0-ugly`, `1.0-qt5`, etc.)

**Added (justified):**
- `chrony` — better NTP for edge (replaces systemd-timesyncd)
- `rsync`, `vim`, `less`, `file`, `tcpdump`, `iputils-ping` — operational essentials
- `firmware-sof-signed`, `wireless-regdb` — hardware support
- `dosfstools`, `gdisk`, `pigz` — build and provisioning tools
- `intel-lpmd`, `thermald` — power/thermal management (PR #107)
- `efivar`, `efibootmgr` — EFI boot management
- `bluez` — Bluetooth support
- `stress-ng`, `pcm`, `lms`, `metee` — Intel platform tools

### Non-Docker Script Improvements Preserved
- `curate-host-packages.sh`: categorized installs, audio_fw_update(), chrony/ssh services
- `build-alpine-os.sh`: proxy pass-through, SCRIPT_DIR, CDI verification
- `build-installation-artifacts.sh`: set -euo pipefail, pigz, simplified flow
- `bootable-usb-prepare.sh`: SSH key validation, removed Python bloat
- `install-os.sh`: removed lvm_size, docker group setup, pigz rollback (PR #125)
- `cloud-init.yaml`: NTP removal (chrony migration)
- `config-file`: LVM field removal

---

## Files DELETED by this branch

```
infrastructure/host-os/Dockerfile
infrastructure/enib-base-container/Dockerfile
infrastructure/build-artifacts/Dockerfile
infrastructure/micro-os/Dockerfile
infrastructure/micro-os/build-in-docker.sh
infrastructure/installation-scripts/cdi/Dockerfile
infrastructure/installation-scripts/cdi/build-in-docker.sh
```

## Open Items (not in scope of this branch)

- `prepare-host-img.sh` is NOT restored — old QEMU+ISO approach is obsolete.
  New `custom-image-setup.sh` uses debootstrap which is simpler and more reliable.
- Kernel pinning strategy remains as-is (6.18 mainline per PR #124 revert).
