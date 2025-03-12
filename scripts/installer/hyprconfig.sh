#!/bin/bash

# Get the directory of the current script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source helper file
source $SCRIPT_DIR/helper.sh

# Trap for unexpected exits
trap 'trap_message' INT TERM

# Script start
log_message "Installation started"
print_bold_blue "\nSimple Hyprland"

echo -e "\n------------------------------------------------------------------------\n"

log_message "Installation started for prerequisites section"
print_info "\nStarting prerequisites setup..."

sudo pacman -Syyu --noconfirm

if sudo pacman -Sy --noconfirm --needed git base-devel; then # 
    git clone https://aur.archlinux.org/yay-bin.git && sudo chown $USER:$USER -R yay-bin
    cd yay-bin && makepkg --noconfirm -si && cd .. && rm -rf yay-bin
fi

sudo pacman -Rdd --noconfirm jack2

yay -Syu --needed --sudoloop --noconfirm \
    acpi \
    adobe-source-han-sans-jp-fonts \
    ags \
    alsa-utils \
    arch-install-scripts \
    aquamarine \
    bluez \
    bluez-utils \
    blueman \
    brightnessctl \
    btop \
    cargo \
    cliphist \
    cmake \
    curl \
    dbus \
    discord \
    dmenu \
    eza \
    fastfetch \
    firefox-bin \
    flatpak \
    fzf \
    ghostty \
    git \
    grim \
    grimblast \
    gvfs \
    hwinfo \
    hyprcursor \
    hyprgraphics \
    hypridle \
    hyprlang \
    hyprland \
    hyprland-protocols \
    hyprland-qt-support \
    hyprland-qtutils \
    hyprlock \
    hyprpaper \
    hyprpicker \
    hyprpolkitagent \
    hyprutils \
    hyprwayland-scanner \
    imagemagick \
    iwd \
    kwayland \
    lib32-alsa-plugins \
    lib32-libpulse \
    lib32-pulseaudio \
    lib32-vulkan-mesa-layers \
    libevdev \
    libinput \
    librewolf-bin \
    libva-nvidia-driver \
    libxkbcommon \
    make \
    mako \
    man-db \
    man-pages \
    mangohud \
    mesa \
    meson \
    mpv \
    neovim \
    network-manager-applet \
    networkmanager \
    nm-connection-editor \
    obsidian \
    pam_rundir \
    pamixer \
    pavucontrol \
    polkit \
    polkit-kde-agent \
    pulseaudio \
    pulseaudio-alsa \
    pulseaudio-bluetooth \
    pulseaudio-equalizer \
    pulseaudio-equalizer-ladspa \
    pulseaudio-jack \
    pulseaudio-lirc \
    pulseaudio-rtp \
    pyprland \
    python \
    qutebrowser \
    ranger \
    ripgrep \
    rofi \
    sddm \
    slurp \
    spotify \
    stow \
    stremio \
    sudo \
    swaync \
    swww \
    tar \
    thunar \
    thunar-archive-plugin \
    tlp \
    tmux \
    ttf-dejavu \
    ttf-fira-code \
    ttf-fira-mono \
    ttf-fira-sans \
    ttf-jetbrains-mono \
    ttf-joypixels \
    ttf-liberation \
    ttf-meslo-nerd \
    ttf-fira-code-nerd \
    ttf-jetbrains-mono-nerd \
    ttf-hack-nerd \
    ttf-source-code-pro-nerd \
    ttf-roboto-mono-nerd \
    unzip \
    vulkan-mesa-layers \
    waybar \
    wayland \
    wayland-protocols \
    waypaper \
    wget \
    wdisplays \
    wine \
    winetricks \
    wireless_tools \
    wlroots \
    wlr-randr \
    xarchiver \
    xdg-desktop-portal \
    xdg-desktop-portal-gtk \
    xdg-desktop-portal-hyprland \
    xdotool \
    xorg-xwayland \
    yay \
    zip \
    zsh \
    fcitx5-im \
    fcitx5-gtk \
    fcitx5-qt \
    fcitx5-anthy \

if lspci | grep -i nvidia &> /dev/null; then
    yay -Syu --needed \
        nvidia-beta-dkms \
        nvidia-utils-beta \
        nvidia-settings \
        nvidia-prime \
        xf86-video-nouveau \
        opencl-nvidia \
        lib32-opencl-nvidia \
        lib32-nvidia-utils-beta \
        libva-nvidia-driver \
        nvidia-hook \
        nvidia-inst
fi

curl -sL --proto-redir -all,https https://raw.githubusercontent.com/zplug/installer/master/installer.zsh | zsh

