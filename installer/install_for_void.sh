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
# [FIX] Moved here from the runit section so it's available to SSD TRIM and any
#       other section that needs it before the runit block runs.
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
# Per Handbook: nonfree is a separate repo package. Install it first so
# NVIDIA drivers and other nonfree packages are available in the same run.
# void-repo-multilib adds 32-bit glibc packages (Steam, Wine, nvidia-32bit).
# =============================================================================
section "Repositories (nonfree + multilib)"

xbps-install -Sy void-repo-nonfree void-repo-multilib \
    || warn "Repo packages may already be installed — continuing."

# [FIX] xbps-install -Sy with no package arguments is a no-op on current xbps.
#       -S (sync indexes only) is the correct flag for a metadata-only refresh.
xbps-install -S
log "Nonfree + multilib repos enabled and indexes synced."

# =============================================================================
# ── XBPS SELF-UPDATE + FULL SYSTEM UPDATE ────────────────────────────────────
# Per Handbook: always update xbps itself first — older xbps may not handle
# newer package metadata correctly.
# =============================================================================
section "xbps self-update + full system update"

xbps-install -Syu xbps || error "xbps self-update failed."
xbps-install -Syu       || warn "System update had non-fatal warnings."
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

# mesa-vdpau is a separate subpackage — split out so a failure doesn't abort
# the whole AMD stack (may not be available on all repo states).
xbps-install -y mesa-vdpau \
    || warn "mesa-vdpau failed — non-fatal, VDPAU decode unavailable."
log "AMD/Mesa stack installed."

# =============================================================================
# ── GPU — NVIDIA proprietary (discrete dGPU, PRIME offload) ──────────────────
# Per Handbook (graphics-drivers/nvidia):
#   - Cards 800+    → 'nvidia' package (DKMS — requires linux-headers)
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
#
# [HARDENING] linux-headers added: the 'nvidia' package is DKMS-based. Without
#             kernel headers present, the DKMS build during xbps-reconfigure
#             fails silently and no nvidia.ko is produced.
# =============================================================================
section "GPU — NVIDIA proprietary (dGPU, PRIME offload)"

xbps-install -y linux-headers \
    || warn "linux-headers install failed — NVIDIA DKMS build may fail."

xbps-install -y nvidia nvidia-libs \
    || error "NVIDIA install failed."

# 32-bit NVIDIA compat — requires void-repo-multilib; non-fatal if unavailable
xbps-install -y nvidia-libs-32bit \
    || warn "nvidia-libs-32bit not found — non-fatal, 32-bit NVIDIA compat unavailable."

mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/nvidia.conf << 'EOF'
# Enable KMS (required for Wayland) and fbdev console on NVIDIA GPU.
options nvidia_drm modeset=1 fbdev=1
EOF

# [FIX] /etc/modules-load.d/ is a systemd convention and is NOT processed by
#       Void's runit boot. Void reads /etc/modules-load on boot via the
#       kernel-modules runit service. Write to both locations for maximum compat.
mkdir -p /etc/modules-load.d
cat > /etc/modules-load.d/nvidia.conf << 'EOF'
nvidia
nvidia_modeset
nvidia_uvm
nvidia_drm
EOF

