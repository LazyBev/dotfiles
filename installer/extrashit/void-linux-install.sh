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
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Args ────────────────────────────────────────────────
USERNAME="${1:-}"
[[ -z "$USERNAME" ]] && die "Usage: $0 <username>"
[[ $EUID -ne 0 ]] && die "Run as root"

id "$USERNAME" &>/dev/null || die "User '$USERNAME' not found"

USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"

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

# ── Logging ─────────────────────────────────────────────
_log() { printf "[%-5s] %s\n" "$1" "$2"; }
info()  { _log "INFO" "$*"; }
warn()  { _log "WARN" "$*"; }
ok()    { _log "OK"   "$*"; }
step()  { echo -e "\n==> $*\n--------------------------------"; }
die()   { _log "FATAL" "$*"; exit 1; }

trap 'die "Error on line ${LINENO}: ${BASH_COMMAND}"' ERR
trap 'warn "Interrupted"; exit 130' INT TERM

# ── Helpers ─────────────────────────────────────────────
enable_service() {
	local svc="$1"
	[[ -d "/etc/sv/$svc" && ! -e "/var/service/$svc" ]] && {
		ln -s "/etc/sv/$svc" "/var/service/"
		ok "Enabled $svc"
	} || true
}

pkg_install() {
	xbps-install -y "$@"
}

run_as_user() {
	su - "$USERNAME" -c "$*"
}

# ════════════════════════════════════════════════════════
# 1. SYSTEM UPDATE & REPOS
# ════════════════════════════════════════════════════════

step "System update & repositories"
xbps-install -Syu -y curl
pkg_install void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree
xbps-install -Syu -y

# ════════════════════════════════════════════════════════
# 2. PACKAGES
# ════════════════════════════════════════════════════════

step "Installing packages"

pkg_install \
	# Desktop / Compositor
	Hyprland hyprlock hypridle \
	swaybg waypaper grim slurp wl-clipboard \
	# Terminal / Shell
	alacritty fish starship atuin \
	# Editors / Dev
	neovim git direnv ripgrep fd bat eza fzf zoxide jq \
	curl wget \
	# File management
	thunar gvfs yazi \
	# Media
	mpv pavucontrol playerctl \
	# Browsers
	qutebrowser librewolf vesktop \
	# System
	btop dunst fuzzel zellij \
	NetworkManager network-manager-applet \
	pipewire wireplumber alsa-utils \
	upower power-profiles-daemon \
	opendoas polkit elogind seatd \
	fcitx5 fcitx5-mozc fcitx5-gtk fcitx5-configtool \
	adguardhome openssh \
	libnotify brightnessctl unzip xdg-utils killall \
	# Steam
	steam \
	# Fonts
	nerd-fonts dejavu-fonts-ttf noto-fonts-ttf noto-fonts-emoji \
	# GTK themes
	dracula-theme dracula-icons \
	# Base utils
	nvi jq ripgrep fd bat fzf \
	unzip zip xz \

# ════════════════════════════════════════════════════════
# 3. GRAPHICS DRIVERS & NVIDIA
# ════════════════════════════════════════════════════════

step "Graphics drivers"

# Detect GPUs
INSTALL_NVIDIA=false; INSTALL_AMD=false; INSTALL_INTEL=false
if lspci 2>/dev/null | grep -qi nvidia; then INSTALL_NVIDIA=true; fi
if lspci 2>/dev/null | grep -qiE "amd|advanced micro devices"; then INSTALL_AMD=true; fi
if lspci 2>/dev/null | grep -qi intel; then INSTALL_INTEL=true; fi

if $INSTALL_NVIDIA; then
	info "NVIDIA GPU detected"

	xbps-remove -Ry mesa-vulkan-nouveau 2>/dev/null || true

	pkg_install \
		nvidia nvidia-libs-32bit \
		mesa mesa-dri mesa-dri-32bit \
		vulkan-loader vulkan-loader-32bit \
		mesa-demos \
		libgcc-32bit libstdc++-32bit \
		libdrm-32bit libglvnd-32bit \
		mesa-32bit \
		libXtst-32bit libXfixes-32bit \
		libXrandr-32bit libXrender-32bit \
		libXi-32bit glib-32bit \
		gtk+3-32bit gdk-pixbuf-32bit \
		libpipewire-32bit \
		libva-32bit libvdpau-32bit \
		libpulseaudio-32bit

	mkdir -p /etc/modprobe.d
	cat > /etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF

	cat > /etc/modprobe.d/nvidia.conf <<'EOF'
