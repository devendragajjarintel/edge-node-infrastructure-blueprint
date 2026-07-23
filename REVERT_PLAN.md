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

### Commit 4: Restore QEMU+ISO host image creation (prepare-host-img.sh)
- Remove `custom-image-setup.sh` (Docker build+export approach from PR #81)
- Restore `prepare-host-img.sh` from before PR #81 (QEMU+ISO+autoinstall)
- Restore `auto-install-pkgs.yaml` (Ubuntu autoinstall cloud-init config)
- Restore ISO_URL parameter in build-installation-artifacts.sh and Makefile
- Restore `MODE=image-from-iso` as default build mode

**Why:** Restores the original, proven image creation method that was in the repo.
The QEMU approach boots the real Ubuntu installer, ensuring the resulting image
is identical to what a user would get from a manual install + package additions.
Swap partition handling is managed by the provisioning scripts (os-partition.sh)
at install time on the target, not at image build time.

### Commit 5: Adapt build-alpine-os.sh — remove Docker-only helpers
- Remove `fix_output_permissions()` (Docker UID mapping not needed)
- Keep: proxy pass-through, SCRIPT_DIR paths, CDI verification, pigz compression

**Why:** Minor cleanup; script already works on host when called directly.

### Commit 6: Update documentation — restore original prerequisites
- Remove Docker setup prerequisites from README.md and system-requirements.md
- Restore Go toolchain requirement (needed for CDI binary compilation)
- Restore BIOS/VT-x requirement (QEMU uses KVM)
- Restore build command: `make build MODE=image-from-iso ISO_URL=...`
- Keep: troubleshooting additions, boot-override tip
- Update `skills/update-install-packages/SKILL.md` (custom-image-setup → prepare-host-img)

**Why:** Docs must match actual build flow.

---

## What is KEPT (already on main — NOT modified by this branch)

> **Note:** This section documents changes from PR #81 and subsequent commits that
> ALREADY EXIST on `main`. We are NOT introducing these — they are listed here so
> reviewers can verify the revert did not accidentally undo them.

### Package List Optimization (from PR #81 diff L68)
Already committed on `main` in `curate-host-packages.sh`. This branch does NOT
touch the package list.

### Non-Docker Script Improvements (already on main, untouched)
- `curate-host-packages.sh`: categorized installs, audio_fw_update(), chrony/ssh services
- `build-alpine-os.sh`: proxy pass-through, SCRIPT_DIR, CDI verification
- `bootable-usb-prepare.sh`: SSH key validation, removed Python bloat
- `install-os.sh`: removed lvm_size, docker group setup, pigz rollback (PR #125)
- `cloud-init.yaml`: NTP removal (chrony migration)
- `config-file`: LVM field removal

---

## Files DELETED by this branch

```
infrastructure/host-os/Dockerfile
infrastructure/host-os/custom-image-setup.sh
infrastructure/enib-base-container/Dockerfile
infrastructure/build-artifacts/Dockerfile
infrastructure/micro-os/Dockerfile
infrastructure/micro-os/build-in-docker.sh
infrastructure/installation-scripts/cdi/Dockerfile
infrastructure/installation-scripts/cdi/build-in-docker.sh
```

## Files RESTORED by this branch (from before PR #81)

```
infrastructure/host-os/prepare-host-img.sh
infrastructure/host-os/auto-install-pkgs.yaml
```

## Note on swap partition (ITEP-94767)

The swap partition regression is NOT caused by the image build method.
The ICT template includes swap in its partition layout. The QEMU-based
`prepare-host-img.sh` produces an image with EFI+root partitions; swap
is created at provisioning time by `os-partition.sh` on the target node.
The Docker-based approach had the same layout (no swap in the build image).
The JIRA issue should be addressed in the provisioning/partition scripts
if swap is not being created on target — that's independent of build method.
