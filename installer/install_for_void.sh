#!/bin/bash
# void-sway-setup.sh
# Installs a basic Sway Wayland desktop on Void Linux
# Run as root (or with sudo) after a fresh base install
# Tested on musl and glibc Void. Adjust xbps-install calls if on musl.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/helper.sh"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

_log() { printf "[%-5s] %s\n" "$1" "$2"; }
info()  { _log "INFO"  "$*"; }
warn()  { _log "WARN"  "$*"; }
skip()  { _log "SKIP"  "$*"; }
ok()    { _log "OK"    "$*"; }
step()  { echo; echo "==> $*"; echo "------------------------------------------------------------"; }
die()   {
    _log "FATAL" "$*"
    echo
    echo "  The script failed at the step above."
    exit 1
}

trap 'echo; die "Unexpected error on line ${LINENO} — command: ${BASH_COMMAND}"' ERR
trap 'echo; warn "Script interrupted by user."; exit 130' INT TERM

USERNAME="${1:-}"
if [[ -z "$USERNAME" ]]; then
  echo "Usage: $0 <username>"
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "Run as root."
  exit 1
fi

# ── Sync repos ────────────────────────────────────────────────────────────────
xbps-install -Syu

# ── Enable all official Void repos ───────────────────────────────────────────
# nonfree: proprietary packages (e.g. nvidia blobs, codecs)
# multilib: 32-bit compat libs (glibc only — skip on musl)
xbps-install -y void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree
xbps-install -Sy   # re-sync with new repos enabled

# ── vpsm dependencies ────────────────────────────────────────────────────────
xbps-install -y git ripgrep xtools zsh

# ── vpsm install ──────────────────────────────────────────────────────────────
# Step 1: void-packages must be cloned by the user (we can't fork for them).
#         Script clones the official repo as a stand-in — replace the URL with
#         your fork before running if you plan to submit packages.
VOID_PKGS="/home/$USERNAME/.void-packages"
if [[ ! -d "$VOID_PKGS" ]]; then
  sudo -u "$USERNAME" git clone \
    https://github.com/void-linux/void-packages.git "$VOID_PKGS"
fi

# Step 2: export XBPS_DISTDIR in ~/.zshrc
sudo -u "$USERNAME" zsh -c \
  "grep -q XBPS_DISTDIR ~/.zshrc 2>/dev/null || echo 'export XBPS_DISTDIR=\$HOME/.void-packages' >> ~/.zshrc"

# Step 3+4: clone vpsm, add to PATH via ~/.bin symlink, export PATH in ~/.zshrc
sudo -u "$USERNAME" zsh -c '
  git clone https://github.com/sinetoami/vpsm.git ~/vpsm
  mkdir -p ~/.bin
  ln -sf ~/vpsm/vpsm ~/.bin/vpsm
  grep -q "\.bin" ~/.zshrc 2>/dev/null || echo "export PATH=\$PATH:\$HOME/.bin" >> ~/.zshrc
'

# ── Sway + Wayland essentials ─────────────────────────────────────────────────
xbps-install -y \
  sway \
  swaylock \
  swayidle \
  swaybg \
  Waybar \
  foot \
  fuzzel \
  dunst \
  wl-clipboard \
  grim \
  slurp \
  xdg-desktop-portal-wlr \
  xdg-utils \
  polkit \
  polkit-gnome \
  pam_rundir \
  dbus \
  elogind \
  rtkit


# ── Fonts ─────────────────────────────────────────────────────────────────────
xbps-install -y \
  noto-fonts-ttf \
  noto-fonts-emoji \
  font-firacode \
  font-awesome6

# ── Audio (PipeWire) ──────────────────────────────────────────────────────────
xbps-install -y \
  pipewire \
  wireplumber \
  alsa-utils \
  pamixer \
  pavucontrol

# ── Network ───────────────────────────────────────────────────────────────────
xbps-install -y \
  NetworkManager \
  network-manager-applet

# ── Useful CLI / dev tools ────────────────────────────────────────────────────
xbps-install -y \
  git \
  curl \
  wget \
  jq \
  ripgrep \
  fd \
  bat \
  fzf \
  zsh \
  neovim \
  tmux \
  btop

# ── Set zsh as default shell ──────────────────────────────────────────────────
chsh -s /bin/zsh "$USERNAME"

# ── doas ──────────────────────────────────────────────────────────────────────
xbps-install -S opendoas
# Allow user to run doas with persist (no password re-prompt for a short window)
cat > /etc/doas.conf <<EOF
permit persist $USERNAME as root
EOF
chmod 0400 /etc/doas.conf

# ── NVIDIA (proprietary) + AMD iGPU — PRIME offload ─────────────────────────
xbps-install -y \
  nvidia \
  nvidia-libs \
  nvidia-libs-32bit \
  nvidia-dkms \
  linux-headers \
  mesa-dri \
  vulkan-loader \
  amdvlk

