#!/usr/bin/env bash
# =============================================================================
# Gentoo Linux Installation Script  —  2025/2026
# Supports: OpenRC / systemd  ·  Wayland / X11 / both
#           Any WM/DE  ·  btrfs/ext4/xfs/f2fs  ·  LUKS2  ·  Secure Boot
#
# Usage:
#   bash gentoo-install.sh                          # interactive config path
#   bash gentoo-install.sh --config gentoo-install.conf
#
# Generate a config first with:
#   bash gentoo-config.sh
#
# Logs are written to /tmp/gentoo-install-<timestamp>.log
# Follow live with: tail -f /tmp/gentoo-install-<timestamp>.log
# =============================================================================

set -eo pipefail
IFS=$'\n\t'

# =============================================================================
# LOGGING SETUP  — must come before everything else
# =============================================================================

LOG_FILE="/tmp/gentoo-install-$(date +%Y%m%d-%H%M%S).log"
STEP_NUM=0
STEP_TOTAL=0   # filled in by main() once we know what's running

exec 3>&1 4>&2
exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1

_log_raw() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

log()     { echo -e "${GREEN}[+]${NC} $*";          _log_raw "[INFO]  $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*";          _log_raw "[WARN]  $*"; }
error()   { echo -e "${RED}[✗]${NC} $*" >&2;        _log_raw "[ERROR] $*"; exit 1; }
debug()   { echo -e "${CYAN}[…]${NC} $*";            _log_raw "[DEBUG] $*"; }

section() {
    STEP_NUM=$((STEP_NUM + 1))
    local title="  Step ${STEP_NUM}: $*"
    echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}${title}${NC}"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════════════${NC}\n"
    _log_raw "====== STEP ${STEP_NUM}: $* ======"
}

_install_start_time=$SECONDS
_on_exit() {
    local code=$?
    local elapsed=$(( SECONDS - _install_start_time ))
    local mins=$(( elapsed / 60 ))
    local secs=$(( elapsed % 60 ))
    echo "" >> "$LOG_FILE"
    if [[ $code -eq 0 ]]; then
        _log_raw "====== INSTALL SUCCEEDED in ${mins}m ${secs}s (exit 0) ======"
    else
        _log_raw "====== INSTALL FAILED after ${mins}m ${secs}s (exit ${code}) ======"
        echo -e "\n${RED}${BOLD}[✗] Installation failed. Check the log for details:${NC}"
        echo -e "    ${BOLD}${LOG_FILE}${NC}"
        echo -e "    Last 20 lines:\n"
        tail -20 "$LOG_FILE" >&3
    fi
}
trap _on_exit EXIT

# =============================================================================
# COLORS
# =============================================================================

RED='\033[0;31m';  GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m';   BOLD='\033[1m'; NC='\033[0m'

# =============================================================================
# DEFAULTS
# =============================================================================

DISK="/dev/nvme0n1"
EFI_SIZE="1"
SWAP_SIZE="8"
FS_TYPE="btrfs"
HOSTNAME="gentoo"
USERNAME="user"
TIMEZONE="America/New_York"
LOCALE="en_US.UTF-8"
KEYMAP="us"
INIT_SYSTEM="openrc"
ACCEPT_KEYWORDS="amd64"
CPU_VENDOR="amd"
GPU_VENDOR="amd"
VIDEO_CARDS="amdgpu radeonsi"
KERNEL_TYPE="dist"
KERNEL_CONFIG="defconfig"
DISPLAY_SERVER="wayland"
DESKTOP_ENV="none"
DISPLAY_MANAGER="none"
USE_FLAGS="wayland -X -gnome -kde -plasma udev dbus policykit"
MAKEOPTS="-j$(nproc) -l$(nproc)"
STAGE3_VARIANT="openrc"
ENABLE_LUKS="no"
ENABLE_BTRFS_SNAPPER="no"
ENABLE_PIPEWIRE="yes"
ENABLE_BLUETOOTH="no"
ENABLE_PRINTING="no"
ENABLE_FLATPAK="no"
ENABLE_LIBVIRT="no"
ENABLE_DOCKER="no"
ENABLE_SECURE_BOOT="no"
SECURE_BOOT_MICROSOFT_KEYS="no"
EXTRA_PACKAGES=""

PART_EFI=""
PART_SWAP=""
PART_ROOT=""
ROOT_HASH=""
USER_HASH=""
LUKS_NAME="cryptroot"

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

CONFIG_FILE=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config|-c)
                [[ -z "${2:-}" ]] && error "--config requires a file argument."
                CONFIG_FILE="$2"; shift 2 ;;
            --help|-h)
                echo "Usage: $0 [--config FILE]"
                echo "  Run gentoo-config.sh first to generate FILE."
                exit 0 ;;
            *)
                error "Unknown argument: $1" ;;
        esac
    done
}

load_config() {
    if [[ -z "$CONFIG_FILE" ]]; then
        if [[ -f "gentoo-install.conf" ]]; then
            warn "No --config specified; using gentoo-install.conf in current directory."
            CONFIG_FILE="gentoo-install.conf"
        else
            error "No config file found. Run gentoo-config.sh to generate one, or pass --config FILE."
        fi
    fi
    [[ ! -f "$CONFIG_FILE" ]] && error "Config file not found: $CONFIG_FILE"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    log "Loaded config: $CONFIG_FILE"

    _log_raw "--- Resolved configuration ---"
    _log_raw "DISK=${DISK}  FS=${FS_TYPE}  LUKS=${ENABLE_LUKS}  SWAP=${SWAP_SIZE}G"
    _log_raw "HOSTNAME=${HOSTNAME}  USER=${USERNAME}"
    _log_raw "INIT=${INIT_SYSTEM}  KERNEL=${KERNEL_TYPE}  DISPLAY=${DISPLAY_SERVER}  DE=${DESKTOP_ENV}"
    _log_raw "CPU=${CPU_VENDOR}  GPU=${GPU_VENDOR}  VIDEO_CARDS=${VIDEO_CARDS}"
    _log_raw "KEYWORDS=${ACCEPT_KEYWORDS}  STAGE3=${STAGE3_VARIANT}"
    _log_raw "PIPEWIRE=${ENABLE_PIPEWIRE}  BT=${ENABLE_BLUETOOTH}  PRINT=${ENABLE_PRINTING}"
    _log_raw "FLATPAK=${ENABLE_FLATPAK}  LIBVIRT=${ENABLE_LIBVIRT}  DOCKER=${ENABLE_DOCKER}"
    _log_raw "SECURE_BOOT=${ENABLE_SECURE_BOOT}  MS_KEYS=${SECURE_BOOT_MICROSOFT_KEYS}"
    _log_raw "EXTRA_PACKAGES=${EXTRA_PACKAGES:-<none>}"
    _log_raw "------------------------------"
}

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

