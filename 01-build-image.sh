#!/bin/bash
###############################################################################
#  01-build-image.sh — Build a complete Gentoo cluster image
#
#  Run this on your PREP MACHINE (any Linux distro with internet).
#  This machine does NOT join the cluster.
#
#  Usage:
#    sudo ./01-build-image.sh <downloads-dir> <ventoy-usb-dir>
#
#  Example:
#    sudo GENTOO_CHROOT=/mnt/gentoo-build/gentoo-cluster-build \
#         ./01-build-image.sh ~/Gentoo_Cluster /media/me/Ventoy
#
#  Env vars:
#    GENTOO_CHROOT  — where the build chroot lives. Default:
#                     /mnt/gentoo-build/gentoo-cluster-build
#                     (expects an ext4 mount with 60+ GB free)
#
#  Time estimate: 4-12 hours. Compile is the bottleneck.
###############################################################################
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
ask()  { echo -ne "${CYAN}[?]${NC} $1 "; }

[[ $# -lt 2 ]] && { echo "Usage: sudo $0 <downloads-dir> <ventoy-usb-dir>"; exit 1; }
[[ $EUID -ne 0 ]] && err "Must run as root."

DOWNLOADS="$(realpath "$1")"
OUTPUT="$(realpath "$2")"
CHROOT="${GENTOO_CHROOT:-/mnt/gentoo-build/gentoo-cluster-build}"

# Free-space precheck on the CHROOT parent (need ~60 GB)
CHROOT_PARENT="$(dirname "$CHROOT")"
mkdir -p "$CHROOT_PARENT"
FREE_KB=$(df -kP "$CHROOT_PARENT" | awk 'NR==2{print $4}')
FREE_GB=$(( FREE_KB / 1024 / 1024 ))
if (( FREE_GB < 55 )); then
  err "Only ${FREE_GB} GB free at $CHROOT_PARENT; need at least 55 GB. Point CHROOT at a bigger filesystem via GENTOO_CHROOT=..."
fi
log "Chroot location: $CHROOT (${FREE_GB} GB free)"

STAGE3=$(find "$DOWNLOADS" -maxdepth 1 -name "stage3-*openrc*.tar.xz" 2>/dev/null | head -1)
[[ -z "$STAGE3" ]] && err "No stage3 tarball found in $DOWNLOADS"
log "Stage3: $(basename "$STAGE3")"

# Check internet (HTTPS, not ICMP — many networks block ping)
if ! curl -fsS --max-time 5 https://gentoo.org >/dev/null 2>&1; then
  err "No internet (https://gentoo.org unreachable). emerge-webrsync needs it."
fi

ask "How many worker nodes per role (compiler and kicad) will the cluster have? [5]:"
read -r NUM_WORKERS
NUM_WORKERS=${NUM_WORKERS:-5}

START_TIME=$(date +%s)

###############################################################################
echo ""
echo -e "${BOLD}PHASE 1: Set up the build chroot${NC}"
echo ""
###############################################################################

# Persistent caches — survive chroot wipes between reruns.
# Live next to the chroot on the loopback, bind-mounted in.
PERSIST="$CHROOT_PARENT/persist"
mkdir -p "$PERSIST"/{portage-tree,distfiles,ccache,binpkgs}

cleanup_mounts() {
  for mp in \
    "$CHROOT/var/cache/ccache" \
    "$CHROOT/var/cache/distfiles" \
    "$CHROOT/var/cache/binpkgs" \
    "$CHROOT/var/db/repos/gentoo" \
    "$CHROOT"/proc "$CHROOT"/sys "$CHROOT"/dev "$CHROOT"/run
  do
    mountpoint -q "$mp" 2>/dev/null && umount -R "$mp" 2>/dev/null || true
  done
}
trap cleanup_mounts EXIT
cleanup_mounts
rm -rf "$CHROOT"
mkdir -p "$CHROOT"

log "Extracting stage3..."
tar xpf "$STAGE3" --xattrs-include='*.*' --numeric-owner -C "$CHROOT"

# Mount kernel filesystems
mount --types proc /proc "$CHROOT/proc"
mount --rbind /sys "$CHROOT/sys"
mount --make-rslave "$CHROOT/sys"
mount --rbind /dev "$CHROOT/dev"
mount --make-rslave "$CHROOT/dev"
mount --rbind /run "$CHROOT/run"
mount --make-rslave "$CHROOT/run"

# Bind-mount persistent caches so rerunning the script does NOT
# redownload portage snapshot / distfiles / rebuild ccache.
mkdir -p "$CHROOT/var/db/repos/gentoo" \
         "$CHROOT/var/cache/distfiles" \
         "$CHROOT/var/cache/ccache" \
         "$CHROOT/var/cache/binpkgs"
mount --bind "$PERSIST/portage-tree" "$CHROOT/var/db/repos/gentoo"
mount --bind "$PERSIST/distfiles"    "$CHROOT/var/cache/distfiles"
mount --bind "$PERSIST/ccache"       "$CHROOT/var/cache/ccache"
mount --bind "$PERSIST/binpkgs"      "$CHROOT/var/cache/binpkgs"
log "Persistent caches bind-mounted from $PERSIST"

# DNS: if the host uses systemd-resolved's 127.0.0.53 stub, it won't work
# inside the chroot — write real public resolvers instead.
if grep -q '127\.0\.0\.53' /etc/resolv.conf 2>/dev/null; then
  warn "Host uses systemd-resolved stub; writing public DNS into chroot."
  cat > "$CHROOT/etc/resolv.conf" <<'RESOLV'
nameserver 1.1.1.1
nameserver 8.8.8.8
RESOLV
else
  cp -L /etc/resolv.conf "$CHROOT/etc/resolv.conf"
fi

###############################################################################
# make.conf — cluster master build
###############################################################################
cat > "$CHROOT/etc/portage/make.conf" << 'MAKECONF'
# ── Gentoo Cluster Master Build ──
# -march=x86-64 produces portable amd64 binaries.
COMMON_FLAGS="-O2 -march=x86-64 -pipe"
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"

MAKEOPTS="-j__NPROC__"

# ── USE flags: union of all roles ──
# NOTE: dbus stays ON (xpra hard-depends on it).
# NOTE: ipv6 stays ON (2026 openssh/nfs-utils expect it).
USE="X opengl egl python threads
     nfs ssh nls icu
     png jpeg tiff svg xml truetype cairo
     readline ncurses ssl zlib lzma bzip2
     gtk gdbm xcb
     -systemd -bluetooth -wifi -pulseaudio -wayland -gstreamer
     -gnome -kde -qt5 -qt6 -cups -avahi
     -doc -info -test"
# NOTE: 'man' stays ON. This is an offline cluster — man pages are the
# only docs you'll have once deployed, so the small build cost is worth it.

FEATURES="ccache parallel-fetch buildpkg"
CCACHE_SIZE="6G"
CCACHE_DIR="/var/cache/ccache"

ACCEPT_LICENSE="*"
L10N="en en-US"
GRUB_PLATFORMS="pc"
INPUT_DEVICES="libinput"
VIDEO_CARDS="intel vesa fbdev radeon nouveau amdgpu"

# Python — match whatever stage3 2026-04 ships (python3_13)
PYTHON_TARGETS="python3_13"
PYTHON_SINGLE_TARGET="python3_13"

# Auto-apply USE/keyword changes suggested by the dep solver instead
# of failing. Writes into /etc/portage/package.use/*.
EMERGE_DEFAULT_OPTS="--autounmask=y --autounmask-write=y --autounmask-continue=y --autounmask-backtrack=y"
MAKECONF

NPROC=$(nproc)
sed -i "s/__NPROC__/$NPROC/" "$CHROOT/etc/portage/make.conf"
log "Prep machine cores: $NPROC (MAKEOPTS=-j$NPROC)"

# ── package.use ──
mkdir -p "$CHROOT/etc/portage/package.use"
cat > "$CHROOT/etc/portage/package.use/cluster" << 'PKGUSE'
# xpra needs server+client for start/attach workflow
x11-wm/xpra server client
# wxGTK needs GL for KiCad 3D viewer
x11-libs/wxGTK opengl X
# Boost with Python bindings for KiCad
dev-libs/boost python nls icu
# freetype + harfbuzz is a mutual dep cycle; force it on
media-libs/freetype harfbuzz
media-libs/harfbuzz truetype
# pillow[truetype] creates a pillow->harfbuzz->glib->docutils->pillow
# cycle; PIL font rendering isn't used by KiCad/matplotlib here.
dev-python/pillow -truetype
PKGUSE

# ── package.accept_keywords (harmless if already stable) ──
mkdir -p "$CHROOT/etc/portage/package.accept_keywords"
cat > "$CHROOT/etc/portage/package.accept_keywords/cluster" << 'KW'
sci-electronics/kicad ~amd64
sci-electronics/kicad-symbols ~amd64
sci-electronics/kicad-footprints ~amd64
KW

###############################################################################
echo ""
echo -e "${BOLD}PHASE 2: Sync portage and build the system${NC}"
echo ""
###############################################################################

# Inner build script — heredoc is quoted, so nothing expands until chroot runs it
cat > "$CHROOT/tmp/build.sh" << 'BUILD'
#!/bin/bash
# Source profile BEFORE -u: Gentoo's /etc/profile.d/debuginfod.sh
# references DEBUGINFOD_URLS without setting it, which trips nounset.
set -eo pipefail
source /etc/profile
set -u
# Helper for every subsequent re-source of /etc/profile
reprofile() { set +u; source /etc/profile; set -u; }
export PS1="(build) ${PS1:-}"

mkdir -p /var/cache/ccache

echo "[+] Syncing portage tree..."
if [[ -f /var/db/repos/gentoo/metadata/timestamp.chk ]]; then
  AGE_HOURS=$(( ( $(date +%s) - $(stat -c %Y /var/db/repos/gentoo/metadata/timestamp.chk) ) / 3600 ))
  if (( AGE_HOURS < 24 )); then
    echo "[+] Portage tree already synced ${AGE_HOURS}h ago, skipping."
  else
    echo "[+] Portage tree is ${AGE_HOURS}h old, refreshing..."
    emerge-webrsync
  fi
else
  emerge-webrsync
fi
echo "[+] Portage tree ready."

echo "[+] Selecting profile..."
# Match plain default/linux/amd64/23.0 (trailing space excludes subvariants)
PNUM=$(eselect profile list \
  | grep -E 'default/linux/amd64/23\.0 ' \
  | grep -v -E 'desktop|systemd|hardened|selinux|split-usr|no-multilib|musl|llvm' \
  | head -1 \
  | grep -oE '\[[0-9]+\]' | tr -d '[]')
if [[ -n "$PNUM" ]]; then
  eselect profile set "$PNUM"
  echo "[+] Profile: $(eselect profile show | tail -1 | xargs)"
else
  echo "[!] Could not auto-detect profile. Available:"
  eselect profile list
  echo "[?] Enter profile number (default/linux/amd64/23.0, non-systemd):"
  read -r PNUM
  eselect profile set "$PNUM"
fi

echo "[+] Setting locale..."
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen || \
  echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set en_US.utf8 2>/dev/null || eselect locale set 1
env-update && reprofile

# Install ccache BEFORE @system so FEATURES=ccache actually works
echo "[+] Installing ccache so @system build can use it..."
emerge --oneshot dev-util/ccache

echo ""
echo "════════════════════════════════════════"
echo "  UPDATING @world with new USE flags"
echo "  Pulls in our USE choices without a full"
echo "  --emptytree rebuild of stage3."
echo "════════════════════════════════════════"
emerge --update --deep --newuse --with-bdeps=y @world 2>&1 \
  | tee /var/log/build-world.log
env-update && reprofile
emerge --depclean --quiet || true

echo ""
echo "════════════════════════════════════════"
echo "  INSTALLING CLUSTER PACKAGES"
echo "════════════════════════════════════════"

# Bootloader
emerge sys-boot/grub

# Core system
emerge app-admin/sysklogd sys-process/cronie sys-fs/e2fsprogs \
       net-misc/dhcpcd sys-apps/iproute2

# Firmware for heterogeneous old laptops — essential
emerge sys-kernel/linux-firmware sys-firmware/intel-microcode || \
  emerge sys-kernel/linux-firmware

# Hardware debug / filesystem tools
emerge sys-apps/pciutils sys-apps/usbutils sys-apps/ethtool \
       sys-fs/dosfstools net-misc/iputils

# SSH, editors, utils
emerge net-misc/openssh app-editors/vim app-misc/tmux sys-process/htop

# Distributed compilation
emerge sys-devel/distcc

# NFS + rpcbind (required by both nfs server and client)
emerge net-fs/nfs-utils net-nds/rpcbind

# Storage
emerge sys-fs/mdadm sys-apps/smartmontools

# X11, window manager, remote display (NOTE: x11-wm/xpra, not x11-misc/xpra)
emerge x11-base/xorg-server x11-wm/icewm x11-wm/xpra

# KiCad (the big one)
echo "[+] Emerging KiCad..."
emerge sci-electronics/kicad sci-electronics/kicad-symbols \
       sci-electronics/kicad-footprints

# Python extras
emerge dev-python/numpy dev-python/matplotlib dev-python/pip

# Kernel sources + genkernel (automated kernel + initramfs builder)
emerge sys-kernel/gentoo-sources sys-kernel/genkernel

# gentoo-sources does not create /usr/src/linux symlink by default
eselect kernel set 1

echo ""
echo "════════════════════════════════════════"
echo "  ALL PACKAGES INSTALLED — BUILDING KERNEL"
echo ""
echo "  genkernel builds a generic kernel + initramfs"
echo "  that probes hardware at boot. No menuconfig."
echo "  Time: 30-90 min depending on cores."
echo "════════════════════════════════════════"

# --no-menuconfig       : fully automatic
# --makeopts=-jN        : parallel compile
# --install             : write kernel + initramfs to /boot
# --symlink             : maintain /boot/vmlinuz symlink
# --oldconfig           : start from a sane baseline
# all                   : build kernel + initramfs
genkernel \
  --no-menuconfig \
  --makeopts="-j$(nproc)" \
  --install \
  --symlink \
  --oldconfig \
  all

echo "[+] Kernel + initramfs built and installed to /boot."
ls -lh /boot/

# Timezone
echo "America/New_York" > /etc/timezone
emerge --config sys-libs/timezone-data 2>/dev/null || true

# Root password
echo ""
echo "[+] Set the root password for the cluster image."
echo "    (Same password on every machine. Change later if desired.)"
until passwd root; do echo "Try again."; done

echo ""
echo "[+] Build complete. Type 'exit' to package the image."
BUILD

chmod +x "$CHROOT/tmp/build.sh"

log "Entering chroot to build everything..."
log "Several hours. Fully automated except kernel menuconfig + root password."
echo ""

chroot "$CHROOT" /tmp/build.sh

###############################################################################
echo ""
echo -e "${BOLD}PHASE 3: Generate SSH keys${NC}"
echo ""
###############################################################################

KEYDIR="$OUTPUT/cluster/ssh-keys"
mkdir -p "$KEYDIR"
cd "$KEYDIR"

ssh-keygen -t ed25519 -f head_key -N "" -C "head@cluster" -q
log "Head node user keypair generated."

# Hostnames MUST match the ones deploy.sh computes per role.
# deploy.sh formats node numbers with printf "%02d" — so build MUST do the same.
# (Old `seq -w` only padded when max width forced it; broke for NUM_WORKERS<10.)
ALL_HOSTS="head storage01"
for i in $(seq 1 "$NUM_WORKERS"); do
  pad=$(printf "%02d" "$i")
  ALL_HOSTS="$ALL_HOSTS compiler${pad} kicad${pad}"
done

for host in $ALL_HOSTS; do
  ssh-keygen -t ed25519 -f "${host}_hostkey" -N "" -q
done

# known_hosts: IP <type> <key> format
{
  echo "192.168.10.1 $(awk '{print $1" "$2}' head_hostkey.pub)"
  echo "192.168.10.2 $(awk '{print $1" "$2}' storage01_hostkey.pub)"
  for i in $(seq 1 "$NUM_WORKERS"); do
    pad=$(printf "%02d" "$i")
    echo "192.168.10.$((10 + i)) $(awk '{print $1" "$2}' compiler${pad}_hostkey.pub)"
    echo "192.168.10.$((20 + i)) $(awk '{print $1" "$2}' kicad${pad}_hostkey.pub)"
  done
} > known_hosts

log "SSH keys generated for: $ALL_HOSTS"

###############################################################################
echo ""
echo -e "${BOLD}PHASE 4: Clean and package the image${NC}"
echo ""
###############################################################################

log "Cleaning build-tmp (keeping persistent caches outside chroot)..."
# distfiles/ccache/binpkgs/portage-tree are bind-mounted from $PERSIST —
# do NOT wipe them, they're shared with future reruns.
rm -rf "$CHROOT/var/tmp/portage/"*
rm -rf "$CHROOT/tmp/"*

# CRITICAL: unmount all bind mounts BEFORE tar, or tar recurses into
# /proc/kcore, /sys, persistent caches, etc. and produces a broken
# image (or fills the disk).
log "Unmounting chroot bind mounts before packaging..."
cleanup_mounts
sleep 1
if mount | grep -q "$CHROOT"; then
  err "Some mount under $CHROOT is still active; refusing to tar. Unmount manually and re-run Phase 4."
fi
rm -rf "$CHROOT/usr/src/linux/.tmp_versions" 2>/dev/null || true
(cd "$CHROOT/usr/src/linux" && make clean 2>/dev/null) || true
cd /

mkdir -p "$OUTPUT/cluster"
log "Packaging image (parallel xz, ~5-10 min)..."
XZ_OPT='-T0 -6' tar cJpf "$OUTPUT/cluster/gentoo-cluster.tar.xz" \
  --xattrs-include='*.*' --numeric-owner \
  -C "$CHROOT" .

IMAGE_SIZE=$(du -sh "$OUTPUT/cluster/gentoo-cluster.tar.xz" | cut -f1)
log "Image packaged: $IMAGE_SIZE"

###############################################################################
echo ""
echo -e "${BOLD}PHASE 5: Create deploy script${NC}"
echo ""
###############################################################################

cat > "$OUTPUT/cluster/deploy.sh" << 'DEPLOY'
#!/bin/bash
###############################################################################
#  deploy.sh — Deploy Gentoo cluster image to a target machine
#
#  Boot target laptop from the Gentoo Minimal Install ISO via Ventoy, then:
#
#    EASIEST (interactive menu):
#      mkdir -p /mnt/usb && mount /dev/sdX1 /mnt/usb
#      cd /mnt/usb/cluster && ./deploy.sh
#
#    FAST (skip the menu):
#      ./deploy.sh <role> [node_number]
#      Roles: host, storage, compiler, kicad
###############################################################################
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
ask()  { echo -ne "${CYAN}[?]${NC} $1 "; }

# Cluster-dir is wherever this script lives. No need to pass it.
CLUSTERDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NUM_WORKERS=__NUM_WORKERS__

# ── Cleanup trap: undo partial state on failure ──
P=""
cleanup() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    warn "Deploy failed (exit $rc). Releasing mounts so you can re-run..."
    umount -R /mnt/gentoo/proc 2>/dev/null || true
    umount -R /mnt/gentoo/dev  2>/dev/null || true
    umount -R /mnt/gentoo/sys  2>/dev/null || true
    umount    /mnt/gentoo/boot 2>/dev/null || true
    umount    /mnt/gentoo      2>/dev/null || true
    [[ -n "$P" ]] && swapoff "${P}2" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ── Sanity: image present? ──
[[ ! -f "$CLUSTERDIR/gentoo-cluster.tar.xz" ]] && \
  err "Image not found at $CLUSTERDIR/gentoo-cluster.tar.xz. Run this script from the cluster/ folder on the USB."

# ── Parse args / role-selection menu ──
ROLE="${1:-}"
NODE_NUM="${2:-}"

if [[ -z "$ROLE" ]]; then
  echo ""
  echo -e "${BOLD}═══════════════════════════════════════${NC}"
  echo -e "${BOLD}  Gentoo Cluster Node Deployment${NC}"
  echo -e "${BOLD}═══════════════════════════════════════${NC}"
  echo ""
  echo "  What kind of node is this?"
  echo ""
  echo "    1) host       your workstation       (192.168.10.1)"
  echo "    2) storage    file server            (192.168.10.2)"
  echo "    3) compiler   distcc worker          (192.168.10.10 + node #)"
  echo "    4) kicad      kicad worker           (192.168.10.20 + node #)"
  echo ""
  ask "Choice [1-4]:"; read -r CHOICE
  case "$CHOICE" in
    1) ROLE=host ;;
    2) ROLE=storage ;;
    3) ROLE=compiler ;;
    4) ROLE=kicad ;;
    *) err "Invalid choice: '$CHOICE'. Pick a number 1-4." ;;
  esac
