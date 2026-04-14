#!/bin/bash
# void-sway-setup.sh (runit + bash + nouveau + pipewire)

set -euo pipefail

# ── Args ────────────────────────────────────────────────────────────────────
USERNAME="${1:-}"
if [[ -z "$USERNAME" ]]; then
    echo "Usage: $0 <username>"
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "Run as root."
    exit 1
fi

USER_HOME="/home/$USERNAME"

# ── Paths ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helper.sh" 2>/dev/null || true

# ── Logging ──────────────────────────────────────────────────────────────────
_log() { printf "[%-5s] %s\n" "$1" "$2"; }
info()  { _log "INFO" "$*"; }
warn()  { _log "WARN" "$*"; }
ok()    { _log "OK"   "$*"; }
skip()  { _log "SKIP" "$*"; }
step()  { echo -e "\n==> $*\n--------------------------------"; }
die()   { _log "FATAL" "$*"; exit 1; }

trap 'die "Error on line ${LINENO}: ${BASH_COMMAND}"' ERR
trap 'warn "Interrupted"; exit 130' INT TERM

# ── Ownership ───────────────────────────────────────────────────────────────
step "Fixing ownership"
chown -R "$USERNAME:$USERNAME" "$USER_HOME"

# ── System update ───────────────────────────────────────────────────────────
step "Updating system"
xbps-install -Syu -y

# ── Repos ───────────────────────────────────────────────────────────────────
xbps-install -y void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree
xbps-install -Syu -y

# ── Dotfiles repo check ─────────────────────────────────────────────────────
if [[ ! -d "$USER_HOME/dotfiles" ]]; then
    warn "dotfiles repo not found at $USER_HOME/dotfiles"
fi

# ── void-packages ───────────────────────────────────────────────────────────
VOID_PKGS="$USER_HOME/.void-packages"
if [[ ! -d "$VOID_PKGS" ]]; then
    sudo -u "$USERNAME" git clone https://github.com/void-linux/void-packages.git "$VOID_PKGS"
fi

sudo -u "$USERNAME" bash -c '
grep -q "XBPS_DISTDIR" ~/.bashrc 2>/dev/null || \
echo "export XBPS_DISTDIR=\$HOME/.void-packages" >> ~/.bashrc
'

# ── vpsm ────────────────────────────────────────────────────────────────────
VPSM_DIR="$USER_HOME/vpsm"
if [[ ! -d "$VPSM_DIR" ]]; then
    sudo -u "$USERNAME" git clone https://github.com/sinetoami/vpsm.git "$VPSM_DIR"
fi

sudo -u "$USERNAME" bash -c '
mkdir -p ~/.bin
ln -sf ~/vpsm/vpsm ~/.bin/vpsm
grep -q ".bin" ~/.bashrc 2>/dev/null || \
echo "export PATH=\$PATH:\$HOME/.bin" >> ~/.bashrc
'

# ── Base + CLI tools ─────────────────────────────────────────────────────────
step "Installing packages"
xbps-install -y \
  git bash curl wget jq ripgrep fd bat fzf neovim tmux btop

# ── Sway stack ──────────────────────────────────────────────────────────────
xbps-install -y \
  sway swaylock swayidle swaybg \
  Waybar foot fuzzel dunst \
  wl-clipboard grim slurp \
  xdg-desktop-portal xdg-desktop-portal-wlr xdg-utils \
  polkit polkit-gnome \
  dbus elogind rtkit chrony fcitx5 fcitx5-anthy

# ── Fonts ───────────────────────────────────────────────────────────────────
xbps-install -y \
  noto-fonts-ttf noto-fonts-emoji \
  font-firacode font-awesome6 terminus-font

setfont ter-v22n || true

# ── Audio ───────────────────────────────────────────────────────────────────
xbps-install -y pipewire wireplumber alsa-utils pamixer pavucontrol
usermod -aG audio,video "$USERNAME"

# ── Network ─────────────────────────────────────────────────────────────────
xbps-install -y NetworkManager network-manager-applet

# ── Shell ───────────────────────────────────────────────────────────────────
chsh -s /bin/bash "$USERNAME" || true

# ── doas ────────────────────────────────────────────────────────────────────
xbps-install -y opendoas
echo "permit persist $USERNAME as root" > /etc/doas.conf
chmod 0400 /etc/doas.conf

# ── GPU (nouveau) ───────────────────────────────────────────────────────────
step "Setting up Nouveau"

xbps-remove -Ry nvidia nvidia-libs nvidia-libs-32bit nvidia-dkms 2>/dev/null || true

# Try mesa-vulkan-nouveau first, fall back to vulkan-nouveau
xbps-install -y mesa-dri vulkan-loader || true
if ! xbps-install -y mesa-vulkan-nouveau 2>/dev/null; then
    warn "mesa-vulkan-nouveau not found, trying vulkan-nouveau"
    xbps-install -y vulkan-nouveau || warn "No Vulkan nouveau package found; skipping"
fi

