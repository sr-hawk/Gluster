# Deploy Guide — for someone who's never touched Gentoo

Goal: turn an old 64-bit laptop into a node of the cluster. Takes ~20 minutes
per machine. You only need the **Ventoy USB**.

## What you need before starting

- The Ventoy USB (the one with `cluster/`, the install ISOs, and Ventoy itself
  on it)
- The target laptop, plugged into power, plugged into the network switch
- Knowledge of which key opens the laptop's boot menu (usually `F12`, `F9`,
  `F10`, `Esc`, or `F2` — varies by manufacturer)

## Decide what role this laptop will play

Before booting, decide which role this laptop is. Each role gets its own IP.

| Role | IP | What it does | How many do I need? |
|------|----|--------------|---------------------|
| **host** | 192.168.10.1 | Your workstation. The only one with a screen + keyboard you actually use. | Exactly 1 |
| **storage** | 192.168.10.2 | NFS file server. | Exactly 1 |
| **compiler** | 192.168.10.10 + N | Distcc workers (where N is the node number, 1..5) | As many as you want |
| **kicad** | 192.168.10.20 + N | KiCad GUI workers + distcc | As many as you want |

Compiler nodes are numbered: compiler01 (IP .11), compiler02 (.12), etc.
Same for kicad: kicad01 (.21), kicad02 (.22), etc.

## Step-by-step

### 1. Plug the Ventoy USB into the target laptop and boot it

Power on. As it starts, hit the boot menu key (usually `F12`). Pick the USB
from the boot list.

You'll see Ventoy's menu listing several install ISOs. Pick:

> **install-amd64-minimal-20260412T164603Z.iso**

(or whatever filename starts with `install-amd64-minimal-`)

A few seconds later, you'll be at a Linux shell prompt that looks like:

```
livecd ~ #
```

That `#` means you're root. Good.

### 2. Mount the USB so you can read the cluster files

The Gentoo live environment doesn't mount USBs automatically. Do it yourself.

First find the USB device name:

```sh
lsblk
```

You'll see something like:

```
NAME    SIZE  MOUNTPOINT
sda     500G              ← internal disk (your target)
sdb     128G              ← Ventoy USB
├─sdb1  127G              ← the partition with your files
└─sdb2  32M
```

The Ventoy partition is the one you want — usually `sdb1`. **The size will
be much larger than 1 GB** (since it has install ISOs on it). Mount it:

```sh
mkdir -p /mnt/usb
mount /dev/sdb1 /mnt/usb
```

If that fails with "unknown filesystem type 'exfat'", the live environment
needs the exfat module. Try:

```sh
modprobe exfat && mount /dev/sdb1 /mnt/usb
```

### 3. Run the deploy script

```sh
cd /mnt/usb/cluster
./deploy.sh
```

A menu appears asking what role this node is. Pick `1`-`4`. If you picked
compiler or kicad, it'll then ask the node number (start at 1, count up).

It then lists the disks on the laptop. **Be careful here**:

```
NAME      SIZE   MODEL              TRAN
sda       500G   ST500LM012-1DG142
sdb       128G   Ventoy            usb     ← DO NOT pick this — it's your USB
```

The internal disk is what you want. Usually `sda`. The USB shows `TRAN=usb`.
Type just the name (`sda`, not `/dev/sda`).

It then shows the disk it's about to wipe and asks you to type `YES` (in
uppercase) to confirm. **This wipes everything on the target disk.**

The script then:
- Partitions and formats the disk (~1 minute)
- Extracts the Gentoo image (~5-15 minutes depending on disk speed)
- Configures hostname, network, SSH keys, GRUB, services
- Prints "DEPLOY COMPLETE"

### 4. Reboot

```sh
umount /mnt/gentoo/boot && umount /mnt/gentoo && reboot
```

When the laptop's BIOS prompt appears, **unplug the USB**. The laptop should
boot from its own internal disk into Gentoo.

You'll see lots of boot messages (we kept verbose boot on purpose). When it's
done you get a login prompt. Log in as `root` with the password you set during
the build.

### 5. Sanity check

The IP should be assigned automatically. Verify:

