#!/usr/bin/env bash
# =============================================================================
# Gentoo Linux Installation Script  —  2025/2026
# Supports: OpenRC / systemd  ·  Wayland / X11 / both
#           Any WM/DE  ·  btrfs/ext4/xfs/f2fs  ·  LUKS2  ·  Secure Boot
#
# Usage:
#   bash gentoo-install.sh                          # looks for gentoo-install.conf
#   bash gentoo-install.sh --config gentoo-install.conf
#
# Logs are written to /tmp/gentoo-install-<timestamp>.log
# Follow live with: tail -f /tmp/gentoo-install-<timestamp>.log
# =============================================================================

set -eo pipefail
IFS=$'\n\t'

# =============================================================================
# COLORS  — must be defined BEFORE the logging functions that use them
# =============================================================================

RED='\033[0;31m';  GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m';   BOLD='\033[1m'; NC='\033[0m'

# =============================================================================
# LOGGING SETUP
# =============================================================================

LOG_FILE="/tmp/gentoo-install-$(date +%Y%m%d-%H%M%S).log"
STEP_NUM=0

exec 3>&1 4>&2
exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1

_log_raw() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

log()     { echo -e "${GREEN}[+]${NC} $*";  _log_raw "[INFO]  $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; _log_raw "[WARN]  $*"; }
error()   { echo -e "${RED}[✗]${NC} $*" >&2; _log_raw "[ERROR] $*"; exit 1; }
debug()   { echo -e "${CYAN}[…]${NC} $*";  _log_raw "[DEBUG] $*"; }

section() {
    STEP_NUM=$((STEP_NUM + 1))
    echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  Step ${STEP_NUM}: $*${NC}"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════════════${NC}\n"
    _log_raw "====== STEP ${STEP_NUM}: $* ======"
}

_install_start_time=$SECONDS
_on_exit() {
    local code=$?
    local elapsed=$(( SECONDS - _install_start_time ))
    local mins=$(( elapsed / 60 )); local secs=$(( elapsed % 60 ))
    echo "" >> "$LOG_FILE"
    if [[ $code -eq 0 ]]; then
        _log_raw "====== INSTALL SUCCEEDED in ${mins}m ${secs}s (exit 0) ======"
    else
        _log_raw "====== INSTALL FAILED after ${mins}m ${secs}s (exit ${code}) ======"
        echo -e "\n${RED}${BOLD}[✗] Installation failed. Check the log:${NC} ${BOLD}${LOG_FILE}${NC}"
        echo -e "    Last 20 lines:\n"; tail -20 "$LOG_FILE" >&3
    fi
}
trap _on_exit EXIT

# =============================================================================
# SYSTEM DETECTION  — run once on host, reused throughout
# =============================================================================

NCPU=$(nproc)
RAM_GIB=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)
TMPFS_SIZE=$(( RAM_GIB / 2 )); [[ $TMPFS_SIZE -lt 4 ]] && TMPFS_SIZE=4

# RUST_CGU is derived from NCPU but must be recalculated AFTER config is loaded
# in case the config overrides NCPU.  A placeholder is set here; the real value
# is computed in load_config() once all variables are settled.
RUST_CGU=0

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
# FIX: default to ~amd64 so Wayland compositors (niri, hyprland, river …)
# and other modern packages are reachable without per-package keywords.
ACCEPT_KEYWORDS="~amd64"
CPU_VENDOR="amd"
GPU_VENDOR="amd"
VIDEO_CARDS="amdgpu radeonsi"
KERNEL_TYPE="dist"
KERNEL_CONFIG="defconfig"
DISPLAY_SERVER="wayland"
DESKTOP_ENV="none"
DISPLAY_MANAGER="none"
USE_FLAGS="wayland -X -gnome -kde -plasma udev dbus policykit"
MAKEOPTS="-j${NCPU} -l${NCPU}"
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
CCACHE_SIZE="10G"

PART_EFI=""; PART_SWAP=""; PART_ROOT=""
ROOT_HASH=""; USER_HASH=""
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
                echo "Usage: $0 [--config FILE]"; exit 0 ;;
            *) error "Unknown argument: $1" ;;
        esac
    done
}

