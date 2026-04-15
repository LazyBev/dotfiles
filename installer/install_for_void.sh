#!/usr/bin/env bash
set -euo pipefail

# ── Logging ─────────────────────────────────────────────
_log() { printf "[%-5s] %s\n" "$1" "$2"; }
info()  { _log "INFO" "$*"; }
warn()  { _log "WARN" "$*"; }
ok()    { _log "OK"   "$*"; }
step()  { echo -e "\n==> $*\n--------------------------------"; }
die()   { _log "FATAL" "$*"; exit 1; }
skip()  { _log "SKIP" "$*"; }

trap 'die "Error on line ${LINENO}: ${BASH_COMMAND}"' ERR
trap 'warn "Interrupted"; exit 130' INT TERM

# ── Args ────────────────────────────────────────────────
USERNAME="${1:-}"
[[ -z "$USERNAME" ]] && die "Usage: $0 <username>"
[[ $EUID -ne 0 ]] && die "Run as root"

id "$USERNAME" &>/dev/null || die "User '$USERNAME' not found"

USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
DOTFILES="$USER_HOME/dotfiles"

[[ -z "$USER_HOME" || ! -d "$USER_HOME" ]] && die "Invalid home directory for $USERNAME"

# ── Helpers ─────────────────────────────────────────────
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

# ── System update ───────────────────────────────────────
step "Updating system"
xbps-install -Syu -y

# ── Repositories ────────────────────────────────────────
step "Enabling repositories"
pkg_install void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree
xbps-install -Syu -y

# ── Base packages ───────────────────────────────────────
step "Installing base packages"
pkg_install \
    git curl wget jq ripgrep fd bat fzf \
    neovim tmux btop \
    dbus elogind rtkit chrony opendoas \
    xdg-user-dirs xdg-utils linux-firmware \
    cpupower irqbalance \
    qt5-svg qt5-quickcontrols2 qt5-graphicaleffects

# ── Performance ─────────────────────────────────────────
step "Performance tuning"
echo 'governor="performance"' > /etc/default/cpupower
enable_service cpupower
enable_service irqbalance

