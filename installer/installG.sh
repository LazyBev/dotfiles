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
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# DEFAULTS  (overridden by --config or env)
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
USE_FLAGS="wayland -X -gnome -kde -plasma udev dbus policykit"
MAKEOPTS="-j$(nproc) -l$(nproc)"
GENTOO_MIRRORS="https://distfiles.gentoo.org"
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
SECURE_BOOT_MICROSOFT_KEYS="no"   # FIX #9: separate opt-in for MS trust anchor
EXTRA_PACKAGES=""

# Runtime globals — set during partitioning
PART_EFI=""
PART_SWAP=""
PART_ROOT=""
ROOT_HASH=""
USER_HASH=""
LUKS_NAME="cryptroot"

# =============================================================================
# COLORS & LOGGING
# =============================================================================

RED='\033[0;31m';  GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m';   BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[+]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
section() {
    echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  $*${NC}"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════════════${NC}\n"
}

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
}

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

preflight_checks() {
    section "Pre-flight Checks"

    [[ $EUID -ne 0 ]]   && error "Must be run as root."
    [[ ! -b "$DISK" ]]  && error "Disk $DISK not found. Verify DISK in config."

    # Check required tools
    local tools=(wipefs sgdisk mkfs.fat mkswap wget gpg openssl chroot)
    for t in "${tools[@]}"; do
        command -v "$t" &>/dev/null || error "Required tool not found: $t"
    done

    # LUKS tooling
    if [[ "$ENABLE_LUKS" == "yes" ]]; then
        command -v cryptsetup &>/dev/null || error "cryptsetup not found (required for LUKS)."
    fi

    # Secure Boot tooling
    if [[ "$ENABLE_SECURE_BOOT" == "yes" ]]; then
        command -v sbctl &>/dev/null \
            || warn "sbctl not found — Secure Boot setup will be manual post-install."
    fi

    # Password prompt — plaintext never stored to disk
    echo ""
    read -rsp "  Enter root password: "    rp1; echo
    read -rsp "  Confirm root password: "  rp2; echo
    [[ "$rp1" != "$rp2" ]] && error "Root passwords do not match."

    read -rsp "  Enter password for ${USERNAME}: "   up1; echo
    read -rsp "  Confirm password for ${USERNAME}: " up2; echo
    [[ "$up1" != "$up2" ]] && error "User passwords do not match."

    ROOT_HASH=$(openssl passwd -6 "$rp1")
    USER_HASH=$(openssl passwd -6 "$up1")
    unset rp1 rp2 up1 up2

    if [[ "$ENABLE_LUKS" == "yes" ]]; then
        echo ""
        read -rsp "  Enter LUKS passphrase: "    lp1; echo
        read -rsp "  Confirm LUKS passphrase: "  lp2; echo
        [[ "$lp1" != "$lp2" ]] && error "LUKS passphrases do not match."
        LUKS_PASSPHRASE="$lp1"
        unset lp1 lp2
    fi

    log "Verifying internet connectivity..."
    ping -c 2 -W 5 gentoo.org &>/dev/null || error "No internet connection."

    log "Syncing system clock..."
    chronyd -q &>/dev/null \
        || ntpd -gq &>/dev/null \
        || warn "Could not sync clock automatically."

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
    section "Partitioning: $DISK  (FS: $FS_TYPE  LUKS: $ENABLE_LUKS)"

    warn "This will DESTROY all data on $DISK"
    local confirm
    read -rp "  Type 'yes' to confirm: " confirm
    [[ "$confirm" != "yes" ]] && error "Aborted by user."

    log "Wiping disk..."
    wipefs -a "$DISK"
    sgdisk --zap-all "$DISK"

    # FIX #1: use arithmetic assignment instead of ((++)) to avoid set -e
    # triggering when the post-increment expression evaluates to 0.
    local part_num=1
    log "Creating GPT layout..."
    # EFI
    sgdisk -n ${part_num}:0:+${EFI_SIZE}G  -t ${part_num}:ef00 -c ${part_num}:"EFI"  "$DISK"
    PART_EFI="$(_part_suffix $part_num)"
    part_num=$((part_num + 1))

    # Optional swap
    if [[ "$SWAP_SIZE" != "0" ]]; then
        sgdisk -n ${part_num}:0:+${SWAP_SIZE}G -t ${part_num}:8200 -c ${part_num}:"swap" "$DISK"
        PART_SWAP="$(_part_suffix $part_num)"
        part_num=$((part_num + 1))
    fi

    # Root (remainder)
    sgdisk -n ${part_num}:0:0 -t ${part_num}:8300 -c ${part_num}:"root" "$DISK"
    PART_ROOT="$(_part_suffix $part_num)"

    # FIX #12: udevadm settle is deterministic; sleep 1 is a race
    partprobe "$DISK"
    udevadm settle

    log "Formatting EFI (FAT32)..."
    mkfs.fat -F32 -n "EFI" "$PART_EFI"

    if [[ -n "$PART_SWAP" ]]; then
        log "Formatting swap..."
        mkswap -L "swap" "$PART_SWAP"
        swapon "$PART_SWAP"
    fi

    # LUKS
    local ROOT_DEVICE="$PART_ROOT"
    if [[ "$ENABLE_LUKS" == "yes" ]]; then
        log "Setting up LUKS2 container on $PART_ROOT..."
        # FIX #7: feed passphrase via process substitution so it never
        # appears in /proc/<pid>/environ as a shell variable during the
        # cryptsetup calls.
        cryptsetup luksFormat --type luks2 \
            --cipher aes-xts-plain64 --key-size 512 \
            --hash sha512 --pbkdf argon2id \
            "$PART_ROOT" - < <(printf '%s' "$LUKS_PASSPHRASE")
        cryptsetup open "$PART_ROOT" "$LUKS_NAME" \
            < <(printf '%s' "$LUKS_PASSPHRASE")
        unset LUKS_PASSPHRASE
        ROOT_DEVICE="/dev/mapper/${LUKS_NAME}"
    fi

    log "Formatting root ($FS_TYPE)..."
    case "$FS_TYPE" in
        btrfs)
            mkfs.btrfs -L "gentoo" -f "$ROOT_DEVICE"
            mount "$ROOT_DEVICE" /mnt/gentoo
            for sv in @ @home @snapshots @var_log; do
                btrfs subvolume create "/mnt/gentoo/${sv}"
            done
            umount /mnt/gentoo

            local btrfs_opts="noatime,compress=zstd:1,space_cache=v2"
            mount -o "${btrfs_opts},subvol=@"          "$ROOT_DEVICE" /mnt/gentoo
            mkdir -p /mnt/gentoo/{home,.snapshots,var/log}
            mount -o "${btrfs_opts},subvol=@home"      "$ROOT_DEVICE" /mnt/gentoo/home
            mount -o "${btrfs_opts},subvol=@snapshots" "$ROOT_DEVICE" /mnt/gentoo/.snapshots
            mount -o "${btrfs_opts},subvol=@var_log"   "$ROOT_DEVICE" /mnt/gentoo/var/log
            ;;
        ext4)
            mkfs.ext4 -L "gentoo" -O dir_index,extent,sparse_super2 "$ROOT_DEVICE"
            mount "$ROOT_DEVICE" /mnt/gentoo
            ;;
        xfs)
            mkfs.xfs -L "gentoo" -f "$ROOT_DEVICE"
            mount "$ROOT_DEVICE" /mnt/gentoo
            ;;
        f2fs)
            mkfs.f2fs -l "gentoo" -O extra_attr,inode_checksum,sb_checksum "$ROOT_DEVICE"
            mount -o noatime "$ROOT_DEVICE" /mnt/gentoo
            ;;
    esac

    mkdir -p /mnt/gentoo/boot/efi
    mount "$PART_EFI" /mnt/gentoo/boot/efi

    log "Partitioning complete."
}

