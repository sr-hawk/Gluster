# Gentoo Offline Cluster — Project Report

## What This Is

An offline compute cluster built from old 64-bit laptops running Gentoo Linux,
compiled entirely from source. After initial deployment, no node ever connects
to the internet again.

## Purpose

- Hardware design work using KiCad (compiled from source with tailored USE flags)
- Multi-language development (Python 3 to start, more languages later)
- Distributed compilation across all nodes via distcc + ccache
- Custom per-machine kernels optimized for each laptop's hardware (post-deployment)
- Eventually, the entire software stack will be built from the user's own
  open-source code

## Cluster Architecture

| Role     | IP Range         | Function |
|----------|------------------|----------|
| host     | 192.168.10.1     | User's workstation. IceWM, xpra client, editor. The only machine with a GUI the user touches directly. |
| storage  | 192.168.10.2     | NFS server. Shared project files, source trees, toolchains. Optional RAID. |
| compiler | 192.168.10.11+   | Headless distcc workers. Receive compilation units, return object files. |
| kicad    | 192.168.10.21+   | Dedicated KiCad subtool workers. Run KiCad components (eeschema, pcbnew, etc.) warm in RAM, served to host via xpra. Also run distccd. |

All machines connect via a dumb network switch on 192.168.10.0/24. No DHCP,
no gateway, no internet.

## Build Approach

The entire Gentoo system is compiled once on a separate prep machine (not part
of the cluster) that has internet access. The result is a single `.tar.xz`
image containing a fully compiled, ready-to-boot Gentoo with all packages
installed. This image is deployed to each cluster machine via a Ventoy USB
stick. A small `deploy.sh` script handles per-machine configuration:
partitioning, extracting the image, setting hostname/IP, installing SSH keys,
configuring GRUB, and enabling role-specific services.

No target machine ever touches the internet.

## Files

```
Gentoo_Cluster/
├── README.md                             — start here
├── DEPLOY-GUIDE.md                       — step-by-step deploying to a node
├── PROJECT-REPORT.md                     — this file
├── RESUME-BRIEF.md                       — short version for resume / job apps
├── 00-download-list.sh                   — what to download manually before building
├── 01-build-image.sh                     — the main image builder (run on prep machine)
├── prep-machine/                         — Mint-on-prep-machine setup notes (not Gentoo)
│   ├── mint-performance.sh
│   └── mint-post-install-notes.txt
├── install-amd64-minimal-*.iso           — Gentoo installer ISO (boots target machines)
└── stage3-amd64-openrc-*.tar.xz          — Gentoo stage3 (basis of the image)
```

## Scripts In Detail

### 00-download-list.sh
Just prints a human-readable list of what to download manually (2 files: stage3
tarball and minimal install ISO from gentoo.org). Not part of the build.

### 01-build-image.sh
The main script. Runs on the internet-connected prep machine as root.

