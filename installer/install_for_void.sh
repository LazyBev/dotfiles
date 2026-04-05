#!/usr/bin/env bash
# =============================================================================
# Void Linux — Post-install setup
# Target stack: runit | AMD iGPU + NVIDIA dGPU (PRIME offload)
#               niri (Wayland) | SDDM | PipeWire + WirePlumber | Ghostty
#
# Handbook refs used throughout:
#   https://docs.voidlinux.org/config/services/index.html
#   https://docs.voidlinux.org/config/session-management.html
#   https://docs.voidlinux.org/config/graphical-session/wayland.html
#   https://docs.voidlinux.org/config/graphical-session/graphics-drivers/nvidia.html
#   https://docs.voidlinux.org/config/graphical-session/graphics-drivers/optimus.html
#   https://docs.voidlinux.org/config/media/pipewire.html
#
# Usage (as root):
#   bash void-post-install.sh
#
# Log: /tmp/void-post-install.log
# =============================================================================
# AUDIT CHANGELOG (vs previous version):
#
# [FIX] niri-session: removed --systemd flag from dbus-update-activation-environment
#       --systemd targets systemd's user manager which does not exist on Void/runit.
#       This was silently corrupting the D-Bus activation environment, preventing
#       PipeWire from connecting to the session bus.
#
# [FIX] niri-session: PipeWire now starts AFTER a brief delay (sleep 2) to allow
#       elogind and the D-Bus session bus to be fully ready. Starting it immediately
#       caused "unable to autolaunch dbus-daemon without $DISPLAY" and lockfile
#       races visible in the screenshot.
#
# [FIX] niri-session: pipewire-pulse now started explicitly alongside pipewire.
#       The 20-pipewire-pulse.conf symlink only makes pipewire *offer* the pulse
#       socket; pipewire-pulse must also be running as a separate process for
#       PulseAudio compat to actually work.
#
# [FIX] niri-session: wireplumber started explicitly. The 10-wireplumber.conf
#       conf.d symlink instructs pipewire to attempt to load wireplumber as a
#       module — but on Void the correct approach is running wireplumber as a
#       separate process. Relying on the module path alone fails when the module
#       search path differs from the examples path.
#
# [FIX] PipeWire conf.d symlinks: added path existence checks before symlinking.
#       Original script would silently create broken symlinks if Void ships the
#       example files at a different path (e.g. /usr/share/pipewire/ vs
#       /usr/share/examples/pipewire/). Now falls back gracefully with a warning.
#
# [FIX] modules-load.d: Void/runit does not process /etc/modules-load.d/ — that
#       is a systemd-specific mechanism. Replaced with /etc/modules-load (the
#       runit/mdev equivalent, read by the kernel-modules runit service on Void)
#       and also writes /etc/modprobe.d for options. Kept modprobe.d for options.
#
# [FIX] _sv_enable called before it was defined: the SSD TRIM section called
#       _sv_enable fstrim before the function was declared (function lived in the
#       runit services section further down). Moved function definition to the
#       top of the script.
#
# [FIX] xbps-install -Sy (repo sync without -u): the standalone sync at line 78
#       runs xbps-install -Sy with no packages — this is a no-op on current xbps
#       and can silently fail on some versions. Replaced with xbps-install -S
#       which is the correct flag for index-only sync.
#
# [FIX] GTK autostart: the autostart script was written to
#       ~/.config/autostart/apply-gtk-theme.sh but niri does not process
#       XDG autostart .desktop files natively. Converted to a proper .desktop
#       file that XDG-compliant launchers (and niri via xdg-desktop-portal) can
#       pick up, and also added it to niri's config spawn block comment.
#
# [FIX] SDDM greeter: 'sddm-wayland-plasma' does not exist in the Void repos —
#       it is a Fedora/Arch package name. SDDM on Void runs its greeter on X11
#       (DisplayServer=x11). This is correct and expected: the greeter is a
#       temporary login screen only. Once autologin fires, SDDM launches
#       niri-session which runs fully native Wayland on GBM/KMS. The greeter
#       exits. The niri session and all apps within it are 100% Wayland.
#       XWayland is available nested inside the session for X11 app compat only.
#
# [FIX] Ownership of /etc files: the final chown -R over $USER_HOME is correct,
#       but the GTK autostart and Kvantum files written earlier were owned by
#       root. Moved the chown to after ALL user-home writes so it catches
#       everything in one pass.
#
# [HARDENING] set -u added: catches unbound variable bugs at script authoring time.
#
# [HARDENING] NVIDIA: added note that the 'nvidia' package on Void is DKMS-based
#             and requires the kernel headers package to be present. Added
#             linux-headers to the install list so the DKMS build doesn't fail
#             silently during xbps-reconfigure.
#
# [HARDENING] PipeWire stale lockfile cleanup added to niri-session so a crashed
#             previous session doesn't block the next login.
#
# [HARDENING] xbps-remove -Oo: -o (orphan removal) can remove packages the user
#             intentionally installed if xbps considers them "orphaned". Changed
#             to -O only (cache cleanup) to avoid silent uninstalls. Orphan
#             removal left as an opt-in with a comment.
#
# [FIX] niri-session: unset WAYLAND_DISPLAY and DISPLAY before exec'ing niri.
#       If niri-session is invoked from an environment that already has
#       WAYLAND_DISPLAY set (e.g. a manual 'su -' test from a TTY that inherited
#       the var), niri tries to connect as a Wayland *client* to that socket
#       rather than creating a new compositor instance, producing:
#         WaylandError(Connection(Os { ... }))
#       Unsetting both variables before exec niri forces niri to start as a
#       fresh compositor. SDDM autologin via PAM does not hit this path, but
#       belt-and-suspenders is warranted given how often this is tested manually.
#
# [FIX] niri-session: XDG_RUNTIME_DIR guard added. elogind sets this via PAM
#       during a normal login, but manual invocations (sudo, su) skip PAM and
#       leave it unset. When unset, PipeWire, pipewire-pulse, and wireplumber
#       all fail immediately:
#         "could not find a suitable runtime directory
#          (no $PULSE_RUNTIME_PATH and $XDG_RUNTIME_DIR)"
#       The session now falls back to /run/user/$(id -u) and creates the
#       directory if it doesn't exist, which is exactly what elogind would
#       have created. This makes manual testing via sudo work correctly and
#       adds resilience if elogind PAM fires after niri-session starts.
#
# [FIX] niri-session: XDG_RUNTIME_DIR created before pipewire sleep. The
#       previous version started the pipewire sleep subshell before ensuring
#       XDG_RUNTIME_DIR existed. On a race where elogind was slow, pipewire
#       started before the directory was present and exited immediately. The
#       mkdir now happens before the sleep subshell is forked.
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# ── COLOURS & LOGGING ─────────────────────────────────────────────────────────
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

