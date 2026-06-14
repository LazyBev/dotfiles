#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Void Linux installer — merges LazyBev/nixos-cfg into Void Linux
# Based on: LazyBev/dotfiles/installer/extrashit/install_for_void.sh
# NixOS source: LazyBev/nixos-cfg (gentuwu / gentuwu-laptop)
#
# Usage:
#   1. Boot Void Linux live ISO
#   2. Partition & format your disk (cfdisk + mkfs)
#   3. Mount root to /mnt, boot to /mnt/boot
#   4. Run: void-installer  (or xbps-install -S -r /mnt base-system)
#   5. chroot: xchroot /mnt /bin/bash
#   6. Run this script as root with your username:
#        ./void-linux-install.sh yari
#
# This script sources modular components from the installer/ directory:
#   lib.sh       — shared logging & helper functions
#   packages.sh  — package installation & graphics drivers
#   system.sh    — system config (repos, locale, network, users, bootloader)
#   configs.sh   — user dotfiles (fish, git, starship, nvim, hyprland, …)
#   optional.sh  — fonts & source builds
# ──────────────────────────────────────────────────────────────────────────────

# ── Args & validation ──────────────────────────────────
USERNAME="${1:-}"
[[ -z "$USERNAME" ]] && { echo "Usage: $0 <username>"; exit 1; }
[[ $EUID -ne 0 ]] && { echo "Run as root"; exit 1; }
id "$USERNAME" &>/dev/null || { echo "User '$USERNAME' not found"; exit 1; }

# ── Config (edit to taste) ──────────────────────────────
HOSTNAME="gentuwu"
USER_EMAIL="yari@ari.lt"
TIMEZONE="Europe/London"
LOCALE="en_GB.UTF-8"
KEYMAP="uk"

GTK_THEME="Dracula"
ICON_THEME="Dracula"
CURSOR_THEME="catppuccin-mocha-mauve-cursors"
CURSOR_SIZE=24

export USERNAME HOSTNAME USER_EMAIL TIMEZONE LOCALE KEYMAP
export GTK_THEME ICON_THEME CURSOR_THEME CURSOR_SIZE

# ── Source modules ──────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# ── Run all installer phases ────────────────────────────

source "$SCRIPT_DIR/system.sh"
setup_repos
setup_locale
setup_network
setup_users

source "$SCRIPT_DIR/packages.sh"
install_packages
install_gpu_drivers

source "$SCRIPT_DIR/system.sh"
setup_bootloader
setup_services

source "$SCRIPT_DIR/optional.sh"
install_fonts
build_sources

source "$SCRIPT_DIR/configs.sh"
setup_fish
setup_git
setup_starship
setup_atuin
setup_env
setup_gtk
setup_hyprland
setup_greetd
setup_adguardhome
setup_neovim
setup_bashprofile
copy_repo_configs
setup_catppuccin_cursors
setup_nvim_plugins

# ── Finalise ────────────────────────────────────────────
step "Finalising"
xbps-reconfigure -fa

ok "All done — reboot to enjoy Void Linux + Hyprland!"
echo ""
echo "  Login:  $USERNAME"
echo "  Shell:  fish"
echo "  WM:     Hyprland (auto-starts on tty1)"
echo ""
