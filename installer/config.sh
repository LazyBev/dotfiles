#!/usr/bin/env bash
# =============================================================================
# Gentoo Installation Profile Builder
# Generates: gentoo-install.conf
# Usage:     bash gentoo-config.sh
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# COLORS & HELPERS
# =============================================================================

RED='\033[0;31m';  GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m';   MAGENTA='\033[0;35m'
BOLD='\033[1m';    DIM='\033[2m';        NC='\033[0m'

log()     { echo -e "${GREEN}[+]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
info()    { echo -e "${CYAN}[i]${NC} $*"; }
header()  {
    local w=54
    echo -e "\n${BOLD}${BLUE}╔$(printf '═%.0s' $(seq 1 $w))╗${NC}"
    printf "${BOLD}${BLUE}║${NC}${BOLD}${CYAN}  %-${w}s${BLUE}║${NC}\n" "$*"
    echo -e "${BOLD}${BLUE}╚$(printf '═%.0s' $(seq 1 $w))╝${NC}\n"
}
section() {
    echo -e "\n${BOLD}${MAGENTA}── $* ${DIM}$(printf '─%.0s' $(seq 1 $((48 - ${#*}))))${NC}\n"
}

# Prompt with default value
#   ask VAR "Prompt text" "default"
ask() {
    local var="$1" prompt="$2" default="${3:-}"
    local hint=""
    [[ -n "$default" ]] && hint=" ${DIM}[${default}]${NC}"
    echo -en "  ${CYAN}?${NC} ${prompt}${hint}: "
    read -r "$var"
    # Apply default if empty
    [[ -z "${!var}" ]] && printf -v "$var" '%s' "$default"
}

# Numbered menu — sets named variable to the selected key
#   menu VAR "Title" key1 "Label 1" key2 "Label 2" ...
menu() {
    local var="$1"; shift
    local title="$1"; shift
    local -a keys=() labels=()
    while [[ $# -ge 2 ]]; do
        keys+=("$1"); labels+=("$2"); shift 2
    done

    echo -e "  ${BOLD}${title}${NC}"
    local i
    for i in "${!keys[@]}"; do
        printf "    ${CYAN}%2d)${NC}  %s\n" $((i+1)) "${labels[$i]}"
    done
    echo ""

    local choice
    while true; do
        echo -en "  ${CYAN}?${NC} Select [1-${#keys[@]}]: "
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] \
            && (( choice >= 1 && choice <= ${#keys[@]} )); then
            printf -v "$var" '%s' "${keys[$((choice-1))]}"
            echo -e "  ${GREEN}✓${NC} ${labels[$((choice-1))]}\n"
            return
        fi
        warn "Invalid choice. Enter a number between 1 and ${#keys[@]}."
    done
}

# Yes/No prompt — sets named variable to "yes" or "no"
#   yesno VAR "Prompt" "yes|no"
yesno() {
    local var="$1" prompt="$2" default="${3:-no}"
    local hint="[y/N]"
    [[ "$default" == "yes" ]] && hint="[Y/n]"
    local ans
    echo -en "  ${CYAN}?${NC} ${prompt} ${DIM}${hint}${NC}: "
    read -r ans
    ans="${ans:-$default}"
    case "${ans,,}" in
        y|yes) printf -v "$var" 'yes' ;;
        *)     printf -v "$var" 'no'  ;;
    esac
}

# Detect available disks
list_disks() {
    echo -e "  ${DIM}Available block devices:${NC}"
    lsblk -d -o NAME,SIZE,MODEL,TRAN 2>/dev/null \
        | grep -v "^loop\|^sr\|^fd" \
        | awk 'NR==1{print "    "$0} NR>1{print "    /dev/"$0}' \
        | column -t
    echo ""
}

# Detect CPU vendor
detect_cpu() {
    if grep -qi "intel" /proc/cpuinfo 2>/dev/null; then
        echo "intel"
    elif grep -qi "amd" /proc/cpuinfo 2>/dev/null; then
        echo "amd"
    else
        echo "generic"
    fi
}

# Detect GPU vendor
detect_gpu() {
    if lspci 2>/dev/null | grep -qi "nvidia"; then
        echo "nvidia"
    elif lspci 2>/dev/null | grep -qi "amd\|radeon\|advanced micro"; then
        echo "amd"
    elif lspci 2>/dev/null | grep -qi "intel"; then
        echo "intel"
    else
        echo "generic"
    fi
}

# Detect core count
detect_cores() {
    nproc 2>/dev/null || echo "4"
}

# =============================================================================
# CONFIGURATION STATE
# =============================================================================

# Defaults — overridden by user selections
DISK="/dev/sda"
HOSTNAME="gentoo"
USERNAME="user"
TIMEZONE="America/New_York"
LOCALE="en_US.UTF-8"
KEYMAP="us"
CPU_VENDOR="$(detect_cpu)"
GPU_VENDOR="$(detect_gpu)"
FS_TYPE="btrfs"
SWAP_SIZE="8"          # GiB
EFI_SIZE="1"           # GiB
DISPLAY_SERVER=""      # x11 | wayland | both
DESKTOP_ENV=""         # none | gnome | kde | xfce | sway | niri | hyprland |
                       #         river | labwc | openbox | i3 | dwm | custom
INIT_SYSTEM="openrc"   # openrc | systemd
KERNEL_TYPE="dist"     # dist | sources | hardened | rt
KERNEL_CONFIG="defconfig"  # defconfig | genkernel | manual
ENABLE_FLATPAK="no"
ENABLE_PIPEWIRE="yes"
ENABLE_BLUETOOTH="no"
ENABLE_PRINTING="no"
ENABLE_LIBVIRT="no"
ENABLE_DOCKER="no"
ENABLE_SECURE_BOOT="no"
ENABLE_LUKS="no"
ENABLE_BTRFS_SNAPPER="no"
EXTRA_PACKAGES=""
MAKEOPTS="-j$(detect_cores) -l$(detect_cores)"
GENTOO_MIRRORS="https://distfiles.gentoo.org"
STAGE3_VARIANT="openrc"   # openrc | systemd | hardened | musl
ACCEPT_KEYWORDS="amd64"   # amd64 | ~amd64

# =============================================================================
# WIZARD SECTIONS
# =============================================================================

wizard_disk() {
    header "Disk & Partitioning"

    list_disks

    ask DISK        "Target disk (WILL BE ERASED)"    "/dev/nvme0n1"
    ask EFI_SIZE    "EFI partition size (GiB)"        "1"
    ask SWAP_SIZE   "Swap size (GiB, 0 to disable)"   "8"

    menu FS_TYPE "Root filesystem" \
        btrfs  "Btrfs  — CoW, snapshots, zstd compression  (recommended)" \
        ext4   "ext4   — Stable, widely supported" \
        xfs    "XFS    — High-performance, good for large files" \
        f2fs   "F2FS   — Flash-friendly (SSD/NVMe)"

    if [[ "$FS_TYPE" == "btrfs" ]]; then
        yesno ENABLE_BTRFS_SNAPPER "Install snapper for automated Btrfs snapshots?" "yes"
    fi

    yesno ENABLE_LUKS "Enable LUKS2 full-disk encryption?" "no"
    if [[ "$ENABLE_LUKS" == "yes" ]]; then
        warn "LUKS support requires manual key enrollment post-install."
        warn "The install script will set up the LUKS container and crypttab."
    fi
}

wizard_system() {
    header "System Configuration"

    ask HOSTNAME  "Hostname"        "gentoo"
    ask USERNAME  "Primary username" "user"

    # Timezone: attempt to detect from timedatectl or fallback
    local tz_default="America/New_York"
    command -v timedatectl &>/dev/null \
        && tz_default=$(timedatectl show -p Timezone --value 2>/dev/null || echo "$tz_default")
    ask TIMEZONE "Timezone (see /usr/share/zoneinfo)" "$tz_default"

    ask LOCALE  "Locale"  "en_US.UTF-8"
    ask KEYMAP  "Keymap"  "us"

    menu INIT_SYSTEM "Init system" \
        openrc  "OpenRC    — Traditional, fast, simple (recommended)" \
        systemd "systemd  — Feature-rich, broad ecosystem support"

    menu ACCEPT_KEYWORDS "Portage keyword branch" \
        amd64  "amd64  — Stable (recommended for servers/production)" \
        "~amd64" "~amd64 — Testing (newer packages, required for some DEs)"
}

wizard_hardware() {
    header "Hardware"

    info "Detected CPU: ${CPU_VENDOR}  |  GPU: ${GPU_VENDOR}"
    yesno OVERRIDE_HW "Override hardware detection?" "no"

    if [[ "$OVERRIDE_HW" == "yes" ]]; then
        menu CPU_VENDOR "CPU vendor" \
            intel   "Intel" \
            amd     "AMD" \
            generic "Generic / VM"

        menu GPU_VENDOR "GPU vendor" \
            amd     "AMD       — AMDGPU (open, Mesa/Vulkan)" \
            intel   "Intel     — i915/iris (open, Mesa/Vulkan)" \
            nvidia  "NVIDIA    — proprietary driver" \
            generic "Generic / VM / Software rendering"
    fi

    ask MAKEOPTS "MAKEOPTS" "-j$(detect_cores) -l$(detect_cores)"
}

wizard_kernel() {
    header "Kernel"

    menu KERNEL_TYPE "Kernel flavour" \
        dist      "gentoo-kernel-bin  — Pre-built distribution kernel  (fastest install)" \
        sources   "gentoo-sources     — Full source, custom config" \
        hardened  "hardened-sources   — Security-hardened kernel" \
        rt        "rt-sources         — Real-time kernel"

    if [[ "$KERNEL_TYPE" == "sources" || "$KERNEL_TYPE" == "hardened" || "$KERNEL_TYPE" == "rt" ]]; then
        menu KERNEL_CONFIG "Build method" \
            defconfig  "make defconfig    — Sane defaults, fast" \
            genkernel  "genkernel         — Automated, initramfs included" \
            manual     "make menuconfig   — Full manual configuration"
    fi
}

wizard_desktop() {
    header "Display Server & Desktop"

    menu DISPLAY_SERVER "Display server" \
        wayland "Wayland  — Modern, recommended for 2025+" \
        x11     "X11      — Legacy, broadest compatibility" \
        both    "Both     — Wayland primary, XWayland fallback"

    echo ""
    info "Select a desktop environment or window manager."
    info "Choose 'none' for a minimal CLI-only system."
    echo ""

    if [[ "$DISPLAY_SERVER" == "x11" ]]; then
        menu DESKTOP_ENV "Desktop / WM" \
            none      "None      — Minimal TTY / headless" \
            gnome     "GNOME     — Full DE, GTK, X11+Wayland" \
            kde       "KDE Plasma — Full DE, Qt, X11+Wayland" \
            xfce      "XFCE      — Lightweight GTK DE, X11" \
            lxqt      "LXQt      — Lightweight Qt DE, X11" \
            openbox   "Openbox   — Minimalist stacking WM, X11" \
            i3        "i3        — Tiling WM, X11" \
            dwm       "dwm       — Dynamic WM, X11 (suckless)" \
            custom    "Custom    — I will configure manually"
    else
        menu DESKTOP_ENV "Desktop / WM" \
            none      "None      — Minimal TTY / headless" \
            gnome     "GNOME     — Full DE, GTK, Wayland-native" \
            kde       "KDE Plasma — Full DE, Qt, Wayland-native" \
            cosmic    "COSMIC    — New DE by System76, Wayland-native (2025)" \
            sway      "Sway      — i3-compatible tiling WM, Wayland" \
            niri      "Niri      — Scrollable-columns tiling WM, Wayland" \
            hyprland  "Hyprland  — Animated tiling WM, Wayland" \
            river     "River     — Tag-based WM, Wayland" \
            labwc     "labwc     — Stacking WM, openbox-like, Wayland" \
            custom    "Custom    — I will configure manually"
    fi
}

wizard_services() {
    header "Optional Services & Features"

    yesno ENABLE_PIPEWIRE   "PipeWire audio (replaces PulseAudio)"  "yes"
    yesno ENABLE_BLUETOOTH  "Bluetooth (bluez + blueman)"           "no"
    yesno ENABLE_PRINTING   "Printing (CUPS + Avahi)"               "no"
    yesno ENABLE_FLATPAK    "Flatpak (+ Flathub remote)"            "no"
    yesno ENABLE_LIBVIRT    "Libvirt / QEMU virtualisation"         "no"
    yesno ENABLE_DOCKER     "Docker / Podman containers"            "no"
    yesno ENABLE_SECURE_BOOT "Secure Boot (sbctl — manual steps required)" "no"

    echo ""
    ask EXTRA_PACKAGES "Extra packages to emerge (space-separated, or leave blank)" ""
}

wizard_mirrors() {
    header "Portage Mirrors"

    info "Current: ${GENTOO_MIRRORS}"
    echo ""
    echo -e "  ${DIM}Common mirrors:${NC}"
    echo "    https://distfiles.gentoo.org                  (global CDN)"
    echo "    https://mirror.leaseweb.com/gentoo            (EU)"
    echo "    https://mirrors.kernel.org/gentoo             (US)"
    echo "    https://mirror.bytemark.co.uk/gentoo          (UK)"
    echo ""
    ask GENTOO_MIRRORS "Mirror URL(s) space-separated" "https://distfiles.gentoo.org"
}

# =============================================================================
# SUMMARY & CONFIRMATION
# =============================================================================

print_summary() {
    header "Configuration Summary"

    local sections=(
        "DISK          ${DISK}  (EFI: ${EFI_SIZE}G  Swap: ${SWAP_SIZE}G  FS: ${FS_TYPE})"
        "LUKS          ${ENABLE_LUKS}"
        "BTRFS snapper ${ENABLE_BTRFS_SNAPPER}"
        "HOSTNAME      ${HOSTNAME}"
        "USER          ${USERNAME}"
        "TIMEZONE      ${TIMEZONE}"
        "LOCALE        ${LOCALE}  (keymap: ${KEYMAP})"
        "INIT          ${INIT_SYSTEM}"
        "KEYWORDS      ${ACCEPT_KEYWORDS}"
        "CPU           ${CPU_VENDOR}"
        "GPU           ${GPU_VENDOR}"
        "KERNEL        ${KERNEL_TYPE}  (config: ${KERNEL_CONFIG:-n/a})"
        "DISPLAY       ${DISPLAY_SERVER}"
        "DESKTOP/WM    ${DESKTOP_ENV}"
        "PIPEWIRE      ${ENABLE_PIPEWIRE}"
        "BLUETOOTH     ${ENABLE_BLUETOOTH}"
        "PRINTING      ${ENABLE_PRINTING}"
        "FLATPAK       ${ENABLE_FLATPAK}"
        "LIBVIRT       ${ENABLE_LIBVIRT}"
        "DOCKER        ${ENABLE_DOCKER}"
        "SECURE BOOT   ${ENABLE_SECURE_BOOT}"
        "MAKEOPTS      ${MAKEOPTS}"
        "MIRRORS       ${GENTOO_MIRRORS}"
    )
    [[ -n "$EXTRA_PACKAGES" ]] && sections+=("EXTRA PKG     ${EXTRA_PACKAGES}")

    for line in "${sections[@]}"; do
        local key="${line%%  *}"
        local val="${line#*  }"
        printf "  ${BOLD}%-16s${NC}%s\n" "$key" "$val"
    done
    echo ""
}

# =============================================================================
# DERIVE PORTAGE SETTINGS FROM SELECTIONS
# =============================================================================

derive_portage_settings() {
    # USE flags
    local use="-systemd udev dbus policykit"

    [[ "$INIT_SYSTEM" == "systemd" ]] && use="${use//-systemd/systemd}"

    case "$DISPLAY_SERVER" in
        wayland) use="$use wayland -X"       ;;
        x11)     use="$use X -wayland"       ;;
        both)    use="$use wayland X"        ;;
    esac

    case "$DESKTOP_ENV" in
        gnome)    use="$use gnome -kde -plasma"  ;;
        kde)      use="$use kde plasma -gnome"   ;;
        cosmic)   use="$use -gnome -kde -plasma" ;;
        xfce)     use="$use -gnome -kde -plasma xfce" ;;
        lxqt)     use="$use -gnome -kde lxqt"   ;;
        *)        use="$use -gnome -kde -plasma" ;;
    esac

    [[ "$ENABLE_PIPEWIRE" == "yes" ]] && use="$use pipewire pulseaudio" \
        || use="$use -pipewire"

    [[ "$ENABLE_BLUETOOTH" == "yes" ]] && use="$use bluetooth"
    [[ "$ENABLE_PRINTING"  == "yes" ]] && use="$use cups"
    [[ "$ENABLE_FLATPAK"   == "yes" ]] && use="$use flatpak"

    USE_FLAGS="$use"

    # Stage3 variant
    case "$INIT_SYSTEM" in
        systemd) STAGE3_VARIANT="systemd" ;;
        openrc)  STAGE3_VARIANT="openrc"  ;;
    esac

    # VIDEO_CARDS
    case "$GPU_VENDOR" in
        amd)     VIDEO_CARDS="amdgpu radeonsi" ;;
        intel)   VIDEO_CARDS="intel i965 iris" ;;
        nvidia)  VIDEO_CARDS="nvidia"          ;;
        generic) VIDEO_CARDS="fbdev vesa"      ;;
    esac
}

