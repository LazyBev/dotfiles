#!/bin/bash

set -eo pipefail

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
    echo "  Your pacman.conf backup is at /etc/pacman.conf.bak if you need to roll back."
    exit 1
}

# Trap unexpected exits (ERR fires on any non-zero exit when set -e is active)
trap 'echo; die "Unexpected error on line ${LINENO} — command: ${BASH_COMMAND}"' ERR
trap 'echo; warn "Script interrupted by user."; exit 130' INT TERM

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

step "Preflight checks"

[[ $EUID -ne 0 ]] || die "Do not run this script as root. It will sudo what it needs."
command -v pacman &>/dev/null || die "pacman not found — are you on Arch?"
command -v curl   &>/dev/null || die "curl not found — install it first: sudo pacman -S curl"
command -v git    &>/dev/null || { warn "git not found — installing..."; sudo pacman -S --noconfirm git; }

# Verify internet connectivity before doing anything
info "Checking internet connectivity..."
if ! curl -fsSL --max-time 10 https://archlinux.org &>/dev/null; then
    die "No internet connection detected. Check your network and try again."
fi
ok "Internet connectivity confirmed"

# Warn if running inside a chroot / container
if [[ ! -d /sys/firmware/efi && ! -d /run/openrc ]]; then
    warn "EFI not detected and OpenRC not running — make sure you're on the target machine, not a chroot."
fi

# ---------------------------------------------------------------------------
# Pacman config
# ---------------------------------------------------------------------------

step "Configuring pacman"

declare -a pacman_conf_patches=(
    "s/#Color/Color/"
    "s/#ParallelDownloads/ParallelDownloads/"
    "s/#\\[multilib\\]/\\[multilib\\]/"
    "s/#Include = \\/etc\\/pacman\\.d\\/mirrorlist/Include = \\/etc\\/pacman\\.d\\/mirrorlist/"
    "/# Misc options/a ILoveCandy"
)

info "Updating Arch mirrorlist..."
if sudo reflector --country US --latest 20 --sort rate --save /etc/pacman.d/mirrorlist 2>/dev/null; then
    ok "reflector updated mirrorlist"
else
    warn "reflector failed — falling back to curl mirrorlist"
    sudo curl -fsSo /etc/pacman.d/mirrorlist --max-time 30 \
        "https://archlinux.org/mirrorlist/?country=US&protocol=https&use_mirror_status=on" \
        || die "Could not fetch Arch mirrorlist — check your connection"
    sudo sed -i 's/^#Server/Server/' /etc/pacman.d/mirrorlist
    ok "curl mirrorlist fetched and uncommented"
fi

if [[ ! -f /etc/pacman.conf.bak ]]; then
    info "Backing up /etc/pacman.conf → /etc/pacman.conf.bak"
    sudo cp /etc/pacman.conf /etc/pacman.conf.bak || die "Failed to back up pacman.conf"
    ok "Backup created"
else
    skip "pacman.conf backup already exists at /etc/pacman.conf.bak"
fi

info "Applying pacman.conf patches..."
for change in "${pacman_conf_patches[@]}"; do
    sudo sed -i "$change" /etc/pacman.conf \
        && info "  Applied: $change" \
        || warn "  May already be applied (non-fatal): $change"
done
ok "pacman.conf patched"

# ---------------------------------------------------------------------------
# Artix repos — injected above Arch repos so systemd-free builds win
# ---------------------------------------------------------------------------

step "Adding Artix repositories"

if ! grep -q '^\[system\]' /etc/pacman.conf; then
    info "Injecting Artix repo blocks above [core]..."
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
    ok "Artix repo blocks added"
else
    skip "Artix repo blocks already present in pacman.conf"
fi

