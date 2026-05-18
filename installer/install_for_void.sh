#!/usr/bin/env bash
set -euo pipefail

# ── Logging ─────────────────────────────────────────────
_log() { printf "[%-5s] %s\n" "$1" "$2"; }
info()  { _log "INFO" "$*"; }
warn()  { _log "WARN" "$*"; }
ok()    { _log "OK"   "$*"; }
step()  { echo -e "\n==> $*\n--------------------------------"; }
die()   { _log "FATAL" "$*"; exit 1; }

trap 'die "Error on line ${LINENO}: ${BASH_COMMAND}"' ERR
trap 'warn "Interrupted"; exit 130' INT TERM

# ── Args ────────────────────────────────────────────────
USERNAME="${1:-}"
[[ -z "$USERNAME" ]] && die "Usage: $0 <username>"
[[ $EUID -ne 0 ]] && die "Run as root"

id "$USERNAME" &>/dev/null || die "User '$USERNAME' not found"

USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"
DOTFILES="$USER_HOME/dotfiles"

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

# ── System Update ───────────────────────────────────────
step "Updating system"
xbps-install -Syu -y curl

# ── Repositories ────────────────────────────────────────
step "Enabling repositories"
pkg_install void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree
xbps-install -Syu -y

# ── Base Packages ───────────────────────────────────────
step "Installing base packages"
pkg_install \
    git curl wget jq ripgrep fd bat fzf \
    neovim tmux btop \
    dbus elogind seatd rtkit chrony opendoas \
    xdg-user-dirs xdg-utils linux-firmware sof-firmware \
    cpupower irqbalance \
    qt5-svg qt5-quickcontrols2 qt5-graphicaleffects \
    glibc-32bit glibc \
    kdenlive mpv mpvpaper \
    unzip zip xz \
    flatpak wine \
    iwd NetworkManager \
    network-manager-applet \
    alacritty \
    bluez upower \
    power-profiles-daemon \
    fcitx5 fcitx5-configtool \
    fcitx5-gtk+3 fcitx5-gtk4 \
    fcitx5-qt5 fcitx5-qt6 \
    fcitx5-mozc fcitx5-chinese-addons \
    fcitx5-cloudpinyin fcitx5-rime \
    fcitx5-hangul fcitx5-m17n

# ── User Groups ─────────────────────────────────────────
step "Configuring groups"
usermod -aG _seatd,input,video,audio,wheel,network "$USERNAME"

# ── doas ────────────────────────────────────────────────
step "Configuring doas"
echo "permit persist :wheel" > /etc/doas.conf
chmod 0400 /etc/doas.conf

# ── Performance ─────────────────────────────────────────
step "Performance tuning"
echo 'governor="performance"' > /etc/default/cpupower

enable_service cpupower
enable_service irqbalance