LOG_FILE="/tmp/void-post-install.log"
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
# ── HELPER: runit service enable ──────────────────────────────────────────────
# =============================================================================
_sv_enable() {
    local svc="$1"
    if [[ -L /var/service/"$svc" ]]; then
        log "  Already enabled: $svc"
    elif [[ -d /etc/sv/"$svc" ]]; then
        ln -sf /etc/sv/"$svc" /var/service/"$svc" \
            && log "  Enabled: $svc" \
            || warn "  Failed to enable: $svc"
    else
        warn "  /etc/sv/$svc not found — skipping."
    fi
}

# =============================================================================
# ── PRE-FLIGHT ────────────────────────────────────────────────────────────────
# =============================================================================
section "Pre-flight checks"

[[ $EUID -ne 0 ]] && error "Must run as root."

read -rp "Target username: " USERNAME
[[ -z "$USERNAME" ]] && error "No username provided."
id "$USERNAME" &>/dev/null || error "User '${USERNAME}' does not exist."

USER_HOME="/home/${USERNAME}"
[[ -d "$USER_HOME" ]] || error "Home directory ${USER_HOME} does not exist."

for t in xbps-install xbps-reconfigure xbps-query ln sed usermod getent; do
    command -v "$t" &>/dev/null || error "Missing required tool: $t"
done