# Bootstrap: inject hardcoded Server= lines so pacman can resolve packages
# before the mirrorlist file exists
if [[ ! -f /etc/pacman.d/artix-mirrorlist ]]; then
    info "artix-mirrorlist not present — bootstrapping via hardcoded mirror..."

    if ! grep -q 'mirror.pascalpuffke.de' /etc/pacman.conf; then
        info "  Injecting temporary Server= lines..."
        sudo sed -i '/^\[system\]/a Server = https://mirror.pascalpuffke.de/artix-linux/packages/system/x86_64' /etc/pacman.conf
        sudo sed -i '/^\[world\]/a Server  = https://mirror.pascalpuffke.de/artix-linux/packages/world/x86_64'  /etc/pacman.conf
        sudo sed -i '/^\[galaxy\]/a Server = https://mirror.pascalpuffke.de/artix-linux/packages/galaxy/x86_64' /etc/pacman.conf
        ok "  Temporary mirror lines injected"
    else
        skip "  Temporary mirror lines already present"
    fi

    info "Trusting Artix signing key..."
    sudo pacman-key --recv-keys 56C9F05E9A5F9B09A71EBE85C9B5DE7A2B67C0AB 2>/dev/null \
        && ok "  Key received" \
        || warn "  Key recv failed (may already be trusted)"
    sudo pacman-key --lsign-key 56C9F05E9A5F9B09A71EBE85C9B5DE7A2B67C0AB 2>/dev/null \
        && ok "  Key locally signed" \
        || warn "  Key lsign failed (may already be signed)"

    info "Syncing package databases..."
    sudo pacman -Sy --noconfirm || die "pacman -Sy failed — check your network and mirror"

    info "Installing artix-mirrorlist and artix-keyring..."
    sudo pacman -S --noconfirm --needed artix-mirrorlist artix-keyring \
        || die "Failed to install artix-mirrorlist/artix-keyring — is the hardcoded mirror reachable?"

    info "Populating Artix keyring..."
    sudo pacman-key --populate artix || warn "pacman-key --populate artix had errors (usually harmless)"
    ok "artix-mirrorlist and artix-keyring installed"
else
    skip "artix-mirrorlist already present at /etc/pacman.d/artix-mirrorlist"
fi

info "Final package database sync..."
sudo pacman -Sy --noconfirm || die "pacman -Sy failed"
ok "Databases synced"

if ! pacman -Q artix-keyring &>/dev/null; then
    info "Installing artix-keyring..."
    sudo pacman -S --noconfirm --needed artix-keyring || die "Failed to install artix-keyring"
    sudo pacman-key --populate artix || warn "pacman-key --populate artix had errors"
    ok "artix-keyring installed"
else
    skip "artix-keyring already installed"
fi

# ---------------------------------------------------------------------------
# Migrate: systemd → OpenRC + elogind
# ---------------------------------------------------------------------------

step "Migrating from systemd to OpenRC"

# Probe for Artix meta-packages — they exist on some repo snapshots but not all
info "Probing for openrc-base and base-artix meta-packages..."
OPENRC_PKG="openrc"
if pacman -Ss '^openrc-base$' 2>/dev/null | grep -q 'openrc-base'; then
    OPENRC_PKG="openrc-base"
    info "  Found openrc-base — will use as OpenRC package"
else
    info "  openrc-base not found — using plain openrc"
fi

BASE_ARTIX_ARGS=()
if pacman -Ss '^base-artix$' 2>/dev/null | grep -q 'base-artix'; then
    BASE_ARTIX_ARGS=(base-artix)
    info "  Found base-artix — will install"
else
    info "  base-artix not found — base from Artix repo will shadow Arch's automatically"
fi

info "Installing OpenRC + elogind (systemd replacement stack)..."
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
    || die "Failed to install OpenRC base stack — see output above"
ok "OpenRC stack installed"

info "Force-removing systemd (elogind satisfies virtual deps)..."
if pacman -Q systemd &>/dev/null; then
    sudo pacman -Rdd --noconfirm systemd systemd-libs systemd-sysvcompat 2>/dev/null \
        && ok "systemd removed" \
        || warn "systemd removal had non-fatal errors — continuing"
else
    skip "systemd already absent"
fi

info "Refreshing util-linux and procps-ng from Artix repo..."
sudo pacman -S --needed --noconfirm util-linux procps-ng \
    && ok "util-linux + procps-ng refreshed" \
    || warn "util-linux/procps-ng refresh had errors — may be fine if already at Artix version"

# ---------------------------------------------------------------------------
# Full system upgrade + yay
# ---------------------------------------------------------------------------

