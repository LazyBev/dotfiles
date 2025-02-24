#!/bin/bash

# Get the directory of the current script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source helper file
source $SCRIPT_DIR/helper.sh

log_message "Installation started for utilities section"
print_info "\nStarting utilities setup..."

run_command "pacman -S --noconfirm waybar" "Install Waybar - Status Bar" "yes"
run_command "cp -r $HOME/simple-hyprland/configs/waybar $HOME/.config/" "Copy Waybar config" "yes" "no"

run_command "yay -S --sudoloop --noconfirm Rofi" "Install Rofi - Application Launcher" "yes" "no"
run_command "cp -r $HOME/simple-hyprland/configs/rofi $HOME/.config/" "Copy Rofi config(s)" "yes" "no"

run_command "pacman -S --noconfirm cliphist" "Install Cliphist - Clipboard Manager" "yes"

run_command "yay -S --sudoloop --noconfirm swww" "Install SWWW for wallpaper management" "yes" "no"
run_command "mkdir -p $HOME/.config/assets/backgrounds && cp -r $HOME/simple-hyprland/assets/backgrounds $HOME/.config/assets/" "Copy sample wallpapers to assets directory (Recommended)" "yes" "no"

run_command "yay -S --sudoloop --noconfirm hyprpicker" "Install Hyprpicker - Color Picker" "yes" "no"

run_command "yay -S --sudoloop --noconfirm hyprlock" "Install Hyprlock - Screen Locker (Must)" "yes" "no"
run_command "cp -r $HOME/simple-hyprland/configs/hypr/hyprlock.conf $HOME/.config/hypr/" "Copy Hyprlock config" "yes" "no"

run_command "yay -S --sudoloop --noconfirm wlogout" "Install Wlogout - Session Manager" "yes" "no"
run_command "cp -r $HOME/simple-hyprland/configs/wlogout $HOME/.config/ && cp -r $HOME/simple-hyprland/assets/wlogout $HOME/.config/assets/" "Copy Wlogout config and assets" "yes" "no"

run_command "yay -S --sudoloop --noconfirm grimblast" "Install Grimblast - Screenshot tool" "yes" "no"

run_command "yay -S --sudoloop --noconfirm hypridle" "Install Hypridle for idle management (Must)" "yes" "no"
run_command "cp -r $HOME/simple-hyprland/configs/hypr/hypridle.conf $HOME/.config/hypr/" "Copy Hypridle config" "yes" "no"

run_command "git clone https://gitlab.torproject.org/tpo/core/arti.git; cd arti; cargo build -p arti --release; sudo mv -f /target/release/arti /usr/bin; cd .. && rm -rf arti" "Install arti - tor in rust" "yes" "no"

echo "------------------------------------------------------------------------"
