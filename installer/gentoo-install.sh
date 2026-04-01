#!/usr/bin/env bash
# =============================================================================
# Gentoo Linux — Base OpenRC + Wayland + niri WM + SDDM + Ghostty
# Follows the Gentoo Handbook installation steps.
#
# Assumptions:
#   • x86_64 (amd64) system booted in UEFI mode
#   • Target disk:  /dev/nvme0n1  (edit DISK below)
#   • AMD GPU       (edit GPU_VENDOR / VIDEO_CARDS below)
#   • Internet available on the live environment
#
# Usage (as root on the live ISO):
#   bash gentoo-install.sh
#
# Log:  /tmp/gentoo-install.log
# =============================================================================

set -eo pipefail
IFS=$'\n\t'

# =============================================================================
# ── EDIT THESE ────────────────────────────────────────────────────────────────
# =============================================================================

DISK="/dev/nvme0n1"       # target block device
HOSTNAME="gentoo"
USERNAME="user"
TIMEZONE="America/New_York"
LOCALE="en_US.UTF-8"
KEYMAP="us"

# GPU: amd | intel | nvidia
GPU_VENDOR="amd"
VIDEO_CARDS="amdgpu radeonsi nvidia"   # passed to VIDEO_CARDS in make.conf

# =============================================================================
# ── DERIVED / FIXED ───────────────────────────────────────────────────────────
# =============================================================================

NCPU=$(nproc)
LOG_FILE="/tmp/gentoo-install.log"

# Partition helpers
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

# =============================================================================
# STEP 1 — Pre-flight
# =============================================================================

section "Pre-flight checks"

[[ $EUID -ne 0 ]]   && error "Must run as root."
[[ ! -b "$DISK" ]]  && error "Disk $DISK not found."

for t in wipefs sgdisk mkfs.fat mkswap wget gpg openssl chroot; do
    command -v "$t" &>/dev/null || error "Missing tool: $t"
done

ping -c2 -W5 gentoo.org &>/dev/null || error "No internet connection."
log "Network OK"

# Sync clock (handbook step)
timedatectl set-ntp true &>/dev/null && sleep 2 || warn "Clock sync failed — continuing"

# Collect passwords
echo
read -rsp "  Root password: "           rp1 </dev/tty; echo
read -rsp "  Confirm root password: "   rp2 </dev/tty; echo
[[ "$rp1" != "$rp2" ]] && error "Root passwords do not match."

read -rsp "  Password for ${USERNAME}: "        up1 </dev/tty; echo
read -rsp "  Confirm password for ${USERNAME}: " up2 </dev/tty; echo
[[ "$up1" != "$up2" ]] && error "User passwords do not match."

ROOT_HASH=$(openssl passwd -6 "$rp1")
USER_HASH=$(openssl passwd -6 "$up1")
unset rp1 rp2 up1 up2

log "Pre-flight OK  (CPUs: ${NCPU})"

# =============================================================================
# STEP 2 — Partition  (handbook: GPT + EFI + swap + root)
# =============================================================================

section "Partitioning ${DISK}"

warn "ALL DATA ON ${DISK} WILL BE DESTROYED"
read -rp "  Type 'yes' to confirm: " _confirm </dev/tty
[[ "$_confirm" != "yes" ]] && error "Aborted."

wipefs -a "$DISK"
sgdisk --zap-all "$DISK"

sgdisk -n 1:0:+1G   -t 1:ef00 -c 1:"EFI"  "$DISK"
sgdisk -n 2:0:+8G   -t 2:8200 -c 2:"swap" "$DISK"
sgdisk -n 3:0:0     -t 3:8300 -c 3:"root" "$DISK"

partprobe "$DISK"; udevadm settle

mkfs.fat -F32 -n "EFI"   "$PART_EFI"
mkswap   -L   "swap"     "$PART_SWAP"; swapon "$PART_SWAP"
mkfs.ext4 -L  "gentoo" -O dir_index,extent,sparse_super2 "$PART_ROOT"

mkdir -p /mnt/gentoo
mount -o noatime "$PART_ROOT" /mnt/gentoo
mkdir -p /mnt/gentoo/boot/efi
mount "$PART_EFI" /mnt/gentoo/boot/efi

log "Partitions mounted."

# =============================================================================
# STEP 3 — Stage3 tarball  (handbook: download latest openrc stage3)
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
log "Downloading: ${TARBALL_URL}"
wget --tries=3 --show-progress "$TARBALL_URL" -O /mnt/gentoo/stage3.tar.xz \
    || error "stage3 download failed."

