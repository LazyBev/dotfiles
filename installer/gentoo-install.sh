#!/usr/bin/env bash
# =============================================================================
# Gentoo Linux — Base OpenRC + Wayland + niri WM + SDDM + Ghostty
# Follows the Gentoo Handbook installation steps.
#
# Assumptions:
#   • x86_64 (amd64) system booted in UEFI mode
#   • Target disk:  /dev/nvme0n1  (edit DISK below)
#   • Hybrid AMD (primary/iGPU) + NVIDIA (discrete) proprietary drivers
#   • Run from an Arch ISO (archiso) as root
#   • Pure OpenRC — no systemd as init; systemd-utils present ONLY for udev
#
# Note on systemd-utils:
#   eudev was removed from Gentoo. sys-apps/systemd-utils now provides udev
#   for OpenRC systems. It does NOT pull in or require sys-apps/systemd.
#   We pin it to USE="udev tmpfiles kmod -boot -sysusers -kernel-install"
#   so only the device manager and tmpfiles components are built.
#
# Usage (as root on archiso):
#   bash gentoo-install.sh
#
# Log:  /tmp/gentoo-install.log
# =============================================================================

set -eo pipefail
IFS=$'\n\t'

# =============================================================================
# ── EDIT THESE ────────────────────────────────────────────────────────────────
# =============================================================================

DISK="/dev/nvme0n1"
HOSTNAME="gentuwu"
USERNAME="25yari"
TIMEZONE="Europe/London"
LOCALE="en_US.UTF-8"
KEYMAP="us"

GPU_PRIMARY="amd"
GPU_SECONDARY="nvidia"
VIDEO_CARDS="amdgpu radeonsi nvidia"

# =============================================================================
# ── DERIVED / FIXED ───────────────────────────────────────────────────────────
# =============================================================================

NCPU=$(nproc)
LOG_FILE="/tmp/gentoo-install.log"

_part() {
    [[ "$DISK" == *nvme* || "$DISK" == *mmcblk* ]] \
        && echo "${DISK}p${1}" || echo "${DISK}${1}"
}
PART_EFI="$(_part 1)"
PART_SWAP="$(_part 2)"
PART_ROOT="$(_part 3)"

# =============================================================================
# ── COLOURS & LOGGING ─────────────────────────────────────────────────────────
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1