load_config() {
    if [[ -z "$CONFIG_FILE" ]]; then
        [[ -f "gentoo-install.conf" ]] \
            && { warn "No --config specified; using gentoo-install.conf"; CONFIG_FILE="gentoo-install.conf"; } \
            || error "No config file found."
    fi
    [[ ! -f "$CONFIG_FILE" ]] && error "Config file not found: $CONFIG_FILE"

    # FIX: only source variables that belong to the known whitelist to prevent
    # arbitrary code execution from a malicious or misconfigured config file.
    local allowed_vars=(
        DISK EFI_SIZE SWAP_SIZE FS_TYPE HOSTNAME USERNAME TIMEZONE LOCALE KEYMAP
        INIT_SYSTEM ACCEPT_KEYWORDS CPU_VENDOR GPU_VENDOR VIDEO_CARDS KERNEL_TYPE
        KERNEL_CONFIG DISPLAY_SERVER DESKTOP_ENV DISPLAY_MANAGER USE_FLAGS
        MAKEOPTS STAGE3_VARIANT ENABLE_LUKS ENABLE_BTRFS_SNAPPER ENABLE_PIPEWIRE
        ENABLE_BLUETOOTH ENABLE_PRINTING ENABLE_FLATPAK ENABLE_LIBVIRT ENABLE_DOCKER
        ENABLE_SECURE_BOOT SECURE_BOOT_MICROSOFT_KEYS EXTRA_PACKAGES CCACHE_SIZE
        NCPU
    )
    local tmp_env
    tmp_env=$(mktemp)
    # Parse only KEY=VALUE lines; skip comments, blank lines, and anything with
    # shell metacharacters in the value that could inject commands.
    grep -E '^[A-Z_]+=.*$' "$CONFIG_FILE" \
        | grep -v '[`$();|&<>]' > "$tmp_env" || true

    while IFS='=' read -r key value; do
        # Strip surrounding quotes from value
        value="${value#[\"\']}"
        value="${value%[\"\']}"
        local ok=0
        for v in "${allowed_vars[@]}"; do [[ "$v" == "$key" ]] && ok=1 && break; done
        if [[ $ok -eq 1 ]]; then
            printf -v "$key" '%s' "$value"
        else
            warn "Config: ignoring unknown variable '$key'"
        fi
    done < "$tmp_env"
    rm -f "$tmp_env"

    # FIX: recompute RUST_CGU now that NCPU is finalised from config
    RUST_CGU=$(( NCPU > 4 ? NCPU / 2 : NCPU ))
    # Recompute MAKEOPTS in case NCPU changed
    MAKEOPTS="-j${NCPU} -l${NCPU}"
    # Recompute TMPFS_SIZE in case RAM changed
    TMPFS_SIZE=$(( RAM_GIB / 2 )); [[ $TMPFS_SIZE -lt 4 ]] && TMPFS_SIZE=4

    log "Loaded config: $CONFIG_FILE"
    _log_raw "--- Resolved configuration ---"
    _log_raw "DISK=${DISK}  FS=${FS_TYPE}  LUKS=${ENABLE_LUKS}  SWAP=${SWAP_SIZE}G"
    _log_raw "HOSTNAME=${HOSTNAME}  USER=${USERNAME}"
    _log_raw "INIT=${INIT_SYSTEM}  KERNEL=${KERNEL_TYPE}  DISPLAY=${DISPLAY_SERVER}  DE=${DESKTOP_ENV}  DM=${DISPLAY_MANAGER:-none}"
    _log_raw "CPU=${CPU_VENDOR}  GPU=${GPU_VENDOR}  VIDEO_CARDS=${VIDEO_CARDS}"
    _log_raw "NCPU=${NCPU}  RAM=${RAM_GIB}G  TMPFS=${TMPFS_SIZE}G  CCACHE=${CCACHE_SIZE}"
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

    [[ $EUID -ne 0 ]] && error "Must be run as root."
    [[ ! -b "$DISK" ]] && error "Disk $DISK not found."
    _log_raw "Disk ${DISK}: $(lsblk -dno SIZE,MODEL "$DISK" 2>/dev/null || echo 'info unavailable')"
    _log_raw "Host CPU: ${NCPU} threads  RAM: ${RAM_GIB}G  Build tmpfs: ${TMPFS_SIZE}G"

    # FIX: warn if TMPFS_SIZE is likely too small for large packages (Mesa, LLVM, Qt)
    if [[ $TMPFS_SIZE -lt 8 ]]; then
        warn "Build tmpfs is ${TMPFS_SIZE}G — large packages (Mesa, LLVM, Qt) may need 8G+."
        warn "Consider setting more RAM or reducing parallel jobs."
    fi

    local tools=(wipefs sgdisk mkfs.fat mkswap wget gpg openssl chroot)
    for t in "${tools[@]}"; do
        command -v "$t" &>/dev/null || error "Required tool not found: $t"
    done

    [[ "$ENABLE_LUKS" == "yes" ]] && \
        { command -v cryptsetup &>/dev/null || error "cryptsetup not found."; }
    [[ "$ENABLE_SECURE_BOOT" == "yes" ]] && \
        { command -v sbctl &>/dev/null || warn "sbctl not found — Secure Boot will be manual."; }

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
    _log_raw "Passwords hashed (SHA-512)."

    if [[ "$ENABLE_LUKS" == "yes" ]]; then
        read -rsp "  Enter LUKS passphrase: "    lp1 </dev/tty; echo
        read -rsp "  Confirm LUKS passphrase: "  lp2 </dev/tty; echo
        [[ "$lp1" != "$lp2" ]] && error "LUKS passphrases do not match."
        LUKS_PASSPHRASE="$lp1"; unset lp1 lp2
    fi

    ping -c 2 -W 5 gentoo.org &>/dev/null || error "No internet connection."
    log "Internet connectivity: OK"

    debug "Syncing system clock..."
    if timedatectl set-ntp true &>/dev/null; then
        sleep 3
        _log_raw "Clock synced via timedatectl"
    elif chronyd -q &>/dev/null; then
        _log_raw "Clock synced via chronyd"
    elif ntpd -gq &>/dev/null; then
        _log_raw "Clock synced via ntpd"
    else
        warn "Could not sync clock — continuing anyway."
    fi

    command -v aria2c &>/dev/null && _log_raw "aria2c available — will use for downloads"

    log "Pre-flight checks passed.  CPUs: ${NCPU}  RAM: ${RAM_GIB}G  Build tmpfs: ${TMPFS_SIZE}G"
}

# =============================================================================
# PARTITION HELPERS
# =============================================================================

_part_suffix() {
    [[ "$DISK" == *"nvme"* || "$DISK" == *"mmcblk"* ]] \
        && echo "${DISK}p${1}" || echo "${DISK}${1}"
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

    log "Wiping disk..."
    wipefs -a "$DISK"; sgdisk --zap-all "$DISK"

    local part_num=1
    sgdisk -n ${part_num}:0:+${EFI_SIZE}G -t ${part_num}:ef00 -c ${part_num}:"EFI" "$DISK"
    PART_EFI="$(_part_suffix $part_num)"; part_num=$((part_num + 1))

    if [[ "$SWAP_SIZE" != "0" ]]; then
        sgdisk -n ${part_num}:0:+${SWAP_SIZE}G -t ${part_num}:8200 -c ${part_num}:"swap" "$DISK"
        PART_SWAP="$(_part_suffix $part_num)"; part_num=$((part_num + 1))
    fi

    sgdisk -n ${part_num}:0:0 -t ${part_num}:8300 -c ${part_num}:"root" "$DISK"
    PART_ROOT="$(_part_suffix $part_num)"

    partprobe "$DISK"; udevadm settle

    mkfs.fat -F32 -n "EFI" "$PART_EFI"

    if [[ -n "$PART_SWAP" ]]; then
        mkswap -L "swap" "$PART_SWAP"; swapon "$PART_SWAP"
    fi

    local ROOT_DEVICE="$PART_ROOT"
    if [[ "$ENABLE_LUKS" == "yes" ]]; then
        cryptsetup luksFormat --type luks2 \
            --cipher aes-xts-plain64 --key-size 512 \
            --hash sha512 --pbkdf argon2id \
            "$PART_ROOT" - < <(printf '%s' "$LUKS_PASSPHRASE")
        cryptsetup open "$PART_ROOT" "$LUKS_NAME" < <(printf '%s' "$LUKS_PASSPHRASE")
        unset LUKS_PASSPHRASE
        ROOT_DEVICE="/dev/mapper/${LUKS_NAME}"
    fi

    mkdir -p /mnt/gentoo
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
            mount -o noatime "$ROOT_DEVICE" /mnt/gentoo ;;
        xfs)
            mkfs.xfs -L "gentoo" -f "$ROOT_DEVICE"
            mount -o noatime "$ROOT_DEVICE" /mnt/gentoo ;;
        f2fs)
            mkfs.f2fs -l "gentoo" -O extra_attr,inode_checksum,sb_checksum "$ROOT_DEVICE"
            mount -o noatime "$ROOT_DEVICE" /mnt/gentoo ;;
    esac

    mkdir -p /mnt/gentoo/boot/efi
    mount "$PART_EFI" /mnt/gentoo/boot/efi

    log "Partition layout complete."
    findmnt --target /mnt/gentoo -R 2>/dev/null >> "$LOG_FILE" || true
}