options nvidia-drm modeset=1
EOF
fi

if $INSTALL_AMD; then
	info "AMD GPU detected"
	pkg_install mesa-dri mesa-vulkan-radeon mesa-vaapi
fi

if $INSTALL_INTEL; then
	info "Intel GPU detected"
	pkg_install mesa-dri mesa-vulkan-intel intel-media-driver
fi

# ════════════════════════════════════════════════════════
# 4. LOCALE & TIME
# ════════════════════════════════════════════════════════

step "Locale & time"

for loc in en_US.UTF-8 "$LOCALE"; do
	grep -q "^$loc UTF-8" /etc/default/libc-locales 2>/dev/null || \
		echo "$loc UTF-8" >> /etc/default/libc-locales
	sed -i "s/^#\s*\($loc UTF-8\)/\1/" /etc/default/libc-locales
done
xbps-reconfigure -f glibc-locales

ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc

echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# ════════════════════════════════════════════════════════
# 5. HOSTNAME & NETWORK
# ════════════════════════════════════════════════════════

step "Network configuration"

echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/wifi-powersave.conf <<'EOF'
[connection]
wifi.powersave=2
EOF

rm -f /var/service/dhcpcd 2>/dev/null || true
rm -f /var/service/wpa_supplicant 2>/dev/null || true

# ════════════════════════════════════════════════════════
# 6. USERS & AUTH
# ════════════════════════════════════════════════════════

step "Users & authentication"

usermod -aG _seatd,input,video,audio,wheel,network "$USERNAME"

echo "permit persist :wheel" > /etc/doas.conf
chmod 0400 /etc/doas.conf

mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/00-wheel.rules <<'POLKIT'
polkit.addRule(function(action, subject) {
	if (subject.isInGroup("wheel")) return polkit.Result.YES;
});
POLKIT

# ════════════════════════════════════════════════════════
# 7. BOOTLOADER (GRUB)
# ════════════════════════════════════════════════════════

step "Bootloader"

GRUB_CFG="/etc/default/grub"
REQUIRED_PARAMS=(quiet loglevel=3 nvidia-drm.modeset=1)

if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_CFG"; then
	CURRENT=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_CFG" | cut -d'"' -f2)
else
	CURRENT=""
fi

CURRENT=$(echo "$CURRENT" | sed 's/\bsplash\b//g')
for param in "${REQUIRED_PARAMS[@]}"; do
	[[ ! " $CURRENT " =~ " $param " ]] && CURRENT="$CURRENT $param"
done
CURRENT=$(echo "$CURRENT" | xargs)

NEW_LINE="GRUB_CMDLINE_LINUX_DEFAULT=\"$CURRENT\""
if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_CFG"; then
	sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|$NEW_LINE|" "$GRUB_CFG"
else
	echo "$NEW_LINE" >> "$GRUB_CFG"
fi

if command -v grub-install &>/dev/null; then
	grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Void
	grub-mkconfig -o /boot/grub/grub.cfg
fi

# ════════════════════════════════════════════════════════
# 8. SERVICES
# ════════════════════════════════════════════════════════

step "Enabling services"

for svc in \
	dbus elogind NetworkManager chronyd rtkit seatd \
	power-profiles-daemon upowerd sshd adguardhome; do
	enable_service "$svc"
done

# PipeWire: user services, NOT system services
rm -f /var/service/pipewire /var/service/pipewire-pulse /var/service/wireplumber 2>/dev/null || true

# greetd (login manager)
enable_service greetd

# ════════════════════════════════════════════════════════
# 9. FONTS (Pragmasevka manual)
# ════════════════════════════════════════════════════════

step "Fonts"

xbps-reconfigure -f fontconfig

if [[ ! -d /usr/share/fonts/truetype/pragmasevka ]]; then
	info "Installing Pragmasevka Nerd Font..."
	FONT_URL="https://github.com/shytikov/pragmasevka/releases/download/v1.7.0/Pragmasevka_NF.zip"
	if wget -qO /tmp/pragmasevka.zip "$FONT_URL"; then
		mkdir -p /usr/share/fonts/truetype/pragmasevka
		unzip -qo /tmp/pragmasevka.zip -d /usr/share/fonts/truetype/pragmasevka/
		fc-cache -f
		rm /tmp/pragmasevka.zip
		ok "Pragmasevka installed"
	else
		warn "Failed to download Pragmasevka"
	fi
fi

# ════════════════════════════════════════════════════════
# 10. SOURCE BUILDS (beaker, omnisearch)
# ════════════════════════════════════════════════════════