log "Extracting stage3..."
tar xpf /mnt/gentoo/stage3.tar.xz \
    --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo
rm -f /mnt/gentoo/stage3.tar.xz

log "Stage3 installed."

# =============================================================================
# STEP 4 — Portage configuration  (handbook: make.conf + repos.conf)
# =============================================================================

section "Portage configuration"

mkdir -p /mnt/gentoo/etc/portage/{package.use,package.accept_keywords,package.license,repos.conf}

cat > /mnt/gentoo/etc/portage/make.conf << EOF
# make.conf — generated $(date -u '+%Y-%m-%dT%H:%M:%SZ')

COMMON_FLAGS="-O2 -pipe -march=native"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"

MAKEOPTS="-j${NCPU} -l${NCPU}"
EMERGE_DEFAULT_OPTS="--jobs=${NCPU} --load-average=${NCPU} --with-bdeps=y --keep-going --verbose"

# Accept testing keywords — required for niri and some Wayland libs
ACCEPT_KEYWORDS="~amd64"
ACCEPT_LICENSE="-* @FREE @BINARY-REDISTRIBUTABLE"

USE="wayland -systemd -kde -X -gnome -kde udev dbus policykit elogind"

VIDEO_CARDS="${VIDEO_CARDS}"
INPUT_DEVICES="libinput"

L10N="en en-US"

GENTOO_MIRRORS="https://distfiles.gentoo.org"
DISTDIR="/var/cache/distfiles"
PKGDIR="/var/cache/binpkgs"
PORTDIR="/var/db/repos/gentoo"
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

# ── package.use ───────────────────────────────────────────────────────────────

# Kernel: dracut-based unified kernel image
cat > /mnt/gentoo/etc/portage/package.use/kernel << 'EOF'
sys-kernel/installkernel        dracut
sys-kernel/gentoo-kernel-bin    initramfs
virtual/dist-kernel             initramfs
EOF

# PAM / elogind
cat > /mnt/gentoo/etc/portage/package.use/system << 'EOF'
>=sys-auth/pambase-20251104-r1  elogind
>=media-libs/freetype-2.14.3    harfbuzz
EOF

# Wayland / wlroots
cat > /mnt/gentoo/etc/portage/package.use/wayland << 'EOF'
gui-libs/wlroots   drm gles2 vulkan xwayland
dev-libs/wayland   -doc
EOF

# GPU — AMD
case "$GPU_VENDOR" in
    amd)
        cat > /mnt/gentoo/etc/portage/package.use/gpu << 'EOF'
media-libs/mesa  vulkan vulkan-overlay video_cards_amdgpu video_cards_radeonsi
EOF
        ;;
    intel)
        cat > /mnt/gentoo/etc/portage/package.use/gpu << 'EOF'
media-libs/mesa  vulkan video_cards_intel video_cards_iris
EOF
        ;;
    nvidia)
        cat > /mnt/gentoo/etc/portage/package.use/gpu << 'EOF'
x11-drivers/nvidia-drivers  wayland
media-libs/mesa             -nvidia
EOF
        echo "x11-drivers/nvidia-drivers  ~amd64" \
            >> /mnt/gentoo/etc/portage/package.accept_keywords/desktop
        echo "x11-drivers/nvidia-drivers  NVIDIA-r2" \
            >> /mnt/gentoo/etc/portage/package.license/nvidia
        ;;
esac

# PipeWire (sddm uses it for the greeter session)
cat > /mnt/gentoo/etc/portage/package.use/audio << 'EOF'
media-video/pipewire    sound-server jack-sdk
media-sound/wireplumber -systemd
EOF

# niri and its Wayland dependencies need ~amd64
cat > /mnt/gentoo/etc/portage/package.accept_keywords/desktop << 'EOF'
gui-wm/niri                ~amd64
dev-libs/wayland-protocols ~amd64
EOF

log "Portage config written."

# =============================================================================
# STEP 5 — fstab
# =============================================================================

section "Generating /etc/fstab"

EFI_UUID=$(blkid -s UUID -o value "$PART_EFI")
ROOT_UUID=$(blkid -s UUID -o value "$PART_ROOT")
SWAP_UUID=$(blkid -s UUID -o value "$PART_SWAP")