**Phase 1 — Set up build chroot:**
1. Sanity-checks free space (≥55 GB on the chroot's filesystem)
2. Wipes any prior chroot at `$GENTOO_CHROOT` (default `/mnt/gentoo-build/gentoo-cluster-build`)
3. Extracts stage3 fresh
4. Mounts proc/sys/dev/run into the chroot
5. Bind-mounts persistent caches (`portage-tree`, `distfiles`, `ccache`, `binpkgs`)
   from `$CHROOT_PARENT/persist/` so reruns don't redownload or recompile
6. Writes `/etc/portage/make.conf` with cluster USE flags, `-march=x86-64`,
   `FEATURES="ccache parallel-fetch buildpkg"`, autounmask defaults
7. Writes `package.use` and `package.accept_keywords` for KiCad

**Phase 2 — Build inside chroot:**
1. `emerge-webrsync` (skipped if already synced within 24h)
2. Selects profile `default/linux/amd64/23.0` (non-systemd, non-desktop)
3. Generates en_US.UTF-8 locale
4. Installs `dev-util/ccache` first so `FEATURES=ccache` actually works
5. `emerge --update --deep --newuse --with-bdeps=y @world` to apply USE flags
   (does NOT use `--emptytree` — that was the original plan, swapped for the
   faster `@world` update)
6. Installs cluster packages:
   - **Bootloader:** sys-boot/grub
   - **Core:** sysklogd, cronie, e2fsprogs, dhcpcd, iproute2
   - **Firmware:** linux-firmware, intel-microcode (essential for heterogeneous
     old laptops; tries microcode but doesn't fail without it)
   - **HW debug:** pciutils, usbutils, ethtool, dosfstools, iputils
   - **Editors / utils:** openssh, vim, tmux, htop
   - **Distcc:** distcc
   - **NFS:** nfs-utils, rpcbind
   - **Storage:** mdadm, smartmontools
   - **GUI:** xorg-server, icewm, xpra
   - **KiCad:** kicad, kicad-symbols, kicad-footprints
   - **Python:** numpy, matplotlib, pip
   - **Kernel:** gentoo-sources, genkernel
7. Builds kernel + initramfs **fully automatically via genkernel** (`--no-menuconfig
   --oldconfig`). Generic config that probes hardware at boot. No user prompts.
8. Sets timezone (America/New_York — change if needed) and prompts for root password.

**Phase 3 — SSH keys (outside chroot):**
- Generates ed25519 keypair for the user (head_key)
- Generates ed25519 host keys for `head`, `storage01`, and `compiler01..compilerNN`,
  `kicad01..kicadNN` where NN = NUM_WORKERS chosen at start
- Hostnames are zero-padded with `printf "%02d"` to match `deploy.sh`'s lookup
- Builds a `known_hosts` file mapping each IP to its host key

**Phase 4 — Package the image:**
- Cleans `/var/tmp/portage`, unmounts everything, refuses to tar if anything
  is still mounted under the chroot (safety check)
- Packages chroot as `gentoo-cluster.tar.xz` with parallel xz

**Phase 5 — Write deploy.sh, copy install ISO:**
- Writes `deploy.sh` to `$OUTPUT/cluster/`
- Substitutes `__NUM_WORKERS__` placeholder with the actual chosen worker count
- Copies the Gentoo install ISO to the Ventoy USB

**Time:** 4-12 hours, mostly compile-bound.

### deploy.sh (embedded in 01-build-image.sh, written to USB)
Runs on target machines after booting from Ventoy into the Gentoo live
environment. Two ways to run:

```sh
# Interactive menu (recommended):
cd /mnt/usb/cluster && ./deploy.sh

# Direct (skip menu):
./deploy.sh <role> [node_number]
```

It then:
1. Auto-detects its own directory (no need to pass `<cluster-dir>`)
2. Prompts via menu if no role given; prompts for node number for compiler/kicad
3. Lists disks, asks for target, requires `YES` confirmation
4. Wipes + partitions disk (256M boot, 2G swap, rest root) via sfdisk
5. Formats partitions (ext4, swap)
6. Extracts `gentoo-cluster.tar.xz` to the root partition
7. Writes hostname, static IP, /etc/hosts, /etc/fstab
8. Installs pre-generated SSH host keys and authorized_keys
9. Hardens sshd (no password auth, root login key-only)
10. Chroots briefly to run `grub-install` (BIOS / `i386-pc`) and `grub-mkconfig`
11. Enables OpenRC services based on role:
    - All roles: sshd, sysklogd, cronie, net.eth0
    - host: nfsclient, rpcbind, distcc helpers, ccache, cluster aliases
    - storage: nfs server, rpcbind, /srv/shared tree, /etc/exports
    - compiler / kicad: distccd, nfsclient, rpcbind, ccache
12. Releases mounts via trap on EXIT (so partial failures don't leave busy mounts)

## Known Issues / Areas to Watch

- **Heredoc variable expansion:** Both the inner build script (`/tmp/build.sh`)
  and the deployed `deploy.sh` are written via `'BUILD'` / `'DEPLOY'` quoted
  heredocs, so nothing expands at write time. `$(nproc)` / `$IP` / `$HOSTNAME`
  / `$ROLE` are evaluated at run time inside the chroot or on the target
  machine, which is what we want. The `__NPROC__` and `__NUM_WORKERS__`
  placeholders are substituted via `sed` after the heredoc is written.
- **Portage USE flag conflicts during emerge:** make.conf sets
  `EMERGE_DEFAULT_OPTS=--autounmask=y --autounmask-write=y --autounmask-continue=y
  --autounmask-backtrack=y` so the dep solver auto-applies suggested USE/keyword
  changes. Complex resolves can still fail; you may need to read errors and
  re-run.
- **Network interface naming:** GRUB cmdline forces `net.ifnames=0
  biosdevname=0` so the interface is always `eth0` and the netifrc setup works
  on old laptops. If you ever switch to a machine that genuinely needs predictable
  names, drop those flags and rename `/etc/init.d/net.eth0`.
- **Kernel config:** Built fully automatically by `genkernel --no-menuconfig
  --oldconfig`. Generic kernel + initramfs that probes hardware at boot. Should
  cover almost any old laptop. If a specific NIC or storage driver is missing,
  rebuild on the affected machine post-deploy with a tailored config.
- **`-march=x86-64`:** Produces portable but un-tuned binaries. Intentional —
  the image must boot on any 64-bit laptop. Per-machine optimization happens
  later via distcc rebuilds on the cluster itself.
- **GRUB:** `GRUB_PLATFORMS="pc"` and `--target=i386-pc` — BIOS only, no UEFI.
  Old laptops are BIOS, so this is correct for the target hardware.
- **Chroot mount cleanup:** `cleanup_mounts` runs via `trap EXIT` and is also
  invoked manually before `tar`. The script then explicitly checks `mount |
  grep -q "$CHROOT"` and refuses to tar if anything is still mounted (so we
  never tar /proc/kcore or /sys into the image).
- **Stage3 / install ISO age:** Pinned to the 2026-04 Gentoo snapshot. To
  refresh, re-download per `00-download-list.sh` and re-run the build.
  `PYTHON_TARGETS="python3_13"` in make.conf assumes that snapshot's Python;
  bump it if a newer stage3 ships a different version.
- **Disk space:** The build needs ≥55 GB free on the chroot's filesystem. If
  `/` is tight, point `GENTOO_CHROOT=/path/to/bigger/disk/gentoo-build` before
  running.

## Deploying

See `DEPLOY-GUIDE.md` for the step-by-step that someone unfamiliar with Gentoo
can follow.