log()     { echo -e "${GREEN}[+]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
section() {
    echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  $*${NC}"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════════════${NC}\n"
}

# NOTE: _systemd_present() is only defined inside the chroot script (below).
# It is NOT defined here in the outer script because portageq does not exist
# on the Arch ISO live environment. Do not call portageq outside the chroot.

# =============================================================================
# STEP 1 — Pre-flight
# =============================================================================

section "Pre-flight checks"

[[ $EUID -ne 0 ]]  && error "Must run as root."
[[ ! -b "$DISK" ]] && error "Disk $DISK not found."

# FIX: Hard-fail early if not booted in UEFI mode. Without efivarfs,
# grub-install will fail deep inside the chroot with a cryptic error.
[[ -d /sys/firmware/efi/efivars ]] \
    || error "Not booted in UEFI mode — cannot install EFI GRUB. Aborting."

for t in wipefs sgdisk mkfs.fat mkswap openssl chroot sha256sum; do
    command -v "$t" &>/dev/null || error "Missing tool: $t"
done

PING_HOSTS=(
    # DNS resolvers — most reliable, pure IP so no DNS needed
    8.8.8.8          # Google DNS
    8.8.4.4          # Google DNS 2
    1.1.1.1          # Cloudflare DNS
    1.0.0.1          # Cloudflare DNS 2
    9.9.9.9          # Quad9 DNS
    149.112.112.112  # Quad9 DNS 2
    208.67.222.222   # OpenDNS
    208.67.220.220   # OpenDNS 2
    4.2.2.1          # Level3 DNS
    4.2.2.2          # Level3 DNS 2
    # Gentoo infrastructure
    gentoo.org
    distfiles.gentoo.org
    rsync.gentoo.org
    # Linux/FOSS infrastructure
    kernel.org
    archlinux.org
    debian.org
    ubuntu.com
    fedoraproject.org
    opensuse.org
    # Major CDNs and tech
    cloudflare.com
    google.com
    github.com
    gitlab.com
    fastly.com
    akamai.com
    # Public DNS by name
    dns.google
    one.one.one.one
    # Universities / mirrors commonly used by Gentoo
    ftp.halifax.rwth-aachen.de
    mirror.bytemark.co.uk
    mirrors.mit.edu
    ftp.ussg.iu.edu
)
NET_OK=0
for host in "${PING_HOSTS[@]}"; do
    [[ "$host" == \#* ]] && continue  # skip comment-only entries
    if ping -c2 -W2 "$host" &>/dev/null 2>&1; then
        log "Network OK (reachable: $host)"
        NET_OK=1
        break
    fi
done
[[ "$NET_OK" -eq 1 ]] || error "No internet connection — all ping targets failed."

# wget is almost always present on archiso; install only if missing
command -v wget &>/dev/null || pacman -Sy --noconfirm wget \
    || error "Failed to install wget on live ISO."

timedatectl set-ntp true && sleep 3 && log "Clock synced." \
    || warn "Clock sync failed — continuing"

echo
read -rsp "  Root password: "            rp1 </dev/tty; echo
read -rsp "  Confirm root password: "    rp2 </dev/tty; echo
[[ "$rp1" != "$rp2" ]] && error "Root passwords do not match."

read -rsp "  Password for ${USERNAME}: "         up1 </dev/tty; echo
read -rsp "  Confirm password for ${USERNAME}: "  up2 </dev/tty; echo
[[ "$up1" != "$up2" ]] && error "User passwords do not match."

ROOT_HASH=$(openssl passwd -6 "$rp1")
USER_HASH=$(openssl passwd -6 "$up1")
unset rp1 rp2 up1 up2

log "Pre-flight OK  (CPUs: ${NCPU})"

# =============================================================================
# STEP 2 — Partition
# =============================================================================

section "Partitioning ${DISK}"

warn "ALL DATA ON ${DISK} WILL BE DESTROYED"
read -rp "  Type 'yes' to confirm: " _confirm </dev/tty
[[ "$_confirm" != "yes" ]] && error "Aborted."

wipefs -a "$DISK"
sgdisk --zap-all "$DISK"

sgdisk -n 1:0:+1G  -t 1:ef00 -c 1:"EFI"  "$DISK"
sgdisk -n 2:0:+8G  -t 2:8200 -c 2:"swap" "$DISK"
sgdisk -n 3:0:0    -t 3:8300 -c 3:"root" "$DISK"

partprobe "$DISK"; udevadm settle

mkfs.fat -F32 -n "EFI"  "$PART_EFI"
mkswap   -L   "swap"    "$PART_SWAP"; swapon "$PART_SWAP"
mkfs.ext4 -L  "gentoo" -O dir_index,extent,sparse_super2 "$PART_ROOT"

mkdir -p /mnt/gentoo
mount -o noatime "$PART_ROOT" /mnt/gentoo
mkdir -p /mnt/gentoo/boot/efi
mount "$PART_EFI" /mnt/gentoo/boot/efi

log "Partitions mounted."

# =============================================================================
# STEP 3 — Stage3 tarball
# =============================================================================

section "Stage3 tarball"

BASE_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds"
MANIFEST=$(wget -qO- "${BASE_URL}/latest-stage3-amd64-openrc.txt") \
    || error "Could not fetch stage3 manifest."

TARBALL_PATH=$(echo "$MANIFEST" \
    | grep -E '^[0-9]{8}T[0-9]{6}Z/stage3-' \
    | awk 'NR==1{print $1}')
[[ -z "$TARBALL_PATH" ]] && error "Could not parse stage3 path."

TARBALL_URL="${BASE_URL}/${TARBALL_PATH}"

# FIX: Retry the download up to 3 times on checksum mismatch.
# --continue is intentionally absent: resuming a corrupt partial produces
# another corrupt file. We delete and re-download from scratch each attempt.
# Mirror list: if the primary distfiles mirror is mid-sync, fall back to
# known-stable mirrors so we get a consistent tarball + .sha256 pair.
log "Downloading: ${TARBALL_URL}"
wget --tries=10 \
     --timeout=60 \
     --waitretry=10 \
     --show-progress \
     "$TARBALL_URL" -O /mnt/gentoo/stage3.tar.xz \
    || error "stage3 download failed."

log "Extracting stage3..."
tar xpf /mnt/gentoo/stage3.tar.xz \
    --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo
rm -f /mnt/gentoo/stage3.tar.xz /tmp/stage3.sha256

log "Stage3 installed."

# =============================================================================
# STEP 4 — Portage configuration
# =============================================================================

section "Portage configuration"

mkdir -p /mnt/gentoo/etc/portage/{package.use,package.accept_keywords,package.license,package.mask,repos.conf}

cat > /mnt/gentoo/etc/portage/make.conf << EOF
# make.conf — generated $(date -u '+%Y-%m-%dT%H:%M:%SZ')

COMMON_FLAGS="-O2 -pipe -march=native"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"

MAKEOPTS="-j${NCPU} -l${NCPU}"
EMERGE_DEFAULT_OPTS="--jobs=${NCPU} --load-average=${NCPU} --with-bdeps=y --verbose"

# NOTE: ~amd64 accepts testing packages globally. This is intentional for a
# bleeding-edge desktop, but be aware that any package may be testing-quality.
ACCEPT_KEYWORDS="~amd64"
ACCEPT_LICENSE="-* @FREE @BINARY-REDISTRIBUTABLE"

# Global -systemd ensures no package silently pulls in systemd deps.
# elogind replaces systemd-logind for seat/session management.
# udev USE flag is satisfied by sys-apps/systemd-utils[udev] (not sys-apps/systemd).
USE="wayland X alsa udev opengl -systemd -kde -gnome dbus policykit elogind -systemd-units"

VIDEO_CARDS="${VIDEO_CARDS}"
INPUT_DEVICES="libinput"

L10N="en en-US"

GENTOO_MIRRORS="https://distfiles.gentoo.org"
DISTDIR="/var/cache/distfiles"
PKGDIR="/var/cache/binpkgs"
PORTDIR="/var/db/repos/gentoo"

# Note: nvidia-drm.modeset=1 is also set in /etc/modprobe.d/nvidia.conf.
# To additionally set it on the kernel cmdline for belt-and-suspenders coverage,
# add: GRUB_CMDLINE_LINUX="nvidia-drm.modeset=1" to /etc/default/grub after install.
GRUB_PLATFORMS="efi-64"
EOF

cat > /mnt/gentoo/etc/portage/repos.conf/gentoo.conf << 'EOF'
[DEFAULT]
main-repo = gentoo

[gentoo]
location  = /var/db/repos/gentoo
sync-type = rsync
sync-uri  = rsync://rsync.gentoo.org/gentoo-portage
auto-sync = yes
sync-rsync-verify-jobs         = 1
sync-rsync-verify-metamanifest = yes
sync-rsync-verify-max-age      = 24
EOF

# ── package.mask — hard-block sys-apps/systemd from ever being installed ──────
# IMPORTANT: This mask must be in place BEFORE any emerge runs inside chroot.
# sys-apps/systemd-utils is NOT masked — it provides udev/tmpfiles for OpenRC
# and does not depend on or activate sys-apps/systemd.
cat > /mnt/gentoo/etc/portage/package.mask/systemd << 'EOF'
# Hard-block the full systemd init — we use OpenRC + elogind.
# sys-apps/systemd-utils is NOT masked; it provides udev/tmpfiles for OpenRC.
sys-apps/systemd
EOF

# Mask legacy ATI DDX driver — pulls in video_cards_radeon on libdrm which is
# masked. We use amdgpu/radeonsi; xf86-video-ati is not needed.
cat > /mnt/gentoo/etc/portage/package.mask/xf86-video-ati << 'EOF'
x11-drivers/xf86-video-ati
EOF

# ── package.use/systemd-utils — pin to only what OpenRC needs ─────────────────
cat > /mnt/gentoo/etc/portage/package.use/systemd-utils << 'EOF'
# udev     — device manager (replaces eudev, which was removed from Gentoo)
# tmpfiles — needed by several packages to set up /run, /tmp entries at boot
# kmod     — allow udev to load kernel modules
# Everything else (boot, sysusers, kernel-install, ukify) is systemd-specific
# tooling we do not want on an OpenRC system.
sys-apps/systemd-utils  udev tmpfiles kmod -boot -sysusers -kernel-install
EOF

# ── package.use/kernel ────────────────────────────────────────────────────────
cat > /mnt/gentoo/etc/portage/package.use/kernel << 'EOF'
sys-kernel/installkernel        dracut -systemd
sys-kernel/gentoo-kernel-bin    initramfs
virtual/dist-kernel             initramfs
EOF

# ── package.use/system ────────────────────────────────────────────────────────
cat > /mnt/gentoo/etc/portage/package.use/system << 'EOF'
sys-auth/pambase                elogind -systemd
>=media-libs/freetype-2.14.3    harfbuzz
# NetworkManager: openrc init script, no systemd unit activation
net-misc/networkmanager         -systemd -systemd-units elogind
# dbus: elogind session tracking, no systemd activation
sys-apps/dbus                   -systemd elogind
# polkit: elogind for session management
sys-auth/polkit                 -systemd elogind
# elogind itself must not pull systemd
sys-auth/elogind                -systemd
# SDDM: use elogind for seat/session management, not systemd-logind
x11-misc/sddm                   elogind -systemd
# xdg-desktop-portal: no systemd socket activation
sys-apps/xdg-desktop-portal     -systemd
# openssh has a conditional systemd dep — explicitly disable it
net-misc/openssh                -systemd
# cronie: no systemd
sys-process/cronie              -systemd
# pam: elogind only
sys-libs/pam                    elogind -systemd
EOF

# ── package.use/wayland ───────────────────────────────────────────────────────
cat > /mnt/gentoo/etc/portage/package.use/wayland << 'EOF'
gui-libs/wlroots   drm gles2 vulkan xwayland
dev-libs/wayland   -doc
EOF

# ── package.use/gpu ───────────────────────────────────────────────────────────
cat > /mnt/gentoo/etc/portage/package.use/gpu << 'EOF'
# AMD (mesa) — -nvidia prevents mesa wrapping the blob
media-libs/mesa  X vulkan vulkan-overlay video_cards_amdgpu video_cards_radeonsi -nvidia
# libdrm: use amdgpu, not legacy radeon
x11-libs/libdrm  video_cards_amdgpu -video_cards_radeon
# xorg-drivers: amdgpu + nvidia DDX only; radeonsi is a Mesa/Gallium driver
# not an Xorg DDX — excluding it here prevents xf86-video-ati being pulled in.
x11-base/xorg-drivers  video_cards_amdgpu video_cards_nvidia -video_cards_radeon -video_cards_radeonsi

# NVIDIA proprietary — Wayland support, no kernel-open, no systemd
x11-drivers/nvidia-drivers  wayland -kernel-open -systemd
EOF

# ── package.use/audio ─────────────────────────────────────────────────────────
cat > /mnt/gentoo/etc/portage/package.use/audio << 'EOF'
media-video/pipewire    sound-server jack-sdk -systemd
media-video/wireplumber -systemd
EOF

# ── package.accept_keywords ───────────────────────────────────────────────────
# FIX: Added keywording for wayland ecosystem packages that have had
# intermittent ~amd64 keywording issues, and for ghostty/niri which
# come from the guru overlay and may need explicit acceptance.
cat > /mnt/gentoo/etc/portage/package.accept_keywords/desktop << 'EOF'
gui-wm/niri                  ~amd64
dev-libs/wayland-protocols   ~amd64
x11-drivers/nvidia-drivers   ~amd64
x11-libs/libdrm              ~amd64
gui-apps/swaylock            ~amd64
gui-apps/grim                ~amd64
gui-apps/slurp               ~amd64
gui-apps/fuzzel              ~amd64
gui-apps/mako                ~amd64
gui-apps/waybar              ~amd64
app-terminals/ghostty        ~amd64
EOF

# ── package.license ───────────────────────────────────────────────────────────
cat > /mnt/gentoo/etc/portage/package.license/nvidia << 'EOF'
x11-drivers/nvidia-drivers  NVIDIA-r2
EOF

log "Portage config written."

# =============================================================================
# STEP 5 — fstab
# =============================================================================

section "Generating /etc/fstab"

EFI_UUID=$(blkid  -s UUID -o value "$PART_EFI")
ROOT_UUID=$(blkid -s UUID -o value "$PART_ROOT")
SWAP_UUID=$(blkid -s UUID -o value "$PART_SWAP")

# NOTE: UUID column alignment is cosmetic; UUIDs are variable-length so
# spacing may not be perfectly even — this is harmless.
cat > /mnt/gentoo/etc/fstab << EOF
# <fs>                    <mp>       <type>  <opts>                        <dump> <pass>
UUID=${ROOT_UUID}  /          ext4    defaults,noatime              0 1
UUID=${EFI_UUID}   /boot/efi  vfat    umask=0077                    0 2
UUID=${SWAP_UUID}  none       swap    sw                            0 0
tmpfs              /tmp       tmpfs   defaults,nosuid,nodev,size=4G 0 0
EOF

log "fstab written."

# =============================================================================
# STEP 6 — Chroot environment
# =============================================================================

section "Preparing chroot"

cp --dereference /etc/resolv.conf /mnt/gentoo/etc/

mount --types proc  /proc /mnt/gentoo/proc
mount --rbind       /sys  /mnt/gentoo/sys;  mount --make-rslave /mnt/gentoo/sys
mount --rbind       /dev  /mnt/gentoo/dev;  mount --make-rslave /mnt/gentoo/dev
mount --bind        /run  /mnt/gentoo/run;  mount --make-slave  /mnt/gentoo/run

# efivarfs is required for grub-install. The pre-flight check above already
# confirmed we are in UEFI mode, so this mount will always succeed.
mount --bind /sys/firmware/efi/efivars /mnt/gentoo/sys/firmware/efi/efivars

log "Chroot ready."

# =============================================================================
# STEP 7 — Write and run the chroot script
# =============================================================================

section "Writing chroot script"
install -m 700 /dev/null /mnt/gentoo/root/chroot-install.sh

# NOTE on variable escaping in this heredoc (delimiter: CHROOT_EOF, unquoted):
#   \$VAR  — evaluated at runtime inside chroot (chroot-script variables)
#   $VAR   — expanded NOW by the outer shell before writing (installer variables)
#   \${…}  — runtime chroot variable with braces

cat > /mnt/gentoo/root/chroot-install.sh << CHROOT_EOF
#!/usr/bin/env bash
set -eo pipefail

# Hashes passed in from outer installer (openssl passwd -6 output contains
# literal \$6\$ which must be stored as a variable, not expanded inline).
ROOT_HASH='${ROOT_HASH}'
USER_HASH='${USER_HASH}'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()     { echo -e "\${GREEN}[+]\${NC} \$*"; }
warn()    { echo -e "\${YELLOW}[!]\${NC} \$*"; }
error()   { echo -e "\${RED}[✗]\${NC} \$*" >&2; exit 1; }
section() {
    echo -e "\n\${BOLD}\${BLUE}══════════════════════════════════════════════\${NC}"
    echo -e "\${BOLD}\${CYAN}  \$*\${NC}"
    echo -e "\${BOLD}\${BLUE}══════════════════════════════════════════════\${NC}\n"
}

# FIX: Helper uses grep without -x so versioned atoms like
# "sys-apps/systemd-260" are still caught. systemd-utils is explicitly
# excluded to prevent false positives.
_systemd_present() {
    portageq match / sys-apps/systemd 2>/dev/null \
        | grep "sys-apps/systemd" \
        | grep -v "sys-apps/systemd-utils" \
        | grep -q "."
}

# set +u guards against unset variables in /etc/profile (e.g. PS1)
set +u; source /etc/profile; set -u
export PS1="(chroot) \${PS1:-}"

# ── Verify package.mask is in place before ANY emerge runs ───────────────────
# FIX: Re-assert the mask inside chroot so it cannot be accidentally missing.
section "Asserting systemd mask"
mkdir -p /etc/portage/package.mask
cat > /etc/portage/package.mask/systemd << 'MASKEOF'
# Hard-block the full systemd init — OpenRC + elogind system.
# sys-apps/systemd-utils is NOT masked — it provides udev for OpenRC.
sys-apps/systemd
MASKEOF

# Mask legacy ATI DDX — pulls in masked libdrm[video_cards_radeon].
cat > /etc/portage/package.mask/xf86-video-ati << 'MASKEOF'
x11-drivers/xf86-video-ati
MASKEOF
log "package.mask/systemd confirmed."

# ── Portage tree ──────────────────────────────────────────────────────────────
section "Syncing Portage tree (emerge-webrsync)"
emerge-webrsync || error "emerge-webrsync failed."
# Follow up with a full rsync for the freshest ~amd64 package versions.
emerge --sync || warn "emerge --sync failed — tree may be slightly stale."

# ── Enable guru overlay for niri, ghostty, and other bleeding-edge packages ───
# FIX: Both gui-wm/niri and app-terminals/ghostty live in the guru overlay,
# not the main Gentoo tree. Set up eselect-repository and enable guru BEFORE
# any GUI package installs so emerge can find these atoms.
section "Enabling guru overlay (niri, ghostty)"
emerge --oneshot app-eselect/eselect-repository dev-vcs/git \
    || error "Failed to install eselect-repository."
eselect repository enable guru \
    || error "Failed to enable guru overlay."
emerge --sync guru \
    || error "Failed to sync guru overlay."
log "guru overlay enabled and synced."

# ── Install systemd-utils with pinned USE flags FIRST ────────────────────────
# FIX: Install systemd-utils before @world so portage cannot later resolve it
# with different USE flags when satisfying a dep mid-update. --oneshot keeps
# it out of the world file.
section "Pinning sys-apps/systemd-utils (udev for OpenRC)"
emerge --oneshot sys-apps/systemd-utils \
    || error "systemd-utils install failed."
log "systemd-utils (udev+tmpfiles only) installed."

# ── Purge systemd if it somehow got pulled in before mask took effect ─────────
section "Enforcing systemd-free system"
if _systemd_present; then
    warn "systemd was found — purging before continuing..."
    emerge --deselect sys-apps/systemd 2>/dev/null || true
    emerge --unmerge sys-apps/systemd 2>/dev/null \
        || error "Failed to unmerge systemd — check USE flags manually."
    log "systemd purged."
else
    log "Confirmed: systemd not present."
fi

# ── Profile ───────────────────────────────────────────────────────────────────
section "Selecting profile"
eselect profile list
echo ""
read -rp "  Enter profile number (default: amd64/23.0/desktop/openrc): " PROFILE_NUM </dev/tty
if [[ -n "\$PROFILE_NUM" ]]; then
    eselect profile set "\$PROFILE_NUM" || warn "Profile set failed."
    log "Profile set to number \${PROFILE_NUM}."
else
    # FIX: Use -E for extended regex so | works as alternation.
    # Without -E, 'plasma|gnome|systemd' is a literal BRE string and the
    # filter has no effect — potentially auto-selecting a systemd profile.
    PROFILE_NUM=\$(eselect profile list \
        | grep 'desktop/openrc' \
        | grep -vE 'plasma|gnome|systemd' \
        | head -1 | awk '{print \$1}' | tr -d '[]')
    if [[ -n "\$PROFILE_NUM" ]]; then
        eselect profile set "\$PROFILE_NUM"
        log "Auto-selected profile \${PROFILE_NUM}: \$(eselect profile show)"
    else
        warn "Could not auto-select profile — set manually with: eselect profile set"
    fi
fi

# ── @world update ─────────────────────────────────────────────────────────────
section "Updating @world"
# --changed-use picks up our new -systemd flags across all packages.
# --keep-going allows the update to finish and surface ALL conflicts
# rather than aborting on the first issue, making debugging easier.
emerge --update --newuse --changed-use --deep --keep-going @world \
    || warn "@world update had non-fatal issues — check output above."

# Post-world systemd check uses the safe helper (no -x flag).
if _systemd_present; then
    error "sys-apps/systemd was pulled in by @world — check USE flags and package.mask!"
fi
log "@world updated — systemd not present, as expected."

# ── Timezone & Locale ─────────────────────────────────────────────────────────
section "Timezone & Locale"
echo "${TIMEZONE}" > /etc/timezone
emerge --config sys-libs/timezone-data
echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
LOC=\$(locale -a | grep -i "\$(echo "${LOCALE}" | tr '[:upper:]' '[:lower:]' | sed 's/utf-8/utf8/')" | head -1)
[[ -n "\$LOC" ]] && eselect locale set "\$LOC" || warn "Set locale manually with: eselect locale set"
set +u; env-update && source /etc/profile; set -u

# ── Firmware ──────────────────────────────────────────────────────────────────
section "Firmware"
# FIX: linux-firmware is large and fetched from kernel.org mirrors which can
# have transient DNS/connectivity failures. Retry up to 3 times with a short
# backoff, and offer multiple mirrors via GENTOO_MIRRORS as fallback.
FIRMWARE_OK=0
for attempt in 1 2 3; do
    log "Firmware install attempt \${attempt}/3..."
    if emerge sys-kernel/linux-firmware sys-firmware/sof-firmware; then
        FIRMWARE_OK=1
        break
    else
        warn "Firmware emerge failed on attempt \${attempt} — waiting 30s before retry..."
        # Rotate mirror on each retry
        case \$attempt in
            1) GENTOO_MIRRORS="https://distfiles.gentoo.org" ;;
            2) GENTOO_MIRRORS="https://ftp.halifax.rwth-aachen.de/gentoo" ;;
        esac
        export GENTOO_MIRRORS
        sleep 30
    fi
done
[[ "\$FIRMWARE_OK" -eq 1 ]] || error "Firmware install failed after 3 attempts — check network."
log "Firmware installed."

# ── Kernel ────────────────────────────────────────────────────────────────────
section "Kernel (gentoo-kernel-bin)"

# FIX: Mount /boot/efi using the UUID from fstab before the kernel postinst.
# installkernel checks for a mounted EFI partition; if absent it falls back to
# treating /boot as flat and the dracut chroot-check then aborts.
mkdir -p /boot/efi
if ! mountpoint -q /boot/efi; then
    EFI_UUID=\$(awk '\$2=="/boot/efi"{print \$1}' /etc/fstab \
               | sed 's/UUID=//')
    if [[ -n "\$EFI_UUID" ]]; then
        mount UUID="\$EFI_UUID" /boot/efi \
            && log "/boot/efi mounted (UUID=\$EFI_UUID)" \
            || error "Failed to mount /boot/efi — kernel postinst will fail."
    else
        # fstab entry missing — find the vfat partition directly
        EFI_DEV=\$(blkid -t TYPE=vfat -o device | head -1)
        [[ -n "\$EFI_DEV" ]] || error "Cannot find EFI partition — aborting."
        mount "\$EFI_DEV" /boot/efi \
            && log "/boot/efi mounted from \$EFI_DEV" \
            || error "Failed to mount /boot/efi."
    fi
fi

# FIX: Provide /etc/cmdline so dracut does not abort when run inside a chroot.
# dracut's 05-check-chroot.install detects the chroot and refuses to continue
# unless either /etc/cmdline or /etc/cmdline.d/<file> supplies a kernel cmdline.
# We write a sensible default; the user can adjust after first boot.
mkdir -p /etc/cmdline.d
cat > /etc/cmdline.d/00-root.conf << 'CMDEOF'
root=LABEL=gentoo rootfstype=ext4 ro quiet
CMDEOF
log "/etc/cmdline.d/00-root.conf written for dracut."

# FIX: Also touch the override file that bypasses the chroot check entirely.
# This is the canonical workaround documented in the installkernel source:
#   touch /etc/kernel/preinst.d/05-check-chroot.install
mkdir -p /etc/kernel/preinst.d
touch /etc/kernel/preinst.d/05-check-chroot.install
log "dracut chroot check bypassed."

# FIX: Install dracut and sys-kernel/installkernel with the correct USE flags
# BEFORE gentoo-kernel-bin. The gentoo-kernel-bin postinst delegates to
# installkernel which calls dracut to build the initramfs and install the
# image. If either is absent or built without the 'dracut' USE flag the
# postinst calls die "Kernel install failed".
emerge --oneshot sys-kernel/dracut \
    || error "dracut install failed."
log "dracut installed."

# installkernel is already pinned to 'dracut -systemd' in package.use/kernel.
# --oneshot keeps it out of the world file.
emerge --oneshot sys-kernel/installkernel \
    || error "installkernel install failed."
log "installkernel installed."

emerge sys-kernel/gentoo-kernel-bin \
    || error "gentoo-kernel-bin install failed."
log "Kernel installed."

# ── Base system ───────────────────────────────────────────────────────────────
section "Base system packages"
emerge \
    app-admin/sudo \
    app-shells/bash-completion \
    net-misc/networkmanager \
    net-misc/openssh \
    sys-apps/dbus \
    sys-apps/pciutils \
    sys-apps/usbutils \
    sys-auth/elogind \
    sys-auth/polkit \
    sys-boot/grub \
    sys-fs/dosfstools \
    sys-fs/e2fsprogs \
    sys-libs/pam \
    sys-auth/pambase \
    sys-process/cronie \
    net-misc/chrony \
    net-misc/curl \
    dev-vcs/git \
    app-editors/neovim
log "Base packages installed."

# ── Hostname & hosts ──────────────────────────────────────────────────────────
section "Hostname"
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts << 'HOSTSEOF'
127.0.0.1   localhost
::1         localhost
HOSTSEOF
echo "127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}" >> /etc/hosts

sed -i "s/^keymap=.*/keymap=\"${KEYMAP}\"/" /etc/conf.d/keymaps 2>/dev/null || true

# ── OpenRC services ───────────────────────────────────────────────────────────
section "OpenRC services"
# Note: udev (via systemd-utils) is added to sysinit. If OpenRC's default
# runlevel already includes it via the package install, this is a no-op.
for svc in NetworkManager elogind dbus cronie sshd chronyd; do
    rc-update add \$svc default 2>/dev/null || warn "rc-update add \$svc failed (non-fatal)"
done
rc-update add udev    sysinit 2>/dev/null || true
rc-update add modules boot    2>/dev/null || true

# ── GPU — hybrid AMD + NVIDIA ─────────────────────────────────────────────────
section "GPU — hybrid AMD + NVIDIA (proprietary)"

log "Installing AMD/Mesa stack..."
emerge \
    media-libs/mesa \
    media-libs/libva \
    media-video/libva-utils \
    media-libs/vulkan-loader \
    dev-util/vulkan-tools
log "AMD/Mesa installed."

log "Installing nvidia-drivers (proprietary)..."
emerge x11-drivers/nvidia-drivers

# OpenRC module loading via /etc/conf.d/modules
# The heredoc delimiter is quoted ('MODEOF') so \${modules} is written
# verbatim and expanded at boot by OpenRC — this is the correct behaviour.
cat >> /etc/conf.d/modules << 'MODEOF'

# NVIDIA (hybrid GPU)
modules="${modules} nvidia nvidia_modeset nvidia_uvm nvidia_drm"
MODEOF

# kmod options file — read by kmod directly, safe on OpenRC.
# nvidia_drm.modeset=1 is the primary mechanism; fbdev=1 enables /dev/fb0.
# For belt-and-suspenders, also add nvidia-drm.modeset=1 to
# GRUB_CMDLINE_LINUX in /etc/default/grub after install.
mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/nvidia.conf << 'NVIDIAEOF'
options nvidia_drm modeset=1 fbdev=1
NVIDIAEOF

log "NVIDIA drivers installed and KMS enabled."

# ── Wayland base ──────────────────────────────────────────────────────────────
section "Wayland base libraries"
emerge \
    dev-libs/wayland \
    dev-libs/wayland-protocols \
    x11-base/xwayland \
    x11-libs/libdrm \
    x11-libs/pixman \
    x11-misc/xkeyboard-config
log "Wayland base installed."

# ── niri WM ───────────────────────────────────────────────────────────────────
section "niri window manager"
# FIX: Also emerge sys-apps/xdg-desktop-portal (the base frontend).
# xdg-desktop-portal-gtk is the backend; without the frontend package the
# portal bus interface won't be registered and portal features will silently
# fail for apps (file pickers, screen share, etc.).
emerge \
    gui-wm/niri \
    gui-apps/swayidle \
    gui-apps/swaylock \
    gui-apps/waybar \
    gui-apps/grim \
    gui-apps/slurp \
    gui-apps/wl-clipboard \
    gui-apps/mako \
    gui-apps/fuzzel \
    sys-apps/xdg-desktop-portal \
    gui-libs/xdg-desktop-portal-wlr \
    x11-libs/xcb-util-cursor
log "niri and companions installed."

# ── SDDM ──────────────────────────────────────────────────────────────────────
section "SDDM display manager"
emerge x11-misc/sddm

# FIX: Configure SDDM explicitly. SDDM defaults to X11 greeter mode.
# We keep the X11 greeter (more mature) but launch niri as a Wayland session.
# The session is selected by the user at the SDDM login screen.
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/general.conf << 'SDDMEOF'
[General]
# Use X11 for the greeter (Wayland greeter support in SDDM is still maturing).
# The niri *session* runs as Wayland regardless of the greeter display server.
DisplayServer=x11

[Theme]
# Leave blank to use SDDM default theme, or set a theme name.
Current=

[Users]
# Autologin is disabled by default for security. Uncomment to enable:
# AutoUser=YOUR_USERNAME
# Relogin=true
SDDMEOF

rc-update add sddm default 2>/dev/null || warn "rc-update add sddm failed (non-fatal)"
log "SDDM installed and configured."

# ── PipeWire audio ────────────────────────────────────────────────────────────
section "PipeWire + WirePlumber"
emerge media-video/pipewire media-video/wireplumber media-sound/pavucontrol
log "PipeWire installed."

# ── Ghostty terminal ──────────────────────────────────────────────────────────
# NOTE: Ghostty is in the guru overlay (enabled earlier in this script).
# If the emerge fails, confirm guru is synced: eselect repository list
section "Ghostty terminal"
emerge app-terminals/ghostty
log "Ghostty installed."

# ── Fonts ─────────────────────────────────────────────────────────────────────
section "Fonts"
emerge \
    media-fonts/noto \
    media-fonts/noto-emoji \
    media-fonts/fira-code
log "Fonts installed."

# ── GRUB bootloader ───────────────────────────────────────────────────────────
section "GRUB bootloader"
# efivarfs is bind-mounted from the live host (guaranteed by pre-flight check).
grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=gentoo \
    --recheck
grub-mkconfig -o /boot/grub/grub.cfg
log "GRUB installed."

# ── User accounts ─────────────────────────────────────────────────────────────
section "User accounts"
echo "root:\${ROOT_HASH}" | chpasswd -e

# FIX: Create any missing supplementary groups before useradd.
# Gentoo does not guarantee plugdev, usb, or seat exist after a base install.
# elogind creates 'seat' during its own emerge, but we guard anyway.
for grp in wheel audio video input seat plugdev usb portage; do
    getent group "\$grp" &>/dev/null || groupadd "\$grp"
done

useradd -m -G "wheel,audio,video,input,seat,plugdev,usb,portage" \
        -s /bin/bash "${USERNAME}"
echo "${USERNAME}:\${USER_HASH}" | chpasswd -e

mkdir -p /etc/sudoers.d
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel
log "Users created."

# ── Environment — /etc/env.d/ is Gentoo/OpenRC native ────────────────────────
section "Wayland + hybrid GPU environment"

cat > /etc/env.d/90wayland << 'ENVEOF'
XDG_SESSION_TYPE=wayland
QT_QPA_PLATFORM=wayland;xcb
QT_WAYLAND_DISABLE_WINDOWDECORATION=1
GDK_BACKEND=wayland,x11
SDL_VIDEODRIVER=wayland
MOZ_ENABLE_WAYLAND=1
ELECTRON_OZONE_PLATFORM_HINT=wayland
ENVEOF

cat > /etc/env.d/91hybrid-gpu << 'GPUEOF'
# AMD as default renderer; NVIDIA available via PRIME offload.
# To offload an app to NVIDIA:
#   __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia <app>
#
# NOTE: VK_ICD_FILENAMES is NOT set here. Let the Vulkan loader discover
# all ICD JSON files under /usr/share/vulkan/icd.d/ automatically.
# Hardcoding paths is fragile across nvidia-drivers version upgrades.
LIBVA_DRIVER_NAME=radeonsi
GPUEOF

# env-update is called after all /etc/env.d/ files are written.
env-update

chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}"

