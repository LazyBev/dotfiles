#!/usr/bin/env bash
# void-sway-setup.sh (full rewrite: runit + sway + pipewire + dotfiles + sddm)

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
DOTFILES="$USER_HOME/dotfiles"

# ── Helpers ───────────────────────────────────────────────────────────────
enable_service() {
    local svc="$1"
    [[ -d "/etc/sv/$svc" && ! -e "/var/service/$svc" ]] && {
        ln -s "/etc/sv/$svc" "/var/service/"
        ok "Enabled $svc"
    } || true
}

pkg_install() {
    xbps-install -y "$@"
}

# ── System update ───────────────────────────────────────────────────────────
step "Updating system"
xbps-install -Syu -y

# ── Repositories ───────────────────────────────────────────────────────────
step "Enabling repositories"
pkg_install void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree
xbps-install -Syu -y

# ── Base packages ──────────────────────────────────────────────────────────
step "Installing base packages"
pkg_install \
    git curl wget jq ripgrep fd bat fzf \
    neovim tmux btop \
    dbus elogind rtkit chrony opendoas \
    xdg-user-dirs xdg-utils linux-firmware \
    cpupower irqbalance \
    sddm qt5-svg qt5-quickcontrols2 qt5-graphicaleffects

# ── Performance ────────────────────────────────────────────────────────────
step "Performance tuning"

echo 'governor="performance"' > /etc/default/cpupower

enable_service cpupower
enable_service irqbalance