step "Building from source"

if ! command -v beaker &>/dev/null; then
	info "Building beaker..."
	pkg_install git curl openssl pkg-config libxml2
	if git clone --depth=1 https://git.bwaaa.monster/beaker /tmp/beaker-build; then
		( cd /tmp/beaker-build && make PREFIX=/usr/local LDCONFIG=true && make install PREFIX=/usr/local )
		rm -rf /tmp/beaker-build
		ok "Beaker built"
	else
		warn "beaker clone failed — skipping"
	fi
fi

if ! command -v omnisearch &>/dev/null; then
	info "Building omnisearch..."
	if git clone --depth=1 https://git.bwaaa.monster/omnisearch /tmp/omnisearch-build; then
		( cd /tmp/omnisearch-build && make PREFIX=/usr/local && make install PREFIX=/usr/local )
		rm -rf /tmp/omnisearch-build
		ok "Omnisearch built"
	else
		warn "omnisearch clone failed — skipping"
	fi
fi

# ════════════════════════════════════════════════════════
# 11. FISH SHELL
# ════════════════════════════════════════════════════════

step "Shell: Fish"

chsh -s /usr/bin/fish "$USERNAME" 2>/dev/null || true
run_as_user mkdir -p ~/.config/fish

cat > "$USER_HOME/.config/fish/config.fish" <<'FISH'
# ── Fish config (ported from LazyBev/nixos-cfg) ─────────────────────────

set -g fish_greeting

if status is-interactive
    zoxide init fish | source
    starship init fish | source
    atuin init fish | source
end

# Aliases (from nixos-cfg: modules/programs/fish.nix)
alias cat="bat -p"
alias ls="eza --icons"
alias ll="eza -la --icons"
alias lt="eza -la --icons --tree --level=2"
alias grep="rg"
alias py="python3"
alias sv="doas nvim"
alias ga="git add"
alias gc="git commit"
alias gp="git push"
alias gs="git status"
alias gd="git diff"
alias gco="git checkout"
alias gb="git branch"
alias gl="git log --oneline --graph"

# Void-specific
alias sysupd="doas xbps-install -Su"
alias clean="doas xbps-remove -Oo"

function gitwho
    echo (git config user.name) '<'(git config user.email)'>'
end

function upgrade
    doas xbps-install -Su
    echo "System updated"
end
FISH
ok "Fish configured"

# ════════════════════════════════════════════════════════
# 12. GIT CONFIG
# ════════════════════════════════════════════════════════

step "Git configuration"

run_as_user "
	git config --global user.name '$USERNAME'
	git config --global user.email '$USER_EMAIL'
	git config --global init.defaultBranch main
	git config --global pull.rebase true
	git config --global push.autoSetupRemote true
	git config --global core.editor nvim
"
ok "Git configured"

# ════════════════════════════════════════════════════════
# 13. STARSIP PROMPT
# ════════════════════════════════════════════════════════

step "Starship prompt"

run_as_user mkdir -p ~/.config
cat > "$USER_HOME/.config/starship.toml" <<'STAR'
format = "$all"

[character]
success_symbol = "[➜](purple)"
error_symbol = "[➜](red)"

[directory]
style = "cyan"
truncation_length = 3

[git_branch]
style = "purple"

[git_status]
style = "orange"

[nodejs]
disabled = false

[rust]
style = "orange"

[python]
style = "yellow"
STAR
ok "Starship configured"

# ════════════════════════════════════════════════════════
# 14. ATUIN
# ════════════════════════════════════════════════════════

step "Atuin"

run_as_user mkdir -p ~/.config/atuin
cat > "$USER_HOME/.config/atuin/config.toml" <<'ATUIN'
dialect = "uk"
style = "compact"
show_preview = true
ATUIN
ok "Atuin configured"

# ════════════════════════════════════════════════════════
# 15. ENVIRONMENT VARIABLES
# ════════════════════════════════════════════════════════

step "Environment variables"

cat > /etc/environment <<ENV
EDITOR=nvim
VISUAL=nvim
TERMINAL=alacritty
BROWSER=qutebrowser
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
SDL_IM_MODULE=fcitx
GLFW_IM_MODULE=ibus
ENV
ok "Environment set"

# ════════════════════════════════════════════════════════
# 16. GTK THEME
# ════════════════════════════════════════════════════════

step "GTK theme"

run_as_user mkdir -p ~/.config/gtk-3.0 ~/.config/gtk-4.0

