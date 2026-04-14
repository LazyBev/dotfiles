#!/bin/bash
# void-sway-setup.sh (runit + bash + nouveau + pipewire + seatd)

set -euo pipefail

# ── Logging ──────────────────────────────────────────────────────────────────
# Defined first so die() is available during arg validation below
_log() { printf "[%-5s] %s\n" "$1" "$2"; }
info()  { _log "INFO" "$*"; }
warn()  { _log "WARN" "$*"; }
ok()    { _log "OK"   "$*"; }
skip()  { _log "SKIP" "$*"; }
step()  { echo -e "\n==> $*\n--------------------------------"; }
die()   { _log "FATAL" "$*"; exit 1; }

trap 'die "Error on line ${LINENO}: ${BASH_COMMAND}"' ERR
trap 'warn "Interrupted"; exit 130' INT TERM

# ── Args ─────────────────────────────────────────────────────────────────────
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
# die() is now defined above, so this is safe
USER_UID=$(id -u "$USERNAME" 2>/dev/null) || die "User $USERNAME not found"

# ── Ownership ────────────────────────────────────────────────────────────────
step "Fixing ownership"
chown -R "$USERNAME:$USERNAME" "$USER_HOME"

# ── System update ─────────────────────────────────────────────────────────────
step "Updating system"
xbps-install -Syu -y

# ── Repos ─────────────────────────────────────────────────────────────────────
step "Enabling repos"
xbps-install -y void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree
xbps-install -Syu -y

# ── Base + CLI tools ──────────────────────────────────────────────────────────
step "Installing base packages"
xbps-install -y \
    git bash curl wget jq ripgrep fd bat fzf neovim tmux btop \
    dbus elogind rtkit chrony opendoas

# ── Sway stack ────────────────────────────────────────────────────────────────
step "Installing Sway stack"
xbps-install -y \
    sway swaylock swayidle swaybg \
    Waybar foot fuzzel dunst \
    wl-clipboard grim slurp \
    xdg-desktop-portal xdg-desktop-portal-wlr xdg-utils \
    polkit polkit-gnome \
    fcitx5 fcitx5-anthy \
    seatd

# ── Fonts ─────────────────────────────────────────────────────────────────────
step "Installing fonts"
xbps-install -y \
    noto-fonts-ttf noto-fonts-emoji \
    font-firacode font-awesome6 terminus-font \
    nerd-fonts

setfont ter-v22n || true

# ── Audio ─────────────────────────────────────────────────────────────────────
step "Installing audio"
# wireplumber ships wpctl; pamixer/pavucontrol for volume control
xbps-install -y pipewire wireplumber alsa-utils pamixer pavucontrol

# ── Network ───────────────────────────────────────────────────────────────────
step "Installing network tools"
xbps-install -y NetworkManager network-manager-applet

# ── GPU (nouveau) ─────────────────────────────────────────────────────────────
step "Setting up Nouveau"

xbps-remove -Ry nvidia nvidia-libs nvidia-libs-32bit nvidia-dkms 2>/dev/null || true

xbps-install -y mesa-dri vulkan-loader || true
if ! xbps-install -y mesa-vulkan-nouveau 2>/dev/null; then
    warn "mesa-vulkan-nouveau not found, trying vulkan-nouveau"
    xbps-install -y vulkan-nouveau || warn "No Vulkan nouveau package found; skipping"
fi

