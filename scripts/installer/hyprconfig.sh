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

yay -Syu --needed --noconfirm \
    aquamarine \
    imagemagick \
    hyprutils \
    polkit-kde-agent \
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
    dbus \
    cliphist \
    zip \
    hyprpicker \
    unzip \
    mpv \
    btop \
    xarchiver \
    eza \
    fzf \
    mesa \
    vulkan-mesa-layers \
    lib32-vulkan-mesa-layers

curl -sL --proto-redir -all,https https://raw.githubusercontent.com/zplug/installer/master/installer.zsh | zsh

yay -S --noconfirm zsh-theme-powerlevel10k-git
echo 'source /usr/share/zsh-theme-powerlevel10k/powerlevel10k.zsh-theme' >>~/.zshrc

sudo pacman -Sy --sudoloop --noconfirm yay -S nerd-fonts-git ttf-cascadia-code-nerd ttf-cascadia-mono-nerd ttf-fira-code ttf-fira-mono ttf-fira-sans ttf-firacode-nerd ttf-iosevka-nerd ttf-iosevkaterm-nerd ttf-jetbrains-mono-nerd ttf-jetbrains-mono ttf-nerd-fonts-symbols ttf-nerd-fonts-symbols ttf-nerd-fonts-symbols-mono 
sudo pacman -Sy --sudoloop --noconfirm pipewire pipewire-alsa pipewire-pulse alsa-utils lib32-libpulse lib32-alsa-plugins wireplumber pamixer brightnessctl ghostty firefox-bin sddm firefox-bin tar neovim pam_rundir

XDG_RUNTIME_DIR=/run/user/$(id -u)
export $(dbus-launch)

sudo systemctl enable sddm.service || echo "Cant enable sddm.service"

useradd -d /var/run/pulse -s /usr/bin/nologin -G audio pulse
groupadd pulse-access
usermod -aG pulse-access $USER

sudo tee /etc/asound.conf <<ASOUND
defaults.pcm.card 0
defaults.ctl.card 0
ASOUND

sudo sed -i "/load-module module-suspend-on-idle/c\# load-module module-suspend-on-idle" /etc/pulse/default.pa

if [ ! -d /etc/mplayer ]; then
    sudo mkdir /etc/mplayer
    if [ -f /etc/mplayer/mplayer.conf ]; then
        sudo tee /etc/mplayer/mplayer.conf <<MPV
ao=pulse
MPV
    else
        sudo tee -a /etc/mplayer/mplayer.conf <<MPV
ao=pulse
MPV
    fi
fi

sudo tee /etc/systemd/system/pulseaudio.service <<PSER
[Unit]
Description=Sound Service
 
[Service]
# Note that notify will only work if --daemonize=no
Type=notify
ExecStart=/usr/bin/pulseaudio --daemonize=no --exit-idle-time=-1 --disallow-exit=true --system --disallow-module-loading
Restart=always
 
[Install]
WantedBy=default.target
PSER

sudo tee ~/.config/pulse/default.pa <<DPA
### Load the integrated PulseAudio equalizer and D-Bus module
load-module module-equalizer-sink
load-module module-dbus-protocol
DPA

sudo systemctl --user enable pulseaudio.service
sudo systemctl --user start pulseaudio.service

echo -e "\n------------------------------------------------------------------------\n"

log_message "Installation started for utilities section"
print_info "\nStarting utilities setup..."

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
CONFIG_DIRS=("waybar" "rofi" "wlogout" "hypr" "zsh" "swaync" "dunst" "kitty" "nvim" "mov-cli")

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

sudo chsh -s /usr/bin/zsh
zsh -c "p10k configure"
