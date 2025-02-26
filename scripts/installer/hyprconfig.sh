#!/bin/bash

# Get the directory of the current script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source helper file
source $SCRIPT_DIR/helper.sh

log_message "Installation started for prerequisites section"
print_info "\nStarting prerequisites setup..."

sudo pacman -Syyu --noconfirm

if sudo pacman -S --noconfirm --needed git base-devel; then # 
    git clone https://aur.archlinux.org/yay-bin.git && sudo chown $USER:$USER -R yay-bin
    cd yay-bin && makepkg --noconfirm -si && cd .. && rm -rf yay-bin
fi

sudo pacman -S --sudoloop --noconfirm yay -S nerd-fonts-git ttf-cascadia-code-nerd ttf-cascadia-mono-nerd ttf-fira-code ttf-fira-mono ttf-fira-sans ttf-firacode-nerd ttf-iosevka-nerd ttf-iosevkaterm-nerd ttf-jetbrains-mono-nerd ttf-jetbrains-mono ttf-nerd-fonts-symbols ttf-nerd-fonts-symbols ttf-nerd-fonts-symbols-mono 
sudo pacman -S --sudoloop --noconfirm pipewire pipewire-alsa pipewire-pulse alsa-utils wireplumber pamixer brightnessctl ghostty firefox-bin sddm firefox-bin tar neovim && systemctl enable sddm.service
useradd -d /var/run/pulse -s /usr/bin/nologin -G audio pulse
groupadd pulse-access
usermod -aG pulse-access $USER

echo tee /etc/asound.conf <<ASOUND
defaults.pcm.card 0
defaults.ctl.card 0
ASOUND

sh -c "$(curl -fsSL https://raw.githubusercontent.com/keyitdev/sddm-astronaut-theme/master/setup.sh)"


echo "------------------------------------------------------------------------"