rm -f /etc/dracut.conf.d/nvidia.conf
rm -f /etc/modprobe.d/nvidia.conf
sed -i '/blacklist nouveau/d' /etc/modprobe.d/* 2>/dev/null || true

dracut --force --regenerate-all

# ── GRUB ──────────────────────────────────────────────────────────────────────
step "Updating GRUB"
GRUB_CFG=/etc/default/grub
sed -i 's/nvidia-drm.modeset=1//g'         "$GRUB_CFG"
sed -i 's/rd.driver.blacklist=nouveau//g'  "$GRUB_CFG"
grub-mkconfig -o /boot/grub/grub.cfg

# ── doas ──────────────────────────────────────────────────────────────────────
step "Configuring doas"
xbps-install -y opendoas
echo "permit persist $USERNAME as root" > /etc/doas.conf
chmod 0400 /etc/doas.conf

# ── Groups ────────────────────────────────────────────────────────────────────
step "Configuring user groups"
usermod -aG _seatd,input,video,audio,wheel,network,plugdev,storage,optical,cdrom,kvm "$USERNAME"
ok "Groups set for $USERNAME"

# ── seatd ─────────────────────────────────────────────────────────────────────
step "Configuring seatd"
ln -sf /etc/sv/seatd /var/service/ 2>/dev/null || true

cat > /etc/runit/core-services/06-seatd-perms.sh <<'EOF'
#!/bin/sh
sleep 1
chown root:_seatd /run/seatd.sock 2>/dev/null || true
chmod 660 /run/seatd.sock 2>/dev/null || true
EOF
chmod +x /etc/runit/core-services/06-seatd-perms.sh 2>/dev/null || \
    warn "Could not install seatd perms hook (non-fatal)"

# ── XDG runtime dir (pam_rundir) ─────────────────────────────────────────────
# pam_rundir creates /run/user/$UID automatically on login; no manual dir or
# runit hook needed
step "Configuring XDG runtime dir via pam_rundir"
xbps-install -y pam_rundir

PAM_LOGIN=/etc/pam.d/login
# Append only if not already present
if ! grep -q 'pam_rundir.so' "$PAM_LOGIN"; then
    printf 'session\toptional\tpam_rundir.so\n' >> "$PAM_LOGIN"
    ok "pam_rundir appended to $PAM_LOGIN"
else
    skip "pam_rundir already in $PAM_LOGIN"
fi

# ── Wayland session ───────────────────────────────────────────────────────────
step "Installing Wayland session"
mkdir -p /usr/share/wayland-sessions
cat > /usr/share/wayland-sessions/sway.desktop <<'EOF'
[Desktop Entry]
Name=Sway
Comment=An i3-compatible Wayland compositor
Exec=env WLR_BACKENDS=drm WLR_NO_HARDWARE_CURSORS=1 sway --unsupported-gpu
Type=Application
EOF

# ── XDG portal config ─────────────────────────────────────────────────────────
step "Configuring xdg-desktop-portal"
mkdir -p /etc/xdg-desktop-portal
cat > /etc/xdg-desktop-portal/sway-portals.conf <<'EOF'
[preferred]
default=wlr
org.freedesktop.impl.portal.Secret=gnome-keyring
EOF

# ── Services ──────────────────────────────────────────────────────────────────
step "Enabling services"
for svc in dbus elogind NetworkManager chronyd rtkit seatd; do
    if [[ -d /etc/sv/$svc ]]; then
        ln -sf /etc/sv/$svc /var/service/ 2>/dev/null || true
        ok "Enabled $svc"
    else
        warn "Service $svc not found, skipping"
    fi
done

# ── Shell ─────────────────────────────────────────────────────────────────────
step "Configuring shell"
xbps-install -y bash
chsh -s /bin/bash "$USERNAME" || true

# ── bash_profile (auto-launch sway on tty1) ───────────────────────────────────
step "Writing .bash_profile"
# cat > "$USER_HOME/.bash_profile" <<EOF
# Auto-launch sway on TTY1
# export XDG_RUNTIME_DIR=/run/user/\$(id -u)
# export XDG_SESSION_TYPE=wayland
# export XDG_CURRENT_DESKTOP=sway
# export XDG_SESSION_DESKTOP=sway
# export SEATD_SOCK=/run/seatd.sock
# export WLR_BACKENDS=drm
# export WLR_NO_HARDWARE_CURSORS=1
# export MOZ_ENABLE_WAYLAND=1
# export QT_QPA_PLATFORM=wayland
# export QT_WAYLAND_DISABLE_WINDOWDECORATION=1
# export GDK_BACKEND=wayland
# export SDL_VIDEODRIVER=wayland
# export CLUTTER_BACKEND=wayland
# export _JAVA_AWT_WM_NONREPARENTING=1
# export XCURSOR_SIZE=24

if [ -z "\$WAYLAND_DISPLAY" ] && [ "\$(tty)" = "/dev/tty1" ]; then
   # exec sway --unsupported-gpu
   echo "Miau"
fi
EOF
chown "$USERNAME:$USERNAME" "$USER_HOME/.bash_profile"
ok ".bash_profile written"

# ── void-packages ─────────────────────────────────────────────────────────────
step "Setting up void-packages"
VOID_PKGS="$USER_HOME/.void-packages"
if [[ ! -d "$VOID_PKGS" ]]; then
    sudo -u "$USERNAME" git clone https://github.com/void-linux/void-packages.git "$VOID_PKGS"
fi

# Use explicit path rather than ~ to ensure correct expansion
sudo -u "$USERNAME" bash -c \
    "grep -q 'XBPS_DISTDIR' \"$USER_HOME/.bashrc\" 2>/dev/null || \
     echo 'export XBPS_DISTDIR=\$HOME/.void-packages' >> \"$USER_HOME/.bashrc\""

# ── vpsm ──────────────────────────────────────────────────────────────────────
step "Setting up vpsm"
VPSM_DIR="$USER_HOME/vpsm"
if [[ ! -d "$VPSM_DIR" ]]; then
    sudo -u "$USERNAME" git clone https://github.com/sinetoami/vpsm.git "$VPSM_DIR"
fi

# Use explicit paths; ~ inside single-quoted sudo bash -c won't expand to USER_HOME
sudo -u "$USERNAME" bash -c \
    "mkdir -p \"$USER_HOME/.bin\" && \
     ln -sf \"$USER_HOME/vpsm/vpsm\" \"$USER_HOME/.bin/vpsm\" && \
     grep -q '.bin' \"$USER_HOME/.bashrc\" 2>/dev/null || \
     echo 'export PATH=\$PATH:\$HOME/.bin' >> \"$USER_HOME/.bashrc\""

# ── Sway config ───────────────────────────────────────────────────────────────
step "Configuring Sway"
SWAY_CFG="$USER_HOME/.config/sway/config"

if [[ ! -f "$SWAY_CFG" ]]; then
    mkdir -p "$(dirname "$SWAY_CFG")"
    cp /etc/sway/config "$SWAY_CFG"
    chown "$USERNAME:$USERNAME" "$SWAY_CFG"
    ok "Default sway config copied"
else
    skip "Sway config already exists"
fi

# Do NOT replace --all with --systemd; this is runit, not systemd
# Append PipeWire autostart and correct polkit exec if not already present
if ! grep -q "pipewire" "$SWAY_CFG"; then
    cat >> "$SWAY_CFG" <<'EOF'

# PipeWire / audio
exec /usr/bin/pipewire
exec /usr/bin/pipewire-pulse
exec /usr/bin/wireplumber
# Wrap in sh -c so || fallback works (sway exec doesn't chain shell operators)
exec sh -c '/usr/lib/polkit-kde-authentication-agent-1 || /usr/libexec/polkit-gnome-authentication-agent-1'
EOF
fi
chown "$USERNAME:$USERNAME" "$SWAY_CFG"

# ── PipeWire user services ────────────────────────────────────────────────────
step "Linking PipeWire user services"
USER_SV="$USER_HOME/.config/service"
for pw_svc in pipewire pipewire-pulse wireplumber; do
    if [[ -d /etc/sv/$pw_svc ]] && [[ ! -L "$USER_SV/$pw_svc" ]]; then
        mkdir -p "$USER_SV"
        ln -sf /etc/sv/$pw_svc "$USER_SV/$pw_svc"
        ok "Linked user service: $pw_svc"
    fi
done
chown -R "$USERNAME:$USERNAME" "$USER_SV" 2>/dev/null || true

# ── XDG user dirs ─────────────────────────────────────────────────────────────
sudo -u "$USERNAME" xdg-user-dirs-update 2>/dev/null || true

# ── Dotfiles sync ─────────────────────────────────────────────────────────────
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

# ── oh-my-bash ────────────────────────────────────────────────────────────────
step "Installing oh-my-bash"
# Pipe into bash -s so --unattended is passed as an arg to the install script,
# not treated as an argument to the bash binary itself
curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh \
    | sudo -u "$USERNAME" bash -s -- --unattended \
    || warn "oh-my-bash install failed (non-fatal)"

# ── Final ownership fix ───────────────────────────────────────────────────────
step "Final ownership fix"
chown -R "$USERNAME:$USERNAME" "$USER_HOME"

# ── Done ──────────────────────────────────────────────────────────────────────
cat <<EOF

========================================
 Setup complete

 User:    $USERNAME
 Shell:   bash
 WM:      sway (auto-launches on TTY1)
 GPU:     nouveau
 Audio:   pipewire + wireplumber
 Seat:    seatd
 Portal:  xdg-desktop-portal-wlr

 Reboot and log in on TTY1 — sway will
 launch automatically.
========================================
EOF
