#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# system.sh — system-level configuration (repos, locale, network, users,
#              bootloader, services)
# ──────────────────────────────────────────────────────────────────────────────
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

setup_repos() {
	step "System update & repositories"
	xbps-install -Syu -y curl
	pkg_install void-repo-nonfree void-repo-multilib void-repo-multilib-nonfree
	xbps-install -Syu -y
}

setup_locale() {
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
}

setup_network() {
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
}

setup_users() {
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
}

setup_bootloader() {
	step "Bootloader"

	local GRUB_CFG="/etc/default/grub"
	local -a REQUIRED_PARAMS=(quiet loglevel=3 nvidia-drm.modeset=1)
	local CURRENT

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

	local NEW_LINE="GRUB_CMDLINE_LINUX_DEFAULT=\"$CURRENT\""
	if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_CFG"; then
		sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|$NEW_LINE|" "$GRUB_CFG"
	else
		echo "$NEW_LINE" >> "$GRUB_CFG"
	fi

	if command -v grub-install &>/dev/null; then
		grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Void
		grub-mkconfig -o /boot/grub/grub.cfg
	fi
}

setup_services() {
	step "Enabling services"

	for svc in \
		dbus elogind NetworkManager chronyd rtkit seatd \
		power-profiles-daemon upowerd sshd adguardhome; do
		enable_service "$svc"
	done

	rm -f /var/service/pipewire /var/service/pipewire-pulse /var/service/wireplumber 2>/dev/null || true

	enable_service greetd
}
