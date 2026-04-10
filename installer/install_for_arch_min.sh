#!/bin/bash

set -eo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/helper.sh"

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

_log() { printf "[%-5s] %s\n" "$1" "$2"; }
info()  { _log "INFO"  "$*"; }
warn()  { _log "WARN"  "$*"; }
skip()  { _log "SKIP"  "$*"; }
ok()    { _log "OK"    "$*"; }
step()  { echo; echo "==> $*"; echo "------------------------------------------------------------"; }
die()   {
    _log "FATAL" "$*"
    echo
    echo "  The script failed at the step above."
    echo "  Your pacman.conf backup is at /etc/pacman.conf.bak if you need to roll back."
    exit 1
}

trap 'echo; die "Unexpected error on line ${LINENO} — command: ${BASH_COMMAND}"' ERR
trap 'echo; warn "Script interrupted by user."; exit 130' INT TERM

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

step "Preflight checks"

[[ $EUID -ne 0 ]] || die "Do not run this script as root. It will sudo what it needs."
command -v pacman &>/dev/null || die "pacman not found — are you on Arch?"
command -v curl   &>/dev/null || die "curl not found — install it first: sudo pacman -S curl"
command -v git    &>/dev/null || { warn "git not found — installing..."; sudo pacman -S --noconfirm git; }

info "Checking internet connectivity..."
curl -fsSL --max-time 10 https://archlinux.org &>/dev/null \
    || die "No internet connection detected. Check your network and try again."
ok "Internet connectivity confirmed"

[[ -d /sys/firmware/efi ]] || warn "EFI not detected — make sure you're on the target machine, not a chroot."

# ---------------------------------------------------------------------------
# Pacman config
# ---------------------------------------------------------------------------

step "Configuring pacman"

MULTILIB_INCLUDE_FIX='/^\[multilib\]/{n;s/^#Include/Include/}'

info "Ensuring mirrorlist has active Server lines..."
if ! grep -q '^Server' /etc/pacman.d/mirrorlist 2>/dev/null; then
    sudo sed -i 's/^## \(Server = \)/\1/' /etc/pacman.d/mirrorlist
    sudo sed -i 's/^#\(Server = \)/\1/' /etc/pacman.d/mirrorlist
    if grep -q '^Server' /etc/pacman.d/mirrorlist; then
        ok "Mirrorlist Server lines uncommented"
    else
        warn "Still no Server lines — trying reflector..."
        sudo reflector --country GB --latest 10 --sort rate --save /etc/pacman.d/mirrorlist 2>/dev/null \
            && ok "reflector wrote a fresh mirrorlist" \
            || die "Could not produce a usable mirrorlist — fix it manually and re-run"
    fi
else
    skip "Mirrorlist already has active Server lines"
fi

info "Fetching clean pacman.conf from Arch upstream..."
if sudo curl -fsSL --max-time 15 \
    "https://gitlab.archlinux.org/archlinux/packaging/packages/pacman/-/raw/main/pacman.conf" \
    -o /etc/pacman.conf 2>/dev/null && grep -q '^\[options\]' /etc/pacman.conf; then
    ok "Clean pacman.conf fetched"
    sudo cp /etc/pacman.conf /etc/pacman.conf.bak
    ok "Backup written to /etc/pacman.conf.bak"
else
    warn "Could not fetch upstream pacman.conf — using existing file"
    [[ ! -f /etc/pacman.conf.bak ]] && sudo cp /etc/pacman.conf /etc/pacman.conf.bak
fi

info "Applying pacman.conf patches..."
for change in \
    "s/#Color/Color/" \
    "s/#ParallelDownloads/ParallelDownloads/" \
    "s/#\\[multilib\\]/\\[multilib\\]/" \
    "/# Misc options/a ILoveCandy"; do
    sudo sed -i "$change" /etc/pacman.conf \
        && info "  Applied: $change" \
        || warn "  Non-fatal (may already be set): $change"
done

if grep -q '^\[multilib\]' /etc/pacman.conf \
    && ! grep -A1 '^\[multilib\]' /etc/pacman.conf | grep -q '^Include'; then
    sudo sed -i "$MULTILIB_INCLUDE_FIX" /etc/pacman.conf \
        && info "  Applied: multilib Include uncomment" \
        || warn "  multilib Include may already be active"
else
    skip "multilib Include already active"
fi

info "Syncing package databases..."
sudo pacman -Sy --noconfirm || die "pacman -Sy failed"
ok "pacman.conf patched and databases synced"

# ---------------------------------------------------------------------------
# System upgrade + yay
# ---------------------------------------------------------------------------

step "System upgrade and AUR helper"

info "Running full system upgrade..."
sudo pacman -Syu --noconfirm \
    && ok "System upgraded" \
    || warn "Upgrade had warnings — check output above"