# =============================================================================
# FSTAB
# =============================================================================

write_fstab() {
    # FIX #5: called after install_stage3 so /mnt/gentoo/etc/ exists.
    # The /etc dir comes from the stage3 tarball extract.
    section "Generating /etc/fstab"

    local root_source efi_uuid swap_uuid
    efi_uuid=$(blkid -s UUID -o value "$PART_EFI")

    if [[ "$ENABLE_LUKS" == "yes" ]]; then
        root_source="/dev/mapper/${LUKS_NAME}"
        local luks_uuid
        luks_uuid=$(blkid -s UUID -o value "$PART_ROOT")
        echo "${LUKS_NAME}  UUID=${luks_uuid}  none  luks,discard" \
            > /mnt/gentoo/etc/crypttab
        log "crypttab written."
    else
        root_source="UUID=$(blkid -s UUID -o value "$PART_ROOT")"
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
            ext4)
                echo "${root_source}  /          ext4    defaults,noatime  0 1"
                ;;
            xfs)
                echo "${root_source}  /          xfs     defaults,noatime  0 1"
                ;;
            f2fs)
                echo "${root_source}  /          f2fs    defaults,noatime  0 1"
                ;;
        esac

        echo "UUID=${efi_uuid}   /boot/efi  vfat    umask=0077                                     0 2"
        [[ -n "$PART_SWAP" ]] && \
            echo "UUID=$(blkid -s UUID -o value "$PART_SWAP")  none       swap    sw                                             0 0"
        echo "tmpfs                         /tmp          tmpfs   defaults,nosuid,nodev,size=4G           0 0"
    } > /mnt/gentoo/etc/fstab

    log "fstab written."
}

# =============================================================================
# STAGE3
# =============================================================================