for sched in /sys/block/*/queue/scheduler; do
    echo mq-deadline > "$sched" 2>/dev/null || true
done

# ── Sway Stack ──────────────────────────────────────────
step "Installing Sway stack"

pkg_install \
    sway swaylock swayidle swaybg \
    foot fuzzel dunst \
    wl-clipboard grim slurp \
    xdg-desktop-portal \
    xdg-desktop-portal-wlr \
    polkit polkit-gnome \
    dolphin pipewire wireplumber \
    network-manager-applet \
    alsa-utils pamixer pavucontrol \
    wireplumber-devel alsa-pipewire \

# ── Noctalia ────────────────────────────────────────────
step "Installing Noctalia"

echo "repository=https://universalrepository.pages.dev/void" \
    > /etc/xbps.d/10-noctalia.conf

xbps-install -Sy \
    noctalia-shell \
    brightnessctl \
    ImageMagick \
    python3 \
    ddcutil \
    cliphist \
    wlsunset \
    evolution-data-server

# ── Flatpak ─────────────────────────────────────────────
step "Configuring Flatpak"

flatpak remote-add --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo

# ── Fonts ───────────────────────────────────────────────
step "Installing fonts"

pkg_install \
    noto-fonts-ttf \
    noto-fonts-emoji \
    font-firacode \
    font-awesome6 \
    terminus-font \
    nerd-fonts

xbps-reconfigure -f fontconfig
setfont ter-v22n || true

# ── NVIDIA Setup ────────────────────────────────────────
step "Configuring NVIDIA"

xbps-remove -Ry mesa-vulkan-nouveau 2>/dev/null || true

pkg_install \
    nvidia \
    nvidia-libs-32bit \
    mesa mesa-dri mesa-dri-32bit \
    vulkan-loader vulkan-loader-32bit \
    mesa-demos \
    libgcc-32bit libstdc++-32bit \
    libdrm-32bit libglvnd-32bit \
    mesa-32bit \
    libXtst-32bit libXfixes-32bit \
    libXrandr-32bit libXrender-32bit \
    libXi-32bit glib-32bit \
    gtk+3-32bit gdk-pixbuf-32bit \
    libpipewire-32bit \
    libva-32bit libvdpau-32bit \
    libpulseaudio-32bit

mkdir -p /etc/modprobe.d

cat > /etc/modprobe.d/blacklist-nouveau.conf <<EOF
blacklist nouveau
options nouveau modeset=0
EOF

xbps-reconfigure -fa
dracut --force --regenerate-all

# ── Locales ─────────────────────────────────────────────
step "Fixing locales"

FILE="/etc/default/libc-locales"

grep -q "^en_US.UTF-8 UTF-8" "$FILE" || \
    echo "en_US.UTF-8 UTF-8" >> "$FILE"

grep -q "^en_GB.UTF-8 UTF-8" "$FILE" || \
    echo "en_GB.UTF-8 UTF-8" >> "$FILE"

sed -i 's/^#\s*\(en_US.UTF-8 UTF-8\)/\1/' "$FILE"
sed -i 's/^#\s*\(en_GB.UTF-8 UTF-8\)/\1/' "$FILE"

xbps-reconfigure -f glibc-locales

# ── Services ────────────────────────────────────────────
step "Enabling services"

for svc in \
    dbus \
    elogind \
    NetworkManager \
    chronyd \
    rtkit \
    seatd \
    bluetoothd \
    power-profiles-daemon \
    upower; do
    enable_service "$svc"
done

# IMPORTANT: Do NOT run PipeWire as system services
rm -f /var/service/pipewire 2>/dev/null || true
rm -f /var/service/pipewire-pulse 2>/dev/null || true
rm -f /var/service/wireplumber 2>/dev/null || true

# ── NetworkManager + iwd ────────────────────────────────
step "Configuring NetworkManager"

mkdir -p /etc/NetworkManager/conf.d

cat > /etc/NetworkManager/conf.d/iwd.conf <<EOF
[device]
wifi.backend=iwd
EOF

cat > /etc/NetworkManager/conf.d/wifi-powersave.conf <<EOF
[connection]
wifi.powersave=2
EOF

rm -f /var/service/dhcpcd 2>/dev/null || true
rm -f /var/service/wpa_supplicant 2>/dev/null || true

# ── PAM Runtime ─────────────────────────────────────────
step "Configuring PAM runtime"

pkg_install pam_rundir || true

grep -q pam_rundir.so /etc/pam.d/login || \
    echo 'session optional pam_rundir.so' >> /etc/pam.d/login

# ── Bash Profile ────────────────────────────────────────
step "Creating sway autostart"

cat > "$USER_HOME/.bash_profile" <<'EOF'
if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    export XDG_CURRENT_DESKTOP=sway
    export XDG_SESSION_TYPE=wayland

    export WLR_NO_HARDWARE_CURSORS=1
    export GBM_BACKEND=nvidia-drm
    export __GLX_VENDOR_LIBRARY_NAME=nvidia
    export EGL_PLATFORM=wayland

    nm-applet --indicator &

    exec dbus-run-session sway --unsupported-gpu
fi
EOF

chown "$USERNAME:$USERNAME" "$USER_HOME/.bash_profile"

# ── GTK Theme ───────────────────────────────────────────
step "Configuring GTK"

mkdir -p "$USER_HOME/.config/gtk-3.0"
mkdir -p "$USER_HOME/.config/gtk-4.0"

tee "$USER_HOME/.config/gtk-3.0/settings.ini" > /dev/null << 'EOF'
[Settings]
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Adwaita
gtk-font-name=Sans 10
gtk-cursor-theme-name=Adwaita
gtk-cursor-theme-size=24
EOF

tee "$USER_HOME/.config/gtk-4.0/settings.ini" > /dev/null << 'EOF'
[Settings]
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Adwaita
gtk-font-name=Sans 10
gtk-cursor-theme-name=Adwaita
gtk-cursor-theme-size=24
EOF

chown -R "$USERNAME:$USERNAME" "$USER_HOME/.config"

# ── Dotfiles sync ───────────────────────────────────────
step "Syncing dotfiles"
CONFIG="$USER_HOME/.config"

if [[ -d "$DOTFILES" ]]; then
    mkdir -p "$CONFIG"

    info "Using dotfiles at $DOTFILES"

    # Bash config
    if [[ -f "$DOTFILES/.bashrc" ]]; then
        cp -f "$DOTFILES/.bashrc" "$USER_HOME/.bashrc"
        ok "Installed .bashrc"
    fi

    # Config directories
    for dir in dunst wlogout sway foot fuzzel fcitx5 qutebrowser noctalia; do
        SRC="$DOTFILES/configs/$dir"
        DST="$CONFIG/$dir"

        if [[ -d "$SRC" ]]; then
            rm -rf "$DST"
            cp -r "$SRC" "$DST"
            ok "Synced $dir"
        else
            warn "Missing config: $dir"
        fi
    done

    # Optional assets
    if [[ -d "$DOTFILES/configs/Pictures" ]]; then
        cp -r "$DOTFILES/configs/Pictures" "$USER_HOME/"
        ok "Copied Pictures"
    fi

    chown -R "$USERNAME:$USERNAME" "$USER_HOME"
else
    warn "Dotfiles directory not found: $DOTFILES"
    warn "Skipping dotfiles sync"
fi

# ── ALSA Setup ───────────────────────────────────────────
step "Configuring ALSA"

pkg_install alsa-utils || true

# system-wide ALSA defaults
mkdir -p /etc/alsa
cat > /etc/asound.conf <<'EOF'
defaults.pcm.card 0
defaults.ctl.card 0
EOF

# ensure mixer is not muted (best effort)
amixer sset Master unmute 2>/dev/null || true
amixer sset PCM unmute 2>/dev/null || true

# user ALSA config
cat > "$USER_HOME/.asoundrc" <<'EOF'
defaults.pcm.card 0
defaults.ctl.card 0
EOF

chown "$USERNAME:$USERNAME" "$USER_HOME/.asoundrc"

ok "ALSA configured"

# ── GRUB ────────────────────────────────────────────────
step "Configuring GRUB"

GRUB_CFG="/etc/default/grub"

REQUIRED_PARAMS=(
    quiet
    loglevel=3
    preempt=full
    threadirqs
    nvidia-drm.modeset=1
)

if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_CFG"; then
    CURRENT=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_CFG" | cut -d'"' -f2)
else
    CURRENT=""
fi

CURRENT=$(echo "$CURRENT" | sed 's/\bsplash\b//g')

for param in "${REQUIRED_PARAMS[@]}"; do
    [[ ! " $CURRENT " =~ " $param " ]] && CURRENT="$CURRENT $param"
done

CURRENT=$(echo "$CURRENT" | xargs)

NEW_LINE="GRUB_CMDLINE_LINUX_DEFAULT=\"$CURRENT\""

if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_CFG"; then
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|$NEW_LINE|" "$GRUB_CFG"
else
    echo "$NEW_LINE" >> "$GRUB_CFG"
fi

grub-mkconfig -o /boot/grub/grub.cfg

# ── ZRAM ────────────────────────────────────────────────
step "Setting up ZRAM"

modprobe zram num_devices=1 2>/dev/null || true

if [[ -e /sys/block/zram0/disksize ]]; then
    echo $((6 * 1024 * 1024 * 1024)) > /sys/block/zram0/disksize || true
    mkswap /dev/zram0 || true
    swapon /dev/zram0 || true
fi

# ── Final ───────────────────────────────────────────────
step "Final cleanup"

rm -rf "$USER_HOME/.local/state/wireplumber" 2>/dev/null || true

bash -c "$(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh)" || true

ok "Setup complete"
ok "Reboot required"
