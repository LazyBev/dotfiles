#!/bin/bash

set -eo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/helper.sh"

trap 'trap_message' INT TERM

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

info()    { echo "[INFO]  $*"; }
warn()    { echo "[WARN]  $*"; }
skip()    { echo "[SKIP]  $*"; }
die()     { echo "[FATAL] $*"; exit 1; }

# Run a pacman/yay install and keep going even if one package is not found.
# Packages that do exist will still install.
pkg_install() {
    local mgr="$1"; shift
    local -a missing=()
    for pkg in "$@"; do
        if ! "$mgr" -S --needed --noconfirm "$pkg" 2>/dev/null; then
            warn "Package not found / failed: $pkg — skipping"
            missing+=("$pkg")
        fi
    done
    [[ ${#missing[@]} -gt 0 ]] && warn "Skipped packages: ${missing[*]}"
    return 0
}

# rc-update wrapper — skips gracefully if the service file doesn't exist
rc_enable() {
    local svc="$1" lvl="${2:-default}"
    if [[ -f /etc/openrc/init.d/$svc || -f /etc/init.d/$svc ]]; then
        sudo rc-update add "$svc" "$lvl" 2>/dev/null || skip "rc-update: $svc already in $lvl"
    else
        skip "Service file missing for $svc — not enabling"
    fi
}

# ---------------------------------------------------------------------------
# Pacman config
# ---------------------------------------------------------------------------

declare -a pacman_conf=(
    "s/#Color/Color/"
    "s/#ParallelDownloads/ParallelDownloads/"
    "s/#\\[multilib\\]/\\[multilib\\]/"
    "s/#Include = \\/etc\\/pacman\\.d\\/mirrorlist/Include = \\/etc\\/pacman\\.d\\/mirrorlist/"
    "/# Misc options/a ILoveCandy"
)

if ! sudo reflector --country US --latest 20 --sort rate --save /etc/pacman.d/mirrorlist 2>/dev/null; then
    warn "reflector failed — falling back to curl mirrorlist"
    sudo curl -fsSo /etc/pacman.d/mirrorlist \
        "https://archlinux.org/mirrorlist/?country=US&protocol=https&use_mirror_status=on" \
        || die "Could not fetch mirrorlist"
    sudo sed -i 's/^#Server/Server/' /etc/pacman.d/mirrorlist
fi

if [[ ! -f /etc/pacman.conf.bak ]]; then
    info "Backing up /etc/pacman.conf"
    sudo cp /etc/pacman.conf /etc/pacman.conf.bak || die "Failed to back up pacman.conf"
else
    skip "pacman.conf backup already exists"
fi

info "Patching /etc/pacman.conf"
for change in "${pacman_conf[@]}"; do
    sudo sed -i "$change" /etc/pacman.conf || warn "sed change may have already been applied: $change"
done

# ---------------------------------------------------------------------------
# Artix repos — injected above Arch repos so systemd-free builds win
# ---------------------------------------------------------------------------

info "Adding Artix repositories..."

if ! grep -q '^\[system\]' /etc/pacman.conf; then
    sudo sed -i '/^\[core\]/i \
[system]\
Include = /etc/pacman.d/artix-mirrorlist\
\
[world]\
Include = /etc/pacman.d/artix-mirrorlist\
\
[galaxy]\
Include = /etc/pacman.d/artix-mirrorlist\
\
[lib32]\
Include = /etc/pacman.d/artix-mirrorlist\
' /etc/pacman.conf
else
    skip "Artix repo blocks already in pacman.conf"
fi

# Bootstrap artix-mirrorlist from CDN if not present
if [[ ! -f /etc/pacman.d/artix-mirrorlist ]]; then
    info "Fetching artix-mirrorlist..."
    MIRRORLIST_PKG=$(curl -s 'https://mirrors.artixlinux.org/packages/system/x86_64/' \
        | grep -oP 'artix-mirrorlist-[^"]+\.pkg\.tar\.zst' | tail -1)
    [[ -z "$MIRRORLIST_PKG" ]] && die "Could not find artix-mirrorlist package on CDN"
    sudo curl -fsSo /tmp/artix-mirrorlist.pkg.tar.zst \
        "https://mirrors.artixlinux.org/packages/system/x86_64/${MIRRORLIST_PKG}" \
        || die "Failed to download artix-mirrorlist"
    sudo pacman -U --noconfirm /tmp/artix-mirrorlist.pkg.tar.zst \
        || die "Failed to install artix-mirrorlist"
else
    skip "artix-mirrorlist already present"
fi

sudo pacman -Sy

if ! pacman -Q artix-keyring &>/dev/null; then
    info "Installing artix-keyring..."
    sudo pacman -S --noconfirm artix-keyring || die "Failed to install artix-keyring"
    sudo pacman-key --populate artix
else
    skip "artix-keyring already installed"
fi

# ---------------------------------------------------------------------------
# Migrate: pull out systemd, drop in OpenRC + elogind
# ---------------------------------------------------------------------------

info "Migrating from systemd to OpenRC..."

# Try openrc-base first (Artix meta), fall back to plain openrc
OPENRC_PKG="openrc"
if pacman -Ss '^openrc-base$' 2>/dev/null | grep -q openrc-base; then
    OPENRC_PKG="openrc-base"
fi

# Try base-artix, fall back to nothing (base from Artix repo will shadow Arch's)
BASE_ARTIX_ARGS=()
if pacman -Ss '^base-artix$' 2>/dev/null | grep -q base-artix; then
    BASE_ARTIX_ARGS=(base-artix)
fi

sudo pacman -S --needed --noconfirm \
    "$OPENRC_PKG" \
    "${BASE_ARTIX_ARGS[@]}" \
    elogind \
    elogind-openrc \
    libelogind \
    udev-openrc \
    dbus-openrc \
    sysvinit \
    openrc-arch-services-git \
    || die "Failed to install OpenRC base packages"

# Force-remove systemd — elogind/libelogind satisfy virtual deps
if pacman -Q systemd &>/dev/null; then
    sudo pacman -Rdd --noconfirm systemd systemd-libs systemd-sysvcompat 2>/dev/null \
        || warn "systemd removal had errors — continuing"
else
    skip "systemd already removed"
fi

# Refresh util-linux + procps-ng from Artix repo
sudo pacman -S --needed --noconfirm util-linux procps-ng || warn "util-linux/procps-ng refresh failed — may be fine"

# ---------------------------------------------------------------------------
# Start
# ---------------------------------------------------------------------------

print_bold_blue "\nBev's dotfiles"
echo -e "\n------------------------------------------------------------------------\n"
print_info "\nStarting prerequisites setup..."

sudo pacman -Syu --noconfirm || warn "Full upgrade had warnings — continuing"

# Install yay if missing
if ! command -v yay &>/dev/null; then
    info "Installing yay..."
    [[ -d yay-bin ]] && sudo rm -rf yay-bin
    sudo git clone https://aur.archlinux.org/yay-bin.git || die "Failed to clone yay-bin"
    sudo chown -R "$USER:$USER" yay-bin
    (cd yay-bin && makepkg -si --noconfirm) || die "Failed to build yay"
    sudo rm -rf yay-bin
else
    skip "yay already installed"
fi

# ---------------------------------------------------------------------------
# Main package install
# yay --needed means already-installed packages are silently skipped.
# Unknown packages warn but don't abort (pkg_install wrapper not used here
# because yay handles its own missing-pkg reporting; --needed covers idempotency).
# ---------------------------------------------------------------------------

info "Installing main packages..."
yay -Syu --needed --noconfirm \
    acpi \
    acpid \
    alsa-firmware \
    alsa-plugins \
    alsa-tools \
    alsa-utils \
    alsa-utils-openrc \
    arch-install-scripts \
    blueman \
    bluez \
    bluez-openrc \
    bluez-utils \
    brightnessctl \
    btop \
    chafa \
    cliphist \
    cmake \
    cronie \
    cronie-openrc \
    curl \
    dbus \
    dbus-openrc \
    dconf \
    dconf-editor \
    dmenu \
    dolphin \
    dunst \
    easyeffects \
    egl-wayland \
    elogind \
    elogind-openrc \
    emacs \
    eza \
    fastfetch \
    fcitx5-anthy \
    fcitx5-gtk \
    fcitx5-im \
    fcitx5-qt \
    ffmpeg \
    fuzzel \
    fzf \
    ghostty \
    git \
    gst-libav \
    gst-plugin-pipewire \
    gst-plugins-bad \
    gst-plugins-good \
    gvfs \
    helvum \
    hwinfo \
    imagemagick \
    iw \
    kdenlive \
    kvantum \
    kvantum-theme-catppuccin-git \
    kwayland \
    lib32-alsa-plugins \
    lib32-elogind \
    lib32-libpipewire \
    lib32-nvidia-utils \
    lib32-opencl-nvidia \
    lib32-pipewire \
    lib32-pipewire-jack \
    lib32-pipewire-v4l2 \
    lib32-vulkan-mesa-layers \
    libevdev \
    libinput \
    libpipewire \
    libva-nvidia-driver \
    libwireplumber \
    libxkbcommon \
    make \
    man-db \
    man-pages \
    mesa \
    meson \
    mpv \
    neovim \
    network-manager-applet \
    networkmanager \
    networkmanager-openrc \
    nm-connection-editor \
    noto-fonts-emoji \
    nwg-look \
    obsidian \
    openrc \
    openrc-arch-services-git \
    pam_rundir \
    pamixer \
    pavucontrol \
    pipewire \
    pipewire-alsa \
    pipewire-jack \
    pipewire-pulse \
    pipewire-v4l2 \
    playerctl \
    polkit \
    polkit-kde-agent \
    python \
    python-pip \
    python-pipx \
    qemu-audio-pipewire \
    qpwgraph \
    qt5ct \
    qt6ct \
    qutebrowser \
    ranger \
    ripgrep \
    sddm \
    sddm-openrc \
    slurp \
    stow \
    sudo \
    swayidle \
    swaylock \
    swww \
    tar \
    tlp \
    tlp-openrc \
    tmux \
    ttf-dejavu \
    ttf-jetbrains-mono \
    ttf-jetbrains-mono-nerd \
    ttf-liberation \
    udev-openrc \
    unzip \
    vulkan-mesa-layers \
    waybar \
    wayland \
    wayland-protocols \
    wayland-utils \
    waypaper \
    wev \
    wf-recorder \
    wget \
    wireplumber \
    wireplumber-docs \
    wl-clipboard \
    wlr-randr \
    wlroots \
    xarchiver \
    xbindkeys \
    xdg-desktop-portal \
    xdg-desktop-portal-gtk \
    xdotool \
    xf86-input-libinput \
    xorg-xev \
    xwayland \
    xwayland-run \
    xwayland-satellite \
    yt-dlp \
    ytfzf \
    zen-browser-bin \
    zip \
    || warn "Some packages failed to install — check output above"

if ! command -v iwctl &>/dev/null; then
    yay -Syu --needed --noconfirm iwd iwd-openrc || warn "iwd install failed"
else
    skip "iwd already present"
fi

# ---------------------------------------------------------------------------
# Remove conflicting JACK
# ---------------------------------------------------------------------------

if pacman -Q jack2 &>/dev/null; then
    info "Removing conflicting jack2..."
    sudo pacman -Rdd --noconfirm jack2 || warn "jack2 removal failed — may already be gone"
else
    skip "jack2 not installed"
fi

# ---------------------------------------------------------------------------
# PulseAudio removal
# ---------------------------------------------------------------------------

if pacman -Q | grep -qE '^pulseaudio'; then
    info "Removing PulseAudio..."
    rc-service pulseaudio stop 2>/dev/null || true
    mapfile -t pa_pkgs < <(pacman -Q | awk '{print $1}' | grep -E '^pulseaudio')
    [[ ${#pa_pkgs[@]} -gt 0 ]] && sudo pacman -Rns --noconfirm "${pa_pkgs[@]}" \
        || warn "PulseAudio removal had errors"
else
    skip "PulseAudio not installed"
fi

if ! groups | grep -q '\baudio\b'; then
    sudo usermod -aG audio "$USER"
else
    skip "User already in audio group"
fi

# ---------------------------------------------------------------------------
# OpenRC service setup
# ---------------------------------------------------------------------------

info "Enabling OpenRC services..."

rc_enable udev        sysinit
rc_enable udev-trigger sysinit
rc_enable udev-settle  sysinit
rc_enable elogind      boot
rc_enable acpid        boot
rc_enable dbus         boot
rc_enable NetworkManager default
rc_enable bluetoothd    default
rc_enable tlp           default
rc_enable cronie        default
rc_enable sddm          default

# getty on tty1 — openrc-init doesn't auto-spawn TTYs like systemd does
AGETTY_SRC="/etc/openrc/init.d/agetty"
AGETTY_TTY1="/etc/openrc/init.d/agetty.tty1"
if [[ -f "$AGETTY_SRC" ]]; then
    if [[ ! -e "$AGETTY_TTY1" ]]; then
        sudo ln -sf "$AGETTY_SRC" "$AGETTY_TTY1"
    else
        skip "agetty.tty1 symlink already exists"
    fi
    rc_enable agetty.tty1 default
else
    warn "agetty service file not found at $AGETTY_SRC — TTY1 not configured"
fi

# ---------------------------------------------------------------------------
# CPU microcode
# ---------------------------------------------------------------------------

VENDOR=$(lscpu | awk '/Vendor ID/{print $3}')
case "$VENDOR" in
    GenuineIntel)
        info "Intel CPU — installing intel-ucode"
        sudo pacman -S --needed --noconfirm intel-ucode || warn "intel-ucode install failed"
        ;;
    AuthenticAMD)
        info "AMD CPU — installing amd-ucode"
        sudo pacman -S --needed --noconfirm amd-ucode || warn "amd-ucode install failed"
        ;;
    *)
        warn "Unknown CPU vendor: $VENDOR — skipping microcode" ;;
esac

# ---------------------------------------------------------------------------
# NVIDIA
# ---------------------------------------------------------------------------

if lspci | grep -qi nvidia; then
    info "NVIDIA GPU detected — installing drivers..."
    yay -Syu --needed --sudoloop --noconfirm \
        egl-wayland \
        lib32-nvidia-utils \
        lib32-opencl-nvidia \
        lib32-vulkan-mesa-layers \
        libva-nvidia-driver \
        nvidia-dkms \
        nvidia-hook \
        nvidia-inst \
        nvidia-settings \
        nvidia-utils \
        opencl-nvidia \
        vulkan-mesa-layers \
        xf86-video-nouveau \
        || warn "Some NVIDIA packages failed"
else
    skip "No NVIDIA GPU detected"
fi

# ---------------------------------------------------------------------------
# D-Bus session
# ---------------------------------------------------------------------------

if [[ -z "$DBUS_SESSION_BUS_ADDRESS" ]]; then
    eval "$(dbus-launch --sh-syntax)" 2>/dev/null || warn "dbus-launch failed — dbus may not be running yet"
fi

# ---------------------------------------------------------------------------
# Strip pam_systemd from PAM stack
# ---------------------------------------------------------------------------

PAM_FILE="/etc/pam.d/system-auth"
if [[ -f "$PAM_FILE" ]] && grep -q 'pam_systemd' "$PAM_FILE"; then
    info "Removing pam_systemd from $PAM_FILE..."
    sudo sed -i '/pam_systemd/d' "$PAM_FILE"
else
    skip "pam_systemd not in $PAM_FILE"
fi

# ---------------------------------------------------------------------------
# GRUB — inject init=/usr/bin/openrc-init + CPU params
# ---------------------------------------------------------------------------

GRUB_FILE="/etc/default/grub"
[[ -f "$GRUB_FILE" ]] || die "GRUB config not found at $GRUB_FILE"

CPU_MODEL=$(lscpu | awk '/Model name/{print $3}')
case "$CPU_MODEL" in
    AMD*)   EXTRA_PARAMS="init=/usr/bin/openrc-init amd_pstate=active mitigations=off" ;;
    Intel*) EXTRA_PARAMS="init=/usr/bin/openrc-init intel_pstate=active mitigations=off" ;;
    *)      EXTRA_PARAMS="init=/usr/bin/openrc-init"
            warn "Unknown CPU model — only setting init param" ;;