# =============================================================================
# WRITE CONFIG FILE
# =============================================================================

write_config() {
    local outfile="gentoo-install.conf"

    derive_portage_settings

    cat > "$outfile" << EOF
# =============================================================================
# Gentoo Installation Configuration
# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# Edit this file, then run: bash gentoo-install.sh
# =============================================================================

# ── Disk ──────────────────────────────────────────────────────────────────────
DISK="${DISK}"
EFI_SIZE="${EFI_SIZE}"        # GiB
SWAP_SIZE="${SWAP_SIZE}"       # GiB  (set to 0 to skip swap partition)
FS_TYPE="${FS_TYPE}"           # btrfs | ext4 | xfs | f2fs

# ── Encryption ────────────────────────────────────────────────────────────────
ENABLE_LUKS="${ENABLE_LUKS}"   # LUKS2 full-disk encryption

# ── Btrfs ─────────────────────────────────────────────────────────────────────
ENABLE_BTRFS_SNAPPER="${ENABLE_BTRFS_SNAPPER}"

# ── Identity ──────────────────────────────────────────────────────────────────
HOSTNAME="${HOSTNAME}"
USERNAME="${USERNAME}"
# Passwords are NOT stored here. The install script will prompt securely.

# ── Localisation ──────────────────────────────────────────────────────────────
TIMEZONE="${TIMEZONE}"
LOCALE="${LOCALE}"
KEYMAP="${KEYMAP}"

# ── Init system ───────────────────────────────────────────────────────────────
INIT_SYSTEM="${INIT_SYSTEM}"   # openrc | systemd

# ── Portage keywords ──────────────────────────────────────────────────────────
ACCEPT_KEYWORDS="${ACCEPT_KEYWORDS}"   # amd64 | ~amd64

# ── Hardware ──────────────────────────────────────────────────────────────────
CPU_VENDOR="${CPU_VENDOR}"     # intel | amd | generic
GPU_VENDOR="${GPU_VENDOR}"     # amd | intel | nvidia | generic
VIDEO_CARDS="${VIDEO_CARDS}"

# ── Kernel ────────────────────────────────────────────────────────────────────
KERNEL_TYPE="${KERNEL_TYPE}"           # dist | sources | hardened | rt
KERNEL_CONFIG="${KERNEL_CONFIG}"       # defconfig | genkernel | manual

# ── Display & Desktop ─────────────────────────────────────────────────────────
DISPLAY_SERVER="${DISPLAY_SERVER}"     # wayland | x11 | both
DESKTOP_ENV="${DESKTOP_ENV}"           # none | gnome | kde | cosmic | sway |
                                       # niri | hyprland | river | labwc |
                                       # xfce | lxqt | openbox | i3 | dwm | custom

# ── Portage USE flags (auto-derived — edit as needed) ─────────────────────────
USE_FLAGS="${USE_FLAGS}"

# ── Build ─────────────────────────────────────────────────────────────────────
MAKEOPTS="${MAKEOPTS}"
GENTOO_MIRRORS="${GENTOO_MIRRORS}"

# Stage3 variant (auto-derived from INIT_SYSTEM)
STAGE3_VARIANT="${STAGE3_VARIANT}"     # openrc | systemd | hardened | musl

# ── Optional features ─────────────────────────────────────────────────────────
ENABLE_PIPEWIRE="${ENABLE_PIPEWIRE}"
ENABLE_BLUETOOTH="${ENABLE_BLUETOOTH}"
ENABLE_PRINTING="${ENABLE_PRINTING}"
ENABLE_FLATPAK="${ENABLE_FLATPAK}"
ENABLE_LIBVIRT="${ENABLE_LIBVIRT}"
ENABLE_DOCKER="${ENABLE_DOCKER}"
ENABLE_SECURE_BOOT="${ENABLE_SECURE_BOOT}"

# ── Extra packages ────────────────────────────────────────────────────────────
# Space-separated list of additional emerge targets
EXTRA_PACKAGES="${EXTRA_PACKAGES}"
EOF

    echo ""
    log "Configuration written to: ${BOLD}${outfile}${NC}"
    echo ""
    info "Review the file, then run:"
    echo -e "  ${BOLD}bash gentoo-install.sh --config ${outfile}${NC}"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║   Gentoo Installation Profile Builder               ║"
    echo "  ║   Generates gentoo-install.conf                     ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "  Press ${BOLD}Enter${NC} to accept defaults shown in ${DIM}[brackets]${NC}.\n"

    wizard_disk
    wizard_system
    wizard_hardware
    wizard_kernel
    wizard_desktop
    wizard_services
    wizard_mirrors

    print_summary

    local proceed
    yesno proceed "Write configuration file?" "yes"
    [[ "$proceed" != "yes" ]] && { warn "Aborted."; exit 0; }

    write_config
}

main "$@"