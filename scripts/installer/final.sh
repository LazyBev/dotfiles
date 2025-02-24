#!/bin/bash

# Get the directory of the current script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source helper file
source $SCRIPT_DIR/helper.sh

run_command "yay -Syu"
yay -Syu --needed --noconfirm \
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

if lspci | grep -i nvidia &> /dev/null; then
    yay -Syu --needed \
        nvidia-dkms \
        nvidia-utils \
        nvidia-settings \
        nvidia-prime \
        lib32-nvidia-utils \
        xf86-video-nouveau \
        opencl-nvidia \
        lib32-opencl-nvidia
fi

log_message "Final setup script started"
print_bold_blue "\nCongratulations! Your Simple Hyprland setup is complete!"

print_bold_blue "\nRepository Information:"
echo "   - GitHub Repository: https://github.com/gaurav210233/simple-hyprland"
echo "   - If you found this repo helpful, please consider giving it a star on GitHub!"

print_bold_blue "\nContribute:"
echo "   - Feel free to open issues, submit pull requests, or provide feedback."
echo "   - Every contribution, big or small, is valuable to the community."

print_bold_blue "\nTroubleshooting:"
echo "   - If you encounter any issues, please check the GitHub issues section."
echo "   - Don't hesitate to open a new issue if you can't find a solution to your problem."

print_success "\nEnjoy your new Hyprland environment!"

echo "------------------------------------------------------------------------"