# =============================================================================
# FSTAB
# =============================================================================

write_fstab() {
    section "Generating /etc/fstab"

    local root_source efi_uuid
    efi_uuid=$(blkid -s UUID -o value "$PART_EFI")

    if [[ "$ENABLE_LUKS" == "yes" ]]; then
        root_source="/dev/mapper/${LUKS_NAME}"
        local luks_uuid; luks_uuid=$(blkid -s UUID -o value "$PART_ROOT")
        echo "${LUKS_NAME}  UUID=${luks_uuid}  none  luks,discard" > /mnt/gentoo/etc/crypttab
    else
        root_source="UUID=$(blkid -s UUID -o value "$PART_ROOT")"
    fi

    {
        echo "# <fs>  <mp>  <type>  <opts>  <dump> <pass>"
        case "$FS_TYPE" in
            btrfs)
                local o="noatime,compress=zstd:1,space_cache=v2"
                echo "${root_source}  /            btrfs  ${o},subvol=@           0 0"
                echo "${root_source}  /home        btrfs  ${o},subvol=@home       0 0"
                echo "${root_source}  /.snapshots  btrfs  ${o},subvol=@snapshots  0 0"
                echo "${root_source}  /var/log     btrfs  ${o},subvol=@var_log    0 0"
                ;;
            ext4) echo "${root_source}  /  ext4  defaults,noatime  0 1" ;;
            xfs)  echo "${root_source}  /  xfs   defaults,noatime  0 1" ;;
            f2fs) echo "${root_source}  /  f2fs  defaults,noatime  0 1" ;;
        esac
        echo "UUID=${efi_uuid}  /boot/efi  vfat  umask=0077  0 2"
        [[ -n "$PART_SWAP" ]] && \
            echo "UUID=$(blkid -s UUID -o value "$PART_SWAP")  none  swap  sw  0 0"
        echo "tmpfs  /tmp  tmpfs  defaults,nosuid,nodev,size=4G  0 0"
    } > /mnt/gentoo/etc/fstab

    log "fstab written."
}

# =============================================================================
# STAGE3
# =============================================================================

install_stage3() {
    section "Installing Stage3 Tarball"

    # FIX: Dynamically resolve the latest stage3 URL from the Gentoo autobuilds
    # manifest instead of using a hardcoded URL that immediately goes stale.
    # Also honour STAGE3_VARIANT (openrc / systemd / desktop-openrc / etc.)
    local base_url="https://distfiles.gentoo.org/releases/amd64/autobuilds"
    local latest_file

    # The "current" symlink points to the most recent build directory
    case "$STAGE3_VARIANT" in
        openrc)   latest_file="latest-stage3-amd64-openrc.txt" ;;
        systemd)  latest_file="latest-stage3-amd64-systemd.txt" ;;
        *)        latest_file="latest-stage3-amd64-${STAGE3_VARIANT}.txt" ;;
    esac

    log "Fetching stage3 manifest for variant '${STAGE3_VARIANT}'..."
    local manifest_url="${base_url}/${latest_file}"
    local manifest
    manifest=$(wget -qO- "$manifest_url") \
        || error "Failed to download stage3 manifest from ${manifest_url}"

    # The manifest is PGP-signed; lines before the actual content include
    # '-----BEGIN PGP SIGNED MESSAGE-----', 'Hash: SHA512', etc.
    # Only match lines that start with a Gentoo timestamp directory prefix
    # of the form YYYYMMDDTHHMMSSZ/stage3-... to skip all header lines.
    local tarball_path
    tarball_path=$(echo "$manifest" \
        | grep -E '^[0-9]{8}T[0-9]{6}Z/stage3-' \
        | awk 'NR==1{print $1}')
    [[ -z "$tarball_path" ]] && error "Could not parse stage3 path from manifest."
    [[ "$tarball_path" == *.tar.xz ]] \
        || error "Parsed stage3 path looks wrong: '${tarball_path}'"

    local tarball_url="${base_url}/${tarball_path}"
    local dest="/mnt/gentoo/stage3.tar.xz"

    log "Stage3 URL: ${tarball_url}"

    if command -v aria2c &>/dev/null; then
        aria2c --split=8 --max-connection-per-server=8 --min-split-size=10M \
               --dir=/mnt/gentoo --out=stage3.tar.xz "$tarball_url" \
               --out=stage3.tar.xz.DIGESTS "${tarball_url}.sha256" \
            || error "aria2c download failed"
    else
        wget --tries=3 --show-progress "$tarball_url"            -O "$dest"         || error "wget tarball failed"
        wget --tries=3 --show-progress "${tarball_url}.sha256"   -O "${dest}.sha256" || error "wget sha256 failed"
        wget --tries=3 --show-progress "${tarball_url}.asc"      -O "${dest}.asc"   || error "wget asc failed"
    fi

    # FIX: Verify tarball integrity before extraction.
    log "Verifying stage3 checksum..."
    pushd /mnt/gentoo >/dev/null
    # sha256 file contains lines like: <hash>  stage3-....tar.xz
    sha256sum --check --ignore-missing stage3.tar.xz.sha256 \
        || error "Stage3 SHA-256 checksum mismatch — aborting."
    popd >/dev/null
    log "Checksum OK."

    log "Extracting stage3..."
    if command -v pixz &>/dev/null; then
        pixz -d < "$dest" | tar xp --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo
    else
        tar xpf "$dest" --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo
    fi

    rm -f "$dest" "${dest}.sha256" "${dest}.asc"
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
# CPU: ${NCPU} threads   RAM: ${RAM_GIB}G   Build tmpfs: ${TMPFS_SIZE}G
# =============================================================================

# ── Compiler flags ────────────────────────────────────────────────────────────
COMMON_FLAGS="-O2 -pipe -march=native"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"

# Rust: parallel codegen units + native CPU target
RUSTFLAGS="-C opt-level=2 -C target-cpu=native -C codegen-units=${RUST_CGU}"

