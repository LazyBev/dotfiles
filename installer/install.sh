#!/bin/bash

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/helper.sh"

trap 'trap_message' INT TERM

# ─────────────────────────────────────────────
# pacman.conf
# ─────────────────────────────────────────────

declare -a pacman_conf=(
    "s/#Color/Color/"
    "s/#ParallelDownloads/ParallelDownloads/"
    "s/#\\[multilib\\]/\\[multilib\\]/"
    "s/#Include = \\/etc\\/pacman\\.d\\/mirrorlist/Include = \\/etc\\/pacman\\.d\\/mirrorlist/"
    "/# Misc options/a ILoveCandy"
)

echo "Backing up /etc/pacman.conf"
sudo cp /etc/pacman.conf /etc/pacman.conf.bak || { echo "Failed to back up pacman.conf"; exit 1; }

echo "Modifying /etc/pacman.conf"
for change in "${pacman_conf[@]}"; do
    sudo sed -i "$change" /etc/pacman.conf || { echo "Failed to update pacman.conf"; exit 1; }
done

# ─────────────────────────────────────────────
# Prerequisites
# ─────────────────────────────────────────────

print_bold_blue "\nBev's dotfiles"
echo -e "\n------------------------------------------------------------------------\n"
print_info "\nStarting prerequisites setup..."

sudo pacman -Syu --noconfirm

if ! command -v yay &> /dev/null; then
    sudo git clone https://aur.archlinux.org/yay-bin.git
    sudo chown "$USER:$USER" -R yay-bin
    cd yay-bin && makepkg -si && cd .. && sudo rm -rf yay-bin
fi

yay -Syu --noconfirm \
    acpi alsa-utils artix-install-scripts blueman bluez bluez-utils \
    brightnessctl btop chafa cliphist cmake curl dbus dconf dconf-editor \
    dmenu dolphin dunst emacs eza fastfetch fcitx5-anthy fcitx5-gtk fcitx5-im \
    fcitx5-qt firedragon-bin floorp-bin fuzzel fzf ghostty git gvfs hwinfo \
    imagemagick iw kvantum kvantum-theme-catppuccin-git kitty kwayland \
    lib32-alsa-plugins lib32-vulkan-mesa-layers libevdev libinput \
    libxkbcommon make man-db man-pages mesa meson mpv neovim networkmanager \
    network-manager-applet nm-connection-editor noto-fonts-emoji nwg-look obsidian \
    pam_rundir pamixer pavucontrol playerctl polkit polkit-kde-agent python python-pip \
    python-pipx qt5ct qt6ct qutebrowser ranger ripgrep sddm-openrc slurp stow sudo swayidle \
    swaylock swww tar tlp tmux ttf-jetbrains-mono ttf-jetbrains-mono-nerd ttf-dejavu \
    ttf-liberation unzip vulkan-mesa-layers waybar wayland wayland-protocols wayland-utils \
    waypaper wev wf-recorder wget wl-clipboard wlr-randr xarchiver xbindkeys \
    xdg-desktop-portal xdg-desktop-portal-gtk xdotool xf86-input-libinput xorg-xev xwayland \
    xwayland-run xwayland-satellite yt-dlp ytfzf zip zram-generator

if ! command -v iwctl &> /dev/null; then
    yay -Syu --noconfirm iwd
fi

sudo rc-update add NetworkManager default

# ─────────────────────────────────────────────
# PipeWire / PulseAudio
# ─────────────────────────────────────────────

if pacman -Q jack2 &>/dev/null; then
    sudo pacman -Rdd --noconfirm jack2
fi

echo "Installing PipeWire and dependencies..."
yay -Syu --noconfirm \
    alsa-utils alsa-plugins alsa-firmware alsa-tools ffmpeg \
    pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber \
    gst-plugins-good gst-plugins-bad gst-plugin-pipewire gst-libav \
    helvum pavucontrol qpwgraph easyeffects \
    libwireplumber lib32-libpipewire lib32-pipewire lib32-pipewire-jack \
    lib32-pipewire-v4l2 libpipewire pipewire-v4l2 \
    qemu-audio-pipewire wireplumber-docs

if pacman -Q | grep -E '^pulseaudio' &>/dev/null; then
    echo "PulseAudio detected. Stopping and removing..."

    if rc-service pulseaudio status &>/dev/null 2>&1; then
        rc-service pulseaudio stop
        rc-update del pulseaudio
    fi

    packages=$(pacman -Q | awk '{print $1}' | grep -E '^pulseaudio')
    if [[ -n "$packages" ]]; then
        sudo pacman -Rns --noconfirm $packages
    fi
else
    echo "PulseAudio not installed. Skipping."
fi

if ! groups | grep -q audio; then
    echo "Adding $USER to 'audio' group..."
    sudo usermod -aG audio "$USER"
fi

# ─────────────────────────────────────────────
# CPU microcode
# ─────────────────────────────────────────────

VENDOR_ID=$(lscpu | awk '/Vendor ID/ {print $3}')

if [[ "$VENDOR_ID" == "GenuineIntel" ]]; then
    echo "Intel CPU detected. Installing intel-ucode..."
    sudo pacman -S --noconfirm intel-ucode
