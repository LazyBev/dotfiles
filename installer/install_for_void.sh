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
set -eo pipefail
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
# ── PRE-FLIGHT ────────────────────────────────────────────────────────────────
# =============================================================================
section "Pre-flight checks"

[[ $EUID -ne 0 ]] && error "Must run as root."

read -rp "Target username: " USERNAME
[[ -z "$USERNAME" ]] && error "No username provided."
id "$USERNAME" &>/dev/null || error "User '${USERNAME}' does not exist."

USER_HOME="/home/${USERNAME}"

for t in xbps-install xbps-reconfigure xbps-query ln sed usermod; do
    command -v "$t" &>/dev/null || error "Missing tool: $t"
done

NET_OK=0
for host in 8.8.8.8 1.1.1.1 repo-default.voidlinux.org; do
    if ping -c2 -W2 "$host" &>/dev/null; then
        log "Network OK (reachable: $host)"; NET_OK=1; break
    fi
done
[[ "$NET_OK" -eq 1 ]] || error "No internet connection."

log "Pre-flight OK — target user: ${USERNAME}"

# =============================================================================
# ── REPOS ─────────────────────────────────────────────────────────────────────
# Per Handbook: nonfree is a separate repo package. Install it first so
# NVIDIA drivers and other nonfree packages are available in the same run.
# void-repo-multilib adds 32-bit glibc packages (Steam, Wine, nvidia-32bit).
# =============================================================================
section "Repositories (nonfree + multilib)"

xbps-install -Sy void-repo-nonfree void-repo-multilib \
    || warn "Repo packages may already be installed — continuing."
xbps-install -Sy   # sync new repo indexes
log "Nonfree + multilib repos enabled and indexes synced."

# =============================================================================
# ── XBPS SELF-UPDATE + FULL SYSTEM UPDATE ────────────────────────────────────
# Per Handbook: always update xbps itself first — older xbps may not handle
# newer package metadata correctly.
# =============================================================================
section "xbps self-update + full system update"

xbps-install -Syu xbps  || error "xbps self-update failed."
xbps-install -Syu        || warn "System update had non-fatal warnings."
log "System fully up to date."

# =============================================================================
# ── FIRMWARE ──────────────────────────────────────────────────────────────────
# Per Handbook (config/firmware):
#   linux-firmware     — full upstream firmware blob set
#   linux-firmware-amd — AMD GPU/CPU microcode
#   sof-firmware       — Intel/AMD audio DSP firmware (many modern systems need this)
# Note: as of linux-firmware-20260309_1, Void compresses firmware with zstd.
# Ensure the running kernel supports zstd before updating firmware.
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
# Per Handbook (graphics-drivers/amd):
#   mesa-dri           — OpenGL via radeonsi; REQUIRED by all GBM-based Wayland
#                        compositors. niri uses GBM.
#   mesa-vulkan-radeon — Vulkan (RADV driver)
#   mesa-vaapi         — VA-API hardware video decode (radeonsi backend)
#   mesa-vdpau         — VDPAU hardware video decode (mpv, VLC)
#   vulkan-loader      — runtime Vulkan ICD loader (used by both AMD and NVIDIA)
#   libva-utils        — vainfo for VA-API verification
# =============================================================================
section "GPU — AMD/Mesa (iGPU)"

xbps-install -y \
    mesa-dri \
    mesa-vulkan-radeon \
    mesa-vaapi \
    vulkan-loader \
    libva-utils \
    || error "AMD/Mesa install failed."

# mesa-vdpau is a separate subpackage — split out so a failure doesn't
# abort the whole AMD stack (may not be available on all repo states).
xbps-install -y mesa-vdpau || warn "mesa-vdpau failed — non-fatal, VDPAU decode unavailable."
log "AMD/Mesa stack installed."

