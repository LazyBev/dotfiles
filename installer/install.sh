#!/bin/bash

set -e

# Get the directory of the current script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source helper file
source "$SCRIPT_DIR/helper.sh"

# Trap for unexpected exits
trap 'trap_message' INT TERM 

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

# Get the directory of the current script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source helper file
source "$SCRIPT_DIR/helper.sh"

# Trap for unexpected exits
trap 'trap_message' INT TERM

# Script start
print_bold_blue "\nBev's dotfiles"

echo -e "\n------------------------------------------------------------------------\n"
print_info "\nStarting prerequisites setup..."

sudo pacman -Syu --noconfirm

if ! command -v yay &> /dev/null; then
    sudo git clone https://aur.archlinux.org/yay-bin.git
    sudo chown "$USER:$USER" -R yay-bin
    cd yay-bin && makepkg -si && cd .. && sudo rm -rf yay-bin
fi

yay -Syu --noconfirm acpi adobe-source-han-sans-cn-fonts adobe-source-han-sans-jp-fonts adobe-source-han-sans-kr-fonts alsa-utils arch-install-scripts acpi blueman bluez bluez-utils brightnessctl btop chafa 
yay -Syu --noconfirm cliphist cmake curl dbus dconf-editor dconf dmenu dolphin dunst emacs eza fastfetch fcitx5-anthy fcitx5-gtk fcitx5-im fcitx5-qt firedragon-bin floorp-bin fuzzel fzf ghostty git gvfs hwinfo
yay -Syu --noconfirm imagemagick kvantum kvantum-theme-catppuccin-git kitty kwayland lib32-alsa-plugins lib32-vulkan-mesa-layers libevdev libinput libxkbcommon make man-db man-pages mesa meson mov-cli mpv neovim
yay -Syu --noconfirm network-manager-applet noto-fonts-emoji nwg-look obsidian pam_rundir networkmanager niri nm-connection-editor pamixer pavucontrol playerctl polkit polkit-kde-agent python python-pip python-pipx
yay -Syu --noconfirm qt5ct qt6ct qutebrowser ranger ripgrep sddm sddm slurp stow sudo swayidle swaylock swww tar themix-full-git tlp tmux ttf-dejavu ttf-fira-code ttf-fira-mono ttf-fira-sans ttf-hack-nerd
yay -Syu --noconfirm ttf-jetbrains-mono ttf-jetbrains-mono-nerd ttf-joypixels ttf-liberation ttf-material-design-iconic-font ttf-meslo-nerd ttf-roboto-mono-nerd unzip vulkan-mesa-layers waybar wayland wayland-protocols 
yay -Syu --noconfirm wayland-utils waypaper wev wf-recorder wget wireless_tools wlr-randr wlroots xarchiver xbindkeys xdg-desktop-portal xdg-desktop-portal-gtk xdg-desktop-portal-gnome xdotool xf86-input-libinput
yay -Syu --noconfirm xorg-xev xorg-xwayland xwayland xwayland-run xwayland-satellite ytfzf zip zram-generator
    
if ! command -v iwctl &> /dev/null; then
    yay -Syu --noconfirm iwd
fi

if pacman -Q jack2 &>/dev/null; then
    sudo pacman -Rdd --noconfirm jack2
fi

sudo systemctl enable --now NetworkManager

echo "Installing PipeWire and dependencies..."
yay -Syu --noconfirm alsa-utils alsa-plugins alsa-firmware alsa-tools ffmpeg pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber gst-plugins-good gst-plugins-bad gst-plugin-pipewire 
yay -Syu --noconfirm gst-libav helvum pavucontrol qpwgraph easyeffects libwireplumber lib32-libpipewire lib32-pipewire lib32-pipewire-jack lib32-pipewire-v4l2 libpipewire pipewire-v4l2 
yay -Syu --noconfirm qemu-audio-pipewire wireplumber-docs

# Check if PulseAudio is installed
if pacman -Q | grep -E '^pulseaudio' &>/dev/null; then
    echo "PulseAudio detected! Checking if it's active..."

    if systemctl is-active --quiet pulseaudio.service || systemctl --user is-active --quiet pulseaudio.socket; then
        echo "PulseAudio is running. Stopping and disabling it..."
        systemctl disable --now pulseaudio.service pulseaudio.socket
    fi

    echo "Finding and removing all PulseAudio-related packages..."
    packages=$(pacman -Q | awk '{print $1}' | grep -E '^pulseaudio')

    if [[ -n "$packages" ]]; then
        sudo pacman -Rns --noconfirm "$packages"
    else
        echo "No PulseAudio packages found to remove."
    fi