fi

if [[ "$ROLE" == "compiler" || "$ROLE" == "kicad" ]] && [[ -z "$NODE_NUM" ]]; then
  ask "Which $ROLE node number? (1-$NUM_WORKERS) [1]:"; read -r NODE_NUM
  NODE_NUM="${NODE_NUM:-1}"
fi
NODE_NUM="${NODE_NUM:-1}"

# Zero-padded node number for hostname lookup (matches build-time SSH key naming)
NODE_PAD=$(printf "%02d" "$NODE_NUM")

case $ROLE in
  host)      IP="192.168.10.1";  HOSTNAME="head" ;;
  storage)   IP="192.168.10.2";  HOSTNAME="storage01" ;;
  compiler)  IP="192.168.10.$((10 + NODE_NUM))"; HOSTNAME="compiler${NODE_PAD}" ;;
  kicad)     IP="192.168.10.$((20 + NODE_NUM))"; HOSTNAME="kicad${NODE_PAD}" ;;
  *)         err "Unknown role: '$ROLE' (use host, storage, compiler, or kicad)" ;;
esac

echo ""
echo -e "${CYAN}═══════════════════════════════════════${NC}"
echo -e "${CYAN}  Deploying: ${BOLD}$ROLE${NC}"
echo -e "${CYAN}  Hostname:  ${BOLD}$HOSTNAME${NC}"
echo -e "${CYAN}  IP:        ${BOLD}$IP${NC}"
echo -e "${CYAN}═══════════════════════════════════════${NC}"
echo ""