# =============================================================================
# ── GPU — NVIDIA proprietary (discrete dGPU, PRIME offload) ──────────────────
# Per Handbook (graphics-drivers/nvidia):
#   - Cards 800+   → 'nvidia' package (DKMS, integrates into kernel via DKMS)
#   - Cards 600/700 → 'nvidia470'
#   - Cards 400/500 → 'nvidia390'
#   nvidia-libs         — 64-bit OpenGL/Vulkan userspace
#   nvidia-libs-32bit   — 32-bit compat for Steam/Wine
#
# Per Handbook (graphics-drivers/optimus — PRIME Render Offload):
#   Recommended method for hybrid AMD+NVIDIA systems.
#   The 'prime-run' wrapper script ships with the nvidia package.
#   Usage: prime-run <application>
#   Manual: __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia <app>
#
# nvidia_drm.modeset=1  — required for Wayland (GBM output)
# fbdev=1               — framebuffer console on NVIDIA GPU
# =============================================================================
section "GPU — NVIDIA proprietary (dGPU, PRIME offload)"

xbps-install -y nvidia nvidia-libs \
    || error "NVIDIA install failed."

# 32-bit NVIDIA compat — requires void-repo-multilib; non-fatal if unavailable
xbps-install -y nvidia-libs-32bit || warn "nvidia-libs-32bit not found — non-fatal, 32-bit NVIDIA compat unavailable."

mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/nvidia.conf << 'EOF'
# Enable KMS (required for Wayland) and fbdev console on NVIDIA GPU.
options nvidia_drm modeset=1 fbdev=1
EOF

mkdir -p /etc/modules-load.d
cat > /etc/modules-load.d/nvidia.conf << 'EOF'
nvidia
nvidia_modeset
nvidia_uvm
nvidia_drm
EOF

log "NVIDIA proprietary driver installed."
log "  KMS: nvidia_drm modeset=1 fbdev=1"
log "  PRIME offload: prime-run <app>"
log "  Manual: __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia <app>"

# =============================================================================
# ── CORE SYSTEM PACKAGES ──────────────────────────────────────────────────────
# Per Handbook (config/services, session-management):
#   dbus        — system IPC bus; must be enabled before elogind + NetworkManager
#   elogind     — manages logins, provides XDG_RUNTIME_DIR and seat access for
#                 Wayland. Requires the system dbus service to be running.
#   polkit      — privilege escalation; required for NetworkManager non-root use.
#                 polkitd is socket-activated — no runit symlink needed.
#   eudev       — udev device management (Void's eudev fork)
#   socklog-void — Void's recommended runit-native logging solution.
#                  Logs go to /var/log/socklog/ per facility.
#   chrony      — NTP time sync. More accurate than openntpd on modern hardware.
#   rtkit       — realtime scheduling for PipeWire (reduces audio xruns)
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
# Per Handbook (graphical-session/wayland):
#   mesa-dri required by GBM compositors (already installed above).
#   qt5-wayland / qt6-wayland: enable Qt Wayland backend.
#     Activate with QT_QPA_PLATFORM=wayland (set in /etc/profile.d below).
#   xorg-server-xwayland: XWayland bridge for X11 apps under Wayland.
#   libxkbcommon + xkeyboard-config: keyboard map handling for compositors.
#   XDG_RUNTIME_DIR: provided automatically by elogind at login.
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
# Per Handbook (graphical-session/wayland): niri is a packaged standalone
# Wayland compositor (scrolling-tiling). Uses GBM — mesa-dri required.
#
# xdg-desktop-portal + xdg-desktop-portal-wlr:
#   Portal backend for screen capture, file picker, etc. (wlroots-compatible)
# xdg-desktop-portal-gtk: GTK portal backend (file dialogs, app chooser)
# xdg-user-dirs: creates ~/Desktop, ~/Downloads, ~/Music, etc.
# xcb-util-cursor: cursor theme support — missing = invisible cursor in niri.
# swaylock: screen locker. REQUIRES /etc/pam.d/swaylock to authenticate.
# mako: Wayland notification daemon (D-Bus org.freedesktop.Notifications)
# fuzzel: Wayland-native app launcher.
# grim + slurp: screenshot pipeline for Wayland.
# wl-clipboard: wl-copy/wl-paste clipboard tools.
# swayidle: idle management (lock, dpms off, suspend on inactivity).
# Waybar: status bar with Wayland support.
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
    mako \
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
# Per Handbook (graphical-session/kde): SDDM requires the dbus service to be
# enabled. Enable dbus before enabling sddm.
# DisplayServer=wayland: SDDM Wayland greeter mode (uses GBM via mesa-dri).
# Autologin block: remove or comment out [Autologin] to disable autologin.
# =============================================================================
section "SDDM display manager"

