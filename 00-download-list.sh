#!/bin/bash
cat << 'LIST'
═══════════════════════════════════════════════════════════════
  GENTOO OFFLINE CLUSTER — FILES TO DOWNLOAD
═══════════════════════════════════════════════════════════════

Create a directory:  mkdir ~/gentoo-cluster-files

Download into it:

1. GENTOO STAGE (amd64, OpenRC):
   https://www.gentoo.org/downloads/amd64/
   Click "Stage openrc" (.tar.xz, ~284 MB)
   Filename example: stage3-amd64-openrc-20260412T170205Z.tar.xz

2. GENTOO MINIMAL INSTALL ISO:
   Same page, "Minimal Installation CD" (.iso, ~927 MB)
   This goes on your Ventoy USB for booting target machines.

That is it. Two files.

The build script handles everything else automatically:
  - Syncs the portage tree inside a chroot (emerge-webrsync)
  - Compiles the full system with your USE flags and CFLAGS
  - Installs KiCad, Python 3, distcc, NFS, xpra, everything
  - Builds a custom kernel (you configure it once)
  - Packages the result into a single deployable image
  - Generates SSH keys for all cluster nodes

AFTER the build, your Ventoy USB will contain:
  ventoy-usb/
  ├── install-amd64-minimal-*.iso    (boot target machines)
  ├── cluster/
  │   ├── gentoo-cluster.tar.xz      (complete compiled Gentoo)
  │   ├── deploy.sh                   (per-machine setup)
  │   └── ssh-keys/                   (pre-generated)

Boot a target laptop from Ventoy → pick the Gentoo ISO →
  mount the USB → run deploy.sh → pick role → reboot.
  Machine never touches the internet.

═══════════════════════════════════════════════════════════════
LIST