```sh
ip addr show eth0      # should show 192.168.10.X for your role
ping 192.168.10.1      # should reach the head node (if deployed)
```

You're done with this node. Repeat for each machine.

## Order of deployment

Roughly:
1. **Storage first** — so other nodes can mount its NFS share later
2. **Host second** — your workstation, where you'll run everything
3. **Compiler / kicad nodes** — in any order

But honestly nothing breaks if you do them in a different order; you'll just
get warnings about unreachable NFS until storage is up.

## After the storage node boots

It needs an actual disk to serve. The deploy script writes /etc/exports but
doesn't format your data drive (you might want to use a separate disk or a
RAID array). After storage01 boots, log in and run:

```sh
# Single disk (e.g. a second internal drive at /dev/sdb):
mkfs.ext4 /dev/sdb1
mount /dev/sdb1 /srv/shared
echo "/dev/sdb1 /srv/shared ext4 defaults 0 2" >> /etc/fstab
rc-service nfs restart
```

For RAID1 instead (two disks mirrored):
```sh
mdadm --create /dev/md0 --level=1 --raid-devices=2 /dev/sdb /dev/sdc
mkfs.ext4 /dev/md0
mount /dev/md0 /srv/shared
# add /dev/md0 to /etc/fstab and: rc-service nfs restart
```

## After each compiler / kicad node boots

Tell the head node about it. SSH into the head node (192.168.10.1) and add:

```sh
# Append the new node to head's distcc hosts file
echo "192.168.10.11/$(ssh 192.168.10.11 nproc)" >> /etc/distcc/hosts
```

Replace 192.168.10.11 with whatever IP the new node got. The `$(ssh ... nproc)`
asks the new node how many cores it has.

For kicad nodes, you can also launch KiCad on them from the head node:
```sh
xpra start ssh://kicad01/100 --start=kicad
xpra attach ssh://kicad01/100
```

## Troubleshooting

### "deploy.sh: command not found"
You're not in the right directory. Run `cd /mnt/usb/cluster && ls`. You should
see `deploy.sh`, `gentoo-cluster.tar.xz`, and `ssh-keys/`.

### "Image not found at .../gentoo-cluster.tar.xz"
You're running `deploy.sh` from a directory that doesn't contain the image.
Either `cd` into the cluster folder first, or run it via its full path
(`/mnt/usb/cluster/deploy.sh`).

### "$TARGET does not exist"
You typed the disk name wrong. Use just `sda`, not `/dev/sda`. Run `lsblk`
again to double-check the name.

### Reboot fails — "no bootable device"
GRUB didn't install correctly, or you wiped the wrong disk. Boot back into
Ventoy, mount the USB, and re-run `deploy.sh`.

### After reboot, no network
Run `rc-service net.eth0 start` manually. If the interface isn't `eth0`, run
`ip link` to find the actual name and fix `/etc/conf.d/net` and the symlink.
This shouldn't happen — we force `eth0` naming via kernel cmdline — but very
old NICs occasionally get weird.

### "No pre-generated hostkey for $HOSTNAME" warning
The image only ships SSH host keys for compiler01, kicad01, head, storage01.
If you deploy compiler02+ or kicad02+, sshd will generate new keys at first
boot, and you'll need to add them to the head node's `~/.ssh/known_hosts`
manually:
```sh
ssh-keyscan -t ed25519 192.168.10.12 >> ~/.ssh/known_hosts
```

### Want to wipe and start over?
Boot the Ventoy USB again, run deploy.sh again on the same disk. It re-wipes
and re-installs.

## Rebuilding the image (only the prep machine — internet-connected)

If you ever need to rebuild the image (different USE flags, newer stage3,
more workers):

1. Make sure you have ≥55 GB free on some filesystem. If `/` is tight, point
   the chroot elsewhere:
   ```sh
   sudo GENTOO_CHROOT=/path/to/big/disk/gentoo-build \
        ./01-build-image.sh ~/Gentoo_Cluster /media/me/Ventoy
   ```
2. Make sure the prep machine has internet.
3. Take 4-12 hours.

The script uses persistent caches under `<chroot-parent>/persist/` so reruns
skip downloading and recompiling whatever it already has.