xbps-install -y sddm xorg-minimal || error "SDDM install failed."

mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/general.conf << EOF
[General]
DisplayServer=wayland

[Theme]
Current=

[Users]
DefaultUser=${USERNAME}
HideUsers=false

[Autologin]
User=${USERNAME}
Session=niri
EOF
log "SDDM installed and configured (autologin: ${USERNAME} → niri)."

# =============================================================================
# ── PIPEWIRE + WIREPLUMBER ────────────────────────────────────────────────────
# Per Handbook (config/media/pipewire):
#  1. Install 'pipewire' — wireplumber is pulled in as the session manager.
#     Without a session manager PipeWire does NOT function.
#  2. Link 10-wireplumber.conf — tells PipeWire to launch WirePlumber.
#  3. Link 20-pipewire-pulse.conf — PulseAudio compat interface.
#     Most apps speak PulseAudio, not native PipeWire.
#  4. alsa-pipewire + conf.d symlinks — makes PipeWire the default ALSA device.
#  5. PipeWire MUST run as the logged-in user (not as a system service).
#     Per Handbook: launch it from the compositor startup script.
#  6. Requires an active D-Bus user session bus + XDG_RUNTIME_DIR.
#     elogind provides XDG_RUNTIME_DIR; SDDM + elogind provides the session bus.
#  7. rtkit (installed in core packages) provides realtime scheduling.
# =============================================================================
section "PipeWire + WirePlumber"

xbps-install -y \
    pipewire \
    alsa-pipewire \
    pavucontrol \
    pulseaudio-utils \
    || error "PipeWire install failed."

# System-wide PipeWire config
mkdir -p /etc/pipewire/pipewire.conf.d
ln -sf /usr/share/examples/wireplumber/10-wireplumber.conf \
       /etc/pipewire/pipewire.conf.d/10-wireplumber.conf
ln -sf /usr/share/examples/pipewire/20-pipewire-pulse.conf \
       /etc/pipewire/pipewire.conf.d/20-pipewire-pulse.conf

# Make PipeWire the default ALSA output device
mkdir -p /etc/alsa/conf.d
ln -sf /usr/share/alsa/alsa.conf.d/50-pipewire.conf \
       /etc/alsa/conf.d/50-pipewire.conf
ln -sf /usr/share/alsa/alsa.conf.d/99-pipewire-default.conf \
       /etc/alsa/conf.d/99-pipewire-default.conf

log "PipeWire + WirePlumber configured."
log "  PipeWire launched per-user from niri-session (NOT a system service)."

# =============================================================================
# ── GHOSTTY TERMINAL ──────────────────────────────────────────────────────────
# =============================================================================
section "Ghostty terminal"

xbps-install -y ghostty || error "ghostty install failed."
log "Ghostty installed."

# =============================================================================
# ── BLUETOOTH ─────────────────────────────────────────────────────────────────
# Per Handbook (config/bluetooth):
#   bluez provides bluetoothd and bluetoothctl.
#   Enable the bluetoothd runit service.
#   User must be in the 'bluetooth' group (added in groups section below).
# =============================================================================
section "Bluetooth"

xbps-install -y bluez || warn "bluez install failed — non-fatal."
log "Bluetooth (bluez) installed."