preflight_checks() {
    section "Pre-flight Checks"

    debug "Running as UID ${EUID}"
    [[ $EUID -ne 0 ]] && error "Must be run as root."

    debug "Checking disk: ${DISK}"
    [[ ! -b "$DISK" ]] && error "Disk $DISK not found. Verify DISK in config."
    _log_raw "Disk ${DISK}: $(lsblk -dno SIZE,MODEL "$DISK" 2>/dev/null || echo 'info unavailable')"

    debug "Checking required tools..."
    local tools=(wipefs sgdisk mkfs.fat mkswap wget gpg openssl chroot)
    for t in "${tools[@]}"; do
        if command -v "$t" &>/dev/null; then
            _log_raw "  tool ok: ${t} ($(command -v "$t"))"
        else
            error "Required tool not found: $t"
        fi
    done

    if [[ "$ENABLE_LUKS" == "yes" ]]; then
        debug "Checking cryptsetup for LUKS..."
        command -v cryptsetup &>/dev/null || error "cryptsetup not found (required for LUKS)."
        _log_raw "  cryptsetup: $(cryptsetup --version)"
    fi

    if [[ "$ENABLE_SECURE_BOOT" == "yes" ]]; then
        command -v sbctl &>/dev/null \
            || warn "sbctl not found — Secure Boot setup will be manual post-install."
    fi

    echo ""
    read -rsp "  Enter root password: "    rp1 </dev/tty; echo
    read -rsp "  Confirm root password: "  rp2 </dev/tty; echo
    [[ "$rp1" != "$rp2" ]] && error "Root passwords do not match."

    read -rsp "  Enter password for ${USERNAME}: "   up1 </dev/tty; echo
    read -rsp "  Confirm password for ${USERNAME}: " up2 </dev/tty; echo
    [[ "$up1" != "$up2" ]] && error "User passwords do not match."

    ROOT_HASH=$(openssl passwd -6 "$rp1")
    USER_HASH=$(openssl passwd -6 "$up1")
    unset rp1 rp2 up1 up2
    _log_raw "Passwords hashed (SHA-512). Plaintext not stored."

    if [[ "$ENABLE_LUKS" == "yes" ]]; then
        echo ""
        read -rsp "  Enter LUKS passphrase: "    lp1 </dev/tty; echo
        read -rsp "  Confirm LUKS passphrase: "  lp2 </dev/tty; echo
        [[ "$lp1" != "$lp2" ]] && error "LUKS passphrases do not match."
        LUKS_PASSPHRASE="$lp1"
        unset lp1 lp2
        _log_raw "LUKS passphrase accepted (not logged)."
    fi

    debug "Checking internet connectivity..."
    if ping -c 2 -W 5 gentoo.org &>/dev/null; then
        log "Internet connectivity: OK"
        _log_raw "  ping gentoo.org: OK"
    else
        error "No internet connection."
    fi

    debug "Syncing system clock..."
    if chronyd -q &>/dev/null; then
        _log_raw "Clock synced via chronyd"
    elif ntpd -gq &>/dev/null; then
        _log_raw "Clock synced via ntpd"
    else
        warn "Could not sync clock automatically."
    fi

    log "Pre-flight checks passed."
}

# =============================================================================
# PARTITION HELPERS
# =============================================================================

_part_suffix() {
    if [[ "$DISK" == *"nvme"* || "$DISK" == *"mmcblk"* ]]; then
        echo "${DISK}p${1}"
    else
        echo "${DISK}${1}"
    fi
}

# =============================================================================
# PARTITIONING
# =============================================================================

partition_disk() {
    section "Partitioning  —  ${DISK}  (${FS_TYPE}  LUKS: ${ENABLE_LUKS})"

    warn "This will DESTROY all data on $DISK"
    local confirm
    read -rp "  Type 'yes' to confirm: " confirm </dev/tty
    [[ "$confirm" != "yes" ]] && error "Aborted by user."
    _log_raw "User confirmed destructive wipe of ${DISK}"

    log "Wiping disk signatures..."
    wipefs -a "$DISK"
    sgdisk --zap-all "$DISK"
    _log_raw "Disk wiped: ${DISK}"

    local part_num=1
    log "Creating GPT partition layout..."

    sgdisk -n ${part_num}:0:+${EFI_SIZE}G -t ${part_num}:ef00 -c ${part_num}:"EFI" "$DISK"
    PART_EFI="$(_part_suffix $part_num)"
    _log_raw "  Part ${part_num}: EFI  ${EFI_SIZE}G  → ${PART_EFI}"
    part_num=$((part_num + 1))

    if [[ "$SWAP_SIZE" != "0" ]]; then
        sgdisk -n ${part_num}:0:+${SWAP_SIZE}G -t ${part_num}:8200 -c ${part_num}:"swap" "$DISK"
        PART_SWAP="$(_part_suffix $part_num)"
        _log_raw "  Part ${part_num}: swap ${SWAP_SIZE}G  → ${PART_SWAP}"
        part_num=$((part_num + 1))
    fi

    sgdisk -n ${part_num}:0:0 -t ${part_num}:8300 -c ${part_num}:"root" "$DISK"
    PART_ROOT="$(_part_suffix $part_num)"
    _log_raw "  Part ${part_num}: root (remainder) → ${PART_ROOT}"

    debug "Waiting for kernel to re-read partition table..."
    partprobe "$DISK"
    udevadm settle
    _log_raw "partprobe + udevadm settle complete"

    log "Formatting EFI partition (FAT32)..."
    mkfs.fat -F32 -n "EFI" "$PART_EFI"
    _log_raw "EFI formatted: ${PART_EFI}"

    if [[ -n "$PART_SWAP" ]]; then
        log "Formatting swap..."
        mkswap -L "swap" "$PART_SWAP"
        swapon "$PART_SWAP"
        _log_raw "Swap formatted and activated: ${PART_SWAP}"
    fi

    local ROOT_DEVICE="$PART_ROOT"
    if [[ "$ENABLE_LUKS" == "yes" ]]; then
        log "Setting up LUKS2 container on ${PART_ROOT}..."
        cryptsetup luksFormat --type luks2 \
            --cipher aes-xts-plain64 --key-size 512 \
            --hash sha512 --pbkdf argon2id \
            "$PART_ROOT" - < <(printf '%s' "$LUKS_PASSPHRASE")
        cryptsetup open "$PART_ROOT" "$LUKS_NAME" \
            < <(printf '%s' "$LUKS_PASSPHRASE")
        unset LUKS_PASSPHRASE
        ROOT_DEVICE="/dev/mapper/${LUKS_NAME}"
        _log_raw "LUKS2 container opened: ${ROOT_DEVICE}"
    fi

    log "Formatting root partition (${FS_TYPE})..."
    mkdir -p /mnt/gentoo
    case "$FS_TYPE" in
        btrfs)
            mkfs.btrfs -L "gentoo" -f "$ROOT_DEVICE"
            _log_raw "btrfs formatted: ${ROOT_DEVICE}"

            debug "Creating btrfs subvolumes..."
            mount "$ROOT_DEVICE" /mnt/gentoo
            for sv in @ @home @snapshots @var_log; do
                btrfs subvolume create "/mnt/gentoo/${sv}"
                _log_raw "  subvolume created: ${sv}"
            done
            umount /mnt/gentoo

            local btrfs_opts="noatime,compress=zstd:1,space_cache=v2"
            debug "Mounting btrfs subvolumes..."
            mount -o "${btrfs_opts},subvol=@"          "$ROOT_DEVICE" /mnt/gentoo
            mkdir -p /mnt/gentoo/{home,.snapshots,var/log}
            mount -o "${btrfs_opts},subvol=@home"      "$ROOT_DEVICE" /mnt/gentoo/home
            mount -o "${btrfs_opts},subvol=@snapshots" "$ROOT_DEVICE" /mnt/gentoo/.snapshots
            mount -o "${btrfs_opts},subvol=@var_log"   "$ROOT_DEVICE" /mnt/gentoo/var/log
            _log_raw "btrfs subvolumes mounted (opts: ${btrfs_opts})"
            ;;
        ext4)
            mkfs.ext4 -L "gentoo" -O dir_index,extent,sparse_super2 "$ROOT_DEVICE"
            mount "$ROOT_DEVICE" /mnt/gentoo
            _log_raw "ext4 formatted and mounted: ${ROOT_DEVICE}"
            ;;
        xfs)
            mkfs.xfs -L "gentoo" -f "$ROOT_DEVICE"
            mount "$ROOT_DEVICE" /mnt/gentoo
            _log_raw "xfs formatted and mounted: ${ROOT_DEVICE}"
            ;;
        f2fs)
            mkfs.f2fs -l "gentoo" -O extra_attr,inode_checksum,sb_checksum "$ROOT_DEVICE"
            mount -o noatime "$ROOT_DEVICE" /mnt/gentoo
            _log_raw "f2fs formatted and mounted: ${ROOT_DEVICE}"
            ;;
    esac

    mkdir -p /mnt/gentoo/boot/efi
    mount "$PART_EFI" /mnt/gentoo/boot/efi
    _log_raw "EFI mounted: ${PART_EFI} → /mnt/gentoo/boot/efi"

    log "Partition layout complete."
    _log_raw "Final mount state:"; findmnt --target /mnt/gentoo -R 2>/dev/null >> "$LOG_FILE" || true
}