step "System upgrade and AUR helper"

info "Running full system upgrade..."
sudo pacman -Syu --noconfirm \
    && ok "System upgraded" \
    || warn "Upgrade had warnings — check output above"

if ! command -v yay &>/dev/null; then
    info "Installing yay (AUR helper)..."
    [[ -d yay-bin ]] && { warn "Stale yay-bin dir found — removing"; sudo rm -rf yay-bin; }
    git clone https://aur.archlinux.org/yay-bin.git || die "Failed to clone yay-bin"
    sudo chown -R "$USER:$USER" yay-bin
    (cd yay-bin && makepkg -si --noconfirm) || die "makepkg failed for yay-bin"
    sudo rm -rf yay-bin
    ok "yay installed"
else
    skip "yay already installed ($(yay --version 2>/dev/null | head -1))"
fi

# ---------------------------------------------------------------------------
# Main package install
# ---------------------------------------------------------------------------

step "Installing main packages"
info "This may take a while depending on your connection speed..."

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
    && ok "Main packages installed" \
    || warn "Some packages failed — check output above (non-fatal, continuing)"

# iwd: only if iwctl isn't present
if ! command -v iwctl &>/dev/null; then
    info "iwctl not found — installing iwd..."
    yay -Syu --needed --noconfirm iwd iwd-openrc \
        && ok "iwd installed" \
        || warn "iwd install failed"
else
    skip "iwd already present ($(iwctl --version 2>/dev/null || echo 'version unknown'))"
fi

# ---------------------------------------------------------------------------
# JACK conflict
# ---------------------------------------------------------------------------

step "Checking for JACK conflicts"

if pacman -Q jack2 &>/dev/null; then
    info "Conflicting jack2 found — removing..."
    sudo pacman -Rdd --noconfirm jack2 \
        && ok "jack2 removed" \
        || warn "jack2 removal failed — PipeWire-JACK may have issues"
else
    skip "jack2 not installed — no conflict"
fi

# ---------------------------------------------------------------------------
# PulseAudio removal
# ---------------------------------------------------------------------------

step "Checking for PulseAudio"

if pacman -Q | grep -qE '^pulseaudio'; then
    info "PulseAudio detected — stopping and removing..."
    rc-service pulseaudio stop 2>/dev/null \
        && info "  PulseAudio service stopped" \
        || info "  PulseAudio service was not running (fine)"
    mapfile -t pa_pkgs < <(pacman -Q | awk '{print $1}' | grep -E '^pulseaudio')
    info "  Packages to remove: ${pa_pkgs[*]}"
    sudo pacman -Rns --noconfirm "${pa_pkgs[@]}" \
        && ok "PulseAudio removed" \
        || warn "PulseAudio removal had errors — may need manual cleanup"
else
    skip "PulseAudio not installed"
fi

if ! groups "$USER" | grep -q '\baudio\b'; then
    info "Adding $USER to audio group..."
    sudo usermod -aG audio "$USER" && ok "$USER added to audio group"
else
    skip "$USER already in audio group"
fi

# ---------------------------------------------------------------------------
# OpenRC services
# ---------------------------------------------------------------------------

step "Enabling OpenRC services"

# rc_enable: skips cleanly if service file is missing
rc_enable() {
    local svc="$1" lvl="${2:-default}"
    if [[ -f /etc/openrc/init.d/$svc || -f /etc/init.d/$svc ]]; then
        if sudo rc-update add "$svc" "$lvl" 2>/dev/null; then
            ok "  Enabled: $svc @ $lvl"
        else
            skip "  $svc already in $lvl runlevel"
        fi
    else
        warn "  Service file not found for '$svc' — skipping (install may have used a different name)"
    fi
}

rc_enable udev         sysinit
rc_enable udev-trigger sysinit
rc_enable udev-settle  sysinit
rc_enable elogind      boot
rc_enable acpid        boot
rc_enable dbus         boot
rc_enable NetworkManager default
rc_enable bluetoothd   default
rc_enable tlp          default
rc_enable cronie       default
rc_enable sddm         default