esac

# Only patch if openrc-init isn't already in there
if ! grep -q 'openrc-init' "$GRUB_FILE"; then
    sudo sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"\([^\"]*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 ${EXTRA_PARAMS}\"/" "$GRUB_FILE"
else
    skip "openrc-init already in GRUB_CMDLINE_LINUX_DEFAULT"
fi

# ---------------------------------------------------------------------------
# Config setup
# ---------------------------------------------------------------------------

echo -e "\n------------------------------------------------------------------------\n"
print_info "\nStarting config setup..."

# Fontconfig
mkdir -p "$HOME/.config/fontconfig"
if [[ ! -f "$HOME/.config/fontconfig/fonts.conf" ]]; then
    cat > "$HOME/.config/fontconfig/fonts.conf" <<'FONTS'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <alias>
    <family>sans-serif</family>
    <prefer>
      <family>Noto Sans</family>
      <family>Noto Color Emoji</family>
      <family>Noto Emoji</family>
      <family>DejaVu Sans</family>
    </prefer>
  </alias>
  <alias>
    <family>serif</family>
    <prefer>
      <family>Noto Serif</family>
      <family>Noto Color Emoji</family>
      <family>Noto Emoji</family>
      <family>DejaVu Serif</family>
    </prefer>
  </alias>
  <alias>
    <family>monospace</family>
    <prefer>
      <family>Noto Mono</family>
      <family>Noto Color Emoji</family>
      <family>Noto Emoji</family>
    </prefer>
  </alias>