else
    echo "PulseAudio is not installed. Skipping removal."
fi

# Check if user is in 'audio' group (optional for JACK)
if ! groups | grep -q audio; then
    echo "Adding user to 'audio' group..."
    sudo usermod -aG audio "$USER"
fi 

# Detect CPU vendor
VENDOR=$(lscpu | grep "Vendor ID" | awk '{print $3}')

if [[ "$VENDOR" == "GenuineIntel" ]]; then
    echo "Detected Intel CPU. Installing intel-ucode..."
    sudo pacman -S --noconfirm intel-ucode
elif [[ "$VENDOR" == "AuthenticAMD" ]]; then
    echo "Detected AMD CPU. Installing amd-ucode..."
    sudo pacman -S --noconfirm amd-ucode
else
    echo "Unknown CPU vendor: $VENDOR"
    exit 1
fi

if lspci | grep -i nvidia &> /dev/null; then
    yay -Syu --needed --sudoloop --noconfirm nvidia-dkms nvidia-utils nvidia-settings nvidia-prime xf86-video-nouveau opencl-nvidia lib32-opencl-nvidia lib32-nvidia-utils libva-nvidia-driver
    yay -Syu --needed --sudoloop --noconfirm nvidia-hook nvidia-inst libva-nvidia-driver egl-wayland vulkan-mesa-layers lib32-vulkan-mesa-layers
        
: <<'NOT_NEEDED'
# Get NVIDIA vendor ID
NVIDIA_VENDOR="0x$(lspci -nn | grep -i nvidia | sed -n 's/.*\[\([0-9A-Fa-f]\+\):[0-9A-Fa-f]\+\].*/\1/p' | head -n 1)"
        
# Create udev rules for NVIDIA power management
echo "# Enable runtime PM for NVIDIA VGA/3D controller devices on driver bind
ACTION==\"bind\", SUBSYSTEM==\"pci\", ATTR{vendor}==\"$NVIDIA_VENDOR\", ATTR{class}==\"0x030000\", TEST==\"power/control\", ATTR{power/control}=\"auto\"
ACTION==\"bind\", SUBSYSTEM==\"pci\", ATTR{vendor}==\"$NVIDIA_VENDOR\", ATTR{class}==\"0x030200\", TEST==\"power/control\", ATTR{power/control}=\"auto\"

# Disable runtime PM for NVIDIA VGA/3D controller devices on driver unbind
ACTION==\"unbind\", SUBSYSTEM==\"pci\", ATTR{vendor}==\"$NVIDIA_VENDOR\", ATTR{class}==\"0x030000\", TEST==\"power/control\", ATTR{power/control}=\"on\"
ACTION==\"unbind\", SUBSYSTEM==\"pci\", ATTR{vendor}==\"$NVIDIA_VENDOR\", ATTR{class}==\"0x030200\", TEST==\"power/control\", ATTR{power/control}=\"on\"

# Enable runtime PM for NVIDIA VGA/3D controller devices on adding device
ACTION==\"add\", SUBSYSTEM==\"pci\", ATTR{vendor}==\"$NVIDIA_VENDOR\", ATTR{class}==\"0x030000\", TEST==\"power/control\", ATTR{power/control}=\"auto\"
ACTION==\"add\", SUBSYSTEM==\"pci\", ATTR{vendor}==\"$NVIDIA_VENDOR\", ATTR{class}==\"0x030200\", TEST==\"power/control\", ATTR{power/control}=\"auto\"" | envsubst | sudo tee /etc/udev/rules.d/80-nvidia-pm.rules > /dev/null

# Set NVIDIA kernel module options
echo "options nvidia NVreg_UsePageAttributeTable=1
options nvidia_drm modeset=1 fbdev=1
options nvidia NVreg_RegistryDwords="PerfLevelSrc=0x2222"
options nvidia NVreg_EnablePCIeGen3=1 NVreg_EnableMSI=1" | sudo tee /etc/modprobe.d/nvidia.conf > /dev/null
    
# Desired modules
MODULES=("nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm")