# ── STEP 1: Pick + wipe target disk ──
log "Detecting available disks on this machine..."
echo ""
lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -vE "loop|sr|ram"
echo ""
warn "DON'T pick the USB you booted from — it's in the list above too!"
warn "(USB drives usually show TRAN=usb. Internal disk is usually 'sda' or 'nvme0n1'.)"
echo ""
ask "Target disk to install Gentoo to (e.g. sda):"; read -r TARGET_DISK
TARGET="/dev/$TARGET_DISK"
[[ ! -b "$TARGET" ]] && err "$TARGET does not exist. Disk names look like 'sda', 'nvme0n1', 'mmcblk0' (no /dev prefix)."

SZ=$(blockdev --getsize64 "$TARGET")
(( SZ < 8 * 1024**3 )) && err "$TARGET is too small ($((SZ/1024/1024/1024)) GB); need >= 8 GB"

DISK_INFO=$(lsblk -d -o NAME,SIZE,MODEL "$TARGET" | tail -1)
echo ""
warn "ALL DATA ON THIS DISK WILL BE ERASED:"
warn "  $DISK_INFO"
echo ""
ask "Type YES (uppercase, exactly) to continue, anything else to abort:"; read -r CONFIRM
[[ "$CONFIRM" != "YES" ]] && err "Aborted by user."

