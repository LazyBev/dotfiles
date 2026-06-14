#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# configs.sh — user dotfile configuration (fish, git, starship, atuin, env,
#              gtk, hyprland, greetd, adguardhome, nvim, bash_profile)
# ──────────────────────────────────────────────────────────────────────────────
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_fish() {
	step "Shell: Fish"

	chsh -s /usr/bin/fish "$USERNAME" 2>/dev/null || true
	run_as_user mkdir -p ~/.config/fish

	cat > "$USER_HOME/.config/fish/config.fish" <<'FISH'
set -g fish_greeting

if status is-interactive
    zoxide init fish | source
    starship init fish | source
    atuin init fish | source
end

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
}

setup_git() {
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
}

setup_starship() {
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
}

setup_atuin() {
	step "Atuin"

	run_as_user mkdir -p ~/.config/atuin
	cat > "$USER_HOME/.config/atuin/config.toml" <<'ATUIN'
dialect = "uk"
style = "compact"
show_preview = true
ATUIN
	ok "Atuin configured"
}

setup_env() {
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
}

setup_gtk() {
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
}

setup_hyprland() {
	step "Hyprland compositor"

	run_as_user mkdir -p ~/.config/hypr

	cat > "$USER_HOME/.config/hypr/hyprland.conf" <<'HYPR'
monitor = ,preferred,auto,1

env = XDG_CURRENT_DESKTOP,Hyprland
env = XDG_SESSION_TYPE,wayland
env = XDG_SESSION_DESKTOP,Hyprland
env = QT_QPA_PLATFORM,wayland;xcb
env = QT_WAYLAND_DISABLE_WINDOWDECORATION,1

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
}

setup_greetd() {
	mkdir -p /etc/greetd
	cat > /etc/greetd/config.toml <<GREETD
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --cmd Hyprland"
user = "$USERNAME"
GREETD
	ok "greetd configured"
}

setup_adguardhome() {
	step "AdGuardHome"

	cat > /etc/adguardhome.yaml <<'ADG'
bind_host: 0.0.0.0
bind_port: 8080
dns:
  bind_host: 0.0.0.0
  port: 53
ADG
	ok "AdGuardHome configured (http://$HOSTNAME:8080)"
}

setup_neovim() {
	step "Neovim configuration"

	run_as_user mkdir -p ~/.config/nvim

	cat > "$USER_HOME/.config/nvim/init.lua" <<'LUA'
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
}

setup_bashprofile() {
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
}

copy_repo_configs() {
	step "Copying repo configs to user home"

	local REPO_CONFIGS="$SCRIPT_DIR/../configs"
	if [[ ! -d "$REPO_CONFIGS" ]]; then
		warn "configs/ directory not found at $REPO_CONFIGS — skipping"
		return
	fi

	for entry in "$REPO_CONFIGS"/*; do
		local name
		name="$(basename "$entry")"

		if [[ "$name" = "Pictures" ]]; then
			run_as_user mkdir -p ~/Pictures
			cp -rf "$entry"/* "$USER_HOME/Pictures/" 2>/dev/null || true
			ok "Copied Pictures"
		else
			local config_dir="$USER_HOME/.config/$name"
			run_as_user mkdir -p "$config_dir"
			cp -rf "$entry"/* "$config_dir/" 2>/dev/null || true
			ok "Copied $name"
		fi
	done

	chown -R "$USERNAME:$USERNAME" "$USER_HOME/.config" "$USER_HOME/Pictures" 2>/dev/null || true
	ok "All repo configs copied to $USER_HOME"
}

setup_catppuccin_cursors() {
	step "Catppuccin cursors"

	local CURSOR_DIR="/usr/share/icons/catppuccin-mocha-mauve-cursors"
	if [[ -d "$CURSOR_DIR" ]]; then
		ok "Catppuccin cursors already installed"
		return
	fi

	info "Downloading Catppuccin Mocha Mauve cursors..."
	local URL="https://github.com/catppuccin/cursors/releases/download/v2.0.0/catppuccin-mocha-mauve-cursors.zip"
	local TMP="/tmp/catppuccin-cursors.zip"

	if wget -qO "$TMP" "$URL"; then
		mkdir -p /usr/share/icons
		unzip -qo "$TMP" -d /usr/share/icons/
		rm "$TMP"
		ok "Catppuccin cursors installed"
	else
		warn "Failed to download Catppuccin cursors — install manually later"
	fi
}

setup_nvim_plugins() {
	step "Neovim plugins"

	info "Installing Neovim plugins headless (this may take a while)..."
	run_as_user "nvim --headless '+Lazy! sync' +qa" 2>/dev/null || true
	ok "Neovim plugins installed"
}
