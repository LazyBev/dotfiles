#!/bin/bash

set -e

run() {
    read -p "Run: $* ? (y/n): " choice
    case "$choice" in
        y|Y ) eval "$*" ;;
        * ) echo "Skipped: $*" ;;
    esac
}

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
run "source \"$SCRIPT_DIR/helper.sh\""

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
run "sudo cp /etc/pacman.conf /etc/pacman.conf.bak || { echo 'Failed to back up pacman.conf'; exit 1; }"

echo "Modifying /etc/pacman.conf"
for change in "${pacman_conf[@]}"; do
    run "sudo sed -i \"$change\" /etc/pacman.conf || { echo 'Failed'; exit 1; }"
done

# ─────────────────────────────────────────────
# Prerequisites
# ─────────────────────────────────────────────

print_bold_blue "\nBev's dotfiles"
echo -e "\n------------------------------------------------------------------------\n"
print_info "\nStarting prerequisites setup..."

run "sudo pacman -Syu"

if ! command -v yay &> /dev/null; then
    run "sudo git clone https://aur.archlinux.org/yay-bin.git"
    run "sudo chown \"$USER:$USER\" -R yay-bin"
    run "cd yay-bin && makepkg -si && cd .. && sudo rm -rf yay-bin"
fi

run "yay -Syu \
    acpi alsa-utils blueman bluez bluez-utils \
    brightnessctl btop chafa cmake curl \
    dbus dbus-openrc dconf dconf-editor \
    dolphin dunst emacs eza fastfetch \
    fuzzel fzf ghostty git gvfs hwinfo \
    imagemagick iw \
    kvantum kvantum-theme-catppuccin-git \
    kitty kwayland \
    lib32-alsa-plugins lib32-vulkan-mesa-layers \
    libevdev libinput libxkbcommon \
    make man-db man-pages mesa meson mpv neovim \
    networkmanager networkmanager-openrc \
    network-manager-applet nm-connection-editor \
    noto-fonts-emoji nwg-look obsidian \
    pam_rundir pamixer pavucontrol playerctl \
    polkit polkit-kde-agent \
    python python-pip python-pipx \
    qt5ct qt6ct qutebrowser ranger ripgrep \
    sddm-openrc slurp stow sudo swayidle swaylock swww \
    tar tlp tmux \
    ttf-jetbrains-mono ttf-jetbrains-mono-nerd ttf-dejavu ttf-liberation \
    unzip vulkan-mesa-layers \
    waybar wayland wayland-protocols wayland-utils \
    wev wf-recorder wget wl-clipboard wlr-randr \
    xarchiver xbindkeys xdg-desktop-portal xdg-desktop-portal-gtk \
    xdotool xorg-xev xorg-xwayland \
    yt-dlp ytfzf zip"

if ! command -v iwctl &> /dev/null; then
    run "yay -Syu iwd"
fi

run "sudo rc-update add NetworkManager default"
run "sudo rc-service NetworkManager start"

# ─────────────────────────────────────────────
# PipeWire
# ─────────────────────────────────────────────

if pacman -Q jack2 &>/dev/null; then
    run "sudo pacman -Rdd jack2"
fi

run "yay -Syu \
    alsa-utils alsa-plugins alsa-firmware alsa-tools ffmpeg \
    pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber \
    gst-plugins-good gst-plugins-bad gst-plugin-pipewire gst-libav \
    helvum pavucontrol qpwgraph easyeffects \
    libwireplumber lib32-libpipewire lib32-pipewire lib32-pipewire-jack \
    libpipewire pipewire-v4l2"

run "sudo rc-update add dbus default"
run "sudo rc-update add pipewire default"
run "sudo rc-update add wireplumber default"

# ─────────────────────────────────────────────
# CPU microcode
# ─────────────────────────────────────────────

VENDOR_ID=$(lscpu | awk '/Vendor ID/ {print $3}')

if [[ "$VENDOR_ID" == "GenuineIntel" ]]; then
    run "sudo pacman -S intel-ucode"
elif [[ "$VENDOR_ID" == "AuthenticAMD" ]]; then
    run "sudo pacman -S amd-ucode"
else
    echo "Unknown CPU vendor: $VENDOR_ID"
    exit 1
fi

# ─────────────────────────────────────────────
# NVIDIA (fixed detection)
# ─────────────────────────────────────────────

if lspci | grep -i nvidia &>/dev/null; then
    run "yay -Syu --needed \
        nvidia-dkms nvidia-utils nvidia-settings nvidia-prime \
        lib32-nvidia-utils egl-wayland"
fi

# ─────────────────────────────────────────────
# D-Bus / SDDM
# ─────────────────────────────────────────────

if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
    run "eval \$(dbus-launch --sh-syntax) || rc-service dbus start"
fi

run "sudo rc-update add sddm boot"

# ─────────────────────────────────────────────
# Config setup
# ─────────────────────────────────────────────

run "mkdir -p ~/.config/fontconfig"

if run "echo 'Write fonts.conf'"; then
cat > "$HOME/.config/fontconfig/fonts.conf" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <alias>
    <family>sans-serif</family>
    <prefer>
      <family>Noto Sans</family>
      <family>Noto Color Emoji</family>
    </prefer>
  </alias>
</fontconfig>
EOF
fi

run "git clone --depth 1 https://github.com/doomemacs/doomemacs ~/.emacs.d"
run "~/.emacs.d/bin/doom install"
run "~/.emacs.d/bin/doom sync"
run "~/.emacs.d/bin/doom doctor"

run "cp -f \"$HOME/dotfiles/.bashrc\" \"$HOME/\""

CONFIG_DIRS=("waybar" "dunst" "wlogout" "niri" "fuzzel" "fcitx5" "doom" "qutebrowser")
for dir in "${CONFIG_DIRS[@]}"; do
    run "rm -rf \"$HOME/.config/$dir\""
    run "cp -r \"$HOME/dotfiles/configs/$dir\" \"$HOME/.config/\""
done

run "cp -f -r \"$HOME/dotfiles/.emacs\" \"$HOME/\""
run "sudo chown -R \"$USER:$USER\" \"$HOME\""

run "sh -c \"\$(curl -fsSL https://raw.githubusercontent.com/keyitdev/sddm-astronaut-theme/master/setup.sh)\""

run "sudo mv \"$HOME/dotfiles/configs/diinki-retro-dark\" /usr/share/themes"
run "gsettings set org.gnome.desktop.interface gtk-theme \"diinki-retro-dark\""

# ─────────────────────────────────────────────
# GRUB
# ─────────────────────────────────────────────

GRUB_FILE="/etc/default/grub"

if [[ "$VENDOR_ID" == "AuthenticAMD" ]]; then
    run "sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=\"\\([^\"]*\\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\\1 amd_pstate=active mitigations=off\"/' \"$GRUB_FILE\""
elif [[ "$VENDOR_ID" == "GenuineIntel" ]]; then
    run "sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=\"\\([^\"]*\\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\\1 intel_pstate=active mitigations=off\"/' \"$GRUB_FILE\""
fi

# ─────────────────────────────────────────────
# Final
# ─────────────────────────────────────────────

run "sudo mkinitcpio -P && sudo reboot"