log "Wiping $TARGET (removes stale GPT/mdadm/LVM signatures)..."
wipefs -a "$TARGET"

log "Partitioning $TARGET (256M boot, 2G swap, rest root)..."
echo "label: dos
,256M,L,*
,2G,S
,,L" | sfdisk "$TARGET"
partprobe "$TARGET" 2>/dev/null || true
sleep 2

if [[ "$TARGET" == *nvme* ]] || [[ "$TARGET" == *mmcblk* ]]; then
  P="${TARGET}p"
else
  P="${TARGET}"
fi

wipefs -a "${P}1" "${P}2" "${P}3" 2>/dev/null || true
mkfs.ext4 -q -F "${P}1"
mkswap "${P}2"
swapon "${P}2"
mkfs.ext4 -q -F "${P}3"

mkdir -p /mnt/gentoo
mount "${P}3" /mnt/gentoo
mkdir -p /mnt/gentoo/boot
mount "${P}1" /mnt/gentoo/boot

# ── STEP 2: Extract image ──
log "Extracting Gentoo image (5-15 min depending on disk speed)..."
tar xpf "$CLUSTERDIR/gentoo-cluster.tar.xz" \
  --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo
log "Image extracted."

# ── STEP 3: Identity / network / fstab / hosts ──
log "Configuring hostname, network, fstab..."
echo "$HOSTNAME" > /mnt/gentoo/etc/hostname