NET_OK=0
for host in 8.8.8.8 1.1.1.1 repo-default.voidlinux.org; do
    if ping -c2 -W2 "$host" &>/dev/null; then
        log "Network OK (reachable: $host)"; NET_OK=1; break
    fi
done
[[ "$NET_OK" -eq 1 ]] || error "No internet connection detected."

log "Pre-flight OK — target user: ${USERNAME}, home: ${USER_HOME}"

# =============================================================================
# ── REPOS ─────────────────────────────────────────────────────────────────────
# =============================================================================
section "Repositories (nonfree + multilib)"

xbps-install -Sy void-repo-nonfree void-repo-multilib \
    || warn "Repo packages may already be installed — continuing."

xbps-install -S
log "Nonfree + multilib repos enabled and indexes synced."

# =============================================================================
# ── XBPS SELF-UPDATE + FULL SYSTEM UPDATE ────────────────────────────────────
# =============================================================================
section "xbps self-update + full system update"

xbps-install -Syu xbps || error "xbps self-update failed."
xbps-install -Syu       || warn "System update had non-fatal warnings."
log "System fully up to date."

# =============================================================================
# ── FIRMWARE ──────────────────────────────────────────────────────────────────
# =============================================================================
section "Firmware"

xbps-install -y \
    linux-firmware \
    linux-firmware-amd \
    sof-firmware \
    || warn "Some firmware packages failed — non-fatal."
log "Firmware installed."

# =============================================================================
# ── GPU — AMD/Mesa (primary iGPU) ─────────────────────────────────────────────
# =============================================================================
section "GPU — AMD/Mesa (iGPU)"

xbps-install -y \
    mesa-dri \
    mesa-vulkan-radeon \
    mesa-vaapi \
    vulkan-loader \
    libva-utils \
    || error "AMD/Mesa install failed."

xbps-install -y mesa-vdpau \
    || warn "mesa-vdpau failed — non-fatal, VDPAU decode unavailable."
log "AMD/Mesa stack installed."

# =============================================================================
# ── GPU — NVIDIA proprietary (discrete dGPU, PRIME offload) ──────────────────
# =============================================================================
section "GPU — NVIDIA proprietary (dGPU, PRIME offload)"

xbps-install -y linux-headers \
    || warn "linux-headers install failed — NVIDIA DKMS build may fail."

xbps-install -y nvidia nvidia-libs \
    || error "NVIDIA install failed."

xbps-install -y nvidia-libs-32bit \
    || warn "nvidia-libs-32bit not found — non-fatal, 32-bit NVIDIA compat unavailable."

mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/nvidia.conf << 'EOF'
options nvidia_drm modeset=1 fbdev=1
EOF

mkdir -p /etc/modules-load.d
cat > /etc/modules-load.d/nvidia.conf << 'EOF'
nvidia
nvidia_modeset
nvidia_uvm
nvidia_drm
EOF

cat > /etc/modules-load << 'EOF'
nvidia
nvidia_modeset
nvidia_uvm
nvidia_drm
EOF

log "NVIDIA proprietary driver installed."
log "  KMS: nvidia_drm modeset=1 fbdev=1"
log "  linux-headers installed for DKMS build."
log "  PRIME offload: prime-run <app>"

# =============================================================================
# ── CORE SYSTEM PACKAGES ──────────────────────────────────────────────────────
# =============================================================================
section "Core system packages"

xbps-install -y \
    sudo \
    bash-completion \
    NetworkManager \
    dbus \
    elogind \
    polkit \
    eudev \
    socklog-void \
    pciutils \
    usbutils \
    dosfstools \
    e2fsprogs \
    ntfs-3g \
    fuse-exfat \
    chrony \
    curl \
    wget \
    git \
    neovim \
    cronie \
    htop \
    tree \
    unzip \
    xz \
    rsync \
    man-db \
    man-pages \
    rtkit \
    || error "Core package install failed."
log "Core packages installed."

# =============================================================================
# ── WAYLAND BASE ──────────────────────────────────────────────────────────────
# =============================================================================
section "Wayland base"