if ! command -v yay &>/dev/null; then
    info "Installing yay (AUR helper)..."
    [[ -d yay-bin ]] && { warn "Stale yay-bin dir found — removing"; sudo rm -rf yay-bin; }
    git clone https://aur.archlinux.org/yay-bin.git || die "Failed to clone yay-bin"
    sudo chown -R "$USER:$USER" yay-bin
    (cd yay-bin && makepkg -si --noconfirm) || die "makepkg failed for yay-bin"
    sudo rm -rf yay-bin
    ok "yay installed"
else
    skip "yay already installed ($(yay --version 2>/dev/null | head -1))"
fi

# ---------------------------------------------------------------------------
# Main package install
# ---------------------------------------------------------------------------

step "Installing packages"
info "This may take a while depending on your connection speed..."

# Core: niri compositor, NetworkManager, Ghostty terminal, SDDM display manager.
# xdg-desktop-portal-gnome provides the minimal portal backend niri needs.
# polkit + polkit-kde-agent are required for privilege escalation under niri.
# noto-fonts-emoji + ttf-jetbrains-mono-nerd give basic font coverage for the terminal.
yay -Syu --needed --noconfirm \
    curl \
    dbus \
    dunst \
    fuzzel \
    ghostty \
    git \
    libxkbcommon \
    networkmanager \
    nm-connection-editor \
    niri \
    noto-fonts-emoji \
    polkit \
    polkit-kde-agent \
    sddm \
    sudo \
    ttf-jetbrains-mono-nerd \
    waybar \
    wayland \
    wayland-protocols \
    xdg-desktop-portal \
    xdg-desktop-portal-gnome \
    xwayland-satellite \
    && ok "Packages installed" \
    || warn "Some packages failed — check output above (non-fatal, continuing)"

# ---------------------------------------------------------------------------
# JACK conflict
# ---------------------------------------------------------------------------

step "Checking for JACK conflicts"

if pacman -Q jack2 &>/dev/null; then
    info "Conflicting jack2 found — removing..."
    sudo pacman -Rdd --noconfirm jack2 \
        && ok "jack2 removed" \
        || warn "jack2 removal failed — PipeWire-JACK may have issues"
else
    skip "jack2 not installed — no conflict"
fi

# ---------------------------------------------------------------------------
# PulseAudio removal
# ---------------------------------------------------------------------------

step "Checking for PulseAudio"

if pacman -Q | grep -qE '^pulseaudio'; then
    info "PulseAudio detected — stopping and removing..."
    systemctl --user stop pulseaudio.service pulseaudio.socket 2>/dev/null || true
    mapfile -t pa_pkgs < <(pacman -Q | awk '{print $1}' | grep -E '^pulseaudio')
    info "  Packages to remove: ${pa_pkgs[*]}"
    sudo pacman -Rns --noconfirm "${pa_pkgs[@]}" \
        && ok "PulseAudio removed" \
        || warn "PulseAudio removal had errors — may need manual cleanup"
else
    skip "PulseAudio not installed"
fi

if ! groups "$USER" | grep -q '\baudio\b'; then
    info "Adding $USER to audio group..."
    sudo usermod -aG audio "$USER" && ok "$USER added to audio group"
else
    skip "$USER already in audio group"
fi

# ---------------------------------------------------------------------------
# systemd services
# ---------------------------------------------------------------------------

step "Enabling systemd services"

sd_enable() {
    local svc="$1"
    if systemctl list-unit-files "$svc" &>/dev/null; then
        sudo systemctl enable "$svc" \
            && ok "  Enabled: $svc" \
            || warn "  Failed to enable: $svc"
    else
        warn "  Unit not found: $svc — skipping"
    fi
}

sd_enable NetworkManager.service
sd_enable sddm.service

# ---------------------------------------------------------------------------
# CPU microcode
# ---------------------------------------------------------------------------

step "CPU microcode"

VENDOR=$(lscpu | awk '/Vendor ID/{print $3}')
info "Detected CPU vendor: $VENDOR"
case "$VENDOR" in
    GenuineIntel)
        sudo pacman -S --needed --noconfirm intel-ucode \
            && ok "intel-ucode installed" \
            || warn "intel-ucode install failed"
        ;;
    AuthenticAMD)
        sudo pacman -S --needed --noconfirm amd-ucode \
            && ok "amd-ucode installed" \
            || warn "amd-ucode install failed"
        ;;
    *)
        warn "Unknown CPU vendor '$VENDOR' — skipping microcode"
        ;;
esac

# ---------------------------------------------------------------------------
# NVIDIA
# ---------------------------------------------------------------------------

step "GPU detection"

if lspci | grep -qi nvidia; then
    info "NVIDIA GPU detected — installing drivers..."
    yay -Syu --needed --sudoloop --noconfirm \
        egl-wayland \
        lib32-nvidia-utils \
        lib32-opencl-nvidia \
        lib32-vulkan-mesa-layers \
        libva-nvidia-driver \
        nvidia-dkms \
        nvidia-hook \
        nvidia-inst \
        nvidia-settings \
        nvidia-utils \
        opencl-nvidia \
        vulkan-mesa-layers \
        && ok "NVIDIA drivers installed" \
        || warn "Some NVIDIA packages failed — GPU may not work correctly"