# getty on tty1 — openrc-init doesn't auto-spawn TTYs like systemd does
AGETTY_SRC="/etc/openrc/init.d/agetty"
AGETTY_TTY1="/etc/openrc/init.d/agetty.tty1"
if [[ -f "$AGETTY_SRC" ]]; then
    if [[ ! -e "$AGETTY_TTY1" ]]; then
        info "Creating agetty.tty1 symlink..."
        sudo ln -sf "$AGETTY_SRC" "$AGETTY_TTY1" && ok "agetty.tty1 symlink created"
    else
        skip "agetty.tty1 symlink already exists"
    fi
    rc_enable agetty.tty1 default
else
    warn "agetty service not found at $AGETTY_SRC — TTY1 getty not configured (you may get no login prompt)"
fi

# ---------------------------------------------------------------------------
# CPU microcode
# ---------------------------------------------------------------------------

step "CPU microcode"

VENDOR=$(lscpu | awk '/Vendor ID/{print $3}')
info "Detected CPU vendor: $VENDOR"
case "$VENDOR" in
    GenuineIntel)
        sudo pacman -S --needed --noconfirm intel-ucode \
            && ok "intel-ucode installed" \
            || warn "intel-ucode install failed"
        ;;
    AuthenticAMD)
        sudo pacman -S --needed --noconfirm amd-ucode \
            && ok "amd-ucode installed" \
            || warn "amd-ucode install failed"
        ;;
    *)
        warn "Unknown CPU vendor '$VENDOR' — skipping microcode (boot may still work)"
        ;;
esac

# ---------------------------------------------------------------------------
# NVIDIA
# ---------------------------------------------------------------------------

step "GPU detection"

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
        && ok "NVIDIA drivers installed" \
        || warn "Some NVIDIA packages failed — GPU may not work correctly"
else
    skip "No NVIDIA GPU found (lspci)"
fi

# ---------------------------------------------------------------------------
# D-Bus session
# ---------------------------------------------------------------------------

step "D-Bus session"

if [[ -z "$DBUS_SESSION_BUS_ADDRESS" ]]; then
    info "No D-Bus session found — launching one..."
    eval "$(dbus-launch --sh-syntax)" 2>/dev/null \
        && ok "D-Bus session started" \
        || warn "dbus-launch failed — some config steps may not work until after first login"
else
    skip "D-Bus session already active ($DBUS_SESSION_BUS_ADDRESS)"
fi

# ---------------------------------------------------------------------------
# Strip pam_systemd
# ---------------------------------------------------------------------------

step "PAM cleanup"

PAM_FILE="/etc/pam.d/system-auth"
if [[ -f "$PAM_FILE" ]]; then
    if grep -q 'pam_systemd' "$PAM_FILE"; then
        info "Removing pam_systemd entries from $PAM_FILE..."
        sudo sed -i '/pam_systemd/d' "$PAM_FILE" && ok "pam_systemd removed"
    else
        skip "No pam_systemd entries in $PAM_FILE"
    fi
else
    skip "$PAM_FILE not found (may be named differently on your system)"
fi

# Also check login PAM
PAM_LOGIN="/etc/pam.d/login"
if [[ -f "$PAM_LOGIN" ]] && grep -q 'pam_systemd' "$PAM_LOGIN"; then
    info "Removing pam_systemd from $PAM_LOGIN..."
    sudo sed -i '/pam_systemd/d' "$PAM_LOGIN" && ok "pam_systemd removed from login"
fi

# ---------------------------------------------------------------------------
# GRUB
# ---------------------------------------------------------------------------

step "GRUB configuration"

GRUB_FILE="/etc/default/grub"
[[ -f "$GRUB_FILE" ]] || die "GRUB config not found at $GRUB_FILE — is GRUB installed?"

info "Detecting CPU model for kernel params..."
CPU_MODEL=$(lscpu | awk '/Model name/{print $3}')
info "  CPU model string: $CPU_MODEL"