cat > /mnt/gentoo/etc/conf.d/net <<NETEOF
# Static IP. eth0 naming is forced via kernel cmdline (net.ifnames=0).
config_eth0="${IP}/24"
NETEOF

cat > /mnt/gentoo/etc/fstab <<FSTAB
${P}1    /boot   ext4  defaults,noatime  0 2
${P}2    none    swap  sw                0 0
${P}3    /       ext4  defaults,noatime  0 1
FSTAB

cat > /mnt/gentoo/etc/hosts <<HOSTS
127.0.0.1       localhost
127.0.1.1       ${HOSTNAME}.lan ${HOSTNAME}

192.168.10.1    head.lan         head
192.168.10.2    storage01.lan    storage01
HOSTS

for i in $(seq 1 $NUM_WORKERS); do
  printf "192.168.10.%d   compiler%02d.lan  compiler%02d\n" "$((10+i))" "$i" "$i" \
    >> /mnt/gentoo/etc/hosts
  printf "192.168.10.%d   kicad%02d.lan     kicad%02d\n"    "$((20+i))" "$i" "$i" \
    >> /mnt/gentoo/etc/hosts
done

# ── STEP 4: SSH keys ──
log "Installing SSH keys..."
SSHDIR="$CLUSTERDIR/ssh-keys"