install_stage3() {
    section "Installing Stage3 Tarball"

    local base_url="https://distfiles.gentoo.org/releases/amd64/autobuilds"
    local stage3_url

    case "$STAGE3_VARIANT" in
        openrc)   stage3_url="${base_url}/current-stage3-amd64-openrc/stage3-amd64-openrc-latest.tar.xz" ;;
        systemd)  stage3_url="${base_url}/current-stage3-amd64-systemd/stage3-amd64-systemd-latest.tar.xz" ;;
        hardened) stage3_url="${base_url}/current-stage3-amd64-hardened/stage3-amd64-hardened-latest.tar.xz" ;;
        musl)     stage3_url="${base_url}/current-stage3-amd64-musl/stage3-amd64-musl-latest.tar.xz" ;;
        *)        error "Unknown STAGE3_VARIANT: $STAGE3_VARIANT" ;;
    esac

    cd /mnt/gentoo

    # FIX #11: add --tries=3 for transient network failures
    log "Downloading stage3 (${STAGE3_VARIANT})..."
    wget -q --show-progress --tries=3 "$stage3_url"    -O stage3.tar.xz
    # Fetch the detached signature and separate DIGESTS file
    wget -q --tries=3 "${stage3_url}.asc"              -O stage3.tar.xz.asc  2>/dev/null || true
    wget -q --tries=3 "${stage3_url}.DIGESTS"          -O stage3.tar.xz.DIGESTS 2>/dev/null || true
    wget -q --tries=3 "${stage3_url}.DIGESTS.asc"      -O stage3.tar.xz.DIGESTS.asc 2>/dev/null || true

    log "Verifying GPG signature..."
    gpg --keyserver hkps://keys.openpgp.org \
        --recv-keys 13EBBDBEDE7A12775DFDB1BABB572E0E2D182910 2>/dev/null \
        || warn "GPG key import failed — skipping signature check."

    local gpg_ok=0
    if gpg --verify stage3.tar.xz.asc stage3.tar.xz 2>/dev/null; then
        log "GPG signature verified (detached .asc)."
        gpg_ok=1
    elif gpg --verify stage3.tar.xz.DIGESTS.asc stage3.tar.xz.DIGESTS 2>/dev/null; then
        log "GPG signature verified (DIGESTS.asc)."
        gpg_ok=1
    fi

    # FIX #4: checksum from the dedicated DIGESTS file, not the .asc armored blob.
    # The .asc is a binary/armored signature — grepping it for hex strings is unreliable.
    if [[ "$gpg_ok" -eq 1 && -f stage3.tar.xz.DIGESTS ]]; then
        local expected actual tarball="stage3.tar.xz"
        expected=$(grep -E "^[0-9a-f]{128}  .*stage3.*\.tar\.xz$" stage3.tar.xz.DIGESTS \
                   | grep -v "\.asc" | awk '{print $1}')
        if [[ -n "$expected" ]]; then
            actual=$(sha512sum "$tarball" | awk '{print $1}')
            if [[ "$expected" == "$actual" ]]; then
                log "SHA512 checksum verified."
            else
                error "SHA512 mismatch — aborting."
            fi
        else
            warn "No SHA512 entry found in DIGESTS — skipping checksum."
        fi
    elif [[ "$gpg_ok" -eq 0 ]]; then
        warn "GPG verification skipped — verify manually if security is critical."
    fi

    log "Extracting stage3..."
    tar xpf stage3.tar.xz --xattrs-include='*.*' --numeric-owner
    rm -f stage3.tar.xz stage3.tar.xz.asc stage3.tar.xz.DIGESTS stage3.tar.xz.DIGESTS.asc

    log "Stage3 installed."
}

# =============================================================================
# PORTAGE CONFIGURATION
# =============================================================================

configure_portage() {
    section "Configuring Portage"

    mkdir -p /mnt/gentoo/etc/portage/{package.use,package.accept_keywords,package.license,repos.conf,env,package.mask}

    log "Writing make.conf..."
    cat > /mnt/gentoo/etc/portage/make.conf << EOF
# =============================================================================
# make.conf — generated $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# =============================================================================

# Compiler flags
COMMON_FLAGS="-O2 -pipe -march=native"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
RUSTFLAGS="-C opt-level=2 -C target-cpu=native"
LDFLAGS="-Wl,-O1 -Wl,--as-needed"

# Build parallelism
MAKEOPTS="${MAKEOPTS}"
EMERGE_DEFAULT_OPTS="--jobs=$(nproc) --load-average=$(nproc) --with-bdeps=y --keep-going --verbose-conflicts"
PORTAGE_NICENESS=15

# USE flags
USE="${USE_FLAGS}"

# Licences
ACCEPT_LICENSE="-* @FREE @BINARY-REDISTRIBUTABLE"

# Arch
ACCEPT_KEYWORDS="${ACCEPT_KEYWORDS}"

# Localisation
L10N="en en-US"
LINGUAS="en en_US"

# GPU
VIDEO_CARDS="${VIDEO_CARDS}"
INPUT_DEVICES="libinput"

# Mirrors
GENTOO_MIRRORS="${GENTOO_MIRRORS}"

# Portage dirs
DISTDIR="/var/cache/distfiles"
PKGDIR="/var/cache/binpkgs"
PORTDIR="/var/db/repos/gentoo"

# Logging
PORTAGE_ELOG_CLASSES="warn error log"
PORTAGE_ELOG_SYSTEM="save"

# Features
FEATURES="parallel-fetch parallel-install buildpkg clean-logs split-elog"

# GRUB EFI target
GRUB_PLATFORMS="efi-64"
EOF

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
EOF

    _configure_portage_display
    _configure_portage_gpu
    _configure_portage_audio
    _configure_portage_optional

    log "Portage configuration complete."
}