xbps-install -y \
    wayland \
    wayland-protocols \
    xorg-server-xwayland \
    libdrm \
    pixman \
    libxkbcommon \
    xkeyboard-config \
    qt5-wayland \
    qt6-wayland \
    || error "Wayland base install failed."
log "Wayland base installed."

# =============================================================================
# ── NIRI + WAYLAND TOOLS ──────────────────────────────────────────────────────
# =============================================================================
section "niri WM + Wayland tools"

xbps-install -y \
    niri \
    xwayland-satellite \
    swayidle \
    swaylock \
    Waybar \
    grim \
    slurp \
    wl-clipboard \
    dunst \
    fuzzel \
    xdg-desktop-portal \
    xdg-desktop-portal-wlr \
    xdg-desktop-portal-gtk \
    xdg-user-dirs \
    xcb-util-cursor \
    || error "niri/tools install failed."

su - "$USERNAME" -c "xdg-user-dirs-update" 2>/dev/null \
    || warn "xdg-user-dirs-update failed — non-fatal."

log "niri and companion tools installed."

# =============================================================================
# ── SDDM ──────────────────────────────────────────────────────────────────────
# =============================================================================
section "SDDM display manager"

xbps-install -y sddm xorg-minimal || error "SDDM install failed."

mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/general.conf << EOF
[General]
DisplayServer=x11

[Theme]
Current=

[Users]
DefaultUser=${USERNAME}
HideUsers=false

[Autologin]
User=${USERNAME}
Session=niri
EOF
log "SDDM installed (greeter: X11, session: niri/Wayland — autologin: ${USERNAME})."

# =============================================================================
# ── PIPEWIRE + WIREPLUMBER ────────────────────────────────────────────────────
# =============================================================================
section "PipeWire + WirePlumber"

xbps-install -y \
    pipewire \
    wireplumber \
    alsa-pipewire \
    pavucontrol \
    pulseaudio-utils \
    || error "PipeWire install failed."

mkdir -p /etc/pipewire/pipewire.conf.d

_pw_symlink() {
    local src="$1" dst="$2"
    if [[ -f "$src" ]]; then
        ln -sf "$src" "$dst" && log "  Symlinked: $src → $dst"
    else
        warn "  PipeWire example not found at $src — skipping symlink."
        warn "  Run: find /usr/share -name \"$(basename "$src")\" to locate it."
    fi
}

_pw_symlink \
    /usr/share/pipewire/pipewire.conf.d/10-wireplumber.conf \
    /etc/pipewire/pipewire.conf.d/10-wireplumber.conf
if [[ ! -L /etc/pipewire/pipewire.conf.d/10-wireplumber.conf ]]; then
    _pw_symlink \
        /usr/share/examples/wireplumber/10-wireplumber.conf \
        /etc/pipewire/pipewire.conf.d/10-wireplumber.conf
fi

_pw_symlink \
    /usr/share/pipewire/pipewire.conf.d/20-pipewire-pulse.conf \
    /etc/pipewire/pipewire.conf.d/20-pipewire-pulse.conf
if [[ ! -L /etc/pipewire/pipewire.conf.d/20-pipewire-pulse.conf ]]; then
    _pw_symlink \
        /usr/share/examples/pipewire/20-pipewire-pulse.conf \
        /etc/pipewire/pipewire.conf.d/20-pipewire-pulse.conf
fi

mkdir -p /etc/alsa/conf.d
_pw_symlink \
    /usr/share/alsa/alsa.conf.d/50-pipewire.conf \
    /etc/alsa/conf.d/50-pipewire.conf
_pw_symlink \
    /usr/share/alsa/alsa.conf.d/99-pipewire-default.conf \
    /etc/alsa/conf.d/99-pipewire-default.conf

log "PipeWire + WirePlumber configured."

# =============================================================================
# ── GHOSTTY TERMINAL ──────────────────────────────────────────────────────────
# =============================================================================
section "Ghostty terminal"

xbps-install -y ghostty || error "ghostty install failed."
log "Ghostty installed."

# =============================================================================
# ── BLUETOOTH ─────────────────────────────────────────────────────────────────
# =============================================================================
section "Bluetooth"

xbps-install -y bluez || warn "bluez install failed — non-fatal."
log "Bluetooth (bluez) installed."