if [[ -f "$SSHDIR/${HOSTNAME}_hostkey" ]]; then
  cp "$SSHDIR/${HOSTNAME}_hostkey"     /mnt/gentoo/etc/ssh/ssh_host_ed25519_key
  cp "$SSHDIR/${HOSTNAME}_hostkey.pub" /mnt/gentoo/etc/ssh/ssh_host_ed25519_key.pub
  chmod 600 /mnt/gentoo/etc/ssh/ssh_host_ed25519_key
else
  warn "No pre-generated hostkey for $HOSTNAME; SSH will generate one at first boot."
  warn "You'll then need to update /root/.ssh/known_hosts on the head node manually."
fi

mkdir -p /mnt/gentoo/root/.ssh && chmod 700 /mnt/gentoo/root/.ssh

if [[ -f "$SSHDIR/head_key.pub" ]]; then
  cp "$SSHDIR/head_key.pub" /mnt/gentoo/root/.ssh/authorized_keys
  chmod 600 /mnt/gentoo/root/.ssh/authorized_keys
fi

if [[ "$ROLE" == "host" ]]; then
  cp "$SSHDIR/head_key"     /mnt/gentoo/root/.ssh/id_ed25519
  cp "$SSHDIR/head_key.pub" /mnt/gentoo/root/.ssh/id_ed25519.pub
  cp "$SSHDIR/known_hosts"  /mnt/gentoo/root/.ssh/known_hosts
  chmod 600 /mnt/gentoo/root/.ssh/id_ed25519