cat > "$USER_HOME/.config/gtk-3.0/settings.ini" <<GTK
[Settings]
gtk-theme-name=$GTK_THEME
gtk-icon-theme-name=$ICON_THEME
gtk-cursor-theme-name=$CURSOR_THEME
gtk-cursor-theme-size=$CURSOR_SIZE
gtk-font-name=Noto Sans 10
GTK

ln -sf "$USER_HOME/.config/gtk-3.0/settings.ini" "$USER_HOME/.config/gtk-4.0/settings.ini"
ok "GTK theme set to $GTK_THEME"

# ════════════════════════════════════════════════════════
# 17. HYPRLAND CONFIG
# ════════════════════════════════════════════════════════

step "Hyprland compositor"

run_as_user mkdir -p ~/.config/hypr

cat > "$USER_HOME/.config/hypr/hyprland.conf" <<'HYPR'
# ── Hyprland (ported from LazyBev/nixos-cfg) ────────────────────────────

monitor = ,preferred,auto,1

env = XDG_CURRENT_DESKTOP,Hyprland
env = XDG_SESSION_TYPE,wayland
env = XDG_SESSION_DESKTOP,Hyprland
env = QT_QPA_PLATFORM,wayland;xcb
env = QT_WAYLAND_DISABLE_WINDOWDECORATION,1

# NVIDIA — uncomment if you have an NVIDIA GPU
# env = WLR_NO_HARDWARE_CURSORS,1
# env = LIBVA_DRIVER_NAME,nvidia
# env = GBM_BACKEND,nvidia-drm
# env = __GLX_VENDOR_LIBRARY_NAME,nvidia

input {
    kb_layout = gb
    follow_mouse = 1
    touchpad { natural_scroll = yes }
}

exec-once = dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP
exec-once = waypaper --restore
exec-once = dunst
exec-once = /usr/libexec/polkit-gnome-authentication-agent-1 &
exec-once = fcitx5 -d
exec-once = nm-applet &

$mainMod = SUPER

bind = $mainMod, Q, exec, alacritty
bind = $mainMod, C, killactive,
bind = $mainMod, M, exit,
bind = $mainMod, E, exec, thunar
bind = $mainMod, V, togglefloating,
bind = $mainMod, R, exec, fuzzel
bind = $mainMod, P, pseudo,
bind = $mainMod, J, togglesplit,
bind = $mainMod, SPACE, exec, fuzzel

bind = $mainMod, left,  movefocus, l
bind = $mainMod, right, movefocus, r
bind = $mainMod, up,    movefocus, u
bind = $mainMod, down,  movefocus, d

bind = $mainMod SHIFT, left,  movewindow, l
bind = $mainMod SHIFT, right, movewindow, r
bind = $mainMod SHIFT, up,    movewindow, u
bind = $mainMod SHIFT, down,  movewindow, d

bind = , Print, exec, grimblast copy area
bind = , XF86AudioRaiseVolume, exec, pactl set-sink-volume @DEFAULT_SINK@ +5%
bind = , XF86AudioLowerVolume, exec, pactl set-sink-volume @DEFAULT_SINK@ -5%
bind = , XF86AudioMute,        exec, pactl set-sink-mute @DEFAULT_SINK@ toggle
bind = , XF86MonBrightnessUp,   exec, brightnessctl s +5%
bind = , XF86MonBrightnessDown, exec, brightnessctl s 5%-

windowrule = float, ^(pavucontrol)$
windowrule = float, ^(blueman-manager)$
windowrule = float, ^(thunar)$

gestures { workspace_swipe = true }

decoration {
    rounding         = 8
    active_opacity   = 1.0
    inactive_opacity = 0.9
    drop_shadow      = true
    shadow_range     = 4
    shadow_offset    = 0 2
    shadow_render_power = 3
    col.shadow       = rgba(1a1a2e66)
}

animations {
    enabled = true
    bezier = myBezier, 0.05, 0.9, 0.1, 1.05
    animation = windows,     1, 7, myBezier
    animation = windowsOut,  1, 7, default
    animation = fade,        1, 7, default
    animation = workspaces,  1, 6, default
}

blur {
    enabled = true
    size    = 3
    passes  = 1
}
HYPR
ok "Hyprland configured"

# ── greetd (login manager) ───────────────────────────────
mkdir -p /etc/greetd
cat > /etc/greetd/config.toml <<GREETD
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --cmd Hyprland"
user = "$USERNAME"
GREETD
ok "greetd configured"

# ════════════════════════════════════════════════════════
# 18. ADGUARDHOME
# ════════════════════════════════════════════════════════

step "AdGuardHome"