# FIX: mold linker is only set AFTER it is installed via package.env override
# so that early bootstrap packages (before mold is emerged) do not fail to
# link.  The system-wide LDFLAGS intentionally omit -fuse-ld=mold here.
LDFLAGS="-Wl,-O1 -Wl,--as-needed"

# ── Parallelism ───────────────────────────────────────────────────────────────
MAKEOPTS="-j${NCPU} -l${NCPU}"
EMERGE_DEFAULT_OPTS="--jobs=${NCPU} --load-average=${NCPU} --with-bdeps=y --keep-going --verbose-conflicts --getbinpkg --binpkg-respect-use=y --verbose --quiet-build=n"
PORTAGE_NICENESS=10

# ── Build directory ───────────────────────────────────────────────────────────
# /var/tmp/portage is mounted as tmpfs (${TMPFS_SIZE}G) — all builds happen in RAM
PORTAGE_TMPDIR="/var/tmp/portage"

# ── ccache ────────────────────────────────────────────────────────────────────
CCACHE_DIR="/var/cache/ccache"
CCACHE_SIZE="${CCACHE_SIZE}"

# ── USE flags ─────────────────────────────────────────────────────────────────
USE="${USE_FLAGS}"

ACCEPT_LICENSE="-* @FREE @BINARY-REDISTRIBUTABLE"
ACCEPT_KEYWORDS="${ACCEPT_KEYWORDS}"

L10N="en en-US"
LINGUAS="en en_US"

VIDEO_CARDS="${VIDEO_CARDS}"
INPUT_DEVICES="libinput"

# ── Mirrors ───────────────────────────────────────────────────────────────────
GENTOO_MIRRORS="https://distfiles.gentoo.org"
WEBSYNC_MIRROR="https://distfiles.gentoo.org"

# ── Paths ─────────────────────────────────────────────────────────────────────
DISTDIR="/var/cache/distfiles"
PKGDIR="/var/cache/binpkgs"
PORTDIR="/var/db/repos/gentoo"

# ── Output ────────────────────────────────────────────────────────────────────
PORTAGE_VERBOSE=1
PORTAGE_QUIET=0

PORTAGE_ELOG_CLASSES="warn error log"
PORTAGE_ELOG_SYSTEM="save"

# ── Portage features ──────────────────────────────────────────────────────────
# parallel-fetch        — download next distfile while current package builds
# parallel-install      — install finished packages while others still compile
# buildpkg              — cache every built package as a local .gpkg binary
# binpkg-multi-instance — keep multiple versions of same pkg in PKGDIR
# clean-logs            — auto-remove old build logs
# split-elog            — one elog file per package
# compress-build-logs   — gzip build logs to save space
# ipc-sandbox           — isolate builds from host IPC
# network-sandbox       — block network access during builds
# userfetch             — fetch distfiles as portage user in parallel
# ccache                — enable compiler cache
FEATURES="parallel-fetch parallel-install buildpkg binpkg-multi-instance clean-logs split-elog compress-build-logs ipc-sandbox network-sandbox userfetch ccache"

# ── Bootloader ────────────────────────────────────────────────────────────────
GRUB_PLATFORMS="efi-64"
EOF
    _log_raw "make.conf written"

    # FIX: package.env override — enable mold linker only for packages that
    # are built AFTER mold itself has been installed.
    mkdir -p /mnt/gentoo/etc/portage/env
    cat > /mnt/gentoo/etc/portage/env/use-mold.conf << 'EOF'
LDFLAGS="-Wl,-O1 -Wl,--as-needed -fuse-ld=mold"
EOF
    # Apply mold to the heavy packages that benefit most.
    # Add more entries here as needed; early-bootstrap pkgs are intentionally absent.
    cat > /mnt/gentoo/etc/portage/package.env/mold << 'EOF'
media-libs/mesa          use-mold.conf
sys-devel/llvm           use-mold.conf
dev-qt/qtbase            use-mold.conf
kde-plasma/plasma-meta   use-mold.conf
www-client/firefox       use-mold.conf
www-client/chromium      use-mold.conf
EOF
    _log_raw "mold package.env override written"

    log "Writing repos.conf..."
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
sync-webrsync-verify-signature = no
EOF
    _log_raw "repos.conf written"

    log "Writing binrepos.conf (Gentoo binary host)..."
    cat > /mnt/gentoo/etc/portage/binrepos.conf/gentoo-binhost.conf << 'EOF'
[binhost]
priority = 9999
sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64/
EOF
    _log_raw "binrepos.conf written"

    _configure_portage_kernel
    _configure_portage_display
    _configure_portage_gpu
    _configure_portage_audio
    _configure_portage_optional

    log "Portage configuration complete."
}

_configure_portage_kernel() {
    debug "Configuring kernel USE flags..."
    cat > /mnt/gentoo/etc/portage/package.use/kernel << 'EOF'
sys-kernel/installkernel        dracut
sys-kernel/gentoo-kernel-bin    initramfs
virtual/dist-kernel             initramfs
EOF

    cat > /mnt/gentoo/etc/portage/package.use/system << 'EOF'
>=sys-auth/pambase-20251104-r1  elogind
>=media-libs/freetype-2.14.3    harfbuzz
EOF
    _log_raw "Kernel + system USE flags written"
}

_configure_portage_display() {
    debug "Configuring display USE/keywords..."
    local kw_file="/mnt/gentoo/etc/portage/package.accept_keywords/desktop"
    case "$DESKTOP_ENV" in
        niri)
            cat >> "$kw_file" << 'EOF'
gui-wm/niri                ~amd64
dev-libs/wayland-protocols ~amd64
EOF
            ;;
        hyprland)
            cat >> "$kw_file" << 'EOF'
gui-wm/hyprland              ~amd64
gui-libs/hyprutils           ~amd64
gui-libs/hyprlang            ~amd64
gui-libs/hyprwayland-scanner ~amd64
dev-libs/wayland-protocols   ~amd64
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
gui-libs/wlroots   X drm gles2 vulkan xwayland
dev-libs/wayland   -doc
x11-base/xwayland  -glamor
EOF
    fi
}

_configure_portage_gpu() {
    debug "Configuring GPU USE flags (${GPU_VENDOR})..."
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
    [[ "$ENABLE_PIPEWIRE" != "yes" ]] && return
    cat > /mnt/gentoo/etc/portage/package.use/audio << 'EOF'
media-video/pipewire    sound-server jack-sdk v4l screencast bluetooth
media-sound/wireplumber -systemd
EOF
}