</fontconfig>
FONTS
else
    skip "fonts.conf already exists"
fi

# niri-edit helper
if [[ ! -x /usr/bin/niri-edit ]]; then
    sudo tee /usr/bin/niri-edit > /dev/null <<'EOF'
#!/bin/sh
ghostty -e nvim ~/.config/niri/config.kdl
EOF
    sudo chmod +x /usr/bin/niri-edit
else
    skip "niri-edit already installed"
fi

# .bashrc
if [[ -f "$HOME/dotfiles/.bashrc" ]]; then
    cp -f "$HOME/dotfiles/.bashrc" "$HOME/" || {
        rm -f "$HOME/.bashrc"
        cp -f "$HOME/dotfiles/.bashrc" "$HOME/"
    }
else
    warn "dotfiles/.bashrc not found — skipping"
fi

# Config directories — always overwrite to keep dotfiles in sync
for dir in waybar dunst wlogout niri fuzzel fcitx5 qutebrowser; do
    SRC="$HOME/dotfiles/configs/$dir"
    DST="$HOME/.config/$dir"
    if [[ -d "$SRC" ]]; then
        rm -rf "$DST"
        cp -r "$SRC" "$DST"
    else
        warn "dotfiles/configs/$dir not found — skipping"
    fi
done

[[ -d "$HOME/dotfiles/configs/Pictures" ]] \
    && cp -r "$HOME/dotfiles/configs/Pictures" "$HOME/" \
    || skip "No Pictures dir in dotfiles"