else
    skip "No NVIDIA GPU found (lspci)"
fi

# ---------------------------------------------------------------------------
# D-Bus session
# ---------------------------------------------------------------------------

step "D-Bus session"

if [[ -z "$DBUS_SESSION_BUS_ADDRESS" ]]; then
    info "No D-Bus session found — launching one..."
    eval "$(dbus-launch --sh-syntax)" 2>/dev/null \
        && ok "D-Bus session started" \
        || warn "dbus-launch failed — some config steps may not work until after first login"
else
    skip "D-Bus session already active ($DBUS_SESSION_BUS_ADDRESS)"
fi

# ---------------------------------------------------------------------------
# GRUB
# ---------------------------------------------------------------------------

step "GRUB configuration"

GRUB_FILE="/etc/default/grub"
[[ -f "$GRUB_FILE" ]] || die "GRUB config not found at $GRUB_FILE — is GRUB installed?"

info "Detecting CPU model for kernel params..."
CPU_MODEL=$(lscpu | awk '/Model name/{print $3}')
info "  CPU model string: $CPU_MODEL"

case "$CPU_MODEL" in
    AMD*)   EXTRA_PARAMS="amd_pstate=active mitigations=off" ;;
    Intel*) EXTRA_PARAMS="intel_pstate=active mitigations=off" ;;
    *)      EXTRA_PARAMS=""; warn "  Unknown CPU model — no extra params added" ;;
esac

if [[ -n "$EXTRA_PARAMS" ]] && ! grep -q "$EXTRA_PARAMS" "$GRUB_FILE"; then
    info "Patching GRUB_CMDLINE_LINUX_DEFAULT..."
    sudo sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"\([^\"]*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 ${EXTRA_PARAMS}\"/" "$GRUB_FILE"
    ok "GRUB cmdline updated"
    info "  New cmdline: $(grep GRUB_CMDLINE_LINUX_DEFAULT "$GRUB_FILE")"
else
    skip "GRUB cmdline already up to date"
fi

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

step "Installing config"

# niri-edit: quick shortcut to edit the niri config in ghostty+nvim
if [[ ! -x /usr/bin/niri-edit ]]; then
    info "Installing niri-edit helper..."
    sudo tee /usr/bin/niri-edit > /dev/null <<'EOF'
#!/bin/sh
ghostty -e nvim ~/.config/niri/config.kdl
EOF
    sudo chmod +x /usr/bin/niri-edit
    ok "niri-edit installed at /usr/bin/niri-edit"
else
    skip "niri-edit already installed"
fi

info "Syncing config directories from dotfiles..."
for dir in niri waybar fuzzel dunst; do
    SRC="$HOME/dotfiles/configs/$dir"
    DST="$HOME/.config/$dir"
    if [[ -d "$SRC" ]]; then
        rm -rf "$DST"
        cp -r "$SRC" "$DST"
        ok "  $dir → $DST"
    else
        warn "  dotfiles/configs/$dir not found — skipping"
    fi
done

if [[ -f "$HOME/dotfiles/.bashrc" ]]; then
    info "Copying .bashrc from dotfiles..."
    cp -f "$HOME/dotfiles/.bashrc" "$HOME/" && ok ".bashrc installed"
else
    warn "dotfiles/.bashrc not found — skipping"
fi

info "Fixing ownership of $HOME..."
sudo chown -R "$USER:$USER" "$HOME" && ok "Ownership corrected"

# SDDM astronaut theme
if [[ ! -d /usr/share/sddm/themes/sddm-astronaut-theme ]]; then
    info "Installing sddm-astronaut-theme..."
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/keyitdev/sddm-astronaut-theme/master/setup.sh)" \
        && ok "SDDM theme installed" \
        || warn "SDDM theme install failed — SDDM will use default theme"
else
    skip "sddm-astronaut-theme already installed"
fi

# ---------------------------------------------------------------------------
# Finalise
# ---------------------------------------------------------------------------

step "Finalising"

info "Regenerating initramfs (mkinitcpio -P)..."
sudo mkinitcpio -P \
    && ok "initramfs regenerated" \
    || warn "mkinitcpio had errors — boot may fail, check output above"

info "Regenerating GRUB config..."
sudo grub-mkconfig -o /boot/grub/grub.cfg \
    && ok "GRUB config written to /boot/grub/grub.cfg" \
    || die "grub-mkconfig failed — do not reboot until this is fixed"

echo
echo "============================================================"
echo "  Installation complete!"
echo "  - systemd is the init system"
echo "  - GRUB has been updated"
echo "  - pacman.conf backup: /etc/pacman.conf.bak"
echo "  If the system fails to boot:"
echo "    1. Boot from Arch ISO"
echo "    2. arch-chroot into your install"
echo "    3. Restore: cp /etc/pacman.conf.bak /etc/pacman.conf"
echo "============================================================"
echo
info "Rebooting in 10 seconds... Ctrl+C to cancel."
info "If shutdown hangs: Alt+PrtSc, then press R E I S U B one at a time."
sleep 10

sudo reboot