_configure_portage_optional() {
    [[ "$ENABLE_FLATPAK" == "yes" ]] && \
        echo "sys-apps/xdg-desktop-portal  flatpak" \
            >> /mnt/gentoo/etc/portage/package.use/desktop
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
    section "Preparing chroot environment"

    cp --dereference /etc/resolv.conf /mnt/gentoo/etc/

    mount --types proc  /proc /mnt/gentoo/proc
    mount --rbind       /sys  /mnt/gentoo/sys;  mount --make-rslave /mnt/gentoo/sys
    mount --rbind       /dev  /mnt/gentoo/dev;  mount --make-rslave /mnt/gentoo/dev
    mount --bind        /run  /mnt/gentoo/run;  mount --make-slave  /mnt/gentoo/run

    [[ -d /sys/firmware/efi/efivars ]] && \
        mount --bind /sys/firmware/efi/efivars /mnt/gentoo/sys/firmware/efi/efivars

    debug "Mounting build tmpfs (${TMPFS_SIZE}G) on /var/tmp/portage..."
    mkdir -p /mnt/gentoo/var/tmp/portage
    mount -t tmpfs \
        -o "size=${TMPFS_SIZE}G,uid=250,gid=250,mode=775,noatime" \
        tmpfs /mnt/gentoo/var/tmp/portage
    _log_raw "Portage build tmpfs: ${TMPFS_SIZE}G"

    mkdir -p /mnt/gentoo/var/cache/ccache
    chown -R 250:250 /mnt/gentoo/var/cache/ccache 2>/dev/null || true

    mkdir -p /mnt/gentoo/var/cache/distfiles
    if [[ -d /var/cache/distfiles ]] && mountpoint -q /var/cache/distfiles 2>/dev/null; then
        mount --bind /var/cache/distfiles /mnt/gentoo/var/cache/distfiles
        _log_raw "Host distfiles cache bind-mounted"
    fi

    log "Chroot environment ready."
}

# =============================================================================
# CHROOT SCRIPT
# =============================================================================

write_chroot_script() {
    section "Writing chroot install script"
    install -m 700 /dev/null /mnt/gentoo/root/chroot-install.sh

    # Capture variables that need to be expanded NOW (host-side) into the script.
    # Any variable that should be evaluated at chroot runtime is escaped (\$).
    # LUKS_PASSPHRASE is intentionally never referenced inside the chroot script.
    cat >> /mnt/gentoo/root/chroot-install.sh << CHROOT_EOF
#!/usr/bin/env bash
set -eo pipefail

CHROOT_LOG="${LOG_FILE}"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

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

set +u; source /etc/profile; set -u
export PS1="(chroot) \${PS1:-}"

# ── Portage tree sync ─────────────────────────────────────────────────────────
section "Syncing Portage tree"
GENTOO_MIRRORS="https://distfiles.gentoo.org" \
WEBSYNC_MIRROR="https://distfiles.gentoo.org" \
emerge-webrsync
_clog "Portage tree synced"

# ── Profile ───────────────────────────────────────────────────────────────────
section "Setting Portage profile"
# FIX: avoid piping to 'less' inside a non-interactive script — it hangs.
eselect profile list
read -rp "  Enter profile number to use: " PROFILE_NUM </dev/tty
if [[ -n "\$PROFILE_NUM" ]]; then
    eselect profile set "\$PROFILE_NUM" || warn "Profile set failed"
    _clog "Profile: \$(eselect profile show | tail -1 | xargs)"
else
    warn "No profile selected — set manually with: eselect profile set"
fi

# ── World update after profile change ─────────────────────────────────────────
# FIX: rebuild @world so the new profile's USE flags are applied before any
# desktop packages are installed, preventing slot conflicts.
section "Updating @world to reflect new profile"
emerge --update --newuse --deep @world || warn "@world update had non-fatal failures — review logs"
_clog "@world updated"

# ── Timezone & Locale ─────────────────────────────────────────────────────────
section "Timezone & Locale"
echo "${TIMEZONE}" > /etc/timezone
emerge --config sys-libs/timezone-data
echo "${LOCALE} UTF-8" >> /etc/locale.gen
locale-gen
LOC=\$(locale -a | grep -i "\$(echo "${LOCALE}" | tr '[:upper:]' '[:lower:]' | sed 's/utf-8/utf8/')" | head -1)
[[ -n "\$LOC" ]] && eselect locale set "\$LOC" || warn "Set locale manually"
set +u; env-update && source /etc/profile; set -u

# ── ccache + mold bootstrap ───────────────────────────────────────────────────
# Install ccache and mold FIRST so all subsequent compiles benefit from them.
# make.conf intentionally does NOT set -fuse-ld=mold globally; a package.env
# override enables it only for packages built after mold is available.
section "Bootstrap: ccache + mold"
debug "Installing ccache and mold early..."
emerge dev-util/ccache sys-devel/mold
mkdir -p /var/cache/ccache
ccache --max-size="${CCACHE_SIZE}"
ccache --set-config=compression=true
ccache --set-config=compression_level=1
ccache --set-config=hash_dir=false
ccache --set-config=sloppiness=pch_defines,time_macros,include_file_mtime,include_file_ctime,locale
chown -R portage:portage /var/cache/ccache
_clog "ccache initialised (${CCACHE_SIZE}, compressed, max sloppiness)"

# ── Firmware & Microcode ──────────────────────────────────────────────────────
section "Firmware & Microcode  (CPU: ${CPU_VENDOR})"
[[ "${CPU_VENDOR}" == "intel" ]] && emerge sys-firmware/intel-microcode
emerge sys-kernel/linux-firmware sys-firmware/sof-firmware
_clog "Firmware installed"

# ── Kernel ────────────────────────────────────────────────────────────────────
section "Kernel installation  (type: ${KERNEL_TYPE})"

debug "Writing /etc/kernel/cmdline for dracut..."
mkdir -p /etc/kernel /etc/kernel/preinst.d
DRACUT_CMDLINE="root=UUID=\$(findmnt -no UUID /) ro quiet"
[[ "${ENABLE_LUKS}" == "yes" ]] && DRACUT_CMDLINE="rd.luks=1 \${DRACUT_CMDLINE}"
echo "\${DRACUT_CMDLINE}" > /etc/kernel/cmdline
touch /etc/kernel/preinst.d/05-check-chroot.install
_clog "kernel cmdline: \$(cat /etc/kernel/cmdline)"

case "${KERNEL_TYPE}" in
    dist)
        emerge sys-kernel/gentoo-kernel-bin
        _clog "gentoo-kernel-bin installed"
        ;;
    sources|hardened|rt)
        case "${KERNEL_TYPE}" in
            sources)  emerge sys-kernel/gentoo-sources ;;
            hardened) emerge sys-kernel/hardened-sources ;;
            rt)       emerge sys-kernel/rt-sources ;;
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
                emerge sys-kernel/genkernel
                genkernel --menuconfig=no --makeopts="${MAKEOPTS}" \
                    \$( [[ "${ENABLE_LUKS}" == "yes" ]] && echo "--luks" ) all
                ;;
            manual)
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
emerge \
    app-admin/sudo \
    app-arch/zstd \
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
    xfs)  emerge sys-fs/xfsprogs ;;
    f2fs) emerge sys-fs/f2fs-tools ;;