# =============================================================================
# FSTAB
# =============================================================================

write_fstab() {
    section "Generating /etc/fstab"

    local root_source efi_uuid
    efi_uuid=$(blkid -s UUID -o value "$PART_EFI")
    _log_raw "EFI UUID: ${efi_uuid}"

    if [[ "$ENABLE_LUKS" == "yes" ]]; then
        root_source="/dev/mapper/${LUKS_NAME}"
        local luks_uuid
        luks_uuid=$(blkid -s UUID -o value "$PART_ROOT")
        echo "${LUKS_NAME}  UUID=${luks_uuid}  none  luks,discard" \
            > /mnt/gentoo/etc/crypttab
        _log_raw "crypttab written: ${LUKS_NAME} UUID=${luks_uuid}"
        log "crypttab written."
    else
        root_source="UUID=$(blkid -s UUID -o value "$PART_ROOT")"
        _log_raw "Root source: ${root_source}"
    fi

    {
        echo "# <fs>                         <mp>          <type>  <opts>                                         <dump> <pass>"
        case "$FS_TYPE" in
            btrfs)
                local btrfs_opts="noatime,compress=zstd:1,space_cache=v2"
                echo "${root_source}  /             btrfs   ${btrfs_opts},subvol=@           0 0"
                echo "${root_source}  /home         btrfs   ${btrfs_opts},subvol=@home       0 0"
                echo "${root_source}  /.snapshots   btrfs   ${btrfs_opts},subvol=@snapshots  0 0"
                echo "${root_source}  /var/log      btrfs   ${btrfs_opts},subvol=@var_log    0 0"
                ;;
            ext4) echo "${root_source}  /  ext4   defaults,noatime  0 1" ;;
            xfs)  echo "${root_source}  /  xfs    defaults,noatime  0 1" ;;
            f2fs) echo "${root_source}  /  f2fs   defaults,noatime  0 1" ;;
        esac
        echo "UUID=${efi_uuid}   /boot/efi  vfat    umask=0077                                     0 2"
        [[ -n "$PART_SWAP" ]] && \
            echo "UUID=$(blkid -s UUID -o value "$PART_SWAP")  none  swap  sw  0 0"
        echo "tmpfs  /tmp  tmpfs  defaults,nosuid,nodev,size=4G  0 0"
    } > /mnt/gentoo/etc/fstab

    log "fstab written."
    _log_raw "fstab contents:"; cat /mnt/gentoo/etc/fstab >> "$LOG_FILE"
}

# =============================================================================
# STAGE3
# =============================================================================

install_stage3() {
    section "Installing Stage3 Tarball"

    local tarball_url="https://distfiles.gentoo.org/releases/amd64/autobuilds/20260329T161601Z/stage3-amd64-openrc-20260329T161601Z.tar.xz"

    log "Downloading stage3..."
    wget -q --tries=3 "$tarball_url" \
        -O /mnt/gentoo/stage3.tar.xz \
        || error "Failed to download stage3"

    log "Extracting stage3..."
    tar xpf /mnt/gentoo/stage3.tar.xz \
        --xattrs-include='*.*' \
        --numeric-owner \
        -C /mnt/gentoo \
        || error "Failed to extract stage3"

    rm -f /mnt/gentoo/stage3.tar.xz
    log "Stage3 installed."
}

# =============================================================================
# PORTAGE CONFIGURATION
# =============================================================================

configure_portage() {
    section "Configuring Portage"

    mkdir -p /mnt/gentoo/etc/portage/{package.use,package.accept_keywords,package.license,repos.conf,env,package.mask}
    _log_raw "Portage config dirs created"

    log "Writing make.conf..."
    cat > /mnt/gentoo/etc/portage/make.conf << EOF
# =============================================================================
# make.conf — generated $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# =============================================================================

COMMON_FLAGS="-O2 -pipe -march=native"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
RUSTFLAGS="-C opt-level=2 -C target-cpu=native"
LDFLAGS="-Wl,-O1 -Wl,--as-needed"

MAKEOPTS="${MAKEOPTS}"
EMERGE_DEFAULT_OPTS="--jobs=$(nproc) --load-average=$(nproc) --with-bdeps=y --keep-going --verbose-conflicts"
PORTAGE_NICENESS=15

USE="${USE_FLAGS}"

ACCEPT_LICENSE="-* @FREE @BINARY-REDISTRIBUTABLE"
ACCEPT_KEYWORDS="${ACCEPT_KEYWORDS}"

L10N="en en-US"
LINGUAS="en en_US"

VIDEO_CARDS="${VIDEO_CARDS}"
INPUT_DEVICES="libinput"

GENTOO_MIRRORS="https://distfiles.gentoo.org"
WEBSYNC_MIRROR="https://distfiles.gentoo.org"

DISTDIR="/var/cache/distfiles"
PKGDIR="/var/cache/binpkgs"
PORTDIR="/var/db/repos/gentoo"

PORTAGE_ELOG_CLASSES="warn error log"
PORTAGE_ELOG_SYSTEM="save"

FEATURES="parallel-fetch parallel-install buildpkg clean-logs split-elog"

GRUB_PLATFORMS="efi-64"
EOF
    _log_raw "make.conf written"

    log "Writing repos.conf..."
    cat > /mnt/gentoo/etc/portage/repos.conf/gentoo.conf << 'EOF'
[DEFAULT]
main-repo = gentoo

[gentoo]
location  = /var/db/repos/gentoo
sync-type = rsync
sync-uri  = rsync://rsync.gentoo.org/gentoo-portage
auto-sync = yes
sync-rsync-verify-jobs   = 1
sync-rsync-verify-metamanifest = yes
sync-rsync-verify-max-age = 24
sync-webrsync-verify-signature = no
EOF
    _log_raw "repos.conf written"

    _configure_portage_kernel
    _configure_portage_display
    _configure_portage_gpu
    _configure_portage_audio
    _configure_portage_optional

    log "Portage configuration complete."
}