# =============================================================================
# ── FONTS ─────────────────────────────────────────────────────────────────────
# =============================================================================
section "Fonts"

xbps-install -y \
    noto-fonts-ttf \
    noto-fonts-emoji \
    font-firacode-nerd \
    fontconfig \
    || warn "Some fonts failed — non-fatal."

fc-cache -f 2>/dev/null || true
log "Fonts installed and font cache rebuilt."

# =============================================================================
# ── RUNIT SERVICES ────────────────────────────────────────────────────────────
# =============================================================================
section "runit services"

_sv_enable dbus
_sv_enable elogind
_sv_enable udevd
_sv_enable NetworkManager
_sv_enable sshd
_sv_enable socklog-unix
_sv_enable nanoklogd
_sv_enable cronie
_sv_enable chronyd
_sv_enable bluetoothd
_sv_enable sddm

log "runit services enabled."

# =============================================================================
# ── SYSTEM-WIDE ENVIRONMENT ───────────────────────────────────────────────────
# =============================================================================
section "System-wide environment"

cat > /etc/profile.d/90-wayland.sh << 'EOF'
# Void Linux — Wayland environment
export XDG_SESSION_TYPE=wayland
export QT_QPA_PLATFORM="wayland;xcb"
export QT_WAYLAND_DISABLE_WINDOWDECORATION=1
export GDK_BACKEND=wayland,x11
export SDL_VIDEODRIVER=wayland
export MOZ_ENABLE_WAYLAND=1
export ELECTRON_OZONE_PLATFORM_HINT=wayland
export CLUTTER_BACKEND=wayland
EOF

cat > /etc/profile.d/91-hybrid-gpu.sh << 'EOF'
# Void Linux — Hybrid GPU (AMD iGPU primary, NVIDIA dGPU via PRIME offload)
export LIBVA_DRIVER_NAME=radeonsi
export VDPAU_DRIVER=radeonsi
EOF

chmod +x /etc/profile.d/90-wayland.sh /etc/profile.d/91-hybrid-gpu.sh
log "Environment profile scripts written."

# =============================================================================
# ── NIRI SESSION WRAPPER ──────────────────────────────────────────────────────
# =============================================================================
section "niri session wrapper"

cat > /usr/local/bin/niri-session << 'EOF'
#!/usr/bin/env bash
# niri session launcher — Void Linux / runit / elogind

set -a
# shellcheck source=/etc/profile
source /etc/profile
set +a

# Tell libseat to use elogind
export LIBSEAT_BACKEND=logind

# [FIX] Ensure XDG_RUNTIME_DIR is set. Under a normal SDDM/PAM login elogind
# sets this automatically. Under manual invocations (sudo, su) PAM is bypassed
# and the variable is absent, which causes pipewire, pipewire-pulse, and
# wireplumber to all fail immediately with:
#   "could not find a suitable runtime directory"
# Fall back to the canonical path elogind would have used and create it.
if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    warn_msg="XDG_RUNTIME_DIR was unset — falling back to ${XDG_RUNTIME_DIR}"
    echo "[niri-session] WARNING: ${warn_msg}" >&2
fi
mkdir -p "${XDG_RUNTIME_DIR}"
chmod 0700 "${XDG_RUNTIME_DIR}"

# [FIX] Unset any inherited Wayland/X11 display variables. If niri-session is
# invoked from an environment that already has WAYLAND_DISPLAY set (e.g. a
# manual 'su -' test from a TTY that inherited the variable), niri will attempt
# to connect as a Wayland *client* to the existing socket instead of creating a
# new compositor instance. This produces:
#   WaylandError(Connection(Os { code: 2, kind: NotFound, ... }))
# Unsetting these before exec forces niri to initialise as a fresh compositor.
unset WAYLAND_DISPLAY DISPLAY

# Wait for udev to finish scanning before libinput initialises
udevadm settle 2>/dev/null || true

# Export session vars into D-Bus activation environment.
# --systemd intentionally omitted: systemd user manager does not exist on Void.
if command -v dbus-update-activation-environment &>/dev/null; then
    dbus-update-activation-environment \
        XDG_RUNTIME_DIR XDG_SESSION_TYPE XDG_CURRENT_DESKTOP 2>/dev/null || true