_configure_portage_display() {
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
        river)
            cat >> "$kw_file" << 'EOF'
gui-wm/river             ~amd64
EOF
            ;;
        cosmic)
            cat >> "$kw_file" << 'EOF'
gui-wm/cosmic-comp       ~amd64
gui-apps/cosmic-term     ~amd64
gui-apps/cosmic-files    ~amd64
gui-apps/cosmic-launcher ~amd64
EOF
            ;;
        labwc)
            cat >> "$kw_file" << 'EOF'
gui-wm/labwc             ~amd64
EOF
            ;;
    esac

    if [[ "$DISPLAY_SERVER" == "wayland" || "$DISPLAY_SERVER" == "both" ]]; then
        cat > /mnt/gentoo/etc/portage/package.use/wayland << 'EOF'
gui-libs/wlroots       X drm gles2 vulkan xwayland
dev-libs/wayland       doc
x11-base/xwayland      -glamor
EOF
    fi
}

_configure_portage_gpu() {
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
}

_configure_portage_audio() {
    if [[ "$ENABLE_PIPEWIRE" == "yes" ]]; then
        cat > /mnt/gentoo/etc/portage/package.use/audio << 'EOF'
media-video/pipewire    sound-server jack-sdk v4l screencast bluetooth
media-sound/wireplumber -systemd
EOF
    fi
}

_configure_portage_optional() {
    if [[ "$ENABLE_FLATPAK" == "yes" ]]; then
        cat >> /mnt/gentoo/etc/portage/package.use/desktop << 'EOF'
sys-apps/xdg-desktop-portal  flatpak
EOF
    fi

    if [[ "$ENABLE_LIBVIRT" == "yes" ]]; then
        cat >> /mnt/gentoo/etc/portage/package.use/virt << 'EOF'
app-emulation/libvirt  qemu virt-network
app-emulation/qemu     spice usb
EOF
    fi
}

# =============================================================================
# CHROOT SETUP
# =============================================================================

setup_chroot() {
    section "Preparing chroot"

    cp --dereference /etc/resolv.conf /mnt/gentoo/etc/

    mount --types proc  /proc /mnt/gentoo/proc
    mount --rbind       /sys  /mnt/gentoo/sys
    mount --make-rslave       /mnt/gentoo/sys
    mount --rbind       /dev  /mnt/gentoo/dev
    mount --make-rslave       /mnt/gentoo/dev
    mount --bind        /run  /mnt/gentoo/run
    mount --make-slave        /mnt/gentoo/run

    if [[ -d /sys/firmware/efi/efivars ]]; then
        mount --bind /sys/firmware/efi/efivars \
            /mnt/gentoo/sys/firmware/efi/efivars
    fi

    log "Chroot ready."
}

# =============================================================================
# CHROOT SCRIPT
# =============================================================================