# NEW: kernel USE flags — fixes the installkernel dracut requirement
_configure_portage_kernel() {
    debug "Configuring kernel USE flags (type: ${KERNEL_TYPE})..."
    cat > /mnt/gentoo/etc/portage/package.use/kernel << 'EOF'
# dracut is required to build an initramfs for the dist/binary kernel
sys-kernel/installkernel        dracut
sys-kernel/gentoo-kernel-bin    initramfs
virtual/dist-kernel             initramfs
EOF
    _log_raw "Kernel USE flags written (installkernel dracut, dist-kernel initramfs)"

    debug "Writing misc system USE flags..."
    cat > /mnt/gentoo/etc/portage/package.use/system << 'EOF'
# elogind required by xorg-server and libinput
>=sys-auth/pambase-20251104-r1  elogind
# harfbuzz required by freetype (circular dep bootstrapped in ~amd64)
>=media-libs/freetype-2.14.3    harfbuzz
EOF
    _log_raw "System USE flags written (pambase elogind, freetype harfbuzz)"
}

_configure_portage_display() {
    debug "Configuring display USE/keywords (DE: ${DESKTOP_ENV}, display: ${DISPLAY_SERVER})..."
    local kw_file="/mnt/gentoo/etc/portage/package.accept_keywords/desktop"
    case "$DESKTOP_ENV" in
        niri)
            cat >> "$kw_file" << 'EOF'
gui-wm/niri              ~amd64
dev-libs/wayland-protocols ~amd64
EOF
            ;;
        hyprland)
            cat >> "$kw_file" << 'EOF'
gui-wm/hyprland          ~amd64
gui-libs/hyprutils       ~amd64
gui-libs/hyprlang        ~amd64
gui-libs/hyprwayland-scanner ~amd64
dev-libs/wayland-protocols ~amd64
EOF
            ;;
        river)  echo "gui-wm/river  ~amd64" >> "$kw_file" ;;
        cosmic) cat >> "$kw_file" << 'EOF'
gui-wm/cosmic-comp       ~amd64
gui-apps/cosmic-term     ~amd64
gui-apps/cosmic-files    ~amd64
gui-apps/cosmic-launcher ~amd64
EOF
            ;;
        labwc)  echo "gui-wm/labwc  ~amd64" >> "$kw_file" ;;
    esac

    if [[ "$DISPLAY_SERVER" == "wayland" || "$DISPLAY_SERVER" == "both" ]]; then
        cat > /mnt/gentoo/etc/portage/package.use/wayland << 'EOF'
gui-libs/wlroots       X drm gles2 vulkan xwayland
dev-libs/wayland       -doc
x11-base/xwayland      -glamor
EOF
    fi
    _log_raw "Display portage config written (DE=${DESKTOP_ENV})"
}

_configure_portage_gpu() {
    debug "Configuring GPU USE flags (vendor: ${GPU_VENDOR})..."
    local use_file="/mnt/gentoo/etc/portage/package.use/gpu"
    case "$GPU_VENDOR" in
        amd)
            cat > "$use_file" << 'EOF'
media-libs/mesa  vulkan vulkan-overlay video_cards_amdgpu video_cards_radeonsi
EOF
            ;;
        intel)
            cat > "$use_file" << 'EOF'
media-libs/mesa  vulkan video_cards_intel video_cards_iris
EOF
            ;;
        nvidia)
            cat > "$use_file" << 'EOF'
x11-drivers/nvidia-drivers  wayland
media-libs/mesa             -nvidia
EOF
            cat >> /mnt/gentoo/etc/portage/package.accept_keywords/desktop << 'EOF'
x11-drivers/nvidia-drivers  ~amd64
EOF
            echo "x11-drivers/nvidia-drivers  NVIDIA-r2" \
                >> /mnt/gentoo/etc/portage/package.license/nvidia
            ;;
    esac
    _log_raw "GPU portage config written (${GPU_VENDOR})"
}

_configure_portage_audio() {
    if [[ "$ENABLE_PIPEWIRE" == "yes" ]]; then
        debug "Configuring PipeWire USE flags..."
        cat > /mnt/gentoo/etc/portage/package.use/audio << 'EOF'
media-video/pipewire    sound-server jack-sdk v4l screencast bluetooth
media-sound/wireplumber -systemd
EOF
        _log_raw "PipeWire portage config written"
    fi
}

_configure_portage_optional() {
    if [[ "$ENABLE_FLATPAK" == "yes" ]]; then
        echo "sys-apps/xdg-desktop-portal  flatpak" \
            >> /mnt/gentoo/etc/portage/package.use/desktop
        _log_raw "Flatpak USE flag written"
    fi
    if [[ "$ENABLE_LIBVIRT" == "yes" ]]; then
        cat >> /mnt/gentoo/etc/portage/package.use/virt << 'EOF'
app-emulation/libvirt  qemu virt-network
app-emulation/qemu     spice usb
EOF
        _log_raw "Libvirt USE flags written"
    fi
}

# =============================================================================
# CHROOT SETUP
# =============================================================================

setup_chroot() {
    section "Preparing chroot environment"

    debug "Copying resolv.conf..."
    cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
    _log_raw "resolv.conf copied"

    debug "Binding virtual filesystems..."
    mount --types proc  /proc /mnt/gentoo/proc
    mount --rbind       /sys  /mnt/gentoo/sys
    mount --make-rslave       /mnt/gentoo/sys
    mount --rbind       /dev  /mnt/gentoo/dev
    mount --make-rslave       /mnt/gentoo/dev
    mount --bind        /run  /mnt/gentoo/run
    mount --make-slave        /mnt/gentoo/run
    _log_raw "proc/sys/dev/run bound"

    if [[ -d /sys/firmware/efi/efivars ]]; then
        mount --bind /sys/firmware/efi/efivars \
            /mnt/gentoo/sys/firmware/efi/efivars
        _log_raw "efivars bound"
    else
        _log_raw "efivars: not present (non-EFI?), skipped"
    fi

    log "Chroot environment ready."
}

# =============================================================================
# CHROOT SCRIPT
# =============================================================================

