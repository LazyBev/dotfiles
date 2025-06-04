#!/bin/bash

set -e

# Get the directory of the current script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source helper file
source "$SCRIPT_DIR/helper.sh"

# Trap for unexpected exits
trap 'trap_message' INT TERM

# Source helper file
source "$SCRIPT_DIR/helper.sh"

# Trap for unexpected exits
trap 'trap_message' INT TERM

echo -e "\n------------------------------------------------------------------------\n"

bash -c "~/dotfiles/installer/install.sh"

yay -Syu aquamarine hyprland hyprland-protocols hyprpaper hyprpicker hyprshot hyprcursor hyprlock hyprcontrib hyprsome hyprland-per-window-layout hyprlang hyprpm pyprland waybar eww nautilus wlogout
yay -Syu swayidle swaylock-effects grim slurp wl-clipboard wtype xdg-desktop-portal-hyprland polkit-kde-agent swappy wdisplays pamixer pavucontrol playerctl brightnessctl nwg-look qt5ct qt6ct kvantum
yay -Syu btop waybar-module-pacman-updates network-manager-applet wlr-randr wev gnome-keyring xdg-utils cliphist

  sudo cp -rf "$HOME/bev-dotfiles/config/hypr" "$HOME/.config/"