write_chroot_script() {
    section "Writing chroot script"

    # FIX #10: create the file with mode 700 *before* writing content so
    # ROOT_HASH / USER_HASH are never readable by other users even briefly.
    install -m 700 /dev/null /mnt/gentoo/root/chroot-install.sh

    # NOTE: The heredoc uses an unquoted delimiter (CHROOT_EOF) intentionally —
    # outer-scope shell variables (HOSTNAME, INIT_SYSTEM, etc.) are expanded
    # here so their values are baked into the chroot script.  Inner variables
    # that must remain literal use escaped \$ or quoted-delimiter sub-heredocs.
    cat >> /mnt/gentoo/root/chroot-install.sh << CHROOT_EOF
#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m';  GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m';   BOLD='\033[1m'; NC='\033[0m'
log()     { echo -e "\${GREEN}[+]\${NC} \$*"; }
warn()    { echo -e "\${YELLOW}[!]\${NC} \$*"; }
error()   { echo -e "\${RED}[✗]\${NC} \$*" >&2; exit 1; }
section() {
    echo -e "\n\${BOLD}\${BLUE}══════════════════════════════════════════════\${NC}"
    echo -e "\${BOLD}\${CYAN}  \$*\${NC}"
    echo -e "\${BOLD}\${BLUE}══════════════════════════════════════════════\${NC}\n"
}

# ── Environment ───────────────────────────────────────────────────────────────
source /etc/profile
export PS1="(chroot) \${PS1}"

# ── Portage sync ──────────────────────────────────────────────────────────────
section "Syncing Portage tree"
emerge-webrsync
eselect news read all

# ── Profile ───────────────────────────────────────────────────────────────────
section "Setting profile"
PROFILE_PATTERN="amd64/23.0/desktop"
[[ "${INIT_SYSTEM}" == "systemd" ]] && PROFILE_PATTERN="\${PROFILE_PATTERN}/systemd"

# FIX #15: anchor match with a trailing space/bracket so "desktop" doesn't
# accidentally match "desktop/plasma" or "desktop/gnome".
PROFILE_NUM=\$(eselect profile list \
    | awk -v pat="\${PROFILE_PATTERN}" '\$0 ~ pat"[[:space:]]" && !/musl/ {print \$1; exit}' \
    | tr -d '[]')
if [[ -n "\$PROFILE_NUM" ]]; then
    eselect profile set "\$PROFILE_NUM"
    log "Profile: \$(eselect profile show | tail -1 | xargs)"
else
    warn "Could not auto-select profile — run: eselect profile set"
fi

# ── Timezone & Locale ─────────────────────────────────────────────────────────
section "Timezone & Locale"
echo "${TIMEZONE}" > /etc/timezone
emerge -q --config sys-libs/timezone-data

echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
LOC=\$(locale -a | grep -i "\$(echo "${LOCALE}" | tr '[:upper:]' '[:lower:]' | sed 's/utf-8/utf8/')" | head -1)
[[ -n "\$LOC" ]] && eselect locale set "\$LOC" || warn "Set locale manually: eselect locale set"
env-update && source /etc/profile

# ── Firmware & Microcode ──────────────────────────────────────────────────────
section "Firmware & Microcode"
[[ "${CPU_VENDOR}" == "intel" ]] && emerge -q sys-firmware/intel-microcode
emerge -q sys-firmware/linux-firmware

# ── Kernel ────────────────────────────────────────────────────────────────────
section "Kernel: ${KERNEL_TYPE}"
case "${KERNEL_TYPE}" in
    dist)
        emerge -q sys-kernel/gentoo-kernel-bin
        ;;
    sources|hardened|rt)
        case "${KERNEL_TYPE}" in
            sources)  emerge -q sys-kernel/gentoo-sources ;;
            hardened) emerge -q sys-kernel/hardened-sources ;;
            rt)       emerge -q sys-kernel/rt-sources ;;
        esac
        eselect kernel set 1
        cd /usr/src/linux

        case "${KERNEL_CONFIG}" in
            defconfig)
                make defconfig
                scripts/config --enable CONFIG_EFI_STUB
                scripts/config --enable CONFIG_EFI_PARTITION
                [[ "${ENABLE_LUKS}" == "yes" ]] && {
                    scripts/config --enable CONFIG_DM_CRYPT
                    scripts/config --enable CONFIG_CRYPTO_AES
                    scripts/config --enable CONFIG_CRYPTO_XTS
                }
                make olddefconfig
                make ${MAKEOPTS}
                make modules_install
                make install
                ;;
            genkernel)
                emerge -q sys-kernel/genkernel
                genkernel --menuconfig=no \
                          --makeopts="${MAKEOPTS}" \
                          $( [[ "${ENABLE_LUKS}" == "yes" ]] && echo "--luks" ) \
                          all
                ;;
            manual)
                warn "Launching menuconfig — configure and save, then exit."
                make menuconfig
                make ${MAKEOPTS}
                make modules_install
                make install
                ;;
        esac
        ;;
esac

# ── Base system packages ──────────────────────────────────────────────────────
section "Base system packages"
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

# FIX #16: only emerge fs tools relevant to the chosen filesystem
case "${FS_TYPE}" in
    xfs)  emerge -q sys-fs/xfsprogs ;;
    f2fs) emerge -q sys-fs/f2fs-tools ;;
esac

[[ "${ENABLE_LUKS}" == "yes" ]] && emerge -q sys-fs/cryptsetup

# ── Hostname & Networking ─────────────────────────────────────────────────────
section "Hostname & network"
echo "${HOSTNAME}" > /etc/hostname

cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF

# ── OpenRC / systemd services ─────────────────────────────────────────────────
section "Init services"
if [[ "${INIT_SYSTEM}" == "openrc" ]]; then
    rc-update add NetworkManager default
    rc-update add elogind boot
    rc-update add dbus default
    rc-update add udev sysinit
    rc-update add cronie default
    rc-update add sshd default 2>/dev/null || true
else
    systemctl enable NetworkManager
    systemctl enable dbus
    systemctl enable cronie
fi

# ── Display server packages ───────────────────────────────────────────────────
section "Display server: ${DISPLAY_SERVER}"
if [[ "${DISPLAY_SERVER}" == "x11" || "${DISPLAY_SERVER}" == "both" ]]; then
    emerge -q \
        x11-base/xorg-server \
        x11-apps/xinit \
        x11-misc/xkeyboard-config \
        x11-libs/libX11 \
        x11-libs/libXrandr \
        x11-libs/libXinerama
fi

