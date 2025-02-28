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
echo "---------------"

# Check if OS is Arch Linux
check_os

# Define an array of config directories to copy
SCRIPTS_DIRS=("hyprconfig.sh""hypr.sh" "utilities.sh" "theming.sh" "config.sh" "final.sh")

# Loop through and make scripts executable
for scr in "${SCRIPTS_DIRS[@]}"; do
    chmod +x $HOME/simple-hyprland/scripts/installer/$scr
done

# Refactor pacman.conf update
declare -a pacman_conf=(
    "s/#Color/Color/"
    "s/#ParallelDownloads/ParallelDownloads/"
    "s/#\\[multilib\\]/\\[multilib\\]/"
    "s/#Include = \\/etc\\/pacman\\.d\\/mirrorlist/Include = \\/etc\\/pacman\\.d\\/mirrorlist/"
    "/# Misc options/a ILoveCandy"
)

# Backup the pacman.conf before modifying
echo "Backing up /etc/pacman.conf"
sudo cp /etc/pacman.conf /etc/pacman.conf.bak || { echo "Failed to back up pacman.conf"; exit 1;}

echo "Modifying /etc/pacman.conf"
for change in "${pacman_conf[@]}"; do
    sudo sed -i "$change" /etc/pacman.conf || { echo "Failed to update pacman.conf"; exit 1; }
done

# Run child scripts
run_script "hyprconfig.sh" "Whole Install Script"
#run_script "prerequisites.sh" "Prerequisites Setup"
#run_script "hypr.sh" "Hyprland & Critical Softwares Setup"
#run_script "utilities.sh" "Basic Utilities & Configs Setup"
#run_script "theming.sh" "Themes and Tools Setup"
#run script "config.sh" "Config Setup"
#run_script "final.sh" "Final Setup"

print_bold_blue "\n🌟 Setup Complete\n"
log_message "Installation completed successfully"
