# Project Brief — For Resume / Job Application Agent

A short handoff doc summarizing the current personal project so it can be referenced in resumes, cover letters, and application answers.

## The Idea

Building a fully offline compute cluster from old 64-bit laptops running **Gentoo Linux**, compiled from source. After initial setup, no node ever touches the internet again. The cluster is intended for:

- Hardware design work in **KiCad** (compiled with tailored USE flags)
- Multi-language development (starting with Python 3)
- Distributed compilation across all nodes via **distcc + ccache**
- Custom per-machine kernels tuned to each laptop's hardware
- Long-term goal: running a software stack built entirely from my own open-source code

## Architecture (at a glance)

Flat `192.168.10.0/24` network behind a dumb switch. No DHCP, no gateway, no internet. Roles:

- **host** — workstation, IceWM + xpra client, the only machine with a user-facing GUI
- **storage** — NFS server for shared sources, toolchains, and project files
- **compiler nodes** — headless distcc workers
- **kicad nodes** — dedicated KiCad subtool workers (eeschema, pcbnew) kept warm in RAM and served to the host via xpra; also run distccd

The full system image is built once on a separate internet-connected prep machine, packaged as a single `.tar.xz`, and deployed to each node from a Ventoy USB via a `deploy.sh` that handles partitioning, per-machine config, SSH keys, GRUB, and role-specific OpenRC services.

## Hardware

- A collection of **old 64-bit laptops** (early-2000s era, BIOS boot, not UEFI)
- Connected over a plain unmanaged Ethernet switch
- Intentionally compiled with `-march=x86-64` so one portable image boots on any of them; per-machine optimization happens later via distcc rebuilds on the cluster itself
- Prep/build machine is a separate internet-connected box used only to produce the image

## Current Status

- Gentoo is **up and running** on the cluster
- Currently **tuning the cluster** — kernel configs per machine, distcc/ccache setup, NFS sharing, and USE-flag refinement
- Build tooling (`00-download-list.sh`, `01-build-image.sh`, embedded `deploy.sh`) is working end-to-end

## Skills / Keywords Worth Highlighting

Gentoo, Linux from source, OpenRC, custom kernel configuration, distcc, ccache, NFS, SSH key management, GRUB/BIOS boot, shell scripting, chroot-based image building, Ventoo USB deployment, KiCad, xpra, air-gapped systems, offline/reproducible builds, cluster administration, network design.