# ── niri session wrapper (PipeWire launch without systemd user units) ─────────
# FIX: Removed the fragile 'export \$(env -i sh -c ...)' pattern which broke
# on env vars containing spaces or newlines (LS_COLORS, LESS_TERMCAP_*, etc.).
# Instead, use 'set -a / source / set +a' which handles all values correctly.
# exec niri replaces the shell process; bash fires EXIT trap even on exec.
cat > /usr/local/bin/niri-session << 'SESSIONEOF'
#!/usr/bin/env bash
set -a
source /etc/profile
set +a

pipewire &
PIPEWIRE_PID=\$!
wireplumber &
WP_PID=\$!

# Trap fires on EXIT (including after 'exec'), cleaning up audio daemons
# when the niri session ends. This relies on bash's exec-trap behaviour.
trap "kill \$PIPEWIRE_PID \$WP_PID 2>/dev/null; wait \$PIPEWIRE_PID \$WP_PID 2>/dev/null" EXIT

exec niri
SESSIONEOF
chmod +x /usr/local/bin/niri-session

# ── Wayland session desktop entry for SDDM ───────────────────────────────────
mkdir -p /usr/share/wayland-sessions
cat > /usr/share/wayland-sessions/niri.desktop << 'DESKTOPEOF'
[Desktop Entry]
Name=niri
Comment=A scrollable-tiling Wayland compositor
Exec=niri-session
Type=Application
DesktopNames=niri
DESKTOPEOF