# =============================================================================
# ── FONTS ─────────────────────────────────────────────────────────────────────
# Per Handbook (graphical-session/fonts): some Wayland compositors including
# niri do NOT depend on fonts. Missing fonts cause most GUI apps to break.
# Always install at least one font package.
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
# Per Handbook (config/services/index):
#   Enabling: ln -sf /etc/sv/<name> /var/service/<name>
#   runit picks up new symlinks within a few seconds automatically.
#   All services in /etc/sv/ are available; active ones live in /var/service/.
#
# Enable order (dependencies first):
#   dbus         — system bus; elogind + NetworkManager both require it
#   elogind      — seat/session management; needs dbus running first
#   udevd        — eudev device management
#   NetworkManager — needs dbus; polkit for non-root access (socket-activated)
#   sshd         — remote access
#   socklog-unix — syslog receiver (socklog-void)
#   nanoklogd    — kernel log forwarder (socklog-void)
#   cronie       — cron daemon
#   chronyd      — NTP time sync
#   bluetoothd   — Bluetooth daemon
#   sddm         — display manager; Handbook says test dbus before enabling
#
# NOT enabled as system services:
#   pipewire — per Handbook must run as the current user, not as root/system
#   acpid    — per Handbook: do NOT use with elogind (conflicts)
# =============================================================================
section "runit services"

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
_sv_enable sddm   # enable last; depends on dbus

log "runit services enabled."
log "  pipewire — NOT a system service (runs per-user from niri-session)"
log "  acpid    — NOT enabled (conflicts with elogind per Handbook)"

# =============================================================================
# ── SYSTEM-WIDE ENVIRONMENT ───────────────────────────────────────────────────
# Per Handbook (graphical-session/wayland):
#   XDG_SESSION_TYPE=wayland     — required by some apps to pick Wayland backend
#   QT_QPA_PLATFORM=wayland;xcb  — Qt apps use Wayland; xcb is X11 fallback
#   SDL_VIDEODRIVER=wayland       — SDL apps use Wayland backend
#   GDK_BACKEND=wayland,x11       — GTK prefer Wayland, fall back to X11
#   MOZ_ENABLE_WAYLAND=1          — legacy; Firefox now auto-detects (harmless)
#   ELECTRON_OZONE_PLATFORM_HINT  — Electron apps use Wayland backend
#   XDG_RUNTIME_DIR               — set by elogind at login; do NOT hardcode
#
# Per Handbook (graphics-drivers/amd + optimus):
#   LIBVA_DRIVER_NAME=radeonsi — VA-API defaults to AMD iGPU
#   VDPAU_DRIVER=radeonsi      — VDPAU defaults to AMD iGPU
# =============================================================================
section "System-wide environment"

cat > /etc/profile.d/90-wayland.sh << 'EOF'
# Void Linux — Wayland environment
# Ref: https://docs.voidlinux.org/config/graphical-session/wayland.html
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
# Ref: https://docs.voidlinux.org/config/graphical-session/graphics-drivers/optimus.html

# VA-API and VDPAU default to AMD iGPU
export LIBVA_DRIVER_NAME=radeonsi
export VDPAU_DRIVER=radeonsi

# PRIME offload for per-application NVIDIA use:
#   prime-run <app>
#   or: __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia <app>
EOF

chmod +x /etc/profile.d/90-wayland.sh /etc/profile.d/91-hybrid-gpu.sh
log "Environment profile scripts written to /etc/profile.d/."

# =============================================================================
# ── NIRI SESSION WRAPPER ──────────────────────────────────────────────────────
# Per Handbook (config/media/pipewire): PipeWire must be launched from the
# compositor startup script as the logged-in user.
# WirePlumber starts automatically via the 10-wireplumber.conf symlink once
# PipeWire is running.
#
# Per Handbook (session-management): SDDM + elogind provides XDG_RUNTIME_DIR
# and the D-Bus session bus at login. dbus-run-session is not needed.
#
# LIBSEAT_BACKEND=logind: prevents "seatd not present" warnings from libseat
# when elogind is in use (the correct backend here is logind, not seatd).
#
# dbus-update-activation-environment: exports display vars into the D-Bus
# activation environment so portal backends (screen capture, file picker)
# can find the correct Wayland display.
# =============================================================================
section "niri session wrapper"