# Void runit native location (processed by /etc/sv/kernel-modules if enabled)
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
#   xorg-server-xwayland: XWayland compatibility server. The system is fully
#     Wayland-native (SDDM greeter, niri compositor, all env vars set). XWayland
#     runs as a nested X server inside the Wayland session only when an X11 app
#     requests it — it does not make the session "X11". Without it, legacy X11
#     apps (some games, older Electron builds, etc.) fail to start at all.
#   xwayland-satellite: rootless XWayland for niri (handles X11 app windows as
#     native Wayland surfaces, enabling proper tiling of X11 apps).
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
# dunst: notification daemon (D-Bus org.freedesktop.Notifications)
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
# Per Handbook (graphical-session/kde): SDDM requires the dbus service to be
# enabled. Enable dbus before enabling sddm.
#
# DisplayServer=x11 (greeter only): As of SDDM 0.20, the greeter itself runs on
# X11 by default. A Wayland greeter exists but is experimental and not packaged
# separately in Void — 'sddm-wayland-plasma' does not exist in the Void repos.
# This does NOT affect the session: SDDM launches niri-session which runs fully
# native Wayland. The X11 greeter exits completely once the session starts.
# The full Wayland stack is: SDDM greeter (X11, temporary) → niri (Wayland,
# native GBM/KMS) → all apps on Wayland → XWayland nested for X11 app compat.
#
# xorg-minimal is required by SDDM's X11 greeter (it needs an Xorg server to
# render the login screen). It is not used by niri or any app in the session.
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
# Per Handbook (config/media/pipewire):
#  1. Install 'pipewire' — wireplumber is the session manager.
#  2. Link 10-wireplumber.conf — tells PipeWire to load wireplumber.
#  3. Link 20-pipewire-pulse.conf — PulseAudio compat interface.
#  4. alsa-pipewire + conf.d symlinks — makes PipeWire the default ALSA device.
#  5. PipeWire MUST run as the logged-in user (not as a system service).
#     Per Handbook: launch it from the compositor startup script.
#  6. Requires an active D-Bus user session bus + XDG_RUNTIME_DIR.
#     elogind provides XDG_RUNTIME_DIR; SDDM + elogind provides the session bus.
#  7. rtkit (installed in core packages) provides realtime scheduling.
#
# [FIX] Path existence checks added before symlinking. The example conf paths
#       vary across Void package versions. Broken symlinks cause pipewire to
#       fail silently at startup.
#
# [FIX] pipewire-pulse and wireplumber are now started explicitly as separate
#       processes from niri-session. The conf.d symlinks alone are not sufficient
#       on Void — wireplumber and pipewire-pulse must each be exec'd by the user
#       session alongside the main pipewire process.
# =============================================================================
section "PipeWire + WirePlumber"

xbps-install -y \
    pipewire \
    wireplumber \
    alsa-pipewire \
    pavucontrol \
    pulseaudio-utils \
    || error "PipeWire install failed."

# System-wide PipeWire config — symlink example configs with path validation
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

# wireplumber conf — try both known Void paths
_pw_symlink \
    /usr/share/pipewire/pipewire.conf.d/10-wireplumber.conf \
    /etc/pipewire/pipewire.conf.d/10-wireplumber.conf
# Fallback path seen on some Void installs
if [[ ! -L /etc/pipewire/pipewire.conf.d/10-wireplumber.conf ]]; then
    _pw_symlink \
        /usr/share/examples/wireplumber/10-wireplumber.conf \
        /etc/pipewire/pipewire.conf.d/10-wireplumber.conf
fi

# pipewire-pulse conf
_pw_symlink \
    /usr/share/pipewire/pipewire.conf.d/20-pipewire-pulse.conf \
    /etc/pipewire/pipewire.conf.d/20-pipewire-pulse.conf
if [[ ! -L /etc/pipewire/pipewire.conf.d/20-pipewire-pulse.conf ]]; then
    _pw_symlink \
        /usr/share/examples/pipewire/20-pipewire-pulse.conf \
        /etc/pipewire/pipewire.conf.d/20-pipewire-pulse.conf
fi

# Make PipeWire the default ALSA output device
mkdir -p /etc/alsa/conf.d
_pw_symlink \
    /usr/share/alsa/alsa.conf.d/50-pipewire.conf \
    /etc/alsa/conf.d/50-pipewire.conf
_pw_symlink \
    /usr/share/alsa/alsa.conf.d/99-pipewire-default.conf \
    /etc/alsa/conf.d/99-pipewire-default.conf

