#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# packages.sh — package installation & graphics drivers
# ──────────────────────────────────────────────────────────────────────────────
# shellcheck source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

install_packages() {
	step "Installing packages"

	pkg_install \
		Hyprland hyprlock hypridle \
		swaybg waypaper grim slurp wl-clipboard \
		alacritty fish starship atuin \
		neovim git direnv ripgrep fd bat eza fzf zoxide jq \
		curl wget \
		thunar gvfs yazi \
		mpv pavucontrol playerctl \
		qutebrowser librewolf vesktop \
		btop dunst fuzzel zellij \
		NetworkManager network-manager-applet \
		pipewire wireplumber alsa-utils \
		upower power-profiles-daemon \
		opendoas polkit elogind seatd \
		fcitx5 fcitx5-mozc fcitx5-gtk fcitx5-configtool \
		adguardhome openssh \
		libnotify brightnessctl unzip xdg-utils killall \
		steam \
		nerd-fonts dejavu-fonts-ttf noto-fonts-ttf noto-fonts-emoji \
		dracula-theme dracula-icons \
		nvi ripgrep fd bat fzf \
		unzip zip xz
}

install_gpu_drivers() {
	step "Graphics drivers"

	local INSTALL_NVIDIA=false INSTALL_AMD=false INSTALL_INTEL=false
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
}