elif [[ "$VENDOR_ID" == "AuthenticAMD" ]]; then
    echo "AMD CPU detected. Installing amd-ucode..."
    sudo pacman -S --noconfirm amd-ucode
else
    echo "Unknown CPU vendor: $VENDOR_ID"
    exit 1
fi

# ─────────────────────────────────────────────
# NVIDIA (if present)
# ─────────────────────────────────────────────

#if lspci | grep -i nvidia &>/dev/null; then
    echo "NVIDIA GPU detected. Installing drivers..."
    yay -Syu --needed --sudoloop --noconfirm \
        nvidia-dkms nvidia-utils nvidia-settings nvidia-prime \
        xf86-video-nouveau opencl-nvidia lib32-opencl-nvidia lib32-nvidia-utils \
        libva-nvidia-driver nvidia-hook nvidia-inst egl-wayland \
        vulkan-mesa-layers lib32-vulkan-mesa-layers

    # Note: nvidia-persistenced uses OpenRC on Artix — enable via rc-update if service exists
#    if rc-update show | grep -q nvidia-persistenced; then
#        sudo rc-update add nvidia-persistenced default
#    fi
fi

# ─────────────────────────────────────────────
# D-Bus / SDDM
# ─────────────────────────────────────────────

XDG_RUNTIME_DIR=/run/user/$(id -u)

if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
    eval $(dbus-launch --sh-syntax) || rc-service dbus start
fi

sudo rc-update add sddm boot || echo "Could not enable sddm"

# ─────────────────────────────────────────────
# Config setup
# ─────────────────────────────────────────────

echo -e "\n------------------------------------------------------------------------\n"
print_info "\nStarting config setup..."

mkdir -p ~/.config/fontconfig
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

git clone --depth 1 https://github.com/doomemacs/doomemacs ~/.emacs.d
~/.emacs.d/bin/doom install
~/.emacs.d/bin/doom sync
~/.emacs.d/bin/doom doctor

cp -f "$HOME/dotfiles/.bashrc" "$HOME/"

CONFIG_DIRS=("waybar" "dunst" "wlogout" "niri" "fuzzel" "fcitx5" "doom" "qutebrowser")
for dir in "${CONFIG_DIRS[@]}"; do
    rm -rf "$HOME/.config/$dir"
    cp -r "$HOME/dotfiles/configs/$dir" "$HOME/.config/"
done

cp -f -r "$HOME/dotfiles/.emacs" "$HOME/"

sudo chown -R "$USER:$USER" "$HOME"

cp -r "$HOME/dotfiles/configs/Pictures" "$HOME/" &>/dev/null || true

sh -c "$(curl -fsSL https://raw.githubusercontent.com/keyitdev/sddm-astronaut-theme/master/setup.sh)"

sudo mv "$HOME/dotfiles/configs/diinki-retro-dark" /usr/share/themes
gsettings set org.gnome.desktop.interface gtk-theme "diinki-retro-dark"

# ─────────────────────────────────────────────
# GRUB kernel parameters
# ─────────────────────────────────────────────

GRUB_FILE="/etc/default/grub"

# Re-use the same vendor check from earlier
if [[ "$VENDOR_ID" == "AuthenticAMD" ]]; then
    echo "Configuring GRUB for AMD..."
    sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\([^"]*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 amd_pstate=active mitigations=off"/' "$GRUB_FILE"
elif [[ "$VENDOR_ID" == "GenuineIntel" ]]; then
    echo "Configuring GRUB for Intel..."
    sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\([^"]*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 intel_pstate=active mitigations=off"/' "$GRUB_FILE"
fi

# ─────────────────────────────────────────────
# Optional utilities
# ─────────────────────────────────────────────

echo -e "\n------------------------------------------------------------------------\n"

utils() {
    print_info "\nStarting utilities setup..."

    yay -Syu --noconfirm \
        arti flatpak wine lutris winetricks protonplus spotify \
        ardour wine-staging millennium steam

    winetricks d3dx9 d3dcompiler_43 d3dcompiler_47 dxvk
    wineboot -u

    curl https://raw.githubusercontent.com/jarun/advcpmv/master/install.sh \
        --create-dirs -o ./advcpmv/install.sh && (cd advcpmv && sh install.sh)

    mkdir -p ~/.config/Kvantum
    printf '[General]\ntheme=catppuccin-frappe-mauve\n' > ~/.config/Kvantum/kvantum.kvconfig

    flatpak install -y flathub org.vinegarhq.Sober
    flatpak install -y flathub com.stremio.Stremio
    flatpak install -y flathub io.github.equicord.equibop
    flatpak install -y flathub com.usebottles.bottles
    flatpak install -y flathub com.obsproject.Studio

    mkdir -p "$HOME/.config/arti"
    cat > "$HOME/.config/arti/arti.toml" <<'EOF'
# Arti Configuration File

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
EOF

    bash -c "$(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh)"

    echo -e "\n------------------------------------------------------------------------\n"
}

read -rp "Install extra utilities? (Y/n) " ans
ans=${ans:-Y}

if [[ "$ans" =~ ^[Yy]$ ]]; then
    utils
else
    echo "Skipping utils installation."
fi

# ─────────────────────────────────────────────
# Finalise
# ─────────────────────────────────────────────

sudo mkinitcpio -P && sudo reboot
