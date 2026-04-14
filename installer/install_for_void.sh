#!/bin/bash
# void-sway-setup.sh (runit + bash + nouveau + pipewire)

set -euo pipefail

# ── Config ──────────────────────────────────────────────────────────────────
USERNAME="${1:-}"
[[ -z "$USERNAME" ]] && { echo "Usage: $0 <username>"; exit 1; }
[[ $EUID -ne 0 ]] && { echo "Run as root."; exit 1; }

USER_HOME="/home/$USERNAME"

# ── Logging ─────────────────────────────────────────────────────────────────
log() { printf "[%-5s] %s\n" "$1" "$2"; }
info(){ log INFO "$*"; }
warn(){ log WARN "$*"; }
ok(){ log OK "$*"; }
die(){ log FATAL "$*"; exit 1; }

trap 'die "Error on line $LINENO: $BASH_COMMAND"' ERR

# ── Fix ownership ───────────────────────────────────────────────────────────
info "Fixing ownership..."
chown -R "$USERNAME:$USERNAME" "$USER_HOME"

# ── Update system ───────────────────────────────────────────────────────────
info "Updating system..."
xbps-install -Syu

# ── Enable repos ────────────────────────────────────────────────────────────
xbps-install -y void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree
xbps-install -Sy

# ── Base tools ──────────────────────────────────────────────────────────────
xbps-install -y git bash curl wget

# ── void-packages ───────────────────────────────────────────────────────────
VOID_PKGS="$USER_HOME/.void-packages"
if [[ ! -d "$VOID_PKGS" ]]; then
  sudo -u "$USERNAME" git clone https://github.com/void-linux/void-packages.git "$VOID_PKGS"
fi

# ── Bash config ─────────────────────────────────────────────────────────────
sudo -u "$USERNAME" bash -c \
'grep -q XBPS_DISTDIR ~/.bashrc 2>/dev/null || \
 echo "export XBPS_DISTDIR=\$HOME/.void-packages" >> ~/.bashrc'

# ── vpsm ────────────────────────────────────────────────────────────────────
sudo -u "$USERNAME" bash -c '
git clone https://github.com/sinetoami/vpsm.git ~/vpsm 2>/dev/null || true
mkdir -p ~/.bin
ln -sf ~/vpsm/vpsm ~/.bin/vpsm
grep -q "\.bin" ~/.bashrc 2>/dev/null || \
 echo "export PATH=\$PATH:\$HOME/.bin" >> ~/.bashrc
'

# ── Sway stack ──────────────────────────────────────────────────────────────
xbps-install -y \
  sway swaylock swayidle swaybg \
  Waybar foot fuzzel dunst \
  wl-clipboard grim slurp \
  xdg-desktop-portal-wlr xdg-utils \
  polkit polkit-gnome \
  dbus elogind rtkit chrony fcitx5 fcitx5-anthy

# ── Fonts ───────────────────────────────────────────────────────────────────
xbps-install -y \
  noto-fonts-ttf noto-fonts-emoji \
  font-firacode font-awesome6 terminus-font

setfont ter-122n || true

# ── Audio (PipeWire - runit safe) ───────────────────────────────────────────
xbps-install -y \
  pipewire wireplumber \
  alsa-utils pamixer pavucontrol

usermod -aG audio,video "$USERNAME"
ln -sf /etc/sv/rtkit /var/service/ 2>/dev/null || true

# ── Network ─────────────────────────────────────────────────────────────────
xbps-install -y NetworkManager network-manager-applet

# ── CLI tools ───────────────────────────────────────────────────────────────
xbps-install -y \
  git curl wget jq ripgrep fd bat fzf \
  neovim tmux btop

# ── Shell ───────────────────────────────────────────────────────────────────
chsh -s /bin/bash "$USERNAME"

# ── doas ────────────────────────────────────────────────────────────────────
xbps-install -y opendoas
echo "permit persist $USERNAME as root" > /etc/doas.conf
chmod 0400 /etc/doas.conf

# ── GPU (Nouveau) ───────────────────────────────────────────────────────────
info "Setting up Nouveau..."

xbps-remove -Ry nvidia nvidia-libs nvidia-libs-32bit nvidia-dkms 2>/dev/null || true

xbps-install -y mesa-dri mesa-vulkan-nouveau vulkan-loader

rm -f /etc/dracut.conf.d/nvidia.conf
rm -f /etc/modprobe.d/nvidia.conf
sed -i '/blacklist nouveau/d' /etc/modprobe.d/* 2>/dev/null || true

dracut --force --regenerate-all

# ── GRUB ────────────────────────────────────────────────────────────────────
GRUB_CFG=/etc/default/grub
sed -i 's/nvidia-drm.modeset=1//g' "$GRUB_CFG"
sed -i 's/rd.driver.blacklist=nouveau//g' "$GRUB_CFG"
grub-mkconfig -o /boot/grub/grub.cfg

# ── Display manager ─────────────────────────────────────────────────────────
xbps-install -y sddm
ln -sf /etc/sv/sddm /var/service/ 2>/dev/null || true

# ── Services (runit) ────────────────────────────────────────────────────────
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

# ── PipeWire autostart (NO systemd) ─────────────────────────────────────────
if ! grep -q "pipewire" "$SWAY_CFG"; then
cat >> "$SWAY_CFG" <<'EOF'

# PipeWire (runit)
exec_always pipewire
exec_always pipewire-pulse
exec_always wireplumber
exec_always /usr/libexec/polkit-gnome-authentication-agent-1
EOF
fi

chown "$USERNAME:$USERNAME" "$SWAY_CFG"

# ── Dotfiles / Configs ──────────────────────────────────────────────────────
CONFIG_SRC="$USER_HOME/configs"

if [[ -d "$CONFIG_SRC" ]]; then
  info "Installing user configs..."

  # Ensure target dirs exist
  sudo -u "$USERNAME" mkdir -p "$USER_HOME/.config"
  sudo -u "$USERNAME" mkdir -p "$USER_HOME/Pictures"

  # Copy everything except Pictures into ~/.config
  for item in "$CONFIG_SRC"/*; do
    name="$(basename "$item")"

    if [[ "$name" == "Pictures" ]]; then
      continue
    fi

    sudo -u "$USERNAME" cp -r "$item" "$USER_HOME/.config/"
  done

  # Copy Pictures separately
  if [[ -d "$CONFIG_SRC/Pictures" ]]; then
    sudo -u "$USERNAME" cp -r "$CONFIG_SRC/Pictures/"* "$USER_HOME/Pictures/" 2>/dev/null || true
  fi

  # Fix ownership
  chown -R "$USERNAME:$USERNAME" "$USER_HOME/.config" "$USER_HOME/Pictures"

  ok "Configs installed."
else
  warn "No configs directory found at $CONFIG_SRC"
fi

# ── Done ────────────────────────────────────────────────────────────────────
cat <<EOF

========================================
 Setup complete

 User: $USERNAME
 Shell: bash
 WM: sway
 GPU: nouveau
 Audio: pipewire

 Login → start sway:
   sway
========================================

EOF
