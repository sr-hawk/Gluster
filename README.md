# Gentoo Offline Cluster

An air-gapped compute cluster built from old 64-bit laptops, running
Gentoo Linux compiled entirely from source. Used for KiCad hardware
design, distributed compilation, and Python development.

## Where to start

| If you want to... | Read |
|-------------------|------|
| **Deploy a node** (the common case — image is already built) | [DEPLOY-GUIDE.md](DEPLOY-GUIDE.md) |
| Understand the architecture in detail | [PROJECT-REPORT.md](PROJECT-REPORT.md) |
| Rebuild the cluster image from scratch | [PROJECT-REPORT.md](PROJECT-REPORT.md) — "Build Approach" section, then run `01-build-image.sh` |
| Reference for resume/job apps | [RESUME-BRIEF.md](RESUME-BRIEF.md) |

## Layout

```
.
├── README.md                          ← you are here
├── DEPLOY-GUIDE.md                    ← step-by-step for deploying a node
├── PROJECT-REPORT.md                  ← full architecture + script details
├── RESUME-BRIEF.md                    ← short version for resumes
├── 00-download-list.sh                ← prints what to download manually
├── 01-build-image.sh                  ← the image builder (run on prep machine)
├── prep-machine/                      ← Mint setup notes (not Gentoo)
├── install-amd64-minimal-*.iso        ← Gentoo installer (lives on Ventoy USB too)
└── stage3-amd64-openrc-*.tar.xz       ← Gentoo stage3 base
```

## Quick context

The cluster image is built **once** on this prep machine, packaged as
`gentoo-cluster.tar.xz` (~2.2 GB), and copied to a Ventoy USB. Each
target laptop boots the Gentoo install ISO from Ventoy, runs `deploy.sh`,
and never touches the internet again.

Both your USBs already have a built image on them:
- `/media/me/Ventoy/cluster/` — full Ventoy USB with install ISOs + cluster image
- `/media/me/GENTOO_DEP/` — flat backup containing just the cluster image

For day-to-day deployment you only need the Ventoy USB.
