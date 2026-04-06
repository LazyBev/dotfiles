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

info "Checking internet connectivity..."
curl -fsSL --max-time 10 https://archlinux.org &>/dev/null \
    || die "No internet connection detected. Check your network and try again."
ok "Internet connectivity confirmed"

[[ -d /sys/firmware/efi ]] || warn "EFI not detected — make sure you're on the target machine, not a chroot."

# ---------------------------------------------------------------------------
# Pacman config
# ---------------------------------------------------------------------------

step "Configuring pacman"

MULTILIB_INCLUDE_FIX='/^\[multilib\]/{n;s/^#Include/Include/}'

info "Ensuring mirrorlist has active Server lines..."
if ! grep -q '^Server' /etc/pacman.d/mirrorlist 2>/dev/null; then
    sudo sed -i 's/^## \(Server = \)/\1/' /etc/pacman.d/mirrorlist
    sudo sed -i 's/^#\(Server = \)/\1/' /etc/pacman.d/mirrorlist
    if grep -q '^Server' /etc/pacman.d/mirrorlist; then
        ok "Mirrorlist Server lines uncommented"
    else
        warn "Still no Server lines — trying reflector..."
        sudo reflector --country GB --latest 10 --sort rate --save /etc/pacman.d/mirrorlist 2>/dev/null \
            && ok "reflector wrote a fresh mirrorlist" \
            || die "Could not produce a usable mirrorlist — fix it manually and re-run"
    fi
else
    skip "Mirrorlist already has active Server lines"
fi

info "Fetching clean pacman.conf from Arch upstream..."
if sudo curl -fsSL --max-time 15 \
    "https://gitlab.archlinux.org/archlinux/packaging/packages/pacman/-/raw/main/pacman.conf" \
    -o /etc/pacman.conf 2>/dev/null && grep -q '^\[options\]' /etc/pacman.conf; then
    ok "Clean pacman.conf fetched"
    sudo cp /etc/pacman.conf /etc/pacman.conf.bak
    ok "Backup written to /etc/pacman.conf.bak"
else
    warn "Could not fetch upstream pacman.conf — using existing file"
    [[ ! -f /etc/pacman.conf.bak ]] && sudo cp /etc/pacman.conf /etc/pacman.conf.bak
fi

info "Applying pacman.conf patches..."
for change in \
    "s/#Color/Color/" \
    "s/#ParallelDownloads/ParallelDownloads/" \
    "s/#\\[multilib\\]/\\[multilib\\]/" \
    "/# Misc options/a ILoveCandy"; do
    sudo sed -i "$change" /etc/pacman.conf \
        && info "  Applied: $change" \
        || warn "  Non-fatal (may already be set): $change"
done

if grep -q '^\[multilib\]' /etc/pacman.conf \
    && ! grep -A1 '^\[multilib\]' /etc/pacman.conf | grep -q '^Include'; then
    sudo sed -i "$MULTILIB_INCLUDE_FIX" /etc/pacman.conf \
        && info "  Applied: multilib Include uncomment" \
        || warn "  multilib Include may already be active"
else
    skip "multilib Include already active"
fi

info "Syncing package databases..."
sudo pacman -Sy --noconfirm || die "pacman -Sy failed"
ok "pacman.conf patched and databases synced"

# ---------------------------------------------------------------------------
# System upgrade + yay
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
    arch-install-scripts \
    blueman \
    bluez \
    bluez-utils \
    brightnessctl \
    btop \
    chafa \
    cliphist \
    cmake \
    cronie \
    curl \
    dbus \
    dconf \
    dconf-editor \
    dmenu \
    dolphin \
    dunst \
    easyeffects \
    egl-wayland \
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
    nm-connection-editor \
    noto-fonts-emoji \
    nwg-look \
    obsidian \
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
    slurp \
    stow \
    sudo \
    swayidle \
    swaylock \
    swww \
    tar \
    tlp \
    tmux \
    ttf-dejavu \
    ttf-jetbrains-mono \
    ttf-jetbrains-mono-nerd \
    ttf-liberation \
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

if ! command -v iwctl &>/dev/null; then
    info "iwctl not found — installing iwd..."
    yay -Syu --needed --noconfirm iwd \
        && ok "iwd installed" \
        || warn "iwd install failed"