if [[ "${DISPLAY_SERVER}" == "wayland" || "${DISPLAY_SERVER}" == "both" ]]; then
    emerge -q \
        dev-libs/wayland \
        dev-libs/wayland-protocols \
        x11-base/xwayland \
        x11-libs/libdrm \
        x11-libs/pixman \
        x11-misc/xkeyboard-config
fi

# ── Mesa / GPU drivers ────────────────────────────────────────────────────────
section "GPU drivers: ${GPU_VENDOR}"
emerge -q media-libs/mesa media-libs/libva media-libs/libva-utils

case "${GPU_VENDOR}" in
    amd)
        emerge -q media-libs/vulkan-loader dev-util/vulkan-tools
        ;;
    intel)
        emerge -q media-libs/intel-media-driver media-libs/vulkan-loader
        ;;
    nvidia)
        emerge -q x11-drivers/nvidia-drivers
        [[ "${INIT_SYSTEM}" == "openrc" ]] \
            && rc-update add modules boot \
            && echo "nvidia" >> /etc/modules-load.d/nvidia.conf
        ;;
esac

# ── Desktop environment / WM ──────────────────────────────────────────────────
section "Desktop: ${DESKTOP_ENV}"
case "${DESKTOP_ENV}" in
    gnome)
        emerge -q gnome-base/gnome gnome-base/gnome-extra-apps
        [[ "${INIT_SYSTEM}" == "openrc" ]] \
            && rc-update add gdm default \
            || systemctl enable gdm
        ;;
    kde)
        emerge -q kde-plasma/plasma-meta kde-apps/kde-apps-meta
        [[ "${INIT_SYSTEM}" == "openrc" ]] \
            && rc-update add sddm default \
            || systemctl enable sddm
        ;;
    cosmic)
        emerge -q \
            gui-wm/cosmic-comp \
            gui-apps/cosmic-term \
            gui-apps/cosmic-files \
            gui-apps/cosmic-launcher \
            gui-apps/cosmic-settings
        ;;
    sway)
        emerge -q \
            gui-wm/sway \
            gui-apps/swaybar \
            gui-apps/swaybg \
            gui-apps/swayidle \
            gui-apps/swaylock \
            gui-apps/foot \
            gui-apps/fuzzel \
            gui-apps/mako \
            gui-apps/grim \
            gui-apps/slurp \
            gui-apps/wl-clipboard \
            gui-libs/xdg-desktop-portal-gtk
        ;;
    niri)
        emerge -q \
            gui-wm/niri \
            gui-apps/swayidle \
            gui-apps/swaylock \
            gui-apps/foot \
            gui-apps/fuzzel \
            gui-apps/mako \
            gui-apps/waybar \
            gui-apps/grim \
            gui-apps/slurp \
            gui-apps/wl-clipboard \
            gui-libs/xdg-desktop-portal-gtk \
            x11-libs/xcb-util-cursor
        ;;
    hyprland)
        emerge -q \
            gui-wm/hyprland \
            gui-apps/swayidle \
            gui-apps/swaylock \
            gui-apps/foot \
            gui-apps/fuzzel \
            gui-apps/mako \
            gui-apps/waybar \
            gui-apps/grim \
            gui-apps/slurp \
            gui-apps/wl-clipboard \
            gui-libs/xdg-desktop-portal-gtk
        ;;
    river)
        emerge -q \
            gui-wm/river \
            gui-apps/foot \
            gui-apps/fuzzel \
            gui-apps/mako \
            gui-apps/waybar \
            gui-apps/wl-clipboard \
            gui-libs/xdg-desktop-portal-gtk
        ;;
    labwc)
        emerge -q \
            gui-wm/labwc \
            gui-apps/foot \
            gui-apps/fuzzel \
            gui-apps/mako \
            gui-apps/wl-clipboard \
            gui-libs/xdg-desktop-portal-gtk
        ;;
    xfce)
        emerge -q \
            xfce-base/xfce4-meta \
            x11-misc/lightdm \
            x11-misc/lightdm-gtk-greeter
        [[ "${INIT_SYSTEM}" == "openrc" ]] \
            && rc-update add lightdm default \
            || systemctl enable lightdm
        ;;
    lxqt)
        emerge -q \
            lxqt-base/lxqt-meta \
            x11-misc/sddm
        [[ "${INIT_SYSTEM}" == "openrc" ]] \
            && rc-update add sddm default \
            || systemctl enable sddm
        ;;
    openbox)
        emerge -q \
            x11-wm/openbox \
            x11-misc/obconf \
            x11-apps/xrandr \
            x11-misc/tint2 \
            x11-misc/rofi
        ;;
    i3)
        emerge -q \
            x11-wm/i3 \
            x11-misc/i3status \
            x11-misc/i3lock \
            x11-misc/rofi \
            x11-apps/xrandr \
            x11-misc/picom
        ;;
    dwm)
        emerge -q \
            x11-wm/dwm \
            x11-misc/dmenu \
            x11-misc/st
        ;;
    none|custom)
        log "Skipping desktop install (none/custom)."
        ;;