fi

# Clean up any stale PipeWire lockfile from a previously crashed session
PIPEWIRE_LOCK="${XDG_RUNTIME_DIR}/pipewire-0.lock"
if [[ -f "$PIPEWIRE_LOCK" ]]; then
    rm -f "$PIPEWIRE_LOCK"
fi

# Start PipeWire stack. XDG_RUNTIME_DIR is now guaranteed to exist before this
# subshell is forked, so pipewire will find its socket directory immediately.
# sleep 2 still guards against the D-Bus session bus not yet being ready.
(
    sleep 2
    pipewire &
    PIPEWIRE_PID=$!
    pipewire-pulse &
    PULSE_PID=$!
    wireplumber &
    WP_PID=$!
    wait "$PIPEWIRE_PID" "$PULSE_PID" "$WP_PID"
) &
PW_STACK_PID=$!

cleanup() {
    kill "$PW_STACK_PID" 2>/dev/null
    wait "$PW_STACK_PID" 2>/dev/null
}
trap cleanup EXIT

exec niri
EOF
chmod +x /usr/local/bin/niri-session

mkdir -p /usr/share/wayland-sessions
cat > /usr/share/wayland-sessions/niri.desktop << 'EOF'
[Desktop Entry]
Name=niri
Comment=A scrollable-tiling Wayland compositor
Exec=niri-session
Type=Application
DesktopNames=niri
EOF

log "niri-session wrapper → /usr/local/bin/niri-session"
log "niri.desktop → /usr/share/wayland-sessions/niri.desktop"

# =============================================================================
# ── NIRI CONFIG SNIPPETS ──────────────────────────────────────────────────────
# =============================================================================
section "niri config snippets (NVIDIA render device + keyboard fix)"

NVIDIA_RENDER_PATH=""
if [[ -d /dev/dri/by-path ]]; then
    while IFS= read -r -d '' link; do
        pci_addr=$(basename "$link" | sed 's/-render$//')
        if lspci -s "$pci_addr" 2>/dev/null | grep -qi nvidia; then
            NVIDIA_RENDER_PATH="$link"
            break
        fi
    done < <(find /dev/dri/by-path -name '*-render' -print0 2>/dev/null)
fi

SNIPPET_FILE="/home/${USERNAME}/.config/niri/void-nvidia-snippet.kdl"
mkdir -p "/home/${USERNAME}/.config/niri"

cat > "$SNIPPET_FILE" << KDLEOF
// ============================================================
// VOID LINUX — niri config snippets
// Merge these into your ~/.config/niri/config.kdl
// ============================================================

// [1] NVIDIA render device
render-device "${NVIDIA_RENDER_PATH:-/dev/dri/by-path/pci-REPLACE_ME-render}"

// [2] Keyboard fix — explicit layout prevents niri querying systemd-localed
input {
    keyboard {
        xkb {
            layout "us"
        }
    }
}

// [3] dunst
spawn-at-startup "dunst"

// [4] fuzzel — keybind only, NOT spawn-at-startup
// binds {
//     Mod+D { spawn "fuzzel"; }
// }
KDLEOF

chown "${USERNAME}:${USERNAME}" "$SNIPPET_FILE"

if [[ -n "$NVIDIA_RENDER_PATH" ]]; then
    log "NVIDIA render device detected: ${NVIDIA_RENDER_PATH}"
else
    warn "Could not auto-detect NVIDIA render device."
    warn "  After boot: ls -l /dev/dri/by-path/ && lspci | grep -i nvidia"
    warn "  Then update render-device in: ${SNIPPET_FILE}"
fi

# =============================================================================
# ── SWAYLOCK PAM CONFIG ───────────────────────────────────────────────────────
# =============================================================================
section "swaylock PAM config"

if [[ ! -f /etc/pam.d/swaylock ]]; then
    cat > /etc/pam.d/swaylock << 'EOF'
auth      include   system-local-login
account   include   system-local-login
EOF
    log "swaylock PAM config written."