cat > /mnt/gentoo/etc/fstab << EOF
# <fs>                                  <mp>        <type>  <opts>              <dump> <pass>
UUID=${ROOT_UUID}  /           ext4    defaults,noatime    0 1
UUID=${EFI_UUID}   /boot/efi   vfat    umask=0077          0 2
UUID=${SWAP_UUID}  none        swap    sw                  0 0
tmpfs                                  /tmp        tmpfs   defaults,nosuid,nodev,size=4G  0 0
EOF

log "fstab written."

# =============================================================================
# STEP 6 — Chroot environment  (handbook: bind-mount proc/sys/dev)
# =============================================================================

section "Preparing chroot"

cp --dereference /etc/resolv.conf /mnt/gentoo/etc/

mount --types proc  /proc /mnt/gentoo/proc
mount --rbind       /sys  /mnt/gentoo/sys;  mount --make-rslave /mnt/gentoo/sys
mount --rbind       /dev  /mnt/gentoo/dev;  mount --make-rslave /mnt/gentoo/dev
mount --bind        /run  /mnt/gentoo/run;  mount --make-slave  /mnt/gentoo/run

[[ -d /sys/firmware/efi/efivars ]] && \
    mount --bind /sys/firmware/efi/efivars /mnt/gentoo/sys/firmware/efi/efivars

log "Chroot ready."

# =============================================================================
# STEP 7 — Write and run the chroot script
# =============================================================================

section "Writing chroot script"
install -m 700 /dev/null /mnt/gentoo/root/chroot-install.sh

# Variables expanded HERE (host side) are written verbatim into the script.
# Variables that must be evaluated at chroot runtime are escaped (\$).
cat > /mnt/gentoo/root/chroot-install.sh << CHROOT_EOF
#!/usr/bin/env bash
set -eo pipefail

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

set +u; source /etc/profile; set -u
export PS1="(chroot) \${PS1:-}"

# ── Portage tree ──────────────────────────────────────────────────────────────
section "Syncing Portage tree (emerge-webrsync)"
emerge-webrsync || error "emerge-webrsync failed."

# ── Profile — handbook recommends amd64/23.0/desktop/openrc ──────────────────
section "Selecting profile"
eselect profile list
echo ""
read -rp "  Enter profile number (default: amd64/23.0/desktop/openrc): " PROFILE_NUM </dev/tty
if [[ -n "\$PROFILE_NUM" ]]; then
    eselect profile set "\$PROFILE_NUM" || warn "Profile set failed."
else
    # Try to set the desktop/openrc profile automatically
    PROFILE_NUM=\$(eselect profile list | grep 'desktop/openrc' | grep -v 'plasma\|gnome\|systemd' | head -1 | awk '{print \$1}' | tr -d '[]')
    [[ -n "\$PROFILE_NUM" ]] \
        && { eselect profile set "\$PROFILE_NUM"; log "Set profile \${PROFILE_NUM}."; } \
        || warn "Could not auto-select profile — set manually."
fi

# ── @world update after profile change (handbook step) ───────────────────────
section "Updating @world"
emerge --update --newuse --deep @world || warn "@world update had non-fatal issues."

# ── Timezone (handbook step) ──────────────────────────────────────────────────
section "Timezone & Locale"
echo "${TIMEZONE}" > /etc/timezone
emerge --config sys-libs/timezone-data
echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
LOC=\$(locale -a | grep -i "\$(echo "${LOCALE}" | tr '[:upper:]' '[:lower:]' | sed 's/utf-8/utf8/')" | head -1)
[[ -n "\$LOC" ]] && eselect locale set "\$LOC" || warn "Set locale manually with: eselect locale set"
set +u; env-update && source /etc/profile; set -u

# ── Linux firmware + CPU microcode ────────────────────────────────────────────
section "Firmware"
emerge sys-kernel/linux-firmware sys-firmware/sof-firmware
log "Firmware installed."

# ── Kernel (dist-kernel — handbook fast path) ─────────────────────────────────
section "Kernel (gentoo-kernel-bin)"
# installkernel + dracut handle initramfs generation automatically.
emerge sys-kernel/gentoo-kernel-bin
log "Kernel installed."