write_chroot_script() {
    section "Writing chroot install script"

    install -m 700 /dev/null /mnt/gentoo/root/chroot-install.sh

    cat >> /mnt/gentoo/root/chroot-install.sh << CHROOT_EOF
#!/usr/bin/env bash
set -eo pipefail

CHROOT_LOG="${LOG_FILE}"

RED='\033[0;31m';  GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m';   BOLD='\033[1m'; NC='\033[0m'

_clog() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [CHROOT] \$*" >> "\${CHROOT_LOG}" 2>/dev/null || true; }
log()     { echo -e "\${GREEN}[+]\${NC} \$*";   _clog "[INFO]  \$*"; }
warn()    { echo -e "\${YELLOW}[!]\${NC} \$*";  _clog "[WARN]  \$*"; }
error()   { echo -e "\${RED}[✗]\${NC} \$*" >&2; _clog "[ERROR] \$*"; exit 1; }
debug()   { echo -e "\${CYAN}[…]\${NC} \$*";    _clog "[DEBUG] \$*"; }
section() {
    echo -e "\n\${BOLD}\${BLUE}══════════════════════════════════════════════\${NC}"
    echo -e "\${BOLD}\${CYAN}  \$*\${NC}"
    echo -e "\${BOLD}\${BLUE}══════════════════════════════════════════════\${NC}\n"
    _clog "====== \$* ======"
}

# ── Environment ───────────────────────────────────────────────────────────────
# Disable nounset around profile sourcing — some profile.d scripts (e.g.
# debuginfod.sh) reference variables that may not be set in a chroot.
set +u
source /etc/profile
set -u
export PS1="(chroot) \${PS1:-}"
_clog "Profile sourced, chroot environment ready"

# ── Portage sync ──────────────────────────────────────────────────────────────
section "Syncing Portage tree"
debug "Running emerge-webrsync..."
GENTOO_MIRRORS="https://distfiles.gentoo.org" \
WEBSYNC_MIRROR="https://distfiles.gentoo.org" \
emerge-webrsync
_clog "Portage tree synced"

# ── Profile ───────────────────────────────────────────────────────────────────
section "Setting Portage profile"
log "Available profiles:"
eselect profile list | less
echo ""
read -rp "  Enter profile number to use: " PROFILE_NUM </dev/tty
if [[ -n "$PROFILE_NUM" ]]; then
    eselect profile set "$PROFILE_NUM" || warn "Profile set failed — set manually with: eselect profile set"
    SELECTED="\$(eselect profile show | tail -1 | xargs)"
    log "Profile set: \${SELECTED}"
    _clog "Profile: \${SELECTED}"
else
    warn "No profile selected — set manually with: eselect profile set"
    _clog "Profile selection skipped"
fi

# ── Timezone & Locale ─────────────────────────────────────────────────────────
section "Timezone & Locale"
debug "Setting timezone: ${TIMEZONE}"
echo "${TIMEZONE}" > /etc/timezone
emerge -q --config sys-libs/timezone-data
_clog "Timezone set: ${TIMEZONE}"

echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
LOC=\$(locale -a | grep -i "\$(echo "${LOCALE}" | tr '[:upper:]' '[:lower:]' | sed 's/utf-8/utf8/')" | head -1)
if [[ -n "\$LOC" ]]; then
    eselect locale set "\$LOC"
    _clog "Locale set: \${LOC}"
else
    warn "Set locale manually: eselect locale set"
    _clog "Locale auto-set failed for: ${LOCALE}"
fi
set +u; env-update && source /etc/profile; set -u

# ── Firmware & Microcode ──────────────────────────────────────────────────────
section "Firmware & Microcode  (CPU: ${CPU_VENDOR})"
[[ "${CPU_VENDOR}" == "intel" ]] && {
    debug "Installing Intel microcode..."
    emerge -q sys-firmware/intel-microcode
    _clog "intel-microcode installed"
}
debug "Installing linux-firmware..."
emerge --ask -q sys-kernel/linux-firmware
emerge --ask -q sys-firmware/sof-firmware
_clog "linux-firmware installed"

# ── Kernel ────────────────────────────────────────────────────────────────────
section "Kernel installation  (type: ${KERNEL_TYPE})"

# Provide a kernel cmdline for dracut so it doesn't fall back to
# /proc/cmdline (which is the host's cmdline inside a chroot).
debug "Writing /etc/kernel/cmdline for dracut..."
mkdir -p /etc/kernel
DRACUT_CMDLINE="root=UUID=\$(findmnt -no UUID /) ro quiet"
[[ "${ENABLE_LUKS}" == "yes" ]] && DRACUT_CMDLINE="rd.luks=1 \${DRACUT_CMDLINE}"
echo "\${DRACUT_CMDLINE}" > /etc/kernel/cmdline
_clog "kernel cmdline written: \$(cat /etc/kernel/cmdline)"

# Suppress the chroot preflight check — we know we're in a chroot and
# have already provided /etc/kernel/cmdline above.
mkdir -p /etc/kernel/preinst.d
touch /etc/kernel/preinst.d/05-check-chroot.install
_clog "dracut chroot check suppressed"

case "${KERNEL_TYPE}" in
    dist)
        debug "Installing gentoo-kernel-bin (pre-compiled)..."
        emerge -q sys-kernel/gentoo-kernel-bin
        _clog "gentoo-kernel-bin installed"
        ;;
    sources|hardened|rt)
        case "${KERNEL_TYPE}" in
            sources)  emerge -q sys-kernel/gentoo-sources ;;
            hardened) emerge -q sys-kernel/hardened-sources ;;
            rt)       emerge -q sys-kernel/rt-sources ;;
        esac
        eselect kernel set 1
        KVER=\$(eselect kernel show | tail -1 | xargs | sed 's|.*/||')
        _clog "Kernel sources installed: \${KVER}"
        cd /usr/src/linux

        case "${KERNEL_CONFIG}" in
            defconfig)
                debug "Running make defconfig..."
                make defconfig
                scripts/config --enable CONFIG_EFI_STUB
                scripts/config --enable CONFIG_EFI_PARTITION
                [[ "${ENABLE_LUKS}" == "yes" ]] && {
                    scripts/config --enable CONFIG_DM_CRYPT
                    scripts/config --enable CONFIG_CRYPTO_AES
                    scripts/config --enable CONFIG_CRYPTO_XTS
                    _clog "LUKS kernel options enabled"
                }
                make olddefconfig
                log "Compiling kernel (${MAKEOPTS}) — this will take a while..."
                make ${MAKEOPTS}
                make modules_install
                make install
                _clog "Kernel compiled and installed"
                ;;
            genkernel)
                emerge -q sys-kernel/genkernel
                log "Running genkernel..."
                genkernel --menuconfig=no \
                          --makeopts="${MAKEOPTS}" \
                          $( [[ "${ENABLE_LUKS}" == "yes" ]] && echo "--luks" ) \
                          all
                _clog "genkernel complete"
                ;;
            manual)
                warn "Launching menuconfig — configure, save, then exit."
                make menuconfig
                make ${MAKEOPTS}
                make modules_install
                make install
                _clog "Manual kernel compiled and installed"
                ;;
        esac
        ;;
esac

# ── Base system packages ──────────────────────────────────────────────────────
section "Base system packages"
debug "Emerging base packages..."
emerge -q \
    app-admin/sudo \
    app-editors/neovim \
    app-shells/bash-completion \
    dev-vcs/git \
    net-misc/curl \
    net-misc/wget \
    sys-apps/dbus \
    sys-apps/pciutils \
    sys-apps/usbutils \
    sys-apps/mlocate \
    sys-auth/elogind \
    sys-boot/grub \
    sys-fs/dosfstools \
    sys-fs/e2fsprogs \
    sys-fs/btrfs-progs \
    sys-libs/pam \
    sys-auth/pambase \
    sys-process/cronie \
    net-misc/networkmanager
_clog "Base packages installed"

case "${FS_TYPE}" in
    xfs)  emerge -q sys-fs/xfsprogs;   _clog "xfsprogs installed" ;;
    f2fs) emerge -q sys-fs/f2fs-tools; _clog "f2fs-tools installed" ;;
esac

[[ "${ENABLE_LUKS}" == "yes" ]] && {
    emerge -q sys-fs/cryptsetup
    _clog "cryptsetup installed"
}

# ── Hostname & Networking ─────────────────────────────────────────────────────
section "Hostname & network configuration"
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF
_clog "Hostname: ${HOSTNAME}"

