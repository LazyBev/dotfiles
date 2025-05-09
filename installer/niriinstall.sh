#!/bin/bash

set -e

# Get the directory of the current script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source helper file
source "$SCRIPT_DIR/helper.sh"

# Trap for unexpected exits
trap 'trap_message' INT TERM

sh -c "$(curl -fsSL https://raw.githubusercontent.com/keyitdev/sddm-astronaut-theme/master/setup.sh)"

touch ~/.config/Kvantum/kvantum.kvconfig
echo '[General]\ntheme=catppuccin-frappe-mauve' > ~/.config/Kvantum/kvantum.kvconfig

echo -e "\n------------------------------------------------------------------------\n"
print_info "\nStarting config setup..."
print_info "\nEverything is recommended to change"

mkdir -p "$HOME/.config/arti" && cat > "$HOME/.config/arti/arti.toml" <<EOF
# Arti Configuration File
# Created on May 1, 2025

# Basic application behavior
[application]
watch_configuration = true
permit_debugging = false
allow_running_as_root = false

# SOCKS proxy setup
[proxy]
socks_listen = 9150  # Standard Tor Browser port

# Configure logging
[logging]
console = "info"
log_sensitive_information = false
time_granularity = "1s"

# Files for storing stuff on disk
[storage]
cache_dir = "${ARTI_CACHE}"
state_dir = "${ARTI_LOCAL_DATA}"

[storage.permissions]
dangerously_trust_everyone = false
trust_user = ":current"
trust_group = ":username"

# Circuit configuration for better anonymity
[path_rules]
ipv4_subnet_family_prefix = 16
ipv6_subnet_family_prefix = 32
reachable_addrs = ["*:80", "*:443"]  # Common ports for better connectivity
long_lived_ports = [22, 80, 443, 6667, 8300]

# Preemptive circuit settings for better performance
[preemptive_circuits]
disable_at_threshold = 8
initial_predicted_ports = [80, 443]
prediction_lifetime = "30 mins"
min_exit_circs_for_port = 2

# Channel padding for enhanced security
[channel]
padding = "normal"

# Circuit timing settings
[circuit_timing]
max_dirtiness = "10 minutes"
request_timeout = "30 sec"
request_max_retries = 8
request_loyalty = "50 msec"

# Address filtering
[address_filter]
allow_local_addrs = false
allow_onion_addrs = true

# Stream timeout configuration
[stream_timeouts]
connect_timeout = "15 sec"
resolve_timeout = "10 sec"
resolve_ptr_timeout = "10 sec"

# System resource configuration
[system]
max_files = 8192

[vanguards]
mode = "lite"
EOF

# Define an array of config directories to copy
CONFIG_DIRS=("waybar" "dunst" "wlogout" "niri" "mov-cli" "fuzzel" "fcitx5")

sudo cp -f "$HOME/bev-dotfiles/.bashrc" "$HOME/" || {
    sudo rm -f "$HOME/.bashrc"
    sudo cp -f "$HOME/bev-dotfiles/.bashrc" "$HOME/"
} 

if sudo rm -rf "/root/.config/mov-cli"; then
    sudo cp -f -r "$HOME/bev-dotfiles/configs/mov-cli" "/root/.config/"
else
    sudo cp -f -r "$HOME/bev-dotfiles/configs/mov-cli" "/root/.config/"
fi

# Loop through and copy each config directory
for dir in "${CONFIG_DIRS[@]}"; do
    if [ -d "$HOME/.config/$dir" ]; then 
        sudo rm -rf "$HOME/.config/$dir"
    fi

    sudo cp -f -r "$HOME/bev-dotfiles/configs/$dir" "$HOME/.config/"
done

# Define an array of emacs directories to copy
EMACS_DIRS=(".emacs.local" ".emacs.rc")

sudo cp -f -r "$HOME/bev-dotfiles/.emacs" "$HOME/"

# Loop through and copy each emacs directory
for dir in "${EMACS_DIRS[@]}"; do
    if [ -d "$HOME/$dir" ]; then 
        sudo rm -rf "$HOME/$dir"
    fi

    sudo cp -f -r "$HOME/bev-dotfiles/$dir" "$HOME/"
done

sudo find "$HOME/.config" -type d -exec chmod 755 {} +
sudo find "$HOME/.config" -type f -exec chmod 755 {} +

# Copy Pictures directory silently
sudo cp -f -r "$HOME/bev-dotfiles/configs/Pictures" "$HOME/" &> /dev/null

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