else
    skip "iwd already present"
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
    systemctl --user stop pulseaudio.service pulseaudio.socket 2>/dev/null || true
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
# systemd services
# ---------------------------------------------------------------------------

step "Enabling systemd services"

sd_enable() {
    local svc="$1"
    if systemctl list-unit-files "$svc" &>/dev/null; then
        sudo systemctl enable "$svc" \
            && ok "  Enabled: $svc" \
            || warn "  Failed to enable: $svc"
    else
        warn "  Unit not found: $svc — skipping"
    fi
}

sd_enable acpid.service
sd_enable bluetooth.service
sd_enable NetworkManager.service
sd_enable tlp.service
sd_enable cronie.service
sd_enable sddm.service

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
        warn "Unknown CPU vendor '$VENDOR' — skipping microcode"
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
# GRUB
# ---------------------------------------------------------------------------

step "GRUB configuration"

GRUB_FILE="/etc/default/grub"
[[ -f "$GRUB_FILE" ]] || die "GRUB config not found at $GRUB_FILE — is GRUB installed?"

info "Detecting CPU model for kernel params..."
CPU_MODEL=$(lscpu | awk '/Model name/{print $3}')
info "  CPU model string: $CPU_MODEL"

case "$CPU_MODEL" in
    AMD*)   EXTRA_PARAMS="amd_pstate=active mitigations=off" ;;
    Intel*) EXTRA_PARAMS="intel_pstate=active mitigations=off" ;;
    *)      EXTRA_PARAMS=""; warn "  Unknown CPU model — no extra params added" ;;
esac

if [[ -n "$EXTRA_PARAMS" ]] && ! grep -q "$EXTRA_PARAMS" "$GRUB_FILE"; then
    info "Patching GRUB_CMDLINE_LINUX_DEFAULT..."
    sudo sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"\([^\"]*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 ${EXTRA_PARAMS}\"/" "$GRUB_FILE"
    ok "GRUB cmdline updated"
    info "  New cmdline: $(grep GRUB_CMDLINE_LINUX_DEFAULT "$GRUB_FILE")"
else
    skip "GRUB cmdline already up to date"
fi

# ---------------------------------------------------------------------------
# Dotfiles + config
# ---------------------------------------------------------------------------

step "Installing dotfiles and config"

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

if [[ -f "$HOME/dotfiles/.bashrc" ]]; then
    info "Copying .bashrc from dotfiles..."
    cp -f "$HOME/dotfiles/.bashrc" "$HOME/" && ok ".bashrc installed"
else
    warn "dotfiles/.bashrc not found — skipping"
fi

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

GTK_THEME_SRC="$HOME/dotfiles/configs/diinki-retro-dark"
GTK_THEME_DST="/usr/share/themes/diinki-retro-dark"
if [[ -d "$GTK_THEME_SRC" && ! -d "$GTK_THEME_DST" ]]; then
    sudo mv "$GTK_THEME_SRC" /usr/share/themes/ \
        && ok "GTK theme installed" \
        || warn "GTK theme move failed"
elif [[ -d "$GTK_THEME_DST" ]]; then
    skip "diinki-retro-dark already in /usr/share/themes"
else
    warn "GTK theme source not found at $GTK_THEME_SRC — skipping"
fi

gsettings set org.gnome.desktop.interface gtk-theme "diinki-retro-dark" 2>/dev/null \
    && ok "GTK theme set" \
    || warn "gsettings failed — set GTK theme manually after first login"

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

    winetricks d3dx9 d3dcompiler_43 d3dcompiler_47 ddxv 2>/dev/null \
        && ok "winetricks components installed" \
        || warn "winetricks had errors"

    wineboot -u 2>/dev/null && ok "wineboot done" || warn "wineboot failed (non-fatal)"

    if [[ ! -f ./advcpmv/install.sh ]]; then
        info "Installing advcpmv..."
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

    bash -c "$(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh)" \
        && ok "oh-my-bash installed" \
        || warn "oh-my-bash install failed — bash will still work normally"
}

echo
read -rp "[INPUT] Install extra utilities (gaming, flatpaks, arti, oh-my-bash)? [Y/n] " ans
ans=${ans:-Y}
[[ "${ans,,}" == "y" ]] && utils || info "Skipping optional utilities."

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
echo "  - systemd is the init system"
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

sudo reboot
