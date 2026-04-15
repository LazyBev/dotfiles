#!/usr/bin/env bash
# void-sway-setup.sh (clean rewrite: runit + sway + pipewire + seatd)

set -euo pipefail

# ── Logging ────────────────────────────────────────────────────────────────
_log() { printf "[%-5s] %s\n" "$1" "$2"; }
info()  { _log "INFO" "$*"; }
warn()  { _log "WARN" "$*"; }
ok()    { _log "OK"   "$*"; }
step()  { echo -e "\n==> $*\n--------------------------------"; }
die()   { _log "FATAL" "$*"; exit 1; }

trap 'die "Error on line ${LINENO}: ${BASH_COMMAND}"' ERR
trap 'warn "Interrupted"; exit 130' INT TERM

# ── Args ───────────────────────────────────────────────────────────────────
USERNAME="${1:-}"
[[ -z "$USERNAME" ]] && die "Usage: $0 <username>"
[[ $EUID -ne 0 ]] && die "Run as root"

id "$USERNAME" &>/dev/null || die "User '$USERNAME' not found"
USER_HOME="/home/$USERNAME"

# ── Helpers ────────────────────────────────────────────────────────────────
enable_service() {
    local svc="$1"
    if [[ -d "/etc/sv/$svc" && ! -e "/var/service/$svc" ]]; then
        ln -s "/etc/sv/$svc" "/var/service/"
        ok "Enabled $svc"
    else
        info "$svc already enabled"
    fi
}

pkg_install() {
    xbps-install -y "$@"
}

pkg_if_missing() {
    for pkg in "$@"; do
        if ! xbps-query -Rs "^$pkg$" | grep -q "$pkg"; then
            pkg_install "$pkg"
        else
            info "$pkg already installed"
        fi
    done
}

# ── System update ───────────────────────────────────────────────────────────
step "Updating system"
xbps-install -Syu -y

# ── Repos ───────────────────────────────────────────────────────────────────
step "Enabling repositories"
pkg_install void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree
xbps-install -Syu -y

# ── Base system ─────────────────────────────────────────────────────────────
step "Installing base system"
pkg_install \
    git curl wget jq ripgrep fd bat fzf \
    neovim tmux btop \
    dbus elogind rtkit chrony opendoas \
    xdg-user-dirs xdg-utils linux-firmware

# ── Performance tuning ──────────────────────────────────────────────────────
step "Configuring performance"

pkg_install cpupower irqbalance

echo 'governor="performance"' > /etc/default/cpupower

enable_service cpupower
enable_service irqbalance

# Disk scheduler (safe generic)
for sched in /sys/block/*/queue/scheduler; do
    [[ -f "$sched" ]] && echo mq-deadline > "$sched" 2>/dev/null || true
done

ok "Performance tuning applied"

# ── Sway stack ──────────────────────────────────────────────────────────────
step "Installing Wayland stack"
pkg_install \
    sway swaylock swayidle swaybg \
    waybar foot fuzzel dunst \
    wl-clipboard grim slurp \
    xdg-desktop-portal-wlr \
    polkit polkit-gnome \
    seatd firefox dolphin \
    pipewire wireplumber alsa-utils pamixer pavucontrol \
    NetworkManager network-manager-applet xz unzip zip

# ── Fonts ───────────────────────────────────────────────────────────────────
step "Installing fonts"
pkg_install \
    noto-fonts-ttf noto-fonts-emoji \
    font-firacode font-awesome6 terminus-font \
    nerd-fonts-fira-code nerd-fonts-jetbrains-mono

setfont ter-v22n || true

# ── GPU (Nouveau safe config) ───────────────────────────────────────────────
step "Configuring Nouveau"

xbps-remove -Ry nvidia nvidia-dkms nvidia-libs 2>/dev/null || true

pkg_install mesa-dri mesa-vulkan-nouveau vulkan-loader || true

mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/nouveau.conf <<EOF
options nouveau config=NvPmEnableGating=1
EOF

dracut --force --regenerate-all

# ── doas ────────────────────────────────────────────────────────────────────
step "Configuring doas"
echo "permit persist :wheel" > /etc/doas.conf
chmod 0400 /etc/doas.conf

# ── Groups ──────────────────────────────────────────────────────────────────
step "Adding user to groups"
usermod -aG _seatd,input,video,audio,wheel,network "$USERNAME"

# ── Services ────────────────────────────────────────────────────────────────
step "Enabling services"

for svc in dbus elogind NetworkManager chronyd rtkit seatd; do
    enable_service "$svc"
done

# Remove conflicts
rm -f /var/service/dhcpcd 2>/dev/null || true
rm -f /var/service/wpa_supplicant 2>/dev/null || true

# ── XDG runtime ─────────────────────────────────────────────────────────────
step "Configuring XDG runtime"

pkg_install pam_rundir

grep -q pam_rundir.so /etc/pam.d/login || \
    echo 'session optional pam_rundir.so' >> /etc/pam.d/login

# ── Environment ─────────────────────────────────────────────────────────────
step "Setting user environment"

mkdir -p "$USER_HOME/.config/environment.d"

cat > "$USER_HOME/.config/environment.d/wayland.conf" <<EOF
XDG_CURRENT_DESKTOP=sway
XDG_SESSION_TYPE=wayland
MOZ_ENABLE_WAYLAND=1
EOF

chown -R "$USERNAME:$USERNAME" "$USER_HOME/.config"

# ── Sway session ────────────────────────────────────────────────────────────
step "Creating Sway session"

mkdir -p /usr/share/wayland-sessions

cat > /usr/share/wayland-sessions/sway.desktop <<EOF
[Desktop Entry]
Name=Sway
Exec=env WLR_RENDERER=gles2 sway
Type=Application
EOF

# ── Optional TTY autostart ──────────────────────────────────────────────────
step "Configuring TTY autostart"

cat > "$USER_HOME/.bash_profile" <<'EOF'
if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec sway
fi
EOF

chown "$USERNAME:$USERNAME" "$USER_HOME/.bash_profile"

# ── Final ───────────────────────────────────────────────────────────────────
echo "
========================================
 Setup complete

 User: $USERNAME
 WM:   Sway (TTY1 autostart enabled)
 GPU:  Nouveau (safe config)
 Audio: PipeWire
 Init: runit

 Reboot recommended.
========================================
"
