#!/bin/bash

# Get the directory of the current script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source helper file
source $SCRIPT_DIR/helper.sh

log_message "Installation started for hypr section"
print_info "\nStarting hypr setup..."
print_info "\nEverything is recommended to INSTALL"

run_command "pacman -S --noconfirm hyprland" "Install Hyprland (Must)" "yes"

run_command "pacman -S --noconfirm xdg-desktop-portal-hyprland" "Install XDG desktop portal for Hyprland" "yes"

run_command "pacman -S --noconfirm polkit-kde-agent" "Install KDE Polkit agent for authentication dialogs" "yes"

run_command "pacman -S --noconfirm dunst" "Install Dunst notification daemon" "yes"

run_command "yay (bunch of hypr packages)" "Install a full hypr system" "yes"
yay -Syu --needed \
    aquamarine \
    imagemagick \
    hyprutils \
    ags \
    hyprcursor \
    hyprwayland-scanner \
    hyprgraphics \
    qt5-wayland \
    qt6-wayland \
    hyprlang \
    hyprland-protocols \
    hyprland-qt-support \
    hyprland-qtutils \
    hyprland \
    hyprlock \
    hypridle \
    xdg-desktop-portal \
    xdg-desktop-portal-hyprland \
    xdg-desktop-portal-gtk \
    polkit \
    hyprpolkitagent \
    pyprland \
    dmenu \
    rofi \
    waybar \
    swaync \
    cmake \
    wayland-protocols \
    xorg-xwayland \
    wlroots \
    wayland \
    ranger \
    hyprpaper \
    waypaper \
    swww \
    mako \
    ghostty \
    wdisplays \
    grim \
    slurp \
    pavucontrol \
    python \
    pipewire \
    pipewire-alsa \
    pipewire-pulse \
    pipewire-jack \
    alsa-utils \
    libinput \
    libevdev \
    libxkbcommon \
    kwayland \
    wlr-randr \
    wlr-swaybg \
    steam-native-runtime \
    mangohud \
    sddm \
    gvfs \
    thunar \
    thunar-archive-plugin \
    stow \
    iwd \
    networkmanager \
    nm-connection-editor \
    network-manager-applet \
    zsh \
    tlp \
    stremio \
    fastfetch \
    cargo \
    spotify \
    ttf-dejavu \
    ttf-liberation \
    ttf-joypixels \
    ttf-meslo-nerd \
    tmux \
    blueman \
    bluez \
    bluez-utils \
    steam \
    flatpak \
    discord \
    wine \
    winetricks \
    neovim \
    lua \
    libva-nvidia-driver \
    ripgrep \
    librewolf-bin \
    acpi \
    git \
    hwinfo \
    arch-install-scripts \
    wireless_tools \
    curl \
    make \
    meson \
    obsidian \
    man-db \
    man-pages \
    xdotool \
    wget \
    qutebrowser \
    zip \
    unzip \
    mpv \
    btop \
    xarchiver \
    eza \
    fzf \
    mesa \
    vulkan-mesa-layers \
    lib32-vulkan-mesa-layers

if lspci | grep -i nvidia > /dev/null; then
    yay -S --needed \
        nvidia-dkms \
        nvidia-utils \
        nvidia-settings \
        nvidia-prime \
        lib32-nvidia-utils \
        xf86-video-nouveau \
        opencl-nvidia \
        lib32-opencl-nvidia \
fi

echo "------------------------------------------------------------------------"