cat > /usr/local/bin/niri-session << 'EOF'
#!/usr/bin/env bash
# niri session launcher
# Sources /etc/profile, starts PipeWire as the user, then execs niri.
set -a
source /etc/profile
set +a

# Tell libseat to use elogind (prevents "seatd not found" noise)
export LIBSEAT_BACKEND=logind

# Export Wayland display vars into D-Bus activation env for portal backends
if command -v dbus-update-activation-environment &>/dev/null; then
    dbus-update-activation-environment --systemd \
        WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE 2>/dev/null || true
fi

# Start PipeWire as the current user.
# WirePlumber starts automatically via /etc/pipewire/pipewire.conf.d/10-wireplumber.conf
pipewire &
PIPEWIRE_PID=$!
trap "kill $PIPEWIRE_PID 2>/dev/null; wait $PIPEWIRE_PID 2>/dev/null" EXIT

exec niri
EOF
chmod +x /usr/local/bin/niri-session

# Register niri-session as a valid Wayland session for SDDM
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
# ── SWAYLOCK PAM CONFIG ───────────────────────────────────────────────────────
# swaylock uses PAM to authenticate at screen unlock. Without this file,
# swaylock will NEVER successfully unlock — the screen stays locked forever.
# Void does not ship this file by default; it must be created manually.
# =============================================================================
section "swaylock PAM config"

if [[ ! -f /etc/pam.d/swaylock ]]; then
    cat > /etc/pam.d/swaylock << 'EOF'
auth      include   system-local-login
account   include   system-local-login
EOF
    log "swaylock PAM config written to /etc/pam.d/swaylock."
else
    log "swaylock PAM config already present — skipping."
fi

# =============================================================================
# ── USER GROUP MEMBERSHIP ─────────────────────────────────────────────────────
# Per Handbook (config/users-and-groups) and session-management docs:
#
#   input     — REQUIRED for keyboard/pointer in niri. elogind uses this for
#               seat device access. Without it: mouse works, keyboard does NOT.
#   audio     — Direct ALSA/PipeWire device access (belt-and-suspenders with elogind)
#   video     — GPU and V4L2 (webcam) device access
#   optical   — CD/DVD drive access
#   storage   — Removable storage (udisks2 auto-mount)
#   network   — NetworkManager without sudo
#   wheel     — sudo privilege escalation
#   bluetooth — bluetoothctl without sudo
#
# Changes take effect on NEXT LOGIN (or reboot).
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
# Ensure wheel group has sudo access.
# Void installer sets this, but a manual base install may not.
# =============================================================================
section "sudo configuration"

SUDOERS_WHEEL="/etc/sudoers.d/wheel"
if [[ ! -f "$SUDOERS_WHEEL" ]]; then
    echo "%wheel ALL=(ALL:ALL) ALL" > "$SUDOERS_WHEEL"
    chmod 440 "$SUDOERS_WHEEL"
    log "Wheel group granted sudo access via ${SUDOERS_WHEEL}."
else
    log "sudo wheel config already present — skipping."
fi

# =============================================================================
# ── SSD TRIM ──────────────────────────────────────────────────────────────────
# Per Handbook (config/ssd): periodic TRIM keeps SSD performance healthy.
# On Void/runit, use fstrim via cron since there's no systemd timer.
# =============================================================================
section "SSD TRIM (weekly cron)"

if [[ -d /etc/sv/fstrim ]]; then
    _sv_enable fstrim
    log "fstrim runit service enabled."
else
    mkdir -p /etc/cron.weekly
    cat > /etc/cron.weekly/fstrim << 'EOF'
#!/bin/sh
fstrim -av
EOF
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
    chown -R "${USERNAME}:${USERNAME}" "$DOTFILES_DST"
    log "Dotfiles copied to ${DOTFILES_DST}."