MODPROBE_CONF="/etc/mkinitcpio.conf"
    
# Check if MODULES line exists
if sudo grep -q "^MODULES=" "$MODPROBE_CONF"; then
    # Extract current modules
    CURRENT_MODULES=$(grep "^MODULES=" "$MODPROBE_CONF" | sed -E 's/MODULES=\((.*)\)/\1/')
    
    for mod in "${MODULES[@]}"; do
        if ! echo "$CURRENT_MODULES" | grep -qw "$mod"; then
            CURRENT_MODULES="$CURRENT_MODULES $mod"
        fi
    done

    # Update MODULES line
    sudo sed -i "s|^MODULES=.*|MODULES=($CURRENT_MODULES)|" "$MODPROBE_CONF"
else
    # Add MODULES line if not present
    echo "MODULES=(${MODULES[*]})" | sudo tee -a "$MODPROBE_CONF" > /dev/null
fi
        
# Enable and start NVIDIA persistence daemon
sudo systemctl enable nvidia-persistenced.service
        
# Regenerate initramfs
sudo mkinitcpio -P
        
# Apply udev rules immediately
sudo udevadm control --reload-rules && sudo udevadm trigger
NOT_NEEDED
        
fi

XDG_RUNTIME_DIR=/run/user/$(id -u)

# Ensure D-Bus is running
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
    eval $(dbus-launch --sh-syntax) || systemctl --user start dbus
fi

sudo systemctl enable sddm.service || echo "Cant enable sddm.service"

echo -e "\n------------------------------------------------------------------------\n"
print_info "\nStarting config setup..."
print_info "\nEverything is recommended to change"

# Define an array of config directories to copy
CONFIG_DIRS=("waybar" "dunst" "wlogout" "niri" "fuzzel" "fcitx5")

sudo cp -f "$HOME/dotfiles/.bashrc" "$HOME/" || {
    sudo rm -f "$HOME/.bashrc"
    sudo cp -f "$HOME/dotfiles/.bashrc" "$HOME/"
} 

# Loop through and copy each config directory
for dir in "${CONFIG_DIRS[@]}"; do
    if [ -d "$HOME/.config/$dir" ]; then 
        sudo rm -rf "$HOME/.config/$dir"
    fi

    sudo cp -f -r "$HOME/dotfiles/configs/$dir" "$HOME/.config/"
done

# Define an array of emacs directories to copy
EMACS_DIRS=(".emacs.local" ".emacs.rc")

sudo cp -f -r "$HOME/dotfiles/.emacs" "$HOME/"

# Loop through and copy each emacs directory
for dir in "${EMACS_DIRS[@]}"; do
    if [ -d "$HOME/$dir" ]; then 
        sudo rm -rf "$HOME/$dir"
    fi

    sudo cp -f -r "$HOME/dotfiles/$dir" "$HOME/"
done

sudo chown -R $USER:$USER $HOME

sudo cp -f -r "$HOME/dotfiles/configs/Pictures" "$HOME/" &> /dev/null

sh -c "$(curl -fsSL https://raw.githubusercontent.com/keyitdev/sddm-astronaut-theme/master/setup.sh)"

sudo mv "$HOME/dotfiles/configs/diinki-retro-dark" /usr/share/themes

gsettings set org.gnome.desktop.interface gtk-theme "diinki-retro-dark"

# Automatically determine CPU brand (AMD or Intel)
CPU_VENDOR=$(lscpu | grep "Model name" | awk '{print $3}')
echo "Detected CPU vendor: $CPU_VENDOR"

# Add relevant kernel parameters to GRUB based on the CPU vendor
GRUB_FILE="/etc/default/grub"
if [[ "$CPU_VENDOR" == "AMD" ]]; then
    echo "Configuring GRUB for AMD (amd_pstate=active and mitigations=off)..."
    sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\([^"]*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 amd_pstate=active mitigations=off"/' "$GRUB_FILE"
elif [[ "$CPU_VENDOR" == "Intel" ]]; then
    echo "Configuring GRUB for Intel (intel_pstate=active and mitigations=off)..."
    sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\([^"]*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 intel_pstate=active mitigations=off"/' "$GRUB_FILE"
else
    echo "Unknown CPU vendor. No specific configurations applied."
fi

bash -c "$(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh)" && reboot

echo -e "\n------------------------------------------------------------------------\n"
