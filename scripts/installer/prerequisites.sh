#!/bin/bash

# Get the directory of the current script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source helper file
source $SCRIPT_DIR/helper.sh

log_message "Installation started for prerequisites section"
print_info "\nStarting prerequisites setup..."

run_command "sudo pacman -Syyu --noconfirm" "Update package database and upgrade packages (Recommended)" "yes" # no

if run_command "sudo pacman -S --noconfirm --needed git base-devel" "Install YAY (Must)/Breaks the script" "yes"; then # 
    git clone https://aur.archlinux.org/yay-bin.git && sudo chown $user:$user -R yay-bin
    cd yay-bin && makepkg --noconfirm -si && cd .. && rm -rf yay-bin
fi
run_command "sudo pacman -S --noconfirm pipewire wireplumber pamixer brightnessctl" "Configuring audio and brightness (Recommended)" "yes" 

run_command "sudo pacman -S --noconfirm yay -S nerd-fonts-git ttf-cascadia-code-nerd ttf-cascadia-mono-nerd ttf-fira-code ttf-fira-mono ttf-fira-sans ttf-firacode-nerd ttf-iosevka-nerd ttf-iosevkaterm-nerd ttf-jetbrains-mono-nerd ttf-jetbrains-mono ttf-nerd-fonts-symbols ttf-nerd-fonts-symbols ttf-nerd-fonts-symbols-mono" "Installing Nerd Fonts and Symbols (Recommended)" "yes" 

run_command "sudo pacman -S --noconfirm sddm && systemctl enable sddm.service" "Install and enable SDDM (Recommended)" "yes"

read -p "Do you want to install sddm themes (true/false)" sddm_themes 

if $sddm_themes == true; then
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/keyitdev/sddm-astronaut-theme/master/setup.sh)"
fi

run_command "yay -S --sudoloop --noconfirm firefox-bin" "Install firefox" "yes" "no" 

run_command "sudo pacman -S --noconfirm kitty" "Install Kitty (Recommended)" "yes"

run_command "sudo pacman -S --noconfirm neovim" "Install neovim" "yes"

run_command "sudo pacman -S --noconfirm tar" "Install tar for extracting files (Must)/needed for copying themes" "yes"

echo "------------------------------------------------------------------------"