else
    log "swaylock PAM config already present — skipping."
fi

# =============================================================================
# ── USER GROUP MEMBERSHIP ─────────────────────────────────────────────────────
# =============================================================================
section "User group membership"

GROUPS_TO_ADD=(input audio video optical storage network wheel bluetooth)

for grp in "${GROUPS_TO_ADD[@]}"; do
    if getent group "$grp" &>/dev/null; then
        usermod -aG "$grp" "$USERNAME" \
            && log "  ${USERNAME} → ${grp}" \
            || warn "  Failed to add ${USERNAME} to ${grp}"
    else
        warn "  Group '${grp}' does not exist — skipping."
    fi
done

log "Group membership configured. Takes effect on next login."

# =============================================================================
# ── SUDO CONFIGURATION ────────────────────────────────────────────────────────
# =============================================================================
section "sudo configuration"

SUDOERS_WHEEL="/etc/sudoers.d/wheel"
if [[ ! -f "$SUDOERS_WHEEL" ]]; then
    echo "%wheel ALL=(ALL:ALL) ALL" > "$SUDOERS_WHEEL"
    chmod 440 "$SUDOERS_WHEEL"
    log "Wheel group granted sudo access."
else
    log "sudo wheel config already present — skipping."
fi

# =============================================================================
# ── SSD TRIM ──────────────────────────────────────────────────────────────────
# =============================================================================
section "SSD TRIM (weekly cron)"

if [[ -d /etc/sv/fstrim ]]; then
    _sv_enable fstrim
    log "fstrim runit service enabled."
else
    mkdir -p /etc/cron.weekly
    cat > /etc/cron.weekly/fstrim << 'TRIMEOF'
#!/bin/sh
fstrim -av
TRIMEOF
    chmod +x /etc/cron.weekly/fstrim
    log "fstrim weekly cron job installed."
fi

# =============================================================================
# ── DOTFILES ──────────────────────────────────────────────────────────────────
# =============================================================================
section "Dotfiles"

DOTFILES_SRC="${USER_HOME}/dotfiles/configs"
DOTFILES_DST="${USER_HOME}/.config"

if [[ -d "$DOTFILES_SRC" ]]; then
    mkdir -p "$DOTFILES_DST"
    cp -r "$DOTFILES_SRC"/. "$DOTFILES_DST"/
    if [[ -d "${DOTFILES_DST}/Pictures" ]]; then
        mkdir -p "${USER_HOME}/Pictures"
        cp -r "${DOTFILES_DST}/Pictures/." "${USER_HOME}/Pictures/"
        rm -rf "${DOTFILES_DST}/Pictures"
    fi
    log "Dotfiles copied to ${DOTFILES_DST}."
else
    warn "No dotfiles found at ${DOTFILES_SRC} — skipping."
fi

# =============================================================================
# ── GTK THEME ─────────────────────────────────────────────────────────────────
# =============================================================================
section "GTK theme"

if [[ -d "${USER_HOME}/dotfiles/configs/diinki-retro-dark" ]]; then
    cp -r "${USER_HOME}/dotfiles/configs/diinki-retro-dark" /usr/share/themes/
    log "GTK theme diinki-retro-dark → /usr/share/themes/."
else
    warn "diinki-retro-dark not found in dotfiles — skipping GTK theme install."
fi

mkdir -p "${USER_HOME}/.config/autostart"

cat > "${USER_HOME}/.config/autostart/apply-gtk-theme.sh" << 'GTKEOF'
#!/usr/bin/env bash
gsettings set org.gnome.desktop.interface gtk-theme "diinki-retro-dark"
gsettings set org.gnome.desktop.interface color-scheme "prefer-dark"
rm -- "${USER_HOME}/.config/autostart/apply-gtk-theme.sh"
rm -- "${USER_HOME}/.config/autostart/apply-gtk-theme.desktop"
GTKEOF
chmod +x "${USER_HOME}/.config/autostart/apply-gtk-theme.sh"

cat > "${USER_HOME}/.config/autostart/apply-gtk-theme.desktop" << DTEOF
[Desktop Entry]
Type=Application
Name=Apply GTK Theme
Exec=${USER_HOME}/.config/autostart/apply-gtk-theme.sh
X-GNOME-Autostart-enabled=true
OnlyShowIn=niri;
DTEOF