for sched in /sys/block/*/queue/scheduler; do
    [[ -f "$sched" ]] && echo mq-deadline > "$sched" 2>/dev/null || true
done

# ── Sway stack ─────────────────────────────────────────────────────────────
step "Installing Sway stack"

pkg_install \
    sway swaylock swayidle swaybg \
    Waybar foot fuzzel dunst \
    wl-clipboard grim slurp \
    xdg-desktop-portal-wlr \
    polkit polkit-gnome \
    seatd firefox dolphin \
    pipewire wireplumber alsa-utils pamixer pavucontrol \
    NetworkManager network-manager-applet xz unzip zip

# ── Fonts ──────────────────────────────────────────────────────────────────
step "Installing fonts"

pkg_install \
    noto-fonts-ttf noto-fonts-emoji \
    font-firacode font-awesome6 terminus-font \
    noto-fonts-ttf noto-fonts-cjk nerd-fonts

xbps-reconfigure -f fontconfig

setfont ter-v22n || true

# ── GPU (Nouveau safe) ─────────────────────────────────────────────────────
step "Configuring GPU (Nouveau)"

xbps-remove -Ry nvidia nvidia-dkms nvidia-libs 2>/dev/null || true

pkg_install mesa-dri mesa-vulkan-nouveau vulkan-loader || true

mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/nouveau.conf <<EOF
options nouveau config=NvPmEnableGating=1
EOF

dracut --force --regenerate-all

# ── Services ───────────────────────────────────────────────────────────────
step "Enabling services"

for svc in dbus elogind NetworkManager chronyd rtkit seatd sddm; do
    enable_service "$svc"
done

rm -f /var/service/dhcpcd 2>/dev/null || true
rm -f /var/service/wpa_supplicant 2>/dev/null || true

# ── doas ───────────────────────────────────────────────────────────────────
step "Configuring doas"

echo "permit persist :wheel" > /etc/doas.conf
chmod 0400 /etc/doas.conf

# ── Groups ─────────────────────────────────────────────────────────────────
step "User groups"

usermod -aG _seatd,input,video,audio,wheel,network "$USERNAME"

# ── PAM runtime dir ───────────────────────────────────────────────────────
step "XDG runtime setup"

pkg_install pam_rundir

grep -q pam_rundir.so /etc/pam.d/login || \
    echo 'session optional pam_rundir.so' >> /etc/pam.d/login

# ── Wayland session ───────────────────────────────────────────────────────
step "Sway session"

mkdir -p /usr/share/wayland-sessions

cat > /usr/share/wayland-sessions/sway.desktop <<EOF
[Desktop Entry]
Name=Sway
Exec=env WLR_RENDERER=gles2 sway
Type=Application
EOF

# ── TTY autostart (fallback) ──────────────────────────────────────────────
step "TTY autostart"

cat > "$USER_HOME/.bash_profile" <<'EOF'
if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec sway
fi
EOF

chown "$USERNAME:$USERNAME" "$USER_HOME/.bash_profile"

# ── SDDM AUTO-USER (PASSWORD STILL REQUIRED) ───────────────────────────
step "Configuring SDDM auto-user"

enable_service dbus

if [[ -d /etc/sv/sddm ]]; then
    ln -sf /etc/sv/sddm /var/service/sddm
    ok "SDDM enabled"
else
    warn "SDDM service not found"
fi

# ── Safe TTY handling (Void-correct) ───────────────────────────────────────
if [[ -e /etc/sv/agetty-tty1 ]]; then
    sv down agetty-tty1 2>/dev/null || true
    rm -f /var/service/agetty-tty1 2>/dev/null || true
    ok "agetty-tty1 disabled (safe)"
else
    skip "agetty-tty1 not found (no action needed)"
fi

mkdir -p /etc/sddm.conf.d

cat > /etc/sddm.conf.d/10-autouser.conf <<EOF
[Users]
DefaultUser=$USERNAME
RememberLastUser=true

[General]
DisplayServer=wayland

[X11]
DisplayCommand=

[Wayland]
CompositorCommand=sway
EOF

ok "SDDM auto-user configured (password still required)"

# ── Dotfiles sync ─────────────────────────────────────────────────────────
step "Syncing dotfiles"

if [[ -d "$DOTFILES" ]]; then
    CONFIG="$USER_HOME/.config"
    mkdir -p "$CONFIG"

    [[ -f "$DOTFILES/.bashrc" ]] && cp -f "$DOTFILES/.bashrc" "$USER_HOME/.bashrc"

    for dir in waybar dunst wlogout sway foot fuzzel fcitx5 qutebrowser; do
        SRC="$DOTFILES/configs/$dir"
        DST="$CONFIG/$dir"

        if [[ -d "$SRC" ]]; then
            rm -rf "$DST"
            cp -r "$SRC" "$DST"
            ok "$dir synced"
        else
            warn "$dir missing"
        fi
    done

    [[ -d "$DOTFILES/configs/Pictures" ]] && cp -r "$DOTFILES/configs/Pictures" "$USER_HOME/"

    chown -R "$USERNAME:$USERNAME" "$USER_HOME"
fi

# ── GTK theme ─────────────────────────────────────────────────────────────
step "GTK theme"

GTK_SRC="$DOTFILES/configs/diinki-retro-dark"
GTK_DST="/usr/share/themes/diinki-retro-dark"

if [[ -d "$GTK_SRC" && ! -d "$GTK_DST" ]]; then
    mv "$GTK_SRC" "$GTK_DST" 2>/dev/null || warn "GTK theme install failed"
fi

# ── SDDM theme ─────────────────────────────────────────────────────────────
step "SDDM theme"

if [[ ! -d /usr/share/sddm/themes/sddm-astronaut-theme ]]; then
    warn "Installing SDDM theme (user-level install)"

    sudo -u "$USERNAME" bash -c '
        curl -fsSL https://raw.githubusercontent.com/keyitdev/sddm-astronaut-theme/master/setup.sh | bash
    ' || warn "SDDM theme install failed"
fi

# ── Desktop portals ───────────────────────────────────────────────────────
step "xdg portals"

mkdir -p /etc/xdg/xdg-desktop-portal

cat > /etc/xdg/xdg-desktop-portal/portals.conf <<EOF
[preferred]
default=wlroots
org.freedesktop.impl.portal.ScreenCast=wlroots
org.freedesktop.impl.portal.Screenshot=wlroots
EOF

# ── Final ────────────────────────────────────────────────────────────────
echo "
========================================
 Setup complete

 User: $USERNAME
 WM:   Sway (via SDDM auto-user)
 GPU:  Nouveau
 Audio: PipeWire
 Init: runit

 Reboot recommended.
========================================
"
