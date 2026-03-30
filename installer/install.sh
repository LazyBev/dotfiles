#!/bin/bash
set -e

# Update system
sudo pacman -Syu --noconfirm

# Core packages
sudo pacman -S --noconfirm \
    sway swaybg swaylock swayidle \
    waybar \
    foot \
    wofi \
    wl-clipboard \
    grim slurp \
    xdg-desktop-portal-wlr \
    networkmanager \
    elogind dbus \
    pipewire pipewire-pulse wireplumber \
    pavucontrol alsa-utils \
    thunar \
    firefox \
    ttf-dejavu noto-fonts noto-fonts-emoji

# Enable services (Artix OpenRC)
sudo rc-update add dbus default
sudo rc-update add elogind default
sudo rc-update add NetworkManager default

sudo rc-service dbus start
sudo rc-service elogind start
sudo rc-service NetworkManager start

# Basic Sway config
mkdir -p ~/.config/sway

cat > ~/.config/sway/config <<'EOF'
set $mod Mod4
set $term foot
set $menu wofi --show drun

# Launch terminal
bindsym $mod+Return exec $term

# Launcher
bindsym $mod+d exec $menu

# Kill window
bindsym $mod+Shift+q kill

# Exit sway
bindsym $mod+Shift+e exec "swaymsg exit"

# Reload config
bindsym $mod+Shift+c reload

# Focus movement
bindsym $mod+h focus left
bindsym $mod+j focus down
bindsym $mod+k focus up
bindsym $mod+l focus right

# Basic gaps
gaps inner 5
gaps outer 10

# Start bar
exec waybar
EOF

echo ""
echo "✅ Done!"
echo ""
echo "Start Sway with:"
echo "  sway"
echo ""