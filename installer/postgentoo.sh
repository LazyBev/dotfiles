#!/bin/bash
set -e

# =============================================================================
# GENTOO POST-INSTALL SCRIPT (run after first reboot as your user)
# =============================================================================

# --- Xorg / Wayland USE flags -------------------------------------------------
printf 'sys-auth/pambase elogind\nmedia-libs/libglvnd X\nnet-wireless/wpa_supplicant dbus\n' \
    | sudo tee -a /etc/portage/package.use/xorg

# --- Base packages ------------------------------------------------------------
sudo emerge --ask -q \
    xorg-server \
    x11-apps/xinit \
    x11-apps/xrandr \
    x11-drivers/xf86-video-vesa \
    elogind \

# --- Guru overlay -------------------------------------------------------------
sudo eselect repository enable guru
sudo emerge --sync guru

# --- Niri (Wayland compositor) ------------------------------------------------
echo 'gui-wm/niri ~amd64' | sudo tee -a /etc/portage/package.accept_keywords/niri
sudo emerge --ask -q gui-wm/niri
sudo sed -i 's/Exec=niri --session/Exec=niri-session/' /usr/share/wayland-sessions/niri.desktop

# --- Wayland packages ---------------------------------------------------------
sudo emerge --ask -q \
    x11-base/xwayland \
    gui-apps/waybar \
    gui-apps/fuzzel \
    gui-apps/wl-clipboard \
    xdg-desktop-portal-wlr

# --- Audio -------------------------------------------------------------------
sudo emerge --ask -q     media-sound/alsa-utils     media-libs/pipewire     media-sound/pipewire-pulse     media-sound/pavucontrol
sudo rc-update add alsasound boot

# --- SDDM display manager -----------------------------------------------------
sudo emerge --ask x11-misc/sddm
sudo usermod -a -G video sddm
sudo rc-update add sddm default