log "PipeWire + WirePlumber configured."
log "  PipeWire, WirePlumber, pipewire-pulse launched per-user from niri-session."

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
#   Enabling: ln -sf /etc/sv/<n> /var/service/<n>
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
#   sddm         — display manager; must be enabled last (depends on dbus)
#
# NOT enabled as system services:
#   pipewire    — per Handbook must run as the current user, not as root/system
#   wireplumber — same: per-user, launched from niri-session
#   acpid       — per Handbook: do NOT use with elogind (conflicts)
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
_sv_enable sddm   # enable last; depends on dbus

log "runit services enabled."
log "  pipewire/wireplumber — NOT system services (run per-user from niri-session)"
log "  acpid               — NOT enabled (conflicts with elogind per Handbook)"

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
#
# Per Handbook (session-management): SDDM + elogind provides XDG_RUNTIME_DIR
# and the D-Bus session bus at login. dbus-run-session is not needed.
#
# LIBSEAT_BACKEND=logind: prevents "seatd not present" warnings from libseat
# when elogind is in use (the correct backend here is logind, not seatd).
#
# [FIX] --systemd removed from dbus-update-activation-environment.
#       The --systemd flag exports vars to systemd's user manager (sd-bus),
#       which does not exist on Void/runit. Passing it caused a silent failure
#       that left the D-Bus activation environment incomplete, preventing
#       PipeWire from connecting to the session bus on startup.
#
# [FIX] PipeWire now starts with a sleep 2 delay to allow elogind to fully
#       establish XDG_RUNTIME_DIR and the D-Bus session bus before PipeWire
#       tries to acquire the org.freedesktop.ReserveDevice1 name. Without this
#       delay, PipeWire races the bus and produces the lockfile/DISPLAY errors
#       seen in the screenshot.
#
# [FIX] wireplumber and pipewire-pulse started explicitly as separate processes.
#       The conf.d symlinks instruct pipewire to *attempt* to load them as
#       modules, but on Void the module path may not match the examples path,
#       causing silent failures. Running them as sibling processes is the
#       correct, reliable approach on non-systemd systems.
#
# [HARDENING] Stale PipeWire lockfile cleanup on session start. A previous
#             crashed session leaves /run/user/$UID/pipewire-0.lock behind,
#             blocking the next pipewire instance with "Resource temporarily
#             unavailable". Clean it at session start.
# =============================================================================
section "niri session wrapper"

cat > /usr/local/bin/niri-session << 'EOF'
#!/usr/bin/env bash
# niri session launcher — Void Linux / runit / elogind
# Starts PipeWire stack as current user, then execs niri.
set -a
# shellcheck source=/etc/profile
source /etc/profile
set +a

# Tell libseat to use elogind (prevents "seatd not found" noise)
export LIBSEAT_BACKEND=logind

# [FIX] keyboard intermittent: wait for udev to finish device scanning before
# niri initialises libinput. Without this, niri races elogind's seat activation
# and input devices are missing or unresponsive on some boots. udevadm settle
# blocks until udev has finished processing all pending events.
udevadm settle 2>/dev/null || true

# Export Wayland display vars into D-Bus activation environment.
# NOTE: --systemd flag intentionally omitted — systemd user manager does not
# exist on Void/runit. The flag causes silent failure and a broken activation env.
if command -v dbus-update-activation-environment &>/dev/null; then
    dbus-update-activation-environment \
        WAYLAND_DISPLAY XDG_CURRENT_DESKTOP XDG_SESSION_TYPE 2>/dev/null || true
fi

# Clean up any stale PipeWire lockfile from a previously crashed session.
# Without this, pipewire fails with "Resource temporarily unavailable" on the
# lockfile and refuses to start.
PIPEWIRE_LOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pipewire-0.lock"
if [[ -f "$PIPEWIRE_LOCK" ]]; then
    rm -f "$PIPEWIRE_LOCK"
fi

