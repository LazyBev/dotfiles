#!/bin/bash

set -e

# ─────────────────────────────────────────────
# System update
# ─────────────────────────────────────────────
sudo pacman -Syu --noconfirm

# ─────────────────────────────────────────────
# Base system (Artix)
# ─────────────────────────────────────────────
sudo pacman -S --noconfirm \
    base-devel git curl wget unzip zip \
    networkmanager network-manager-applet \
    bluez bluez-utils blueman \
    elogind dbus sudo

# ─────────────────────────────────────────────
# Enable OpenRC services
# ─────────────────────────────────────────────
sudo rc-update add dbus default
sudo rc-update add elogind default
sudo rc-update add NetworkManager default

sudo rc-service dbus start
sudo rc-service elogind start
sudo rc-service NetworkManager start

# ─────────────────────────────────────────────
# Install yay
# ─────────────────────────────────────────────
if ! command -v yay &> /dev/null; then
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg -si --noconfirm
    cd ..
    rm -rf yay
fi

# ─────────────────────────────────────────────
# Niri + Wayland
# ─────────────────────────────────────────────
yay -S --noconfirm \
    niri \
    waybar \
    fuzzel \
    wl-clipboard \
    grim slurp \
    xdg-desktop-portal xdg-desktop-portal-gtk \
    polkit polkit-kde-agent

# ─────────────────────────────────────────────
# Audio
# ─────────────────────────────────────────────
yay -S --noconfirm \
    pipewire pipewire-pulse wireplumber \
    pavucontrol alsa-utils

# ─────────────────────────────────────────────
# Terminal + tools
# ─────────────────────────────────────────────
yay -S --noconfirm \
    kitty \
    neovim tmux \
    btop fastfetch \
    fzf ripgrep eza

# ─────────────────────────────────────────────
# Fonts
# ─────────────────────────────────────────────
yay -S --noconfirm \
    ttf-jetbrains-mono \
    noto-fonts noto-fonts-emoji

# ─────────────────────────────────────────────
# Zen Browser (binary)
# ─────────────────────────────────────────────
yay -S --noconfirm zen-browser-bin
echo 'export MOZ_ENABLE_WAYLAND=1' >> ~/.bashrc

# ─────────────────────────────────────────────
# CPU microcode
# ─────────────────────────────────────────────
VENDOR_ID=$(lscpu | awk '/Vendor ID/ {print $3}')

if [[ "$VENDOR_ID" == "GenuineIntel" ]]; then
    sudo pacman -S --noconfirm intel-ucode
elif [[ "$VENDOR_ID" == "AuthenticAMD" ]]; then
    sudo pacman -S --noconfirm amd-ucode
else
    echo "Unknown CPU vendor: $VENDOR_ID"
    exit 1
fi

# ─────────────────────────────────────────────
# NVIDIA
# ─────────────────────────────────────────────
if lspci | grep -i nvidia &>/dev/null; then
    yay -S --noconfirm --needed \
        nvidia-dkms nvidia-utils nvidia-settings nvidia-prime \
        egl-wayland
fi

# ─────────────────────────────────────────────
# D-Bus session safety
# ─────────────────────────────────────────────
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
    eval $(dbus-launch --sh-syntax) || sudo rc-service dbus start
fi

# ─────────────────────────────────────────────
# Display manager
# ─────────────────────────────────────────────
yay -S --noconfirm sddm
sudo rc-update add sddm boot

# ─────────────────────────────────────────────
# Config setup
# ─────────────────────────────────────────────
mkdir -p ~/.config/fontconfig

cat > "$HOME/.config/fontconfig/fonts.conf" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <alias>
    <family>sans-serif</family>
    <prefer>
      <family>Noto Sans</family>
      <family>Noto Color Emoji</family>
    </prefer>
  </alias>
</fontconfig>
EOF

# Doom Emacs
git clone --depth 1 https://github.com/doomemacs/doomemacs ~/.emacs.d
~/.emacs.d/bin/doom install
~/.emacs.d/bin/doom sync
~/.emacs.d/bin/doom doctor

# Dotfiles
cp -f "$HOME/dotfiles/.bashrc" "$HOME/"

CONFIG_DIRS=("waybar" "dunst" "wlogout" "niri" "fuzzel" "fcitx5" "doom" "qutebrowser")
for dir in "${CONFIG_DIRS[@]}"; do
    rm -rf "$HOME/.config/$dir"
    cp -r "$HOME/dotfiles/configs/$dir" "$HOME/.config/"
done

cp -f -r "$HOME/dotfiles/.emacs" "$HOME/"
sudo chown -R "$USER:$USER" "$HOME"

# Pictures (one-liner)
mkdir -p ~/Pictures && cp -rn ~/dotfiles/pictures/* ~/Pictures/ 2>/dev/null || true

# SDDM theme
sh -c "$(curl -fsSL https://raw.githubusercontent.com/keyitdev/sddm-astronaut-theme/master/setup.sh)"

# GTK theme
sudo mv "$HOME/dotfiles/configs/diinki-retro-dark" /usr/share/themes
gsettings set org.gnome.desktop.interface gtk-theme "diinki-retro-dark"

# ─────────────────────────────────────────────
# GRUB
# ─────────────────────────────────────────────
GRUB_FILE="/etc/default/grub"

if [[ "$VENDOR_ID" == "AuthenticAMD" ]]; then
    sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\([^"]*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 amd_pstate=active mitigations=off"/' "$GRUB_FILE"
elif [[ "$VENDOR_ID" == "GenuineIntel" ]]; then
    sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\([^"]*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 intel_pstate=active mitigations=off"/' "$GRUB_FILE"
fi

# ─────────────────────────────────────────────
# Final
# ─────────────────────────────────────────────
sudo mkinitcpio -P
sudo reboot