else
    warn "No dotfiles found at ${DOTFILES_SRC} — skipping."
fi

# =============================================================================
# ── GTK THEME ─────────────────────────────────────────────────────────────────
# gsettings requires a running D-Bus session + display — can't run as root.
# Install a first-boot autostart script to apply on first login instead.
# =============================================================================
section "GTK theme"

if [[ -d "${USER_HOME}/dotfiles/configs/diinki-retro-dark" ]]; then
    cp -r "${USER_HOME}/dotfiles/configs/diinki-retro-dark" /usr/share/themes/
    log "GTK theme diinki-retro-dark → /usr/share/themes/."
else
    warn "diinki-retro-dark not found in dotfiles — skipping GTK theme install."
fi

mkdir -p "${USER_HOME}/.config/autostart"
cat > "${USER_HOME}/.config/autostart/apply-gtk-theme.sh" << 'FBEOF'
#!/usr/bin/env bash
gsettings set org.gnome.desktop.interface gtk-theme "diinki-retro-dark"
gsettings set org.gnome.desktop.interface color-scheme "prefer-dark"
rm -- "$0"
FBEOF
chmod +x "${USER_HOME}/.config/autostart/apply-gtk-theme.sh"
log "GTK autostart theme script written — applies on first login then self-deletes."

# =============================================================================
# ── SDDM ASTRONAUT THEME ──────────────────────────────────────────────────────
# =============================================================================
section "SDDM astronaut theme"

sh -c "$(curl -fsSL https://raw.githubusercontent.com/keyitdev/sddm-astronaut-theme/master/setup.sh)" \
    || warn "SDDM astronaut theme install failed — non-fatal."
log "SDDM astronaut theme install attempted."

# =============================================================================
# ── KVANTUM (Qt theme) ────────────────────────────────────────────────────────
# =============================================================================
section "Kvantum config"

mkdir -p "${USER_HOME}/.config/Kvantum"
printf '[General]\ntheme=catppuccin-frappe-mauve\n' \
    > "${USER_HOME}/.config/Kvantum/kvantum.kvconfig"
log "Kvantum theme set to catppuccin-frappe-mauve."

# =============================================================================
# ── XBPS CACHE CLEANUP ────────────────────────────────────────────────────────
# -O: remove cached package archive files (downloaded .xbps files)
# -o: remove orphaned packages (installed but no longer needed by anything)
# =============================================================================
section "XBPS cache cleanup"

xbps-remove -Oo || warn "xbps cache cleanup had non-fatal issues."
log "Package cache cleaned."

# =============================================================================
# ── FIX OWNERSHIP ─────────────────────────────────────────────────────────────
# =============================================================================
chown -R "${USERNAME}:${USERNAME}" "${USER_HOME}"

# =============================================================================
# ── XBPS RECONFIGURE ──────────────────────────────────────────────────────────
# Runs post-install hooks for all packages. Required after installing DKMS
# packages (nvidia) and firmware to ensure kernel modules are built.
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
echo -e "${BOLD}  NVIDIA PRIME offload:${NC}"
echo -e "   ${BOLD}prime-run <app>${NC}"
echo -e "   ${BOLD}__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia <app>${NC}"
echo ""
echo -e "${BOLD}  Verify GPU/audio:${NC}"
echo -e "   ${BOLD}vainfo${NC}            — AMD VA-API"
echo -e "   ${BOLD}nvidia-smi${NC}        — NVIDIA status"
echo -e "   ${BOLD}pw-cli info all${NC}   — PipeWire graph"
echo -e "   ${BOLD}pactl info${NC}        — PulseAudio compat"
echo ""
echo -e "${BOLD}  xbps quick ref:${NC}"
echo -e "   xbps-install -S <pkg>      — install"
echo -e "   xbps-remove -Rcon <pkg>    — remove + orphans"
echo -e "   xbps-query -Rs <term>      — search remote repos"
echo -e "   xbps-query -s <term>       — search installed"
echo -e "   xbps-install -Syu          — full system update"
echo ""