rm -f /etc/dracut.conf.d/nvidia.conf
rm -f /etc/modprobe.d/nvidia.conf
sed -i '/blacklist nouveau/d' /etc/modprobe.d/* 2>/dev/null || true

dracut --force --regenerate-all

# ── GRUB ────────────────────────────────────────────────────────────────────
GRUB_CFG=/etc/default/grub
sed -i 's/nvidia-drm.modeset=1//g'          "$GRUB_CFG"
sed -i 's/rd.driver.blacklist=nouveau//g'   "$GRUB_CFG"
grub-mkconfig -o /boot/grub/grub.cfg

# ── greetd (replaces SDDM for Sway) ─────────────────────────────────────────
step "Setting up greetd + tuigreet"
xbps-install -y greetd greetd-tuigreet

mkdir -p /etc/greetd
cat > /etc/greetd/config.toml <<EOF
[terminal]
vt = 1

[default_session]
command = "tuigreet --cmd sway --time --remember"
user = "greeter"
EOF

# Remove SDDM if previously installed
xbps-remove -Ry sddm 2>/dev/null || true
rm -f /var/service/sddm 2>/dev/null || true

ln -sf /etc/sv/greetd /var/service/ 2>/dev/null || true

# ── XDG portal config for Sway ──────────────────────────────────────────────
step "Configuring xdg-desktop-portal"
mkdir -p /etc/xdg-desktop-portal
cat > /etc/xdg-desktop-portal/sway-portals.conf <<'EOF'
[preferred]
default=wlr
org.freedesktop.impl.portal.Secret=gnome-keyring
EOF

# ── Services ────────────────────────────────────────────────────────────────
step "Enabling services"
for svc in dbus elogind NetworkManager chronyd rtkit; do
    if [[ -d /etc/sv/$svc ]]; then
        ln -sf /etc/sv/$svc /var/service/ 2>/dev/null || true
        ok "Enabled $svc"
    else
        warn "Service $svc not found, skipping"
    fi
done

# ── User dirs ───────────────────────────────────────────────────────────────
sudo -u "$USERNAME" xdg-user-dirs-update 2>/dev/null || true

# ── Sway config ─────────────────────────────────────────────────────────────
step "Configuring Sway"
SWAY_CFG="$USER_HOME/.config/sway/config"

if [[ ! -f "$SWAY_CFG" ]]; then
    mkdir -p "$(dirname "$SWAY_CFG")"
    cp /etc/sway/config "$SWAY_CFG"
    chown "$USERNAME:$USERNAME" "$SWAY_CFG"
fi

# ── PipeWire autostart (exec, not exec_always) ──────────────────────────────
if ! grep -q "pipewire" "$SWAY_CFG"; then
cat >> "$SWAY_CFG" <<'EOF'

# PipeWire / audio
exec pipewire
exec pipewire-pulse
exec wireplumber
exec /usr/libexec/polkit-gnome-authentication-agent-1
EOF
fi

chown "$USERNAME:$USERNAME" "$SWAY_CFG"

# ── PipeWire user runit services ─────────────────────────────────────────────
# Optional: set up ~/.config/service/ entries for user-level runit management
USER_SV="$USER_HOME/.config/service"
for pw_svc in pipewire pipewire-pulse wireplumber; do
    if [[ -d /etc/sv/$pw_svc ]] && [[ ! -L "$USER_SV/$pw_svc" ]]; then
        mkdir -p "$USER_SV"
        ln -sf /etc/sv/$pw_svc "$USER_SV/$pw_svc"
        ok "Linked user service: $pw_svc"
    fi
done
chown -R "$USERNAME:$USERNAME" "$USER_SV" 2>/dev/null || true

# ── Dotfiles sync ───────────────────────────────────────────────────────────
step "Syncing dotfiles"

if [[ -f "$USER_HOME/dotfiles/.bashrc" ]]; then
    cp -f "$USER_HOME/dotfiles/.bashrc" "$USER_HOME/"
    ok ".bashrc installed"
else
    warn "No .bashrc in dotfiles"
fi

for dir in waybar dunst wlogout sway fuzzel fcitx5 qutebrowser; do
    SRC="$USER_HOME/dotfiles/configs/$dir"
    DST="$USER_HOME/.config/$dir"

    if [[ -d "$SRC" ]]; then
        rm -rf "$DST"
        cp -r "$SRC" "$DST"
        ok "$dir config installed"
    else
        skip "$dir not in dotfiles"
    fi
done

if [[ -d "$USER_HOME/dotfiles/configs/Pictures" ]]; then
    cp -r "$USER_HOME/dotfiles/configs/Pictures" "$USER_HOME/"
    ok "Pictures copied"
else
    skip "Pictures not found"
fi

# ── Final ownership fix ─────────────────────────────────────────────────────
chown -R "$USERNAME:$USERNAME" "$USER_HOME"

# ── Done ────────────────────────────────────────────────────────────────────
cat <<EOF

========================================
 Setup complete

 User:    $USERNAME
 Shell:   bash
 WM:      sway
 DM:      greetd + tuigreet
 GPU:     nouveau
 Audio:   pipewire + wireplumber
 Portal:  xdg-desktop-portal-wlr

 Reboot to start greetd and launch Sway.
========================================
EOF
