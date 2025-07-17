#!/bin/bash

set -e

# Get the directory of the current script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source helper file
source "$SCRIPT_DIR/helper.sh"

# Trap for unexpected exits
trap 'trap_message' INT TERM 

# Get the directory of the current script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source helper file
source "$SCRIPT_DIR/helper.sh"

# Trap for unexpected exits
trap 'trap_message' INT TERM

echo -e "\n------------------------------------------------------------------------\n"
print_info "\nStarting utilities setup..."

# Install flatpak and Sober
yay -Syu --noconfirm arti flatpak wine lutris winegui winetricks protonplus yabridge fl-studio-integrator spotify ardour waydroid

curl https://raw.githubusercontent.com/jarun/advcpmv/master/install.sh --create-dirs -o ./advcpmv/install.sh && (cd advcpmv && sh install.sh)

mkdir -p ~/.config/Kvantum/ && touch ~/.config/Kvantum/kvantum.kvconfig
echo '[General]\ntheme=catppuccin-frappe-mauve' > ~/.config/Kvantum/kvantum.kvconfig

# flatpak install flathub com.valvesoftware.Steam
flatpak install flathub org.vinegarhq.Sober
flatpak install flathub com.stremio.Stremio
flatpak install flathub io.github.equicord.equibop
flatpak install flathub com.usebottles.bottles
flatpak install flathub com.github.tchx84.Flatseal
flatpak install flathub com.obsproject.Studio

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

echo -e "\n------------------------------------------------------------------------\n"