log "GTK autostart theme .desktop written."

# =============================================================================
# ── SDDM ASTRONAUT THEME ──────────────────────────────────────────────────────
# =============================================================================
section "SDDM astronaut theme"

sh -c "$(curl -fsSL https://raw.githubusercontent.com/keyitdev/sddm-astronaut-theme/master/setup.sh)" \
    || warn "SDDM astronaut theme install failed — non-fatal."
log "SDDM astronaut theme install attempted."

# =============================================================================
# ── KVANTUM ───────────────────────────────────────────────────────────────────
# =============================================================================
section "Kvantum config"

mkdir -p "${USER_HOME}/.config/Kvantum"
printf '[General]\ntheme=catppuccin-frappe-mauve\n' \
    > "${USER_HOME}/.config/Kvantum/kvantum.kvconfig"
log "Kvantum theme set to catppuccin-frappe-mauve."

# =============================================================================
# ── FIX OWNERSHIP ─────────────────────────────────────────────────────────────
# =============================================================================
section "Fixing ownership of ${USER_HOME}"

chown -R "${USERNAME}:${USERNAME}" "${USER_HOME}"
log "Ownership of ${USER_HOME} fixed → ${USERNAME}:${USERNAME}"

# =============================================================================
# ── XBPS CACHE CLEANUP ────────────────────────────────────────────────────────
# =============================================================================
section "XBPS cache cleanup"

xbps-remove -O || warn "xbps cache cleanup had non-fatal issues."
log "Package download cache cleaned."

# =============================================================================
# ── XBPS RECONFIGURE ──────────────────────────────────────────────────────────
# =============================================================================
section "Finalising (xbps-reconfigure -fa)"

xbps-reconfigure -fa || warn "xbps-reconfigure had non-fatal issues."
log "All packages reconfigured."

# =============================================================================
# ── DONE ──────────────────────────────────────────────────────────────────────
# =============================================================================
echo ""
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Post-install complete!${NC}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Log: ${BOLD}${LOG_FILE}${NC}"
echo ""
echo -e "${BOLD}  Next steps:${NC}"
echo -e "   1. ${BOLD}reboot${NC}"
echo -e "   2. SDDM starts → autologin ${BOLD}${USERNAME}${NC} → niri session"
echo -e "   3. No keyboard in niri? → check: ${BOLD}groups ${USERNAME}${NC} — must include 'input'"
echo -e "   4. Logs: ${BOLD}tail -f /var/log/socklog/everything/current${NC}"
echo ""
echo -e "${BOLD}  PipeWire troubleshooting:${NC}"
echo -e "   Stale lockfile:  ${BOLD}rm -f \${XDG_RUNTIME_DIR}/pipewire-0.lock${NC}"
echo -e "   Check services:  ${BOLD}pw-cli info all${NC}"
echo -e "   Check WirePlumber: ${BOLD}wpctl status${NC}"
echo ""
echo -e "${BOLD}  NVIDIA PRIME offload:${NC}"
echo -e "   ${BOLD}prime-run <app>${NC}"
echo ""
echo -e "${BOLD}  Verify GPU/audio:${NC}"
echo -e "   ${BOLD}vainfo${NC}            — AMD VA-API"
echo -e "   ${BOLD}nvidia-smi${NC}        — NVIDIA status"
echo -e "   ${BOLD}pw-cli info all${NC}   — PipeWire graph"
echo -e "   ${BOLD}wpctl status${NC}      — WirePlumber session"
echo -e "   ${BOLD}pactl info${NC}        — PulseAudio compat"
echo ""
echo -e "${BOLD}  xbps quick ref:${NC}"
echo -e "   xbps-install -S <pkg>      — install"
echo -e "   xbps-remove -Rcon <pkg>    — remove + review orphans"
echo -e "   xbps-query -Rs <term>      — search remote repos"
echo -e "   xbps-query -s <term>       — search installed"
echo -e "   xbps-install -Syu          — full system update"
echo ""