# Start PipeWire stack after a brief delay to allow the D-Bus session bus and
# XDG_RUNTIME_DIR (provided by elogind) to be fully ready.
# All three processes are background siblings; they're cleaned up on EXIT.
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
# ── NIRI CONFIG SNIPPETS (NVIDIA render device + keyboard fix) ────────────────
# niri config.kdl changes needed for:
#
#  1. NVIDIA as render device:
#     niri picks the first render node it finds. On AMD+NVIDIA hybrid systems
#     this is usually renderD128 (AMD iGPU). To force NVIDIA, set render-device
#     to the NVIDIA PCI path under /dev/dri/by-path/. This makes niri render
#     via NVIDIA GBM directly.
#     Ref: https://github.com/niri-wm/niri/wiki/Getting-Started#nvidia
#
#  2. Keyboard intermittent:
#     If the xkb block in config.kdl is empty, niri queries
#     org.freedesktop.locale1 (systemd-localed) over D-Bus for the layout.
#     That service does not exist on Void/runit. The query fails silently and
#     niri may start with no keymap, causing intermittent keyboard behaviour.
#     Fix: explicitly set layout "us" (or your layout) in the xkb block.
#
#  3. fuzzel not launching:
#     fuzzel launched via spawn-at-startup races xdg-desktop-portal startup
#     and exits silently if the portal isn't ready. Use a keybind instead.
#     fuzzel should NOT be in spawn-at-startup.
#
# Writes a snippet file the user merges into ~/.config/niri/config.kdl.
# config.kdl is user-owned (managed by dotfiles) so we don't edit it directly.
# =============================================================================
section "niri config snippets (NVIDIA render device + keyboard fix)"

# Detect NVIDIA render device PCI path at install time (best-effort)
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

// [1] NVIDIA render device — forces niri compositor to render via NVIDIA GBM.
// If the path below is wrong, run: ls -l /dev/dri/by-path/
// then cross-reference with: lspci | grep -i nvidia
render-device "${NVIDIA_RENDER_PATH:-/dev/dri/by-path/pci-REPLACE_ME-render}"

// [2] Keyboard fix — explicit layout prevents niri querying systemd-localed
// (which doesn't exist on Void/runit), fixing intermittent keyboard issues.
input {
    keyboard {
        xkb {
            layout "us"
            // Change "us" to your actual layout e.g. "gb", "de", "fr"
            // Uncomment to add a compose key:
            // options "compose:ralt"
        }
    }
}

// [3] dunst — must be spawned at startup (notification daemon)
// Add at the top level of config.kdl (not inside any block):
spawn-at-startup "dunst"

// [4] fuzzel — use a keybind ONLY, do NOT use spawn-at-startup.
// fuzzel races xdg-desktop-portal on startup and exits silently if the
// portal isn't ready yet. A keybind fires on demand and always works.
// Add inside your binds { } block:
// binds {
//     Mod+D { spawn "fuzzel"; }
// }
KDLEOF

chown "${USERNAME}:${USERNAME}" "$SNIPPET_FILE"

if [[ -n "$NVIDIA_RENDER_PATH" ]]; then
    log "NVIDIA render device detected: ${NVIDIA_RENDER_PATH}"
else
    warn "Could not auto-detect NVIDIA render device (lspci may not be ready yet)."
    warn "  After boot: ls -l /dev/dri/by-path/ and: lspci | grep -i nvidia"
    warn "  Then update render-device in: ${SNIPPET_FILE}"
fi
log "niri config snippet → ${SNIPPET_FILE}"
log "  Merge into ~/.config/niri/config.kdl before first login."

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
# Note: _sv_enable is defined at the top of this script.
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
# gsettings requires a running D-Bus session + display — can't run as root.
# Install a first-boot XDG autostart .desktop file to apply on first login.
#
# [FIX] Original wrote a bare .sh file to ~/.config/autostart/. Niri does not
#       natively execute files from that directory — it is an XDG autostart
#       convention that requires an XDG-compliant session manager or portal.
#       Converted to a proper .desktop file which xdg-autostart-service (if
#       installed) and GNOME-compatible portals can process. The .sh is still
#       the payload; the .desktop wraps it correctly.
# =============================================================================
section "GTK theme"