esac

# ── Audio ─────────────────────────────────────────────────────────────────────
if [[ "${ENABLE_PIPEWIRE}" == "yes" ]]; then
    section "PipeWire audio"
    emerge -q \
        media-video/pipewire \
        media-sound/wireplumber \
        media-sound/pavucontrol
    [[ "${INIT_SYSTEM}" == "openrc" ]] \
        && rc-update add pipewire default \
        || true
fi

# ── Bluetooth ─────────────────────────────────────────────────────────────────
if [[ "${ENABLE_BLUETOOTH}" == "yes" ]]; then
    section "Bluetooth"
    emerge -q net-wireless/bluez app-misc/blueman
    [[ "${INIT_SYSTEM}" == "openrc" ]] \
        && rc-update add bluetooth default \
        || systemctl enable bluetooth
fi

# ── Printing ──────────────────────────────────────────────────────────────────
if [[ "${ENABLE_PRINTING}" == "yes" ]]; then
    section "Printing (CUPS + Avahi)"
    emerge -q net-print/cups net-dns/avahi app-text/ghostscript-gpl
    [[ "${INIT_SYSTEM}" == "openrc" ]] && {
        rc-update add cupsd default
        rc-update add avahi-daemon default
    } || {
        systemctl enable cups
        systemctl enable avahi-daemon
    }
fi

# ── Flatpak ───────────────────────────────────────────────────────────────────
if [[ "${ENABLE_FLATPAK}" == "yes" ]]; then
    section "Flatpak"
    emerge -q sys-apps/flatpak
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
fi

# ── Libvirt / QEMU ────────────────────────────────────────────────────────────
if [[ "${ENABLE_LIBVIRT}" == "yes" ]]; then
    section "Libvirt / QEMU"
    emerge -q app-emulation/libvirt app-emulation/qemu app-emulation/virt-manager
    [[ "${INIT_SYSTEM}" == "openrc" ]] \
        && rc-update add libvirtd default \
        || systemctl enable libvirtd
fi

# ── Docker / Podman ───────────────────────────────────────────────────────────
if [[ "${ENABLE_DOCKER}" == "yes" ]]; then
    section "Containers"
    emerge -q app-containers/docker app-containers/podman app-containers/docker-compose
    [[ "${INIT_SYSTEM}" == "openrc" ]] \
        && rc-update add docker default \
        || systemctl enable docker
fi

# ── Snapper (Btrfs snapshots) ─────────────────────────────────────────────────
if [[ "${ENABLE_BTRFS_SNAPPER}" == "yes" && "${FS_TYPE}" == "btrfs" ]]; then
    section "Snapper"
    emerge -q app-backup/snapper
    snapper -c root create-config /
    [[ "${INIT_SYSTEM}" == "openrc" ]] \
        && rc-update add snapper-timeline default \
        && rc-update add snapper-cleanup default \
        || { systemctl enable snapper-timeline.timer; systemctl enable snapper-cleanup.timer; }
fi

# ── Extra packages ────────────────────────────────────────────────────────────
if [[ -n "${EXTRA_PACKAGES}" ]]; then
    section "Extra packages"
    # shellcheck disable=SC2086
    emerge -q ${EXTRA_PACKAGES}
fi

# ── Common fonts & themes ─────────────────────────────────────────────────────
section "Fonts & themes"
emerge -q \
    media-fonts/noto \
    media-fonts/noto-emoji \
    media-fonts/fira-code \
    x11-themes/papirus-icon-theme \
    x11-themes/capitaine-cursors

# ── GRUB ──────────────────────────────────────────────────────────────────────
section "GRUB bootloader"
emerge -q sys-boot/grub

GRUB_CMDLINE="quiet loglevel=3 mitigations=auto"
[[ "${ENABLE_LUKS}" == "yes" ]] \
    && GRUB_CMDLINE="\${GRUB_CMDLINE} rd.luks=1"

cat >> /etc/default/grub << EOF
GRUB_CMDLINE_LINUX_DEFAULT="\${GRUB_CMDLINE}"
GRUB_TIMEOUT=3
GRUB_GFXMODE=auto
EOF

grub-install --target=x86_64-efi \
             --efi-directory=/boot/efi \
             --bootloader-id=gentoo \
             --recheck

grub-mkconfig -o /boot/grub/grub.cfg

# ── Secure Boot (sbctl) ───────────────────────────────────────────────────────
if [[ "${ENABLE_SECURE_BOOT}" == "yes" ]]; then
    section "Secure Boot"
    if command -v sbctl &>/dev/null; then
        sbctl create-keys
        # FIX #9: only enroll Microsoft keys when explicitly requested;
        # on Gentoo-only machines they add an unnecessary trust anchor.
        if [[ "${SECURE_BOOT_MICROSOFT_KEYS}" == "yes" ]]; then
            sbctl enroll-keys --microsoft
        else
            sbctl enroll-keys
        fi
        # FIX #6: glob covers both dist-kernel and compiled kernel paths
        sbctl sign -s /boot/efi/EFI/gentoo/grubx64.efi
        for vmlinuz in /boot/vmlinuz-*; do
            [[ -f "\$vmlinuz" ]] && sbctl sign -s "\$vmlinuz"
        done
        log "Secure Boot keys enrolled. Enable Secure Boot in firmware after reboot."
    else
        warn "sbctl not found — install app-crypt/sbctl post-boot and re-run signing."
    fi