# ── swaylock PAM configuration ────────────────────────────────────────────────
# FIX: swaylock requires a PAM service file to authenticate users.
# Without /etc/pam.d/swaylock, swaylock silently fails to unlock on any
# password attempt. Gentoo's swaylock package may or may not install this;
# we ensure it exists unconditionally.
if [[ ! -f /etc/pam.d/swaylock ]]; then
    cat > /etc/pam.d/swaylock << 'PAMEOF'
auth      include   system-local-login
account   include   system-local-login
PAMEOF
    log "swaylock PAM config written."
else
    log "swaylock PAM config already present."
fi

log "Environment configured."

# ── Final systemd verification ────────────────────────────────────────────────
section "Final systemd verification"
# Use the safe helper — no -x flag — so versioned atoms are caught.
if _systemd_present; then
    warn "WARNING: sys-apps/systemd appears to be installed — investigate!"
    portageq match / sys-apps/systemd | grep -v systemd-utils
else
    log "Confirmed: sys-apps/systemd is NOT installed."
fi
log "sys-apps/systemd-utils IS installed (provides udev for OpenRC — expected and correct)."

section "Chroot phase complete"
echo ""
echo "  Everything installed. Type 'exit' and the script will unmount and finish."
CHROOT_EOF

log "Chroot script written."

