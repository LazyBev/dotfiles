#!/usr/bin/env bash
# =============================================================================
# Void Linux — Post-install setup
# Run this after void-installer and first boot into your new system.
#
# What this does:
#   • Updates xbps + system
#   • Installs GPU drivers (AMD mesa + NVIDIA proprietary)
#   • Installs Wayland, niri, SDDM, PipeWire, Ghostty, fonts
#   • Configures services, environment, niri session wrapper
#   • Copies dotfiles if present at ~/dotfiles/configs
#
# Usage (as root or sudo):
#   bash void-post-install.sh
#
# Log: /tmp/void-post-install.log
# =============================================================================
set -eo pipefail
IFS=$'\n\t'

# =============================================================================
# ── EDIT THESE ────────────────────────────────────────────────────────────────
# =============================================================================
USERNAME="yari"
REPO_NONFREE="https://repo-default.voidlinux.org/current/nonfree"

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
# Pre-flight
# =============================================================================
section "Pre-flight checks"

[[ $EUID -ne 0 ]] && error "Must run as root (or with sudo)."

for t in xbps-install xbps-reconfigure ln sed; do
    command -v "$t" &>/dev/null || error "Missing tool: $t"
done

# Network check
NET_OK=0
for host in 8.8.8.8 1.1.1.1 repo-default.voidlinux.org; do
    if ping -c2 -W2 "$host" &>/dev/null; then
        log "Network OK (reachable: $host)"; NET_OK=1; break
    fi
done
[[ "$NET_OK" -eq 1 ]] || error "No internet connection."

log "Pre-flight OK (user: ${USERNAME})"

# =============================================================================
# Nonfree repo
# =============================================================================
section "Nonfree repo"