fi

# Harden SSH
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /mnt/gentoo/etc/ssh/sshd_config
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/'    /mnt/gentoo/etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /mnt/gentoo/etc/ssh/sshd_config

# ── STEP 5: GRUB (BIOS / i386-pc) ──
log "Installing GRUB bootloader..."
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys

# Force legacy interface naming (eth0) — old laptops + netifrc assume it
if grep -q '^GRUB_CMDLINE_LINUX=' /mnt/gentoo/etc/default/grub; then
  sed -i 's|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0"|' \
    /mnt/gentoo/etc/default/grub
else
  echo 'GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0"' >> /mnt/gentoo/etc/default/grub
fi

chroot /mnt/gentoo grub-install --target=i386-pc --recheck "$TARGET"
chroot /mnt/gentoo grub-mkconfig -o /boot/grub/grub.cfg

# ── STEP 6: Role services ──
log "Configuring role-specific services for: $ROLE"

# Every role gets sshd, sysklogd, cronie, networking
chroot /mnt/gentoo rc-update add sshd default
chroot /mnt/gentoo rc-update add sysklogd default
chroot /mnt/gentoo rc-update add cronie default

# net.eth0 is a symlink to net.lo; ln -sfn is idempotent (no test needed)
chroot /mnt/gentoo ln -sfn net.lo /etc/init.d/net.eth0
chroot /mnt/gentoo rc-update add net.eth0 default

case $ROLE in
  host)
    log "Host node: NFS client + distcc helpers..."
    chroot /mnt/gentoo rc-update add rpcbind default
    chroot /mnt/gentoo rc-update add nfsclient default
    mkdir -p /mnt/gentoo/shared /mnt/gentoo/etc/distcc

    echo "localhost/2" > /mnt/gentoo/etc/distcc/hosts

    mkdir -p /mnt/gentoo/root/.ccache
    cat > /mnt/gentoo/root/.ccache/ccache.conf <<'CC'
max_size = 2G
compiler_check = content
CC

    echo "storage01:/srv/shared  /shared  nfs  defaults,noauto  0  0" >> /mnt/gentoo/etc/fstab

    cat >> /mnt/gentoo/root/.bashrc <<'BASH'

# ── Cluster ──
export PATH="/usr/lib/ccache/bin:$PATH"
export DISTCC_HOSTS="$(cat /etc/distcc/hosts 2>/dev/null | tr '\n' ' ')"
alias cmon='distccmon-text 2'
alias cluster='for h in $(grep -E "compiler|kicad|storage" /etc/hosts | awk "{print \$2}"); do echo -n "$h: "; ssh -o ConnectTimeout=2 $h uptime 2>/dev/null || echo OFFLINE; done'
BASH
    # Heredoc was quoted, so \$2 landed literal — fix it.
    sed -i "s|awk \"{print \\\\\\\$2}\"|awk '{print \$2}'|" /mnt/gentoo/root/.bashrc
    ;;

  storage)
    log "Storage node: NFS server + rpcbind..."
    chroot /mnt/gentoo rc-update add rpcbind default
    chroot /mnt/gentoo rc-update add nfs default
    mkdir -p /mnt/gentoo/srv/shared/{projects,src,toolchains,pip-packages,venvs}

    cat > /mnt/gentoo/etc/exports <<'NFS'
/srv/shared  192.168.10.0/24(rw,sync,no_subtree_check,no_root_squash)
NFS

    echo ""
    warn "After first boot, set up your storage disk(s):"
    echo "  Single disk:  mkfs.ext4 /dev/sdX1 && mount /dev/sdX1 /srv/shared"
    echo "  RAID1 mirror: mdadm --create /dev/md0 --level=1 --raid-devices=2 /dev/sdX /dev/sdY"
    echo "                mkfs.ext4 /dev/md0 && mount /dev/md0 /srv/shared"
    echo "  Then add to /etc/fstab and: rc-service nfs restart"
    ;;

  compiler|kicad)
    log "$ROLE node: distccd + NFS client..."
    mkdir -p /mnt/gentoo/etc/conf.d
    cat > /mnt/gentoo/etc/conf.d/distccd <<'DIST'