# ── Init services ─────────────────────────────────────────────────────────────
section "Enabling init services  (${INIT_SYSTEM})"
if [[ "${INIT_SYSTEM}" == "openrc" ]]; then
    for svc in NetworkManager elogind dbus udev cronie; do
        rc-update add \$svc default 2>/dev/null \
            && _clog "  rc-update add \${svc} default" \
            || _clog "  rc-update \${svc}: skipped/already added"
    done
    rc-update add udev sysinit
    rc-update add sshd default 2>/dev/null || true
else
    for unit in NetworkManager dbus cronie; do
        systemctl enable \$unit
        _clog "  systemctl enable \${unit}"
    done
fi

# ── Display server ────────────────────────────────────────────────────────────
section "Display server packages  (${DISPLAY_SERVER})"
if [[ "${DISPLAY_SERVER}" == "x11" || "${DISPLAY_SERVER}" == "both" ]]; then
    debug "Installing X11 packages..."
    emerge -q \
        x11-base/xorg-server \
        x11-apps/xinit \
        x11-misc/xkeyboard-config \
        x11-libs/libX11 \
        x11-libs/libXrandr \
        x11-libs/libXinerama
    _clog "X11 packages installed"
fi

if [[ "${DISPLAY_SERVER}" == "wayland" || "${DISPLAY_SERVER}" == "both" ]]; then
    debug "Installing Wayland packages..."
    emerge -q \
        dev-libs/wayland \
        dev-libs/wayland-protocols \
        x11-base/xwayland \
        x11-libs/libdrm \
        x11-libs/pixman \
        x11-misc/xkeyboard-config
    _clog "Wayland packages installed"
fi

# ── GPU drivers ───────────────────────────────────────────────────────────────
section "GPU drivers  (${GPU_VENDOR})"
debug "Installing Mesa and VA-API..."
emerge -q media-libs/mesa media-libs/libva media-video/libva-utils
_clog "Mesa + libva installed"

case "${GPU_VENDOR}" in
    amd)
        emerge -q media-libs/vulkan-loader dev-util/vulkan-tools
        _clog "AMD Vulkan packages installed"
        ;;
    intel)
        emerge -q media-libs/intel-media-driver media-libs/vulkan-loader
        _clog "Intel media driver + Vulkan installed"
        ;;
    nvidia)
        debug "Installing NVIDIA proprietary driver..."
        emerge -q x11-drivers/nvidia-drivers
        [[ "${INIT_SYSTEM}" == "openrc" ]] && {
            rc-update add modules boot
            echo "nvidia" >> /etc/modules-load.d/nvidia.conf
        }
        _clog "nvidia-drivers installed"
        ;;
esac

# ── Desktop environment / WM ──────────────────────────────────────────────────
section "Desktop environment  (${DESKTOP_ENV})"
debug "Installing DE/WM packages..."
case "${DESKTOP_ENV}" in
    gnome)
        emerge -q gnome-base/gnome gnome-base/gnome-extra-apps
        _clog "GNOME installed"
        ;;
    kde)
        emerge -q kde-plasma/plasma-meta kde-apps/kde-apps-meta
        _clog "KDE Plasma installed"
        ;;
    cosmic)
        emerge -q gui-wm/cosmic-comp gui-apps/cosmic-term gui-apps/cosmic-files \
                   gui-apps/cosmic-launcher gui-apps/cosmic-settings
        _clog "COSMIC installed"
        ;;
    sway)
        emerge -q gui-wm/sway gui-apps/swaybar gui-apps/swaybg gui-apps/swayidle \
                   gui-apps/swaylock gui-apps/foot gui-apps/fuzzel gui-apps/mako \
                   gui-apps/grim gui-apps/slurp gui-apps/wl-clipboard \
                   gui-libs/xdg-desktop-portal-gtk
        _clog "Sway installed"
        ;;
    niri)
        emerge -q gui-wm/niri gui-apps/swayidle gui-apps/swaylock gui-apps/foot \
                   gui-apps/fuzzel gui-apps/mako gui-apps/waybar gui-apps/grim \
                   gui-apps/slurp gui-apps/wl-clipboard \
                   gui-libs/xdg-desktop-portal-gtk x11-libs/xcb-util-cursor
        _clog "niri installed"
        ;;
    hyprland)
        emerge -q gui-wm/hyprland gui-apps/swayidle gui-apps/swaylock gui-apps/foot \
                   gui-apps/fuzzel gui-apps/mako gui-apps/waybar gui-apps/grim \
                   gui-apps/slurp gui-apps/wl-clipboard gui-libs/xdg-desktop-portal-gtk
        _clog "Hyprland installed"
        ;;
    river)
        emerge -q gui-wm/river gui-apps/foot gui-apps/fuzzel gui-apps/mako \
                   gui-apps/waybar gui-apps/wl-clipboard gui-libs/xdg-desktop-portal-gtk
        _clog "river installed"
        ;;
    labwc)
        emerge -q gui-wm/labwc gui-apps/foot gui-apps/fuzzel gui-apps/mako \
                   gui-apps/wl-clipboard gui-libs/xdg-desktop-portal-gtk
        _clog "labwc installed"
        ;;
    xfce)
        emerge -q xfce-base/xfce4-meta
        _clog "XFCE installed"
        ;;
    lxqt)
        emerge -q lxqt-base/lxqt-meta
        _clog "LXQt installed"
        ;;
    openbox)
        emerge -q x11-wm/openbox x11-misc/obconf x11-apps/xrandr x11-misc/tint2 x11-misc/rofi
        _clog "Openbox installed"
        ;;
    i3)
        emerge -q x11-wm/i3 x11-misc/i3status x11-misc/i3lock x11-misc/rofi \
                   x11-apps/xrandr x11-misc/picom
        _clog "i3 installed"
        ;;
    dwm)
        emerge -q x11-wm/dwm x11-misc/dmenu x11-misc/st
        _clog "dwm installed"
        ;;
    none|custom)
        log "Skipping desktop install (none/custom)."
        _clog "Desktop: skipped"
        ;;
esac

# ── Display manager / login daemon ────────────────────────────────────────────
section "Display manager  (${DISPLAY_MANAGER:-none})"
case "${DISPLAY_MANAGER:-none}" in
    gdm)
        emerge -q gnome-base/gdm
        [[ "${INIT_SYSTEM}" == "openrc" ]] && rc-update add gdm default || systemctl enable gdm
        _clog "GDM installed and enabled"
        ;;
    sddm)
        emerge -q x11-misc/sddm
        [[ "${INIT_SYSTEM}" == "openrc" ]] && rc-update add sddm default || systemctl enable sddm
        _clog "SDDM installed and enabled"
        ;;
    lightdm)
        emerge -q x11-misc/lightdm x11-misc/lightdm-gtk-greeter
        [[ "${INIT_SYSTEM}" == "openrc" ]] && rc-update add lightdm default || systemctl enable lightdm
        _clog "LightDM installed and enabled"
        ;;
    greetd)
        emerge -q gui-apps/greetd gui-apps/tuigreet
        if [[ "${INIT_SYSTEM}" == "openrc" ]]; then
            rc-update add greetd default
        else
            systemctl enable greetd
        fi
        cat > /etc/greetd/config.toml << 'EOF'
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --remember --cmd niri-session"
user = "greeter"
EOF
        _clog "greetd + tuigreet installed and enabled"
        ;;
    ly)
        emerge -q x11-misc/ly
        [[ "${INIT_SYSTEM}" == "openrc" ]] && rc-update add ly default || systemctl enable ly
        _clog "ly installed and enabled"
        ;;
    none)
        log "No display manager selected — TTY auto-start will be used."
        _clog "Display manager: none"
        ;;