yay -S --noconfirm zsh-theme-powerlevel10k-git
echo 'source /usr/share/zsh-theme-powerlevel10k/powerlevel10k.zsh-theme' >>~/.zshrc

sudo chsh -s /usr/bin/zsh
zsh -c "p10k configure"

XDG_RUNTIME_DIR=/run/user/$(id -u)

# Ensure D-Bus is running
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
    eval $(dbus-launch --sh-syntax) || systemctl --user start dbus
fi

sudo systemctl enable sddm.service || echo "Cant enable sddm.service"

echo "Installing PipeWire and dependencies..."
sudo pacman -Syu --noconfirm pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber gst-plugin-pipewire helvum pavucontrol

# Check if PulseAudio is installed
if pacman -Q pulseaudio &>/dev/null; then
    echo "PulseAudio detected! Checking if it's active..."

    if systemctl --user is-active --quiet pulseaudio.service || systemctl --user is-active --quiet pulseaudio.socket; then
        echo "PulseAudio is running. Stopping and disabling it..."
        systemctl --user disable --now pulseaudio.service pulseaudio.socket
    fi

    echo "Removing PulseAudio and related packages..."
    sudo pacman -Rns --noconfirm pulseaudio pulseaudio-alsa pulseaudio-bluetooth
else
    echo "PulseAudio is not installed. Skipping removal."
fi

# Enable PipeWire services if not already enabled
echo "Enabling PipeWire systemd services..."
systemctl --user enable --now pipewire.service
systemctl --user enable --now pipewire-pulse.service
systemctl --user enable --now wireplumber.service

# Check if user is in 'audio' group (optional for JACK)
if ! groups | grep -q audio; then
    echo "Adding user to 'audio' group..."
    sudo usermod -aG audio $USER
fi

# Restart user session to apply changes
echo "Restarting PipeWire services..."
systemctl --user restart pipewire pipewire-pulse wireplumber

echo -e "\n------------------------------------------------------------------------\n"

log_message "Installation started for utilities section"
print_info "\nStarting utilities setup..."

tempdir=$PWD; git clone https://github.com/hpjansson/chafa.git; cd chafa && ./autogen.sh; make && sudo make install; cd $HOME && python -m venv yt 

if [ -d tempdir ]; then
    cd $HOME && python -m venv yt
    bash -c "source yt/bin/activate; pip install lxml; pip install mov-cli -U; pip install mov-cli-youtube;"
    cd $tempdir
    cp -r $HOME/simple-hyprland/configs/mov-cli $HOME/.config/
fi

git clone https://gitlab.torproject.org/tpo/core/arti.git; cd arti; cargo build -p arti --release; sudo mv -f /target/release/arti /usr/bin; cd .. && rm -rf arti

if command -v arti; then
    if ! -d $HOME/.config/arti; then
        mkdir $HOME/.config/arti
    fi
    sudo tee $HOME/.config/arti/arti-config.toml <<ART
[network]
socks_port = 9050
ART
fi

echo -e "\n------------------------------------------------------------------------\n"

log_message "Installation started for theming section"
print_info "\nStarting theming setup..."

yay -Sy --sudoloop --noconfirm kvantum-theme-catppuccin-git nwg-look qt5ct qt6ct kvantum

tar -xvf $HOME/simple-hyprland/assets/themes/Catppuccin-Mocha.tar.xz -C /usr/share/themes/

tar -xvf $HOME/simple-hyprland/assets/icons/Tela-circle-dracula.tar.xz -C /usr/share/icons/

sh -c "$(curl -fsSL https://raw.githubusercontent.com/keyitdev/sddm-astronaut-theme/master/setup.sh)"

echo -e "\n------------------------------------------------------------------------\n"

log_message "Installation started for Hyprland section"
print_info "\nStarting config setup..."
print_info "\nEverything is recommended to change"

# Define an array of config directories to copy
CONFIG_DIRS=("waybar" "rofi" "wlogout" "hypr" "zsh" "swaync" "dunst" "nvim" "mov-cli")

# Loop through and copy each config directory
for dir in "${CONFIG_DIRS[@]}"; do
    if [ -d $HOME/.config/dir ]; then 
        sudo rm -rf $HOME/.config/$dir
    fi

    sudo cp -f -r $HOME/simple-hyprland/configs/$dir $HOME/.config/
done

# Copy Pictures directory silently
sudo cp -f -r "$HOME/simple-hyprland/configs/Pictures" "$HOME" &> /dev/null

echo -e "\n------------------------------------------------------------------------\n"
