#!/bin/bash

# Get the directory of the current script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source helper file
source $SCRIPT_DIR/helper.sh

log_message "Installation started for utilities section"
print_info "\nStarting utilities setup..."

run_command "pacman -S --noconfirm waybar" "Install Waybar - Status Bar" "yes"

run_command "yay -S --sudoloop --noconfirm Rofi" "Install Rofi - Application Launcher" "yes" "no"

run_command "pacman -S --noconfirm cliphist" "Install Cliphist - Clipboard Manager" "yes"

run_command "yay -S --sudoloop --noconfirm swww" "Install SWWW for wallpaper management" "yes" "no"

run_command "yay -S --sudoloop --noconfirm hyprpicker" "Install Hyprpicker - Color Picker" "yes" "no"

run_command "yay -S --sudoloop --noconfirm hyprlock" "Install Hyprlock - Screen Locker (Must)" "yes" "no"

run_command "yay -S --sudoloop --noconfirm wlogout" "Install Wlogout - Session Manager" "yes" "no"

run_command "yay -S --sudoloop --noconfirm grimblast python" "Install Grimblast - Screenshot tool" "yes" "no"

run_command "yay -S --sudoloop --noconfirm hypridle" "Install Hypridle for idle management (Must)" "yes" "no"

run_command "tempdir=$PWD; git clone https://github.com/hpjansson/chafa.git; cd chafa && ./autogen.sh; make && sudo make install; cd $HOME && python -m venv yt " "Install mov-cli (youtube in the terminal)" "yes" "no"

if [ -d tempdir ]; then
    cd $HOME && python -m venv yt
    bash -c "source yt/bin/activate; pip install lxml; pip install mov-cli -U; pip install mov-cli-youtube;"
    cd $tempdir
fi

run_command "git clone https://gitlab.torproject.org/tpo/core/arti.git; cd arti; cargo build -p arti --release; sudo mv -f /target/release/arti /usr/bin; cd .. && rm -rf arti" "Install arti - tor in rust" "yes" "no"

if command -v arti; then
    if ! -d $HOME/.config/arti; then
        mkdir $HOME/.config/arti
    fi
    sudo tee $HOME/.config/arti/arti-config.toml <<ART
[network]
socks_port = 9050
ART
fi

echo "------------------------------------------------------------------------"