esac

# ── Audio ─────────────────────────────────────────────────────────────────────
if [[ "${ENABLE_PIPEWIRE}" == "yes" ]]; then
    section "PipeWire audio"
    debug "Installing PipeWire + WirePlumber..."
    emerge -q media-video/pipewire media-sound/wireplumber media-sound/pavucontrol
    [[ "${INIT_SYSTEM}" == "openrc" ]] && rc-update add pipewire default || true
    _clog "PipeWire installed"
fi

# ── Bluetooth ─────────────────────────────────────────────────────────────────
if [[ "${ENABLE_BLUETOOTH}" == "yes" ]]; then
    section "Bluetooth"
    emerge -q net-wireless/bluez app-misc/blueman
    [[ "${INIT_SYSTEM}" == "openrc" ]] && rc-update add bluetooth default || systemctl enable bluetooth
    _clog "Bluetooth installed"
fi

# ── Printing ──────────────────────────────────────────────────────────────────
if [[ "${ENABLE_PRINTING}" == "yes" ]]; then
    section "Printing (CUPS + Avahi)"
    emerge -q net-print/cups net-dns/avahi app-text/ghostscript-gpl
    [[ "${INIT_SYSTEM}" == "openrc" ]] && {
        rc-update add cupsd default; rc-update add avahi-daemon default
    } || { systemctl enable cups; systemctl enable avahi-daemon; }
    _clog "CUPS + Avahi installed"
fi

# ── Flatpak ───────────────────────────────────────────────────────────────────
if [[ "${ENABLE_FLATPAK}" == "yes" ]]; then
    section "Flatpak"
    emerge -q sys-apps/flatpak
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    _clog "Flatpak installed + Flathub remote added"
fi

# ── Libvirt / QEMU ────────────────────────────────────────────────────────────
if [[ "${ENABLE_LIBVIRT}" == "yes" ]]; then
    section "Libvirt / QEMU"
    emerge -q app-emulation/libvirt app-emulation/qemu app-emulation/virt-manager
    [[ "${INIT_SYSTEM}" == "openrc" ]] && rc-update add libvirtd default || systemctl enable libvirtd
    _clog "Libvirt + QEMU installed"
fi

# ── Docker / Podman ───────────────────────────────────────────────────────────
if [[ "${ENABLE_DOCKER}" == "yes" ]]; then
    section "Containers"
    emerge -q app-containers/docker app-containers/podman app-containers/docker-compose
    [[ "${INIT_SYSTEM}" == "openrc" ]] && rc-update add docker default || systemctl enable docker
    _clog "Docker + Podman installed"
fi

# ── Snapper ───────────────────────────────────────────────────────────────────
if [[ "${ENABLE_BTRFS_SNAPPER}" == "yes" && "${FS_TYPE}" == "btrfs" ]]; then
    section "Snapper (btrfs snapshots)"
    emerge -q app-backup/snapper
    snapper -c root create-config /
    [[ "${INIT_SYSTEM}" == "openrc" ]] && {
        rc-update add snapper-timeline default
        rc-update add snapper-cleanup default
    } || {
        systemctl enable snapper-timeline.timer
        systemctl enable snapper-cleanup.timer
    }
    _clog "Snapper installed and configured"
fi

# ── Extra packages ────────────────────────────────────────────────────────────
if [[ -n "${EXTRA_PACKAGES}" ]]; then
    section "Extra packages"
    debug "Installing: ${EXTRA_PACKAGES}"
    # shellcheck disable=SC2086
    emerge -q ${EXTRA_PACKAGES}
    _clog "Extra packages installed: ${EXTRA_PACKAGES}"
fi

# ── Fonts & themes ────────────────────────────────────────────────────────────
section "Fonts & themes"
emerge -q \
    media-fonts/noto \
    media-fonts/noto-emoji \
    media-fonts/fira-code \
    x11-themes/papirus-icon-theme \
    x11-themes/capitaine-cursors
_clog "Fonts and themes installed"

# ── GRUB ──────────────────────────────────────────────────────────────────────
section "GRUB bootloader"
emerge -q sys-boot/grub

GRUB_CMDLINE="quiet loglevel=3 mitigations=auto"
[[ "${ENABLE_LUKS}" == "yes" ]] && GRUB_CMDLINE="\${GRUB_CMDLINE} rd.luks=1"

cat >> /etc/default/grub << EOF
GRUB_CMDLINE_LINUX_DEFAULT="\${GRUB_CMDLINE}"
GRUB_TIMEOUT=3
GRUB_GFXMODE=auto
EOF

debug "Running grub-install..."
grub-install --target=x86_64-efi \
             --efi-directory=/boot/efi \
             --bootloader-id=gentoo \
             --recheck
_clog "grub-install complete"

debug "Running grub-mkconfig..."
grub-mkconfig -o /boot/grub/grub.cfg
_clog "grub.cfg written"

# ── Secure Boot ───────────────────────────────────────────────────────────────
if [[ "${ENABLE_SECURE_BOOT}" == "yes" ]]; then
    section "Secure Boot (sbctl)"
    if command -v sbctl &>/dev/null; then
        sbctl create-keys
        if [[ "${SECURE_BOOT_MICROSOFT_KEYS}" == "yes" ]]; then
            sbctl enroll-keys --microsoft
            _clog "Secure Boot keys enrolled (with Microsoft CA)"
        else
            sbctl enroll-keys
            _clog "Secure Boot keys enrolled (without Microsoft CA)"
        fi
        sbctl sign -s /boot/efi/EFI/gentoo/grubx64.efi
        for vmlinuz in /boot/vmlinuz-*; do
            [[ -f "\$vmlinuz" ]] && sbctl sign -s "\$vmlinuz" \
                && _clog "Signed: \${vmlinuz}"
        done
        log "Secure Boot keys enrolled. Enable in firmware after reboot."
    else
        warn "sbctl not found — install app-crypt/sbctl post-boot and re-run signing."
        _clog "sbctl not found, Secure Boot signing skipped"
    fi
fi

# ── Users ─────────────────────────────────────────────────────────────────────
section "User accounts"
debug "Setting root password..."
echo "root:${ROOT_HASH}" | chpasswd -e
_clog "root password set"

NIRI_CMD="niri"
command -v niri-session &>/dev/null && NIRI_CMD="niri-session"

debug "Creating user: ${USERNAME}"
useradd -m \
    -G wheel,audio,video,input,seat,plugdev,usb,portage \
    $( [[ "${ENABLE_LIBVIRT}" == "yes" ]] && echo "-G libvirt" ) \
    $( [[ "${ENABLE_DOCKER}"  == "yes" ]] && echo "-G docker"  ) \
    -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${USER_HASH}" | chpasswd -e
_clog "User created: ${USERNAME}"

install -m 440 /dev/null /etc/sudoers.d/wheel
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
_clog "sudoers wheel entry written"

# ── Session auto-start ────────────────────────────────────────────────────────
section "Session auto-start (TTY1)"
USER_HOME="/home/${USERNAME}"

_write_autostart() {
    local cmd="\$1"
    cat >> "\${USER_HOME}/.bash_profile" << BEOF

# Auto-start \${cmd} on TTY1
if [[ -z "\\\$DISPLAY" && -z "\\\$WAYLAND_DISPLAY" && "\\\${XDG_VTNR}" -eq 1 ]]; then
    exec \${cmd}
fi
BEOF
    _clog "Auto-start configured: \${cmd}"
}