# Tell dracut to include the nvidia modules in the initramfs
cat > /etc/dracut.conf.d/nvidia.conf <<'EOF'
force_drivers+=" nvidia nvidia_modeset nvidia_uvm nvidia_drm "
EOF

# dracut: also make sure the nvidia DRM framebuffer is not blacklisted
# and that nouveau is blacklisted
cat > /etc/modprobe.d/nvidia.conf <<'EOF'
blacklist nouveau
options nvidia_drm modeset=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
EOF

# Rebuild initramfs for all installed kernels
dracut --force --regenerate-all

# ── GRUB — add nvidia-drm.modeset=1 to kernel cmdline ────────────────────────
GRUB_CFG=/etc/default/grub
if grep -q 'GRUB_CMDLINE_LINUX_DEFAULT' "$GRUB_CFG"; then
  # Append to existing line if not already there
  if ! grep -q 'nvidia-drm.modeset' "$GRUB_CFG"; then
    sed -i 's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 nvidia-drm.modeset=1 rd.driver.blacklist=nouveau"/' "$GRUB_CFG"
  fi
fi
grub-mkconfig -o /boot/grub/grub.cfg


xbps-install -y sddm
ln -sf /etc/sv/sddm /var/service/ 2>/dev/null || true

# ── Enable runit services ─────────────────────────────────────────────────────
for svc in dbus elogind NetworkManager rtkit; do
  ln -sf /etc/sv/$svc /var/service/ 2>/dev/null || true
done

# PipeWire / WirePlumber run as user services — handled below via xinitrc-style
# session startup in the Sway config, not as system runit services.

# ── XDG dirs for the user ─────────────────────────────────────────────────────
sudo -u "$USERNAME" xdg-user-dirs-update 2>/dev/null || true

# ── Basic Sway config (only if none exists) ───────────────────────────────────
SWAY_CFG="/home/$USERNAME/.config/sway/config"
if [[ ! -f "$SWAY_CFG" ]]; then
  mkdir -p "$(dirname "$SWAY_CFG")"
  cp /etc/sway/config "$SWAY_CFG"
  chown "$USERNAME:$USERNAME" "$SWAY_CFG"
  echo "Copied default sway config to $SWAY_CFG"
fi

# ── PipeWire autostart in Sway config ────────────────────────────────────────
# Append only if not already present
if ! grep -q "wireplumber" "$SWAY_CFG"; then
  cat >> "$SWAY_CFG" <<'EOF'

# PipeWire / WirePlumber
exec dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP=sway
exec /usr/bin/pipewire
exec /usr/bin/pipewire-pulse
exec /usr/bin/wireplumber
exec /usr/libexec/polkit-gnome-authentication-agent-1
EOF
  chown "$USERNAME:$USERNAME" "$SWAY_CFG"
fi

for dir in waybar dunst wlogout sway fuzzel fcitx5 qutebrowser; do
    SRC="$HOME/dotfiles/configs/$dir"
    DST="$HOME/.config/$dir"
    if [[ -d "$SRC" ]]; then
        rm -rf "$DST"
        cp -r "$SRC" "$DST"
        ok "  $dir → $DST"
    else
        warn "  dotfiles/configs/$dir not found — skipping"
    fi
done

if [[ -d "$HOME/dotfiles/configs/Pictures" ]]; then
    cp -r "$HOME/dotfiles/configs/Pictures" "$HOME/"
    ok "Pictures copied to $HOME/"
else
    skip "No Pictures dir in dotfiles"
fi

info "Fixing ownership of $HOME..."
sudo chown -R "$USER:$USER" "$HOME" && ok "Ownership corrected"

if [[ ! -d /usr/share/sddm/themes/sddm-astronaut-theme ]]; then
    info "Installing sddm-astronaut-theme..."
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/keyitdev/sddm-astronaut-theme/master/setup.sh)" \
        && ok "SDDM theme installed" \
        || warn "SDDM theme install failed — SDDM will use default theme"
else
    skip "sddm-astronaut-theme already installed"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
cat <<EOF

════════════════════════════════════════════
  Done! Log in as $USERNAME and run:

    sway

  Repos enabled:
    void-repo-nonfree, void-repo-multilib, void-repo-multilib-nonfree

  vpsm installed at: /usr/local/bin/vpsm
    void-packages cloned to ~/.void-packages
    XBPS_DISTDIR exported in ~/.bashrc / ~/.zshrc

  Key apps:
    Terminal : foot
    Launcher : fuzzel  (Mod+d by default in sway config)
    Bar      : waybar
    Notifs   : dunst
    Audio    : pamixer / pavucontrol

  Tip: edit ~/.config/sway/config to customise keybinds,
  outputs, and gaps.
════════════════════════════════════════════
EOF