cat > /etc/adguardhome.yaml <<'ADG'
bind_host: 0.0.0.0
bind_port: 8080
dns:
  bind_host: 0.0.0.0
  port: 53
ADG
ok "AdGuardHome configured (http://$HOSTNAME:8080)"

# ════════════════════════════════════════════════════════
# 19. NEOVIM (lazy.nvim)
# ════════════════════════════════════════════════════════

step "Neovim configuration"

run_as_user mkdir -p ~/.config/nvim

cat > "$USER_HOME/.config/nvim/init.lua" <<'LUA'
-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
	vim.fn.system({
		"git", "clone", "--filter=blob:none",
		"https://github.com/folke/lazy.nvim.git",
		"--branch=stable", lazypath,
	})
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
	{ "Mofiqul/dracula.nvim", priority = 1000, config = true },
	{ "neovim/nvim-lspconfig" },
	{ "hrsh7th/nvim-cmp" },
	{ "hrsh7th/cmp-nvim-lsp" },
	{ "L3MON4D3/LuaSnip" },
	{ "nvim-telescope/telescope.nvim", dependencies = { "nvim-lua/plenary.nvim" } },
	{ "nvim-treesitter/nvim-treesitter", build = ":TSUpdate" },
	{ "nvim-neo-tree/neo-tree.nvim", dependencies = { "nvim-lua/plenary.nvim", "nvim-tree/nvim-web-devicons" } },
	{ "nvim-lualine/lualine.nvim", dependencies = { "nvim-tree/nvim-web-devicons" } },
	{ "folke/which-key.nvim" },
	{ "lewis6991/gitsigns.nvim" },
	{ "TimUntersberger/neogit" },
	{ "numToStr/Comment.nvim" },
	{ "lukas-reineke/indent-blankline.nvim" },
	{ "akinsho/nvim-bufferline.lua" },
	{ "folke/noice.nvim", dependencies = { "MunifTanjim/nui.nvim" } },
	{ "rcarriga/nvim-notify" },
	{ "folke/trouble.nvim" },
	{ "folke/flash.nvim" },
	{ "folke/todo-comments.nvim" },
	{ "akinsho/toggleterm.nvim" },
	{ "yamatsum/nvim-cursorline" },
	{ "j-hui/fidget.nvim" },
	{ "goolord/alpha-nvim", dependencies = { "nvim-lua/plenary.nvim" } },
	{ "echasnovski/mini.indentscope" },
	{ "echasnovski/mini.pairs" },
	{ "echasnovski/mini.surround" },
	{ "ray-x/lsp_signature.nvim" },
})

for k, v in pairs({
	number = true, relativenumber = true, shiftwidth = 2,
	tabstop = 2, expandtab = true, mouse = "a",
	termguicolors = true, updatetime = 50, scrolloff = 8,
	signcolumn = "yes", smartcase = true, ignorecase = true,
	splitright = true, splitbelow = true, undofile = true,
	wrap = false, cursorline = true, clipboard = "unnamedplus",
}) do vim.opt[k] = v end

vim.cmd("colorscheme dracula")
LUA
ok "Neovim configured (plugins install on first launch)"

# ════════════════════════════════════════════════════════
# 20. BASHPROFILE (auto-start Hyprland on tty1)
# ════════════════════════════════════════════════════════

step "Autostart config"

cat > "$USER_HOME/.bash_profile" <<'BASH'
if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
	export XDG_CURRENT_DESKTOP=Hyprland
	export XDG_SESSION_TYPE=wayland
	exec Hyprland
fi
BASH

chown "$USERNAME:$USERNAME" "$USER_HOME/.bash_profile"
ok "bash_profile created"

# ════════════════════════════════════════════════════════
# 21. FINAL
# ════════════════════════════════════════════════════════

step "Finalising"

xbps-reconfigure -fa

ok "All done — reboot to enjoy Void Linux + Hyprland!"
echo ""
echo "  Login:  $USERNAME / <password set during install>"
echo "  Shell:  fish"
echo "  WM:     Hyprland (auto-starts on tty1)"
echo ""
echo "  Post-reboot:"
echo "    1. passwd              # change password"
echo "    2. git clone <dotfiles> ~/dotfiles"
echo "    3. Copy configs: hypr, alacritty, dunst, fuzzel,"
echo "       zellij, yazi, rmpc, qutebrowser, librewolf,"
echo "       vesktop, fcitx5, Pictures"
echo "    4. nvim                # installs plugins on first launch"
echo "    5. Download catppuccin cursors from GitHub"
echo ""