case "$CPU_MODEL" in
    AMD*)
        EXTRA_PARAMS="init=/usr/bin/openrc-init amd_pstate=active mitigations=off"
        info "  Using AMD params: $EXTRA_PARAMS"
        ;;
    Intel*)
        EXTRA_PARAMS="init=/usr/bin/openrc-init intel_pstate=active mitigations=off"
        info "  Using Intel params: $EXTRA_PARAMS"
        ;;
    *)
        EXTRA_PARAMS="init=/usr/bin/openrc-init"
        warn "  Unknown CPU model — only adding init param: $EXTRA_PARAMS"
        ;;
esac

if ! grep -q 'openrc-init' "$GRUB_FILE"; then
    info "Patching GRUB_CMDLINE_LINUX_DEFAULT..."
    sudo sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"\([^\"]*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 ${EXTRA_PARAMS}\"/" "$GRUB_FILE"
    ok "GRUB cmdline updated"
    info "  New cmdline: $(grep GRUB_CMDLINE_LINUX_DEFAULT "$GRUB_FILE")"
else
    skip "openrc-init already present in GRUB_CMDLINE_LINUX_DEFAULT"
fi

# ---------------------------------------------------------------------------
# Dotfiles + config
# ---------------------------------------------------------------------------

step "Installing dotfiles and config"

# Fontconfig
mkdir -p "$HOME/.config/fontconfig"
if [[ ! -f "$HOME/.config/fontconfig/fonts.conf" ]]; then
    info "Writing fonts.conf..."
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
    ok "fonts.conf written"
else
    skip "fonts.conf already exists"
fi

# niri-edit helper script
if [[ ! -x /usr/bin/niri-edit ]]; then
    info "Installing niri-edit helper..."
    sudo tee /usr/bin/niri-edit > /dev/null <<'EOF'
#!/bin/sh
ghostty -e nvim ~/.config/niri/config.kdl
EOF
    sudo chmod +x /usr/bin/niri-edit
    ok "niri-edit installed at /usr/bin/niri-edit"
else
    skip "niri-edit already installed"
fi

# .bashrc
if [[ -f "$HOME/dotfiles/.bashrc" ]]; then
    info "Copying .bashrc from dotfiles..."
    cp -f "$HOME/dotfiles/.bashrc" "$HOME/" \
        && ok ".bashrc installed" \
        || { rm -f "$HOME/.bashrc"; cp -f "$HOME/dotfiles/.bashrc" "$HOME/" && ok ".bashrc installed (retry)"; }
else
    warn "dotfiles/.bashrc not found — skipping (your current .bashrc is untouched)"
fi

# Config directories
info "Syncing config directories..."
for dir in waybar dunst wlogout niri fuzzel fcitx5 qutebrowser; do
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

# Pictures
if [[ -d "$HOME/dotfiles/configs/Pictures" ]]; then
    cp -r "$HOME/dotfiles/configs/Pictures" "$HOME/"
    ok "Pictures copied to $HOME/"
else
    skip "No Pictures dir in dotfiles"
fi

info "Fixing ownership of $HOME..."
sudo chown -R "$USER:$USER" "$HOME" && ok "Ownership corrected"

# SDDM theme
if [[ ! -d /usr/share/sddm/themes/sddm-astronaut-theme ]]; then
    info "Installing sddm-astronaut-theme..."
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/keyitdev/sddm-astronaut-theme/master/setup.sh)" \
        && ok "SDDM theme installed" \
        || warn "SDDM theme install failed — SDDM will use default theme"
else
    skip "sddm-astronaut-theme already installed"
fi

# GTK theme
GTK_THEME_SRC="$HOME/dotfiles/configs/diinki-retro-dark"
GTK_THEME_DST="/usr/share/themes/diinki-retro-dark"
if [[ -d "$GTK_THEME_SRC" && ! -d "$GTK_THEME_DST" ]]; then
    info "Installing GTK theme diinki-retro-dark..."
    sudo mv "$GTK_THEME_SRC" /usr/share/themes/ \
        && ok "GTK theme installed" \
        || warn "GTK theme move failed"
elif [[ -d "$GTK_THEME_DST" ]]; then
    skip "diinki-retro-dark already in /usr/share/themes"
else
    warn "GTK theme source not found at $GTK_THEME_SRC — skipping"
fi