DISTCCD_OPTS="--port 3632 --log-level error --allow 192.168.10.0/24"
DIST
    chroot /mnt/gentoo rc-update add distccd default
    chroot /mnt/gentoo rc-update add rpcbind default
    chroot /mnt/gentoo rc-update add nfsclient default
    mkdir -p /mnt/gentoo/shared /mnt/gentoo/var/cache/ccache

    mkdir -p /mnt/gentoo/root/.ccache
    cat > /mnt/gentoo/root/.ccache/ccache.conf <<'CC'
max_size = 1G
cache_dir = /var/cache/ccache
compiler_check = content
CC

    echo "storage01:/srv/shared  /shared  nfs  defaults,noauto  0  0" >> /mnt/gentoo/etc/fstab

    echo ""
    log "After this node is online, append to /etc/distcc/hosts on the head node:"
    echo "    ${IP}/\$(nproc)"
    if [[ "$ROLE" == "kicad" ]]; then
      echo ""
      log "From the head node, launch KiCad on this node via xpra over ssh:"
      echo "    xpra start ssh://${HOSTNAME}/100 --start=kicad"
      echo "    xpra attach ssh://${HOSTNAME}/100"
    fi
    ;;
esac

# ── STEP 7: Cleanup chroot mounts ──
umount -R /mnt/gentoo/proc 2>/dev/null || true
umount -R /mnt/gentoo/dev  2>/dev/null || true
umount -R /mnt/gentoo/sys  2>/dev/null || true

# Disarm cleanup trap — we made it
trap - EXIT

echo ""
echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo -e "${GREEN}  DEPLOY COMPLETE${NC}"
echo -e "${GREEN}═══════════════════════════════════════${NC}"
echo ""
echo "  Role:     $ROLE"
echo "  Hostname: $HOSTNAME"
echo "  IP:       $IP"
echo ""
echo "  Now run:"
echo "    umount /mnt/gentoo/boot && umount /mnt/gentoo && reboot"
echo ""
echo "  Then UNPLUG the USB so the laptop boots from its own disk."
echo ""
DEPLOY

# Substitute the build-time worker count into the deployed deploy.sh
sed -i "s/__NUM_WORKERS__/$NUM_WORKERS/" "$OUTPUT/cluster/deploy.sh"
chmod +x "$OUTPUT/cluster/deploy.sh"

###############################################################################
# Copy the Gentoo install ISO to Ventoy
###############################################################################
ISO=$(find "$DOWNLOADS" -maxdepth 1 -name "install-*-minimal-*.iso" | head -1)
if [[ -n "$ISO" ]]; then
  log "Copying Gentoo install ISO to Ventoy USB..."
  cp "$ISO" "$OUTPUT/"
  log "ISO copied. Ventoy will detect it automatically."
else
  warn "No install ISO found in $DOWNLOADS. Copy it to $OUTPUT/ manually."
fi

###############################################################################
# Summary
###############################################################################
END_TIME=$(date +%s)
ELAPSED=$(( (END_TIME - START_TIME) / 60 ))

# Delete the chroot now that the image is packaged (saves 20-30 GB)
log "Removing build chroot..."
cleanup_mounts
rm -rf "$CHROOT"

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  BUILD COMPLETE${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""
echo "  Time:       ${ELAPSED} minutes"
echo "  Image size: $IMAGE_SIZE"
echo ""
echo "  Ventoy USB contents ($OUTPUT):"
echo "    install-*.iso           ← boot target machines from this"
echo "    cluster/"
echo "      gentoo-cluster.tar.xz ← complete compiled Gentoo"
echo "      deploy.sh              ← run per machine"
echo "      ssh-keys/              ← pre-generated keys"
echo ""
echo "  DEPLOYMENT (per machine):"
echo "    1. Boot laptop from Ventoy → select Gentoo ISO"
echo "    2. At the live shell:"
echo "       mkdir -p /mnt/usb && mount /dev/sdX1 /mnt/usb"
echo "       cd /mnt/usb/cluster && ./deploy.sh"
echo "       (Pick role from the menu, or pass it: ./deploy.sh compiler 1)"
echo "    3. Unmount, reboot, unplug USB."
echo ""
echo "  See DEPLOY-GUIDE.md for the non-expert step-by-step."
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