if [[ "${DISPLAY_MANAGER:-none}" != "none" ]]; then
    _clog "Session start handled by display manager: ${DISPLAY_MANAGER}"
else
    case "${DESKTOP_ENV}" in
        sway)     _write_autostart "sway" ;;
        niri)     _write_autostart "\${NIRI_CMD}" ;;
        hyprland) _write_autostart "Hyprland" ;;
        river)    _write_autostart "river" ;;
        labwc)    _write_autostart "labwc" ;;
        cosmic)   _write_autostart "cosmic-session" ;;
        openbox)  _write_autostart "openbox-session" ;;
        i3)       _write_autostart "i3" ;;
        dwm)      _write_autostart "dwm" ;;
        gnome|kde|xfce|lxqt) warn "No display manager set for ${DESKTOP_ENV} — set DISPLAY_MANAGER in config." ;;
        none|custom) warn "Configure session start manually." ;;
    esac
fi

# ── Wayland environment vars ──────────────────────────────────────────────────
if [[ "${DISPLAY_SERVER}" == "wayland" || "${DISPLAY_SERVER}" == "both" ]]; then
    mkdir -p "\${USER_HOME}/.config/environment.d"
    cat > "\${USER_HOME}/.config/environment.d/wayland.conf" << 'EEOF'
XDG_SESSION_TYPE=wayland
QT_QPA_PLATFORM=wayland;xcb
QT_WAYLAND_DISABLE_WINDOWDECORATION=1
GDK_BACKEND=wayland,x11
SDL_VIDEODRIVER=wayland
CLUTTER_BACKEND=wayland
MOZ_ENABLE_WAYLAND=1
_JAVA_AWT_WM_NONREPARENTING=1
ELECTRON_OZONE_PLATFORM_HINT=wayland
EEOF
    _clog "Wayland environment.d written"
fi

# ── Keymap ────────────────────────────────────────────────────────────────────
sed -i 's/^keymap=.*/keymap="${KEYMAP}"/' /etc/conf.d/keymaps 2>/dev/null || true
_clog "Keymap set: ${KEYMAP}"

# ── Ownership ─────────────────────────────────────────────────────────────────
chown -R "${USERNAME}:${USERNAME}" "\${USER_HOME}"
_clog "Ownership set for \${USER_HOME}"

_clog "====== Chroot phase complete ======"
section "Chroot phase complete"
CHROOT_EOF

    log "Chroot script written to /root/chroot-install.sh"
    _log_raw "Chroot script size: $(wc -l < /mnt/gentoo/root/chroot-install.sh) lines"
}

# =============================================================================
# RUN CHROOT
# =============================================================================

run_chroot() {
    section "Entering chroot"
    _log_raw "Handing off to chroot script..."
    chroot /mnt/gentoo /bin/bash /root/chroot-install.sh
    _log_raw "Chroot script returned successfully"
}

# =============================================================================
# CLEANUP
# =============================================================================

cleanup() {
    section "Cleanup & unmount"

    rm -f /mnt/gentoo/root/chroot-install.sh
    _log_raw "Chroot script removed"

    local mounts=(
        /mnt/gentoo/sys/firmware/efi/efivars
        /mnt/gentoo/proc
        /mnt/gentoo/sys
        /mnt/gentoo/dev
        /mnt/gentoo/run
        /mnt/gentoo/var/log
        /mnt/gentoo/home
        /mnt/gentoo/.snapshots
        /mnt/gentoo/boot/efi
        /mnt/gentoo
    )
    for mp in "${mounts[@]}"; do
        if mountpoint -q "$mp" 2>/dev/null; then
            umount -R "$mp" 2>/dev/null && _log_raw "  unmounted: ${mp}" \
                || _log_raw "  unmount failed (non-fatal): ${mp}"
        fi
    done

    if [[ -n "$PART_SWAP" ]]; then
        swapoff "$PART_SWAP" 2>/dev/null && _log_raw "swap off: ${PART_SWAP}" || true
    fi

    if [[ "$ENABLE_LUKS" == "yes" ]]; then
        cryptsetup close "$LUKS_NAME" 2>/dev/null \
            && _log_raw "LUKS container closed: ${LUKS_NAME}" || true
    fi

    log "Unmount complete."
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "  ╔════════════════════════════════════════════════════╗"
    echo "  ║   Gentoo Linux Installer  —  2025/2026            ║"
    echo "  ║   Agnostic: any init · display · desktop          ║"
    echo "  ╚════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    echo -e "  ${CYAN}Log file:${NC} ${BOLD}${LOG_FILE}${NC}"
    echo -e "  ${CYAN}Follow:${NC}   ${BOLD}tail -f ${LOG_FILE}${NC}"
    echo ""
    _log_raw "====== Gentoo Installer started (PID $$) ======"

    parse_args "$@"
    load_config

    echo -e "  Config:   ${BOLD}${CONFIG_FILE}${NC}"
    echo -e "  Disk:     ${BOLD}${DISK}${NC}  (${FS_TYPE}$([ "$ENABLE_LUKS" = yes ] && echo " + LUKS2"))"
    echo -e "  Init:     ${BOLD}${INIT_SYSTEM}${NC}"
    echo -e "  Display:  ${BOLD}${DISPLAY_SERVER}${NC}"
    echo -e "  Desktop:  ${BOLD}${DESKTOP_ENV}${NC}  (DM: ${BOLD}${DISPLAY_MANAGER:-none}${NC})"
    echo -e "  Kernel:   ${BOLD}${KERNEL_TYPE}${NC}"
    echo -e "  CPU/GPU:  ${BOLD}${CPU_VENDOR}${NC} / ${BOLD}${GPU_VENDOR}${NC}"
    echo ""

    trap 'cleanup; _on_exit' EXIT

    preflight_checks
    partition_disk
    install_stage3
    write_fstab
    configure_portage
    setup_chroot
    write_chroot_script
    run_chroot
    cleanup

    trap - EXIT

    local elapsed=$(( SECONDS - _install_start_time ))
    local mins=$(( elapsed / 60 ))
    local secs=$(( elapsed % 60 ))

    echo ""
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  Installation complete!  (${mins}m ${secs}s)${NC}"
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${CYAN}Log saved to:${NC} ${BOLD}${LOG_FILE}${NC}"
    echo ""
    echo -e "  ${CYAN}Next steps:${NC}"
    echo -e "   1. ${BOLD}reboot${NC}"
    echo -e "   2. Login as ${BOLD}${USERNAME}${NC}"
    [[ "$DESKTOP_ENV" != "gnome" && "$DESKTOP_ENV" != "kde" \
        && "$DESKTOP_ENV" != "xfce" && "$DESKTOP_ENV" != "lxqt" ]] \
        && echo -e "   3. Session starts automatically on TTY1"
    [[ "$ENABLE_SECURE_BOOT" == "yes" ]] \
        && echo -e "   4. Enable Secure Boot in your firmware settings"
    [[ "$ENABLE_LUKS" == "yes" ]] \
        && echo -e "   ${YELLOW}[!]${NC} You will be prompted for your LUKS passphrase on boot"
    echo ""
    _log_raw "====== Installer main() returned cleanly ======"
}

main "$@"