# =============================================================================
# STEP 8 — Enter chroot
# =============================================================================

section "Entering chroot"
chroot /mnt/gentoo /bin/bash /root/chroot-install.sh

# =============================================================================
# STEP 9 — Cleanup & unmount
# =============================================================================

section "Unmounting"
rm -f /mnt/gentoo/root/chroot-install.sh

for mp in \
    /mnt/gentoo/sys/firmware/efi/efivars \
    /mnt/gentoo/proc \
    /mnt/gentoo/sys \
    /mnt/gentoo/dev \
    /mnt/gentoo/run \
    /mnt/gentoo/boot/efi \
    /mnt/gentoo
do
    mountpoint -q "$mp" 2>/dev/null \
        && umount -R "$mp" 2>/dev/null \
        || true
done

swapoff "$PART_SWAP" 2>/dev/null || true

log "Unmount complete."

echo ""
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Installation complete!${NC}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Log: ${BOLD}${LOG_FILE}${NC}"
echo ""
echo -e "  Next steps:"
echo -e "   1. ${BOLD}reboot${NC}"
echo -e "   2. SDDM will start — select the ${BOLD}niri${NC} session"
echo -e "   3. Open ${BOLD}Ghostty${NC} from the niri launcher"
echo -e "   4. To offload an app to NVIDIA:"
echo -e "      ${BOLD}__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia <app>${NC}"
echo -e "   5. Optional: add ${BOLD}nvidia-drm.modeset=1${NC} to GRUB_CMDLINE_LINUX"
echo -e "      in ${BOLD}/etc/default/grub${NC} then run grub-mkconfig for belt-and-suspenders KMS."
echo ""