if [[ -d "${USER_HOME}/dotfiles/configs/diinki-retro-dark" ]]; then
    cp -r "${USER_HOME}/dotfiles/configs/diinki-retro-dark" /usr/share/themes/
    log "GTK theme diinki-retro-dark → /usr/share/themes/."
else
    warn "diinki-retro-dark not found in dotfiles — skipping GTK theme install."
fi

mkdir -p "${USER_HOME}/.config/autostart"

# The payload script: applies the theme, then self-deletes
cat > "${USER_HOME}/.config/autostart/apply-gtk-theme.sh" << 'GTKEOF'
#!/usr/bin/env bash
gsettings set org.gnome.desktop.interface gtk-theme "diinki-retro-dark"
gsettings set org.gnome.desktop.interface color-scheme "prefer-dark"
rm -- "${USER_HOME}/.config/autostart/apply-gtk-theme.sh"
rm -- "${USER_HOME}/.config/autostart/apply-gtk-theme.desktop"
GTKEOF
chmod +x "${USER_HOME}/.config/autostart/apply-gtk-theme.sh"

# XDG autostart .desktop file so the script runs on first graphical login
cat > "${USER_HOME}/.config/autostart/apply-gtk-theme.desktop" << DTEOF
[Desktop Entry]
Type=Application
Name=Apply GTK Theme
Exec=${USER_HOME}/.config/autostart/apply-gtk-theme.sh
X-GNOME-Autostart-enabled=true
OnlyShowIn=niri;
DTEOF

log "GTK autostart theme .desktop written — applies on first login then self-deletes."
log "  Note: requires xdg-autostart-service or similar to execute on niri."
log "  Alternatively, add 'spawn-at-startup \"${USER_HOME}/.config/autostart/apply-gtk-theme.sh\"'"
log "  to ~/.config/niri/config.kdl for one-time execution (then remove the line)."

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
# ── FIX OWNERSHIP ─────────────────────────────────────────────────────────────
# [FIX] Moved to after ALL user-home writes (dotfiles, GTK autostart, Kvantum)
#       so the single chown pass catches everything written to $USER_HOME.
#       In the original, files written after the chown were left root-owned.
# =============================================================================
section "Fixing ownership of ${USER_HOME}"

chown -R "${USERNAME}:${USERNAME}" "${USER_HOME}"
log "Ownership of ${USER_HOME} fixed → ${USERNAME}:${USERNAME}"

# =============================================================================
# ── XBPS CACHE CLEANUP ────────────────────────────────────────────────────────
# -O: remove cached package archive files (downloaded .xbps files).
#
# [FIX] Removed -o (orphan removal) from default run. xbps considers a package
#       "orphaned" if nothing in the dependency tree explicitly requires it,
#       which catches many intentionally-installed leaf packages (terminal apps,
#       fonts, CLI tools, etc.) and silently removes them. -O alone is safe.
#       To remove orphans intentionally: xbps-remove -Rcon (interactive review).
# =============================================================================
section "XBPS cache cleanup"

xbps-remove -O || warn "xbps cache cleanup had non-fatal issues."
log "Package download cache cleaned."
log "  Orphan removal skipped — run 'xbps-remove -Rcon' manually to review orphans."

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
echo -e "${BOLD}  PipeWire troubleshooting:${NC}"
echo -e "   Stale lockfile:  ${BOLD}rm -f \${XDG_RUNTIME_DIR}/pipewire-0.lock${NC}"
echo -e "   Check services:  ${BOLD}pw-cli info all${NC}"
echo -e "   Check WirePlumber: ${BOLD}wpctl status${NC}"
echo ""
echo -e "${BOLD}  NVIDIA PRIME offload:${NC}"
echo -e "   ${BOLD}prime-run <app>${NC}"
echo -e "   ${BOLD}__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia <app>${NC}"
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