mkdir -p /etc/xbps.d
if ! grep -q "nonfree" /etc/xbps.d/*.conf 2>/dev/null; then
    echo "repository=${REPO_NONFREE}" > /etc/xbps.d/10-nonfree.conf
    log "Nonfree repo configured."
else
    log "Nonfree repo already present."
fi

# =============================================================================
# Update xbps + system
# =============================================================================
section "Updating xbps and base system"

xbps-install -Syu xbps  || error "xbps self-update failed."
xbps-install -Syu        || warn "System update had non-fatal issues."
log "System up to date."

# =============================================================================
# Firmware
# =============================================================================
section "Firmware"

xbps-install -y linux-firmware linux-firmware-amd sof-firmware \
    || warn "Some firmware packages failed — non-fatal."
log "Firmware installed."

# =============================================================================
# GPU — hybrid AMD (primary) + NVIDIA (discrete, proprietary)
# =============================================================================
section "GPU — AMD/Mesa + NVIDIA proprietary"

log "Installing AMD/Mesa stack..."
xbps-install -y \
    mesa-dri \
    mesa-vulkan-radeon \
    mesa-vaapi \
    vulkan-loader \
    libva-utils \
    || error "AMD/Mesa install failed."
log "AMD/Mesa installed."

log "Installing NVIDIA proprietary drivers..."
xbps-install -y nvidia nvidia-libs || error "NVIDIA install failed."

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

log "NVIDIA installed."
log "  KMS: nvidia_drm modeset=1 fbdev=1"
log "  PRIME offload: __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia <app>"

# =============================================================================
# Core packages
# =============================================================================
section "Core packages"

xbps-install -y \
    sudo \
    bash-completion \
    NetworkManager \
    dbus \
    elogind \
    polkit \
    eudev \
    pciutils \
    usbutils \
    dosfstools \
    e2fsprogs \
    chrony \
    curl \
    wget \
    git \
    neovim \
    cronie \
    || error "Core package install failed."
log "Core packages installed."

# =============================================================================
# Wayland base
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
# niri WM + tools
# =============================================================================
section "niri window manager + tools"

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
    xcb-util-cursor \
    || error "niri/tools install failed."
log "niri and companion tools installed."

# =============================================================================
# SDDM
# =============================================================================
section "SDDM display manager"

xbps-install -y sddm || error "SDDM install failed."

mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/general.conf << 'EOF'
[General]
DisplayServer=x11

[Theme]
Current=

[Users]
# AutoUser=YOUR_USERNAME
# Relogin=true
EOF
log "SDDM installed."

# =============================================================================
# PipeWire + WirePlumber
# =============================================================================
section "PipeWire + WirePlumber"

xbps-install -y pipewire alsa-pipewire pavucontrol \
    || error "PipeWire install failed."

mkdir -p /etc/pipewire/pipewire.conf.d
ln -sf /usr/share/examples/wireplumber/10-wireplumber.conf \
       /etc/pipewire/pipewire.conf.d/10-wireplumber.conf
ln -sf /usr/share/examples/pipewire/20-pipewire-pulse.conf \
       /etc/pipewire/pipewire.conf.d/20-pipewire-pulse.conf

mkdir -p /etc/alsa/conf.d
ln -sf /usr/share/alsa/alsa.conf.d/50-pipewire.conf \
       /etc/alsa/conf.d/50-pipewire.conf
ln -sf /usr/share/alsa/alsa.conf.d/99-pipewire-default.conf \
       /etc/alsa/conf.d/99-pipewire-default.conf

log "PipeWire installed and configured."

# =============================================================================
# Ghostty terminal
# =============================================================================
section "Ghostty terminal"
xbps-install -y ghostty || error "ghostty install failed."
log "Ghostty installed."

# =============================================================================
# Fonts
# =============================================================================
section "Fonts"
xbps-install -y \
    noto-fonts-ttf \
    noto-fonts-emoji \
    font-firacode-nerd \
    || warn "Some fonts failed — non-fatal."
log "Fonts installed."

# =============================================================================
# runit services
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
_sv_enable NetworkManager
_sv_enable sshd
_sv_enable cronie
_sv_enable chronyd
_sv_enable udevd
_sv_enable sddm

log "runit services enabled."

# =============================================================================
# System-wide environment (Wayland + hybrid GPU)
# =============================================================================
section "System-wide environment"

cat > /etc/profile.d/90-wayland.sh << 'EOF'
export XDG_SESSION_TYPE=wayland
export QT_QPA_PLATFORM=wayland;xcb
export QT_WAYLAND_DISABLE_WINDOWDECORATION=1
export GDK_BACKEND=wayland,x11
export SDL_VIDEODRIVER=wayland
export MOZ_ENABLE_WAYLAND=1
export ELECTRON_OZONE_PLATFORM_HINT=wayland
EOF

cat > /etc/profile.d/91-hybrid-gpu.sh << 'EOF'
export LIBVA_DRIVER_NAME=radeonsi
# PRIME offload: __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia <app>
EOF

chmod +x /etc/profile.d/90-wayland.sh /etc/profile.d/91-hybrid-gpu.sh
log "Environment scripts written to /etc/profile.d/."

# =============================================================================
# niri session wrapper
# =============================================================================
section "niri session wrapper"

cat > /usr/local/bin/niri-session << 'EOF'
#!/usr/bin/env bash
set -a
source /etc/profile
set +a

pipewire &
PIPEWIRE_PID=$!
trap "kill $PIPEWIRE_PID 2>/dev/null; wait $PIPEWIRE_PID 2>/dev/null" EXIT

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

log "niri-session wrapper and .desktop entry written."

# =============================================================================
# swaylock PAM config
# =============================================================================
if [[ ! -f /etc/pam.d/swaylock ]]; then
    cat > /etc/pam.d/swaylock << 'EOF'
auth      include   system-local-login
account   include   system-local-login
EOF
    log "swaylock PAM config written."
else
    log "swaylock PAM config already present."
fi

# =============================================================================
# Dotfiles
# =============================================================================
section "Dotfiles"

DOTFILES_SRC="/home/${USERNAME}/dotfiles/configs"
DOTFILES_DST="/home/${USERNAME}/.config"

if [[ -d "$DOTFILES_SRC" ]]; then
    mkdir -p "$DOTFILES_DST"
    cp -r "$DOTFILES_SRC"/. "$DOTFILES_DST"/
    if [[ -d "${DOTFILES_DST}/Pictures" ]]; then
        mkdir -p "/home/${USERNAME}/Pictures"
        mv "${DOTFILES_DST}/Pictures/." "/home/${USERNAME}/Pictures/"
        rm -rf "${DOTFILES_DST}/Pictures"
    fi
    chown -R "${USERNAME}:${USERNAME}" "$DOTFILES_DST"
    log "Dotfiles copied to ${DOTFILES_DST}"
else
    warn "No dotfiles found at ${DOTFILES_SRC} — skipping."
fi

# =============================================================================
# Fix ownership
# =============================================================================
chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}"

# =============================================================================
# Reconfigure all packages
# =============================================================================
section "Finalising (xbps-reconfigure -fa)"
xbps-reconfigure -fa || warn "xbps-reconfigure had non-fatal issues."
log "All packages reconfigured."

# =============================================================================
# Done
# =============================================================================
echo ""
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Post-install complete!${NC}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Log: ${BOLD}${LOG_FILE}${NC}"
echo ""
echo -e "  Next steps:"
echo -e "   1. ${BOLD}reboot${NC}"
echo -e "   2. SDDM will start — select the ${BOLD}niri${NC} session"
echo -e "   3. PRIME offload: ${BOLD}__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia <app>${NC}"
echo ""
