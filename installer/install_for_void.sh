#!/bin/bash
# void-sway-setup.sh (Bash-only + Nouveau GPU)

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/helper.sh"

_log() { printf "[%-5s] %s\n" "$1" "$2"; }
info()  { _log "INFO"  "$*"; }
warn()  { _log "WARN"  "$*"; }
skip()  { _log "SKIP"  "$*"; }
ok()    { _log "OK"    "$*"; }
die()   {
    _log "FATAL" "$*"
    echo
    echo "  The script failed at the step above."
    exit 1
}

trap 'echo; die "Unexpected error on line ${LINENO} — command: ${BASH_COMMAND}"' ERR
trap 'echo; warn "Script interrupted by user."; exit 130' INT TERM

USERNAME="${1:-}"
[[ -z "$USERNAME" ]] && { echo "Usage: $0 <username>"; exit 1; }
[[ $EUID -ne 0 ]] && { echo "Run as root."; exit 1; }

USER_HOME="/home/$USERNAME"

info "Fixing ownership of $USER_HOME..."
chown -R "$USERNAME:$USERNAME" "$USER_HOME"

# ── System update ────────────────────────────────────────────────────────────
xbps-install -Syu

# ── Repos ───────────────────────────────────────────────────────────────────
xbps-install -y void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree
xbps-install -Sy

# ── Base deps ───────────────────────────────────────────────────────────────
xbps-install -y git ripgrep xtools bash

# ── void-packages ────────────────────────────────────────────────────────────
VOID_PKGS="$USER_HOME/.void-packages"
if [[ ! -d "$VOID_PKGS" ]]; then
  sudo -u "$USERNAME" git clone https://github.com/void-linux/void-packages.git "$VOID_PKGS"
fi

# ── Bash config ─────────────────────────────────────────────────────────────
sudo -u "$USERNAME" bash -c \
  "grep -q XBPS_DISTDIR ~/.bashrc 2>/dev/null || echo 'export XBPS_DISTDIR=\$HOME/.void-packages' >> ~/.bashrc"

# ── vpsm ────────────────────────────────────────────────────────────────────
sudo -u "$USERNAME" bash -c '
  git clone https://github.com/sinetoami/vpsm.git ~/vpsm 2>/dev/null || true
  mkdir -p ~/.bin
  ln -sf ~/vpsm/vpsm ~/.bin/vpsm
  grep -q "\.bin" ~/.bashrc 2>/dev/null || echo "export PATH=\$PATH:\$HOME/.bin" >> ~/.bashrc
'

# ── Sway stack ──────────────────────────────────────────────────────────────
xbps-install -y \
  sway swaylock swayidle swaybg \
  Waybar foot fuzzel dunst \
  wl-clipboard grim slurp \
  xdg-desktop-portal-wlr xdg-utils \
  polkit polkit-gnome pam_rundir \
  dbus elogind rtkit chrony

# ── Fonts ───────────────────────────────────────────────────────────────────
xbps-install -y \
  noto-fonts-ttf noto-fonts-emoji \
  font-firacode font-awesome6 terminus-font

setfont ter-122n

# ── Audio ───────────────────────────────────────────────────────────────────
xbps-install -y pipewire wireplumber alsa-utils pamixer pavucontrol

# ── Network ─────────────────────────────────────────────────────────────────
xbps-install -y NetworkManager network-manager-applet

# ── CLI tools ───────────────────────────────────────────────────────────────
xbps-install -y git curl wget jq ripgrep fd bat fzf neovim tmux btop

# ── Default shell ───────────────────────────────────────────────────────────
chsh -s /bin/bash "$USERNAME"

# ── doas ────────────────────────────────────────────────────────────────────
xbps-install -y opendoas
cat > /etc/doas.conf <<EOF
permit persist $USERNAME as root
EOF
chmod 0400 /etc/doas.conf

# ── GPU (Nouveau) ───────────────────────────────────────────────────────────
# Remove proprietary NVIDIA drivers if present
xbps-remove -Ry nvidia nvidia-libs nvidia-libs-32bit nvidia-dkms 2>/dev/null || true

# Install open-source stack
xbps-install -y mesa-dri mesa-vulkan-nouveau vulkan-loader

# Remove NVIDIA configs
rm -f /etc/dracut.conf.d/nvidia.conf
rm -f /etc/modprobe.d/nvidia.conf

# Ensure nouveau is not blacklisted
sed -i '/blacklist nouveau/d' /etc/modprobe.d/* 2>/dev/null || true

# Rebuild initramfs
dracut --force --regenerate-all

# ── GRUB cleanup ────────────────────────────────────────────────────────────
GRUB_CFG=/etc/default/grub
if grep -q 'GRUB_CMDLINE_LINUX_DEFAULT' "$GRUB_CFG"; then
  sed -i 's/nvidia-drm.modeset=1//g' "$GRUB_CFG"
  sed -i 's/rd.driver.blacklist=nouveau//g' "$GRUB_CFG"
fi
grub-mkconfig -o /boot/grub/grub.cfg

# ── Display manager ─────────────────────────────────────────────────────────
xbps-install -y sddm
ln -sf /etc/sv/sddm /var/service/ 2>/dev/null || true

# ── Services ────────────────────────────────────────────────────────────────
for svc in dbus elogind NetworkManager chronyd rtkit; do
  ln -sf /etc/sv/$svc /var/service/ 2>/dev/null || true
done

# ── User dirs ───────────────────────────────────────────────────────────────
sudo -u "$USERNAME" xdg-user-dirs-update 2>/dev/null || true

# ── Sway config ─────────────────────────────────────────────────────────────
SWAY_CFG="$USER_HOME/.config/sway/config"
if [[ ! -f "$SWAY_CFG" ]]; then
  mkdir -p "$(dirname "$SWAY_CFG")"
  cp /etc/sway/config "$SWAY_CFG"
  chown "$USERNAME:$USERNAME" "$SWAY_CFG"
fi

# ── PipeWire autostart ──────────────────────────────────────────────────────
if ! grep -q "wireplumber" "$SWAY_CFG"; then
  cat >> "$SWAY_CFG" <<'EOF'

exec dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP=sway
exec /usr/bin/pipewire
exec /usr/bin/pipewire-pulse
exec /usr/bin/wireplumber
exec /usr/libexec/polkit-gnome-authentication-agent-1
EOF
  chown "$USERNAME:$USERNAME" "$SWAY_CFG"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
cat <<EOF

════════════════════════════════════════════
 Done! Log in as $USERNAME and run:

   sway

 GPU driver: Nouveau (open-source)
════════════════════════════════════════════
EOF
