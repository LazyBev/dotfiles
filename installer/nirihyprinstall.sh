#!/bin/bash

bash -c "~/bev-dotfiles/installer/niriinstall.sh"

yay -S \
    aquamarine \
    hyprland \
    hyprland-protocols \
    hyprpaper \
    hyprpicker \
    hyprshot \
    hyprcursor \
    hyprlock \
    hyprcontrib \
    hyprsome \
    hyprland-per-window-layout \
    hyprlang \
    hyprpm \
    pyprland \
    waybar \
    eww \
    nautilus \
    wlogout \
    swayidle \
    swaylock-effects \
    grim \
    slurp \
    wl-clipboard \
    wtype \
    xdg-desktop-portal-hyprland \
    polkit-kde-agent \
    swappy \
    wdisplays \
    pamixer \
    pavucontrol \
    playerctl \
    brightnessctl \
    nwg-look \
    qt5ct \
    qt6ct \
    kvantum \
    btop \
    waybar-module-pacman-updates \
    network-manager-applet \
    wlr-randr \
    wev \
    gnome-keyring \
    xdg-utils \
    cliphist

  sudo cp -rf "$HOME/bev-dotfiles/config/hypr" "$HOME/.config/"