fi

# ── Users ─────────────────────────────────────────────────────────────────────
section "Users"
echo "root:${ROOT_HASH}" | chpasswd -e

# FIX #2: resolve niri session binary name inside the chroot (at install
# time) rather than on the host at script-generation time.
NIRI_CMD="niri"
command -v niri-session &>/dev/null && NIRI_CMD="niri-session"

useradd -m \
    -G wheel,audio,video,input,seat,plugdev,usb,portage \
    $( [[ "${ENABLE_LIBVIRT}" == "yes" ]] && echo "-G libvirt" ) \
    $( [[ "${ENABLE_DOCKER}"  == "yes" ]] && echo "-G docker"  ) \
    -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${USER_HASH}" | chpasswd -e

install -m 440 /dev/null /etc/sudoers.d/wheel
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel

# ── Session auto-start (TTY1) ─────────────────────────────────────────────────
section "Session auto-start"
USER_HOME="/home/${USERNAME}"

_write_autostart() {
    local cmd="\$1"
    cat >> "\${USER_HOME}/.bash_profile" << BEOF

# Auto-start \${cmd} on TTY1
if [[ -z "\\\$DISPLAY" && -z "\\\$WAYLAND_DISPLAY" && "\\\${XDG_VTNR}" -eq 1 ]]; then
    exec \${cmd}
fi
BEOF
}

case "${DESKTOP_ENV}" in
    gnome|kde|xfce|lxqt) : ;;
    sway)     _write_autostart "sway" ;;
    niri)     _write_autostart "\${NIRI_CMD}" ;;
    hyprland) _write_autostart "Hyprland" ;;
    river)    _write_autostart "river" ;;
    labwc)    _write_autostart "labwc" ;;
    cosmic)   _write_autostart "cosmic-session" ;;
    openbox)  _write_autostart "openbox-session" ;;
    i3)       _write_autostart "i3" ;;
    dwm)      _write_autostart "dwm" ;;
    none|custom) warn "Configure session start manually." ;;
esac

# ── Wayland environment ───────────────────────────────────────────────────────
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
fi

# ── Keymap ────────────────────────────────────────────────────────────────────
sed -i 's/^keymap=.*/keymap="${KEYMAP}"/' /etc/conf.d/keymaps 2>/dev/null || true

# ── Fix ownership ─────────────────────────────────────────────────────────────
chown -R "${USERNAME}:${USERNAME}" "\${USER_HOME}"

section "Chroot phase complete."
CHROOT_EOF

    log "Chroot script written."
}

# =============================================================================
# RUN CHROOT
# =============================================================================

run_chroot() {
    section "Entering chroot"
    chroot /mnt/gentoo /bin/bash /root/chroot-install.sh
}

# =============================================================================
# CLEANUP
# =============================================================================

cleanup() {
    section "Cleanup & unmount"

    rm -f /mnt/gentoo/root/chroot-install.sh

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
        mountpoint -q "$mp" 2>/dev/null && umount -R "$mp" 2>/dev/null || true
    done

    [[ -n "$PART_SWAP" ]] && swapoff "$PART_SWAP" 2>/dev/null || true

    if [[ "$ENABLE_LUKS" == "yes" ]]; then
        cryptsetup close "$LUKS_NAME" 2>/dev/null || true
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

    parse_args "$@"
    load_config

    echo -e "  Config:   ${BOLD}${CONFIG_FILE}${NC}"
    echo -e "  Disk:     ${BOLD}${DISK}${NC}  (${FS_TYPE}$([ "$ENABLE_LUKS" = yes ] && echo " + LUKS2"))"
    echo -e "  Init:     ${BOLD}${INIT_SYSTEM}${NC}"
    echo -e "  Display:  ${BOLD}${DISPLAY_SERVER}${NC}"
    echo -e "  Desktop:  ${BOLD}${DESKTOP_ENV}${NC}"
    echo -e "  Kernel:   ${BOLD}${KERNEL_TYPE}${NC}"
    echo -e "  CPU/GPU:  ${BOLD}${CPU_VENDOR}${NC} / ${BOLD}${GPU_VENDOR}${NC}"
    echo ""

    trap cleanup EXIT

    preflight_checks
    partition_disk
    install_stage3        # FIX #5: stage3 extracted first → /mnt/gentoo/etc/ exists
    write_fstab           #         fstab written after, so the directory is present
    configure_portage
    setup_chroot
    write_chroot_script
    run_chroot
    cleanup

    trap - EXIT

    echo ""
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  Installation complete!${NC}"
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
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
}

main "$@"