esac

[[ "${ENABLE_LUKS}" == "yes" ]] && emerge sys-fs/cryptsetup

# ── Hostname & Networking ─────────────────────────────────────────────────────
section "Hostname & network configuration"
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF

# ── Init services ─────────────────────────────────────────────────────────────
# FIX: guard every rc-update / systemctl call so a missing service
# does not abort the entire installation under set -e.
section "Enabling init services  (${INIT_SYSTEM})"
if [[ "${INIT_SYSTEM}" == "openrc" ]]; then
    for svc in NetworkManager elogind dbus udev cronie; do
        rc-update add \$svc default 2>/dev/null || warn "rc-update add \$svc default failed (non-fatal)"
    done
    rc-update add udev sysinit  2>/dev/null || warn "rc-update add udev sysinit failed (non-fatal)"
    rc-update add sshd default  2>/dev/null || warn "sshd not available yet (non-fatal)"
else
    for unit in NetworkManager dbus cronie; do
        systemctl enable \$unit || warn "systemctl enable \$unit failed (non-fatal)"
    done
fi

# ── Display server ────────────────────────────────────────────────────────────
section "Display server packages  (${DISPLAY_SERVER})"
if [[ "${DISPLAY_SERVER}" == "x11" || "${DISPLAY_SERVER}" == "both" ]]; then
    emerge \
        x11-base/xorg-server \
        x11-apps/xinit \
        x11-misc/xkeyboard-config \
        x11-libs/libX11 \
        x11-libs/libXrandr \
        x11-libs/libXinerama
fi

if [[ "${DISPLAY_SERVER}" == "wayland" || "${DISPLAY_SERVER}" == "both" ]]; then
    emerge \
        dev-libs/wayland \
        dev-libs/wayland-protocols \
        x11-base/xwayland \
        x11-libs/libdrm \
        x11-libs/pixman \
        x11-misc/xkeyboard-config
fi

# ── GPU drivers ───────────────────────────────────────────────────────────────
section "GPU drivers  (${GPU_VENDOR})"
emerge media-libs/mesa media-libs/libva media-video/libva-utils
case "${GPU_VENDOR}" in
    amd)    emerge media-libs/vulkan-loader dev-util/vulkan-tools ;;
    intel)  emerge media-libs/intel-media-driver media-libs/vulkan-loader ;;
    nvidia)
        emerge x11-drivers/nvidia-drivers
        if [[ "${INIT_SYSTEM}" == "openrc" ]]; then
            rc-update add modules boot 2>/dev/null || warn "rc-update modules boot failed (non-fatal)"
            echo "nvidia" >> /etc/modules-load.d/nvidia.conf
        fi
        ;;
esac

# ── Desktop environment / WM ──────────────────────────────────────────────────
section "Desktop environment  (${DESKTOP_ENV})"
case "${DESKTOP_ENV}" in
    gnome)
        emerge gnome-base/gnome gnome-base/gnome-extra-apps ;;
    kde)
        emerge kde-plasma/plasma-meta kde-apps/kde-apps-meta ;;
    cosmic)
        emerge gui-wm/cosmic-comp gui-apps/cosmic-term gui-apps/cosmic-files \
               gui-apps/cosmic-launcher gui-apps/cosmic-settings ;;
    sway)
        emerge gui-wm/sway gui-apps/swaybar gui-apps/swaybg gui-apps/swayidle \
               gui-apps/swaylock gui-apps/foot gui-apps/fuzzel gui-apps/mako \
               gui-apps/grim gui-apps/slurp gui-apps/wl-clipboard \
               gui-libs/xdg-desktop-portal-gtk ;;
    niri)
        emerge gui-wm/niri gui-apps/swayidle gui-apps/swaylock gui-apps/foot \
               gui-apps/fuzzel gui-apps/mako gui-apps/waybar gui-apps/grim \
               gui-apps/slurp gui-apps/wl-clipboard \
               gui-libs/xdg-desktop-portal-gtk x11-libs/xcb-util-cursor ;;
    hyprland)
        emerge gui-wm/hyprland gui-apps/swayidle gui-apps/swaylock gui-apps/foot \
               gui-apps/fuzzel gui-apps/mako gui-apps/waybar gui-apps/grim \
               gui-apps/slurp gui-apps/wl-clipboard gui-libs/xdg-desktop-portal-gtk ;;
    river)
        emerge gui-wm/river gui-apps/foot gui-apps/fuzzel gui-apps/mako \
               gui-apps/waybar gui-apps/wl-clipboard gui-libs/xdg-desktop-portal-gtk ;;
    labwc)
        emerge gui-wm/labwc gui-apps/foot gui-apps/fuzzel gui-apps/mako \
               gui-apps/wl-clipboard gui-libs/xdg-desktop-portal-gtk ;;
    xfce)   emerge xfce-base/xfce4-meta ;;
    lxqt)   emerge lxqt-base/lxqt-meta ;;
    openbox)
        emerge x11-wm/openbox x11-misc/obconf x11-apps/xrandr \
               x11-misc/tint2 x11-misc/rofi ;;
    i3)
        emerge x11-wm/i3 x11-misc/i3status x11-misc/i3lock \
               x11-misc/rofi x11-apps/xrandr x11-misc/picom ;;
    dwm)    emerge x11-wm/dwm x11-misc/dmenu x11-misc/st ;;
    none|custom) log "Skipping desktop install." ;;
esac