sudo chown -R "$USER:$USER" "$HOME"

# SDDM theme
if [[ ! -d /usr/share/sddm/themes/sddm-astronaut-theme ]]; then
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/keyitdev/sddm-astronaut-theme/master/setup.sh)" \
        || warn "SDDM theme install failed"
else
    skip "sddm-astronaut-theme already installed"
fi

# GTK theme
GTK_THEME_SRC="$HOME/dotfiles/configs/diinki-retro-dark"
GTK_THEME_DST="/usr/share/themes/diinki-retro-dark"
if [[ -d "$GTK_THEME_SRC" && ! -d "$GTK_THEME_DST" ]]; then
    sudo mv "$GTK_THEME_SRC" /usr/share/themes/
elif [[ -d "$GTK_THEME_DST" ]]; then
    skip "diinki-retro-dark theme already in /usr/share/themes"
else
    warn "GTK theme source not found — skipping"
fi
gsettings set org.gnome.desktop.interface gtk-theme "diinki-retro-dark" 2>/dev/null || true

echo -e "\n------------------------------------------------------------------------\n"

# ---------------------------------------------------------------------------
# Optional utilities
# ---------------------------------------------------------------------------

utils() {
    print_info "\nStarting utilities setup..."

    yay -Syu --needed --noconfirm \
        ardour \
        flatpak \
        lutris \
        millennium \
        protonplus \
        spotify \
        steam \
        steam-native-runtime \
        wine-staging \
        winetricks \
        || warn "Some utils packages failed"

    winetricks d3dx9 d3dcompiler_43 d3dcompiler_47 ddxv 2>/dev/null || warn "winetricks components failed"
    wineboot -u 2>/dev/null || warn "wineboot failed"

    if [[ ! -f ./advcpmv/install.sh ]]; then
        curl -fsSL https://raw.githubusercontent.com/jarun/advcpmv/master/install.sh \
            --create-dirs -o ./advcpmv/install.sh \
            && (cd advcpmv && sh install.sh) \
            || warn "advcpmv install failed"
    else
        skip "advcpmv install.sh already downloaded"
    fi

    mkdir -p "$HOME/.config/Kvantum"
    printf '[General]\ntheme=catppuccin-frappe-mauve\n' > "$HOME/.config/Kvantum/kvantum.kvconfig"

    flatpak install -y flathub org.vinegarhq.Sober  2>/dev/null || warn "Sober flatpak failed"
    flatpak install -y flathub com.stremio.Stremio  2>/dev/null || warn "Stremio flatpak failed"
    flatpak install -y flathub com.obsproject.Studio 2>/dev/null || warn "OBS flatpak failed"

    mkdir -p "$HOME/.config/arti"
    if [[ ! -f "$HOME/.config/arti/arti.toml" ]]; then
        cat > "$HOME/.config/arti/arti.toml" <<'ARTI'
[application]
watch_configuration = true
permit_debugging = false
allow_running_as_root = false

[proxy]
socks_listen = 9150

[logging]
console = "info"
log_sensitive_information = false
time_granularity = "1s"

[storage]
cache_dir = "${ARTI_CACHE}"
state_dir = "${ARTI_LOCAL_DATA}"

[storage.permissions]
dangerously_trust_everyone = false
trust_user = ":current"
trust_group = ":username"

[path_rules]
ipv4_subnet_family_prefix = 16
ipv6_subnet_family_prefix = 32
reachable_addrs = ["*:80", "*:443"]
long_lived_ports = [22, 80, 443, 6667, 8300]

[preemptive_circuits]
disable_at_threshold = 8
initial_predicted_ports = [80, 443]
prediction_lifetime = "30 mins"
min_exit_circs_for_port = 2

[channel]
padding = "normal"

[circuit_timing]
max_dirtiness = "10 minutes"
request_timeout = "30 sec"
request_max_retries = 8
request_loyalty = "50 msec"

[address_filter]
allow_local_addrs = false
allow_onion_addrs = true

[stream_timeouts]
connect_timeout = "15 sec"
resolve_timeout = "10 sec"
resolve_ptr_timeout = "10 sec"

[system]
max_files = 8192

[vanguards]
mode = "lite"
ARTI
    else
        skip "arti.toml already exists"
    fi

    echo -e "\n------------------------------------------------------------------------\n"

    bash -c "$(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh)" \
        || warn "oh-my-bash install failed"
}

read -rp "Install extra utilities? [Y/n] " ans
ans=${ans:-Y}
if [[ "${ans,,}" == "y" ]]; then
    utils
else
    info "Skipping utils."
fi

# ---------------------------------------------------------------------------
# Finalise
# ---------------------------------------------------------------------------

sudo mkinitcpio -P || warn "mkinitcpio had errors"
sudo grub-mkconfig -o /boot/grub/grub.cfg || die "grub-mkconfig failed"

echo ""
info "Done. Rebooting into OpenRC in 5 seconds..."
info "If shutdown hangs: Alt+PrtSc, then R E I S U B"
sleep 5

sudo openrc-shutdown -r now 2>/dev/null || sudo reboot