for sched in /sys/block/*/queue/scheduler; do
    echo mq-deadline > "$sched" 2>/dev/null || true
done

# ── Sway stack ──────────────────────────────────────────
step "Installing Sway stack"

pkg_install \
    sway swaylock swayidle swaybg \
    Waybar foot fuzzel dunst \
    wl-clipboard grim slurp \
    xdg-desktop-portal-wlr \
    polkit polkit-gnome \
    seatd firefox dolphin \
    pipewire wireplumber alsa-utils pamixer pavucontrol \
    NetworkManager network-manager-applet xz unzip zip flatpak

flatpak install flathub org.freedesktop.Platform.VulkanInfo//23.08
flatpak install flathub org.freedesktop.Platform.GL.default//23.08
flatpak install flathub org.freedesktop.Platform.GL.default//24.08

# ── Fonts ────────────────────────────────────────────────
step "Installing fonts"
pkg_install \
    noto-fonts-ttf noto-fonts-emoji \
    font-firacode font-awesome6 terminus-font \
    nerd-fonts

xbps-reconfigure -f fontconfig
setfont ter-v22n || true

# ── GPU (AMD preferred, disable Nouveau) ────────────────
step "Configuring GPU (AMD Mesa, disable Nouveau)"

# Remove NVIDIA/Nouveau junk
xbps-remove -Ry mesa-vulkan-nouveau 2>/dev/null || true

# Install proper AMD stack
pkg_install mesa mesa-dri mesa-vulkan-radeon vulkan-loader mesa-demos

# Disable Nouveau completely (prevents conflicts)
mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/blacklist-nouveau.conf <<EOF
blacklist nouveau
options nouveau modeset=0
EOF

sudo xbps-reconfigure -fa

dracut --force --regenerate-all

# ── Services ─────────────────────────────────────────────
step "Enabling services"
for svc in dbus elogind NetworkManager chronyd rtkit seatd ; do
    enable_service "$svc"
done

rm -f /var/service/dhcpcd 2>/dev/null || true
rm -f /var/service/wpa_supplicant 2>/dev/null || true

# ── doas ────────────────────────────────────────────────
step "Configuring doas"
echo "permit persist :wheel" > /etc/doas.conf
chmod 0400 /etc/doas.conf

# ── Groups ──────────────────────────────────────────────
step "User groups"
usermod -aG _seatd,input,video,audio,wheel,network "$USERNAME"

# ── PAM runtime dir ──────────────────────────────────────
step "XDG runtime setup"
pkg_install pam_rundir || true

grep -q pam_rundir.so /etc/pam.d/login || \
    echo 'session optional pam_rundir.so' >> /etc/pam.d/login

# ── Wayland session ─────────────────────────────────────
#step "Sway session"

#mkdir -p /usr/share/wayland-sessions

#cat > /usr/share/wayland-sessions/sway.desktop <<EOF
#[Desktop Entry]
#Name=Sway
#Exec=env WLR_RENDERER=gles2 sway
#Type=Application
#EOF

# ── TTY autostart ───────────────────────────────────────
step "TTY autostart"

cat > "$USER_HOME/.bash_profile" <<'EOF'
if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    export WLR_NO_HARDWARE_CURSORS=1
    export GBM_BACKEND=nvidia-drm
    export __GLX_VENDOR_LIBRARY_NAME=nvidia
    export LIBVA_DRIVER_NAME=nvidia
    export MOZ_ENABLE_WAYLAND=1
    exec sway --unsupported-gpu
fi
EOF
chown "$USERNAME:$USERNAME" "$USER_HOME/.bash_profile"

# ── SDDM config ─────────────────────────────────────────
#step "SDDM auto-user"

#mkdir -p /etc/sddm.conf.d

#cat > /etc/sddm.conf.d/10-autouser.conf <<EOF
#[Users]
#DefaultUser=$USERNAME
#RememberLastUser=true

#[General]
#DisplayServer=wayland

#[Wayland]
#CompositorCommand=sway
#EOF

# ──────────────────────── extra  ─────────────────────────────
step "Extras"

VESKTOP_FILE="$HOME/.local/share/applications/vesktop.desktop"

mkdir -p "$HOME/.local/bin"
mkdir -p "$HOME/.local/share/applications"

rm -f "$HOME/.local/bin/vesktop"
rm -f "$VESKTOP_FILE"

# download directly to final name
curl -fL https://vencord.dev/download/vesktop/amd64/appimage \
  -o "$HOME/.local/bin/vesktop"

[[ -s "$HOME/.local/bin/vesktop" ]] || die "Vesktop download failed"

chmod +x "$HOME/.local/bin/vesktop"

cat > "$VESKTOP_FILE" <<EOF
[Desktop Entry]
Name=Vesktop
Exec=vesktop %U
Icon=vesktop
Type=Application
Categories=Network;InstantMessaging;
Terminal=false
EOF

#THEME_REPO="https://github.com/Keyitdev/sddm-astronaut-theme.git"
#THEME_NAME="sddm-astronaut-theme"
#THEMES_DIR="/usr/share/sddm/themes"
#CLONE_DIR="/tmp/$THEME_NAME"

#rm -rf "$CLONE_DIR"
#git clone -b master --depth 1 "$THEME_REPO" "$CLONE_DIR"

#rm -rf "$THEMES_DIR/$THEME_NAME"
#mkdir -p "$THEMES_DIR"
#cp -r "$CLONE_DIR" "$THEMES_DIR/$THEME_NAME"
#chmod -R 755 "$THEMES_DIR/$THEME_NAME"

#THEME_CONF="$THEMES_DIR/$THEME_NAME/metadata.desktop"
#if [[ -f "$THEME_CONF" ]]; then
#    sed -i 's|^ConfigFile=.*|ConfigFile=Themes/hyprland_kath.conf|' "$THEME_CONF" || true
#fi

#cat > /etc/sddm.conf.d/10-theme.conf <<EOF
#[Theme]
#Current=$THEME_NAME
#EOF

# ── Dotfiles sync ───────────────────────────────────────
step "Syncing dotfiles"

if [[ -d "$DOTFILES" ]]; then
    CONFIG="$USER_HOME/.config"
    mkdir -p "$CONFIG"

    [[ -f "$DOTFILES/.bashrc" ]] && cp -f "$DOTFILES/.bashrc" "$USER_HOME/.bashrc"

    for dir in waybar dunst wlogout sway foot fuzzel fcitx5 qutebrowser; do
        SRC="$DOTFILES/configs/$dir"
        DST="$CONFIG/$dir"

        [[ -d "$SRC" ]] && rm -rf "$DST" && cp -r "$SRC" "$DST" || true
    done

    [[ -d "$DOTFILES/configs/Pictures" ]] && cp -r "$DOTFILES/configs/Pictures" "$USER_HOME/"
    chown -R "$USERNAME:$USERNAME" "$USER_HOME"
fi

# ── GTK theme ───────────────────────────────────────────

step "GTK theme"
GTK_SRC="$DOTFILES/configs/diinki-retro-dark"
GTK_DST="/usr/share/themes/diinki-retro-dark"

if [[ -d "$GTK_SRC" ]]; then
    rm -rf "$GTK_DST"
    cp -r "$GTK_SRC" "$GTK_DST"
    ok "GTK theme installed"
else
    warn "GTK theme source not found at $GTK_SRC — skipping"
fi

mkdir -p "$USER_HOME/.config/gtk-3.0" "$USER_HOME/.config/gtk-4.0"

tee "$USER_HOME/.config/gtk-3.0/settings.ini" > /dev/null << 'EOF'
[Settings]
gtk-theme-name=diinki-retro-dark
gtk-icon-theme-name=Adwaita
gtk-font-name=Sans 10
gtk-cursor-theme-name=Adwaita
gtk-cursor-theme-size=24
EOF

tee "$USER_HOME/.config/gtk-4.0/settings.ini" > /dev/null << 'EOF'
[Settings]
gtk-theme-name=diinki-retro-dark
gtk-icon-theme-name=Adwaita
gtk-font-name=Sans 10
gtk-cursor-theme-name=Adwaita
gtk-cursor-theme-size=24
EOF

chown -R "$USERNAME:$USERNAME" "$USER_HOME/.config/gtk-3.0" "$USER_HOME/.config/gtk-4.0"
ok "GTK settings applied"

# ── GRUB Hatsune Miku theme ─────────────────────────────

step "GRUB Hatsune Miku theme"

REPO="https://github.com/yorunoken/HatsuneMiku.git"
TMP="/tmp/miku-grub"
THEMES_DIR="/usr/share/grub/themes"
THEME_NAME="4k-HatsuneMiku"   # or 1080-HatsuneMiku
GRUB_CFG="/etc/default/grub"
THEME_PATH="$THEMES_DIR/$THEME_NAME/theme.txt"

mkdir -p "$TMP"

# Clone repo
if ! git clone --depth=1 "$REPO" "$TMP"; then
    warn "Failed to clone repo — skipping"
else
    mkdir -p "$THEMES_DIR"
    rm -rf "$THEMES_DIR/$THEME_NAME"

    if [[ -d "$TMP/$THEME_NAME" ]]; then
        cp -r "$TMP/$THEME_NAME" "$THEMES_DIR/"
        chmod -R 755 "$THEMES_DIR/$THEME_NAME"
        ok "Theme copied"
    else
        warn "Theme folder '$THEME_NAME' not found — skipping"
    fi

    # Apply GRUB theme
    if [[ -f "$THEME_PATH" ]]; then
        if grep -q "^GRUB_THEME=" "$GRUB_CFG"; then
            sed -i "s|^GRUB_THEME=.*|GRUB_THEME=\"$THEME_PATH\"|" "$GRUB_CFG"
        else
            echo "GRUB_THEME=\"$THEME_PATH\"" >> "$GRUB_CFG"
        fi

        # Update GRUB
        if command -v grub-mkconfig &>/dev/null; then
            grub-mkconfig -o /boot/grub/grub.cfg
            ok "GRUB updated"
        else
            warn "grub-mkconfig not found"
        fi

        ok "Hatsune Miku GRUB theme installed"
    else
        warn "theme.txt missing — skipping GRUB config"
    fi
fi

# Cleanup
rm -rf "$TMP"

# ── FINAL FIX: ZRAM SAFE INIT ───────────────────────────
step "ZRAM setup"

modprobe zram num_devices=1 2>/dev/null || true

if [[ -e /sys/block/zram0/disksize ]]; then
    echo $((6 * 1024 * 1024 * 1024)) > /sys/block/zram0/disksize || true
    mkswap /dev/zram0 || true
    swapon /dev/zram0 || true
fi

ok "Setup complete"