# ── Display manager ───────────────────────────────────────────────────────────
section "Display manager  (${DISPLAY_MANAGER:-none})"
case "${DISPLAY_MANAGER:-none}" in
    gdm)
        emerge gnome-base/gdm
        [[ "${INIT_SYSTEM}" == "openrc" ]] \
            && rc-update add gdm default 2>/dev/null || systemctl enable gdm ;;
    sddm)
        emerge x11-misc/sddm
        [[ "${INIT_SYSTEM}" == "openrc" ]] \
            && rc-update add sddm default 2>/dev/null || systemctl enable sddm ;;
    lightdm)
        emerge x11-misc/lightdm x11-misc/lightdm-gtk-greeter
        [[ "${INIT_SYSTEM}" == "openrc" ]] \
            && rc-update add lightdm default 2>/dev/null || systemctl enable lightdm ;;
    greetd)
        emerge gui-apps/greetd gui-apps/tuigreet
        [[ "${INIT_SYSTEM}" == "openrc" ]] \
            && rc-update add greetd default 2>/dev/null || systemctl enable greetd

        # FIX: use DESKTOP_ENV to determine the session command instead of
        # hardcoding niri-session regardless of what was configured.
        GREETD_CMD="${DESKTOP_ENV}"
        case "${DESKTOP_ENV}" in
            niri)     GREETD_CMD="niri-session" ;;
            sway)     GREETD_CMD="sway" ;;
            hyprland) GREETD_CMD="Hyprland" ;;
            river)    GREETD_CMD="river" ;;
            labwc)    GREETD_CMD="labwc" ;;
            cosmic)   GREETD_CMD="cosmic-session" ;;
            gnome)    GREETD_CMD="gnome-session" ;;
            kde)      GREETD_CMD="startplasma-wayland" ;;
            *)        GREETD_CMD="${DESKTOP_ENV}" ;;
        esac

        cat > /etc/greetd/config.toml << EOF
[terminal]
vt = 1
[default_session]
command = "tuigreet --time --remember --cmd \${GREETD_CMD}"
user = "greeter"
EOF
        ;;
    ly)
        emerge x11-misc/ly
        [[ "${INIT_SYSTEM}" == "openrc" ]] \
            && rc-update add ly default 2>/dev/null || systemctl enable ly ;;
    none) log "No display manager — TTY auto-start will be used." ;;
esac

# ── Audio ─────────────────────────────────────────────────────────────────────
if [[ "${ENABLE_PIPEWIRE}" == "yes" ]]; then
    section "PipeWire audio"
    emerge media-video/pipewire media-sound/wireplumber media-sound/pavucontrol
    [[ "${INIT_SYSTEM}" == "openrc" ]] \
        && rc-update add pipewire default 2>/dev/null || true
fi

# ── Bluetooth ─────────────────────────────────────────────────────────────────
if [[ "${ENABLE_BLUETOOTH}" == "yes" ]]; then
    section "Bluetooth"
    emerge net-wireless/bluez app-misc/blueman
    [[ "${INIT_SYSTEM}" == "openrc" ]] \
        && rc-update add bluetooth default 2>/dev/null \
        || systemctl enable bluetooth || warn "bluetooth enable failed (non-fatal)"
fi

# ── Printing ──────────────────────────────────────────────────────────────────
if [[ "${ENABLE_PRINTING}" == "yes" ]]; then
    section "Printing (CUPS + Avahi)"
    emerge net-print/cups net-dns/avahi app-text/ghostscript-gpl
    if [[ "${INIT_SYSTEM}" == "openrc" ]]; then
        rc-update add cupsd default    2>/dev/null || warn "cupsd enable failed (non-fatal)"
        rc-update add avahi-daemon default 2>/dev/null || warn "avahi enable failed (non-fatal)"
    else
        systemctl enable cups         || warn "cups enable failed (non-fatal)"
        systemctl enable avahi-daemon || warn "avahi enable failed (non-fatal)"
    fi
fi

# ── Flatpak ───────────────────────────────────────────────────────────────────
if [[ "${ENABLE_FLATPAK}" == "yes" ]]; then
    section "Flatpak"
    emerge sys-apps/flatpak
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
fi

# ── Libvirt / QEMU ────────────────────────────────────────────────────────────
if [[ "${ENABLE_LIBVIRT}" == "yes" ]]; then
    section "Libvirt / QEMU"
    emerge app-emulation/libvirt app-emulation/qemu app-emulation/virt-manager
    [[ "${INIT_SYSTEM}" == "openrc" ]] \
        && rc-update add libvirtd default 2>/dev/null \
        || systemctl enable libvirtd || warn "libvirtd enable failed (non-fatal)"
fi

# ── Docker / Podman ───────────────────────────────────────────────────────────
if [[ "${ENABLE_DOCKER}" == "yes" ]]; then
    section "Containers"
    emerge app-containers/docker app-containers/podman app-containers/docker-compose
    [[ "${INIT_SYSTEM}" == "openrc" ]] \
        && rc-update add docker default 2>/dev/null \
        || systemctl enable docker || warn "docker enable failed (non-fatal)"
fi

# ── Snapper ───────────────────────────────────────────────────────────────────
if [[ "${ENABLE_BTRFS_SNAPPER}" == "yes" && "${FS_TYPE}" == "btrfs" ]]; then
    section "Snapper"
    emerge app-backup/snapper
    snapper -c root create-config /
    if [[ "${INIT_SYSTEM}" == "openrc" ]]; then
        rc-update add snapper-timeline default 2>/dev/null || warn "snapper-timeline enable failed (non-fatal)"
        rc-update add snapper-cleanup default  2>/dev/null || warn "snapper-cleanup enable failed (non-fatal)"
    else
        systemctl enable snapper-timeline.timer || warn "snapper-timeline.timer enable failed (non-fatal)"
        systemctl enable snapper-cleanup.timer  || warn "snapper-cleanup.timer enable failed (non-fatal)"
    fi
fi

# ── Extra packages ────────────────────────────────────────────────────────────
if [[ -n "${EXTRA_PACKAGES}" ]]; then
    section "Extra packages"
    emerge ${EXTRA_PACKAGES}
fi

# ── Fonts & themes ────────────────────────────────────────────────────────────
section "Fonts & themes"
emerge \
    media-fonts/noto \
    media-fonts/noto-emoji \
    media-fonts/fira-code \
    x11-themes/papirus-icon-theme \
    x11-themes/capitaine-cursors

# ── GRUB ──────────────────────────────────────────────────────────────────────
section "GRUB bootloader"
emerge sys-boot/grub

GRUB_CMDLINE="quiet loglevel=3 mitigations=auto"
[[ "${ENABLE_LUKS}" == "yes" ]] && GRUB_CMDLINE="\${GRUB_CMDLINE} rd.luks=1"

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
_clog "GRUB installed"