# ── Base system (handbook packages) ──────────────────────────────────────────
section "Base system packages"
emerge \
    app-admin/sudo \
    app-shells/bash-completion \
    net-misc/networkmanager \
    sys-apps/dbus \
    sys-apps/pciutils \
    sys-apps/usbutils \
    sys-auth/elogind \
    sys-boot/grub \
    sys-fs/dosfstools \
    sys-fs/e2fsprogs \
    sys-libs/pam \
    sys-auth/pambase \
    sys-process/cronie \
    net-misc/curl \
    dev-vcs/git \
    app-editors/neovim

log "Base packages installed."

# ── Hostname & /etc/hosts (handbook step) ────────────────────────────────────
section "Hostname"
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts << 'EOF'
127.0.0.1   localhost
::1         localhost
EOF
echo "127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}" >> /etc/hosts

# ── Keymap ────────────────────────────────────────────────────────────────────
sed -i 's/^keymap=.*/keymap="${KEYMAP}"/' /etc/conf.d/keymaps 2>/dev/null || true

# ── OpenRC services ───────────────────────────────────────────────────────────
section "OpenRC services"
for svc in NetworkManager elogind dbus udev cronie; do
    rc-update add \$svc default 2>/dev/null || warn "rc-update add \$svc failed (non-fatal)"
done
rc-update add udev sysinit 2>/dev/null || true

# ── GPU drivers ───────────────────────────────────────────────────────────────
section "GPU / Mesa"
emerge media-libs/mesa media-libs/libva
case "${GPU_VENDOR}" in
    amd)
        emerge media-libs/vulkan-loader
        ;;
    intel)
        emerge media-libs/intel-media-driver media-libs/vulkan-loader
        ;;
    nvidia)
        emerge x11-drivers/nvidia-drivers
        rc-update add modules boot 2>/dev/null || true
        echo "nvidia" > /etc/modules-load.d/nvidia.conf
        ;;
esac
log "GPU drivers installed."

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
    gui-libs/xdg-desktop-portal-gtk \
    x11-libs/xcb-util-cursor
log "niri and companions installed."

# ── SDDM ──────────────────────────────────────────────────────────────────────
section "SDDM display manager"
emerge x11-misc/sddm
rc-update add sddm default 2>/dev/null || warn "rc-update add sddm failed (non-fatal)"
log "SDDM installed and enabled."

# ── PipeWire audio ────────────────────────────────────────────────────────────
section "PipeWire + WirePlumber"
emerge media-video/pipewire media-sound/wireplumber media-sound/pavucontrol
# PipeWire is started as a user session service; no OpenRC daemon needed.
log "PipeWire installed."

# ── Ghostty terminal ──────────────────────────────────────────────────────────
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

# ── GRUB (handbook step) ──────────────────────────────────────────────────────
section "GRUB bootloader"
# make.conf already sets GRUB_PLATFORMS="efi-64"
grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=gentoo \
    --recheck
grub-mkconfig -o /boot/grub/grub.cfg
log "GRUB installed."

# ── Users (handbook step) ─────────────────────────────────────────────────────
section "User accounts"
echo "root:${ROOT_HASH}" | chpasswd -e

useradd -m -G "wheel,audio,video,input,seat,plugdev,usb,portage" \
        -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${USER_HASH}" | chpasswd -e

install -m 440 /dev/null /etc/sudoers.d/wheel
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
log "Users created."

# ── Wayland environment variables ────────────────────────────────────────────
section "Wayland environment"
USER_HOME="/home/${USERNAME}"
mkdir -p "\${USER_HOME}/.config/environment.d"
cat > "\${USER_HOME}/.config/environment.d/wayland.conf" << 'EOF'
XDG_SESSION_TYPE=wayland
QT_QPA_PLATFORM=wayland;xcb
QT_WAYLAND_DISABLE_WINDOWDECORATION=1
GDK_BACKEND=wayland,x11
SDL_VIDEODRIVER=wayland
MOZ_ENABLE_WAYLAND=1
ELECTRON_OZONE_PLATFORM_HINT=wayland
EOF

# SDDM session entry for niri (in case the package doesn't ship one)
if [[ ! -f /usr/share/wayland-sessions/niri.desktop ]]; then
    mkdir -p /usr/share/wayland-sessions
    cat > /usr/share/wayland-sessions/niri.desktop << 'EOF'
[Desktop Entry]
Name=niri
Comment=A scrollable-tiling Wayland compositor
Exec=niri-session
Type=Application
EOF
fi

chown -R "${USERNAME}:${USERNAME}" "\${USER_HOME}"
log "User environment configured."

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
# STEP 9 — Cleanup & unmount  (handbook step)
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
echo ""