info "Setting GTK theme via gsettings..."
gsettings set org.gnome.desktop.interface gtk-theme "diinki-retro-dark" 2>/dev/null \
    && ok "GTK theme set" \
    || warn "gsettings failed — GTK theme may need to be set manually after first login"

# ---------------------------------------------------------------------------
# Optional utilities
# ---------------------------------------------------------------------------

step "Optional utilities"

utils() {
    info "Installing gaming and multimedia utilities..."

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
        && ok "Utility packages installed" \
        || warn "Some utility packages failed"

    info "Running winetricks components..."
    winetricks d3dx9 d3dcompiler_43 d3dcompiler_47 ddxv 2>/dev/null \
        && ok "winetricks components installed" \
        || warn "winetricks had errors — some Windows compatibility may be missing"

    info "Running wineboot..."
    wineboot -u 2>/dev/null && ok "wineboot done" || warn "wineboot failed (non-fatal)"

    if [[ ! -f ./advcpmv/install.sh ]]; then
        info "Installing advcpmv (advanced cp/mv with progress)..."
        curl -fsSL https://raw.githubusercontent.com/jarun/advcpmv/master/install.sh \
            --create-dirs -o ./advcpmv/install.sh \
            && (cd advcpmv && sh install.sh) \
            && ok "advcpmv installed" \
            || warn "advcpmv install failed (non-fatal)"
    else
        skip "advcpmv already downloaded"
    fi

    mkdir -p "$HOME/.config/Kvantum"
    printf '[General]\ntheme=catppuccin-frappe-mauve\n' > "$HOME/.config/Kvantum/kvantum.kvconfig"
    ok "Kvantum theme set to catppuccin-frappe-mauve"

    info "Installing flatpak apps..."
    flatpak install -y flathub org.vinegarhq.Sober   2>/dev/null && ok "  Sober installed"   || warn "  Sober flatpak failed"
    flatpak install -y flathub com.stremio.Stremio   2>/dev/null && ok "  Stremio installed" || warn "  Stremio flatpak failed"
    flatpak install -y flathub com.obsproject.Studio 2>/dev/null && ok "  OBS installed"     || warn "  OBS flatpak failed"

    mkdir -p "$HOME/.config/arti"
    if [[ ! -f "$HOME/.config/arti/arti.toml" ]]; then
        info "Writing arti.toml..."
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
        ok "arti.toml written"
    else
        skip "arti.toml already exists"
    fi

    info "Installing oh-my-bash..."
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh)" \
        && ok "oh-my-bash installed" \
        || warn "oh-my-bash install failed — bash will still work normally"
}

echo
read -rp "[INPUT] Install extra utilities (gaming, flatpaks, arti, oh-my-bash)? [Y/n] " ans
ans=${ans:-Y}
if [[ "${ans,,}" == "y" ]]; then
    utils
else
    info "Skipping optional utilities."
fi

# ---------------------------------------------------------------------------
# Finalise
# ---------------------------------------------------------------------------

step "Finalising"

info "Regenerating initramfs (mkinitcpio -P)..."
sudo mkinitcpio -P \
    && ok "initramfs regenerated" \
    || warn "mkinitcpio had errors — boot may fail, check output above"

info "Regenerating GRUB config..."
sudo grub-mkconfig -o /boot/grub/grub.cfg \
    && ok "GRUB config written to /boot/grub/grub.cfg" \
    || die "grub-mkconfig failed — do not reboot until this is fixed"

echo
echo "============================================================"
echo "  Installation complete!"
echo "  - OpenRC is configured as init (init=/usr/bin/openrc-init)"
echo "  - GRUB has been updated"
echo "  - pacman.conf backup: /etc/pacman.conf.bak"
echo "  If the system fails to boot:"
echo "    1. Boot from Arch ISO"
echo "    2. arch-chroot into your install"
echo "    3. Restore: cp /etc/pacman.conf.bak /etc/pacman.conf"
echo "============================================================"
echo
info "Rebooting in 10 seconds... Ctrl+C to cancel."
info "If shutdown hangs: Alt+PrtSc, then press R E I S U B one at a time."
sleep 10

sudo openrc-shutdown -r now 2>/dev/null || sudo reboot