# ── Secure Boot ───────────────────────────────────────────────────────────────
if [[ "${ENABLE_SECURE_BOOT}" == "yes" ]]; then
    section "Secure Boot (sbctl)"
    if command -v sbctl &>/dev/null; then
        sbctl create-keys
        [[ "${SECURE_BOOT_MICROSOFT_KEYS}" == "yes" ]] \
            && sbctl enroll-keys --microsoft || sbctl enroll-keys
        sbctl sign -s /boot/efi/EFI/gentoo/grubx64.efi
        for vmlinuz in /boot/vmlinuz-*; do
            [[ -f "\$vmlinuz" ]] && sbctl sign -s "\$vmlinuz"
        done
        log "Secure Boot keys enrolled. Enable in firmware after reboot."
    else
        warn "sbctl not found — install app-crypt/sbctl post-boot."
    fi
fi

# ── Users ─────────────────────────────────────────────────────────────────────
section "User accounts"
echo "root:${ROOT_HASH}" | chpasswd -e

# FIX: build the supplementary group list as a single -G argument.
# Multiple -G flags are not valid for useradd and would cause failures.
_GROUPS="wheel,audio,video,input,seat,plugdev,usb,portage"
[[ "${ENABLE_LIBVIRT}" == "yes" ]] && _GROUPS="\${_GROUPS},libvirt"
[[ "${ENABLE_DOCKER}"  == "yes" ]] && _GROUPS="\${_GROUPS},docker"

useradd -m -G "\${_GROUPS}" -s /bin/bash "${USERNAME}"
echo "${USERNAME}:${USER_HASH}" | chpasswd -e

install -m 440 /dev/null /etc/sudoers.d/wheel
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel

# ── Session auto-start ────────────────────────────────────────────────────────
section "Session auto-start"
USER_HOME="/home/${USERNAME}"

# FIX: the inner heredoc delimiter is quoted ('BEOF') so that \${cmd} is
# treated as a literal shell variable reference at runtime, not expanded
# during write_chroot_script() on the host.
_write_autostart() {
    local cmd="\$1"
    cat >> "\${USER_HOME}/.bash_profile" << 'BEOF'

if [[ -z "\$DISPLAY" && -z "\$WAYLAND_DISPLAY" && "\${XDG_VTNR}" -eq 1 ]]; then
BEOF
    # The exec line must contain the runtime value of cmd, so it is written
    # separately without quoting the delimiter.
    echo "    exec \${cmd}" >> "\${USER_HOME}/.bash_profile"
    echo "fi" >> "\${USER_HOME}/.bash_profile"
}

if [[ "${DISPLAY_MANAGER:-none}" != "none" ]]; then
    _clog "Session handled by display manager"
else
    case "${DESKTOP_ENV}" in
        sway)     _write_autostart "sway" ;;
        niri)
            NIRI_CMD="niri"
            command -v niri-session &>/dev/null && NIRI_CMD="niri-session"
            _write_autostart "\${NIRI_CMD}" ;;
        hyprland) _write_autostart "Hyprland" ;;
        river)    _write_autostart "river" ;;
        labwc)    _write_autostart "labwc" ;;
        cosmic)   _write_autostart "cosmic-session" ;;
        openbox)  _write_autostart "openbox-session" ;;
        i3)       _write_autostart "i3" ;;
        dwm)      _write_autostart "dwm" ;;
        gnome|kde|xfce|lxqt) warn "Set DISPLAY_MANAGER for ${DESKTOP_ENV}" ;;
        none|custom) warn "Configure session start manually." ;;
    esac
fi

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

# ── Print ccache stats before finishing ───────────────────────────────────────
section "ccache statistics"
ccache --show-stats || true

# ── Ownership ─────────────────────────────────────────────────────────────────
chown -R "${USERNAME}:${USERNAME}" "\${USER_HOME}"

_clog "====== Chroot phase complete ======"
section "Chroot phase complete"
CHROOT_EOF

    log "Chroot script written."
    _log_raw "Chroot script: $(wc -l < /mnt/gentoo/root/chroot-install.sh) lines"
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
        /mnt/gentoo/var/tmp/portage
        /mnt/gentoo/var/cache/distfiles
        /mnt/gentoo/var/log
        /mnt/gentoo/home
        /mnt/gentoo/.snapshots
        /mnt/gentoo/boot/efi
        /mnt/gentoo
    )
    for mp in "${mounts[@]}"; do
        mountpoint -q "$mp" 2>/dev/null && \
            { umount -R "$mp" 2>/dev/null && _log_raw "  unmounted: ${mp}" \
                || _log_raw "  unmount failed (non-fatal): ${mp}"; }
    done

    [[ -n "$PART_SWAP" ]] && swapoff "$PART_SWAP" 2>/dev/null || true
    [[ "$ENABLE_LUKS" == "yes" ]] && \
        cryptsetup close "$LUKS_NAME" 2>/dev/null || true

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
    echo -e "  ${CYAN}Log:${NC}  ${BOLD}${LOG_FILE}${NC}"
    echo -e "  ${CYAN}Follow:${NC} ${BOLD}tail -f ${LOG_FILE}${NC}"
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
    echo -e "  Threads:  ${BOLD}${NCPU}${NC}  RAM: ${BOLD}${RAM_GIB}G${NC}  Build tmpfs: ${BOLD}${TMPFS_SIZE}G${NC}"
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
    local mins=$(( elapsed / 60 )); local secs=$(( elapsed % 60 ))

    echo ""
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  Installation complete!  (${mins}m ${secs}s)${NC}"
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${CYAN}Log:${NC} ${BOLD}${LOG_FILE}${NC}"
    echo ""
    echo -e "  ${CYAN}Next steps:${NC}"
    echo -e "   1. ${BOLD}reboot${NC}"
    echo -e "   2. Login as ${BOLD}${USERNAME}${NC}"
    [[ "$DISPLAY_MANAGER" == "none" ]] && \
        echo -e "   3. Session starts automatically on TTY1"
    [[ "$ENABLE_SECURE_BOOT" == "yes" ]] && \
        echo -e "   4. Enable Secure Boot in firmware settings"
    [[ "$ENABLE_LUKS" == "yes" ]] && \
        echo -e "   ${YELLOW}[!]${NC} LUKS passphrase required on boot"
    echo ""
    _log_raw "====== Installer main() returned cleanly ======"
}

main "$@"
