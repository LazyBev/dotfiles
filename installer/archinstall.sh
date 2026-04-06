#!/bin/bash

set -euo pipefail

# ==============================
# Colors & UI
# ==============================
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"; RESET="\e[0m"

section() { echo -e "\n${BLUE}==> $1${RESET}"; }
log()     { echo -e "${GREEN} -> $1${RESET}"; }
warn()    { echo -e "${YELLOW}[WARN] $1${RESET}"; }
error()   { echo -e "${RED}[ERROR] $1${RESET}"; exit 1; }

# ==============================
# Prompt helpers
# ==============================
prompt() {
    local var=$1 msg=$2 default=${3:-}
    if [[ -n "$default" ]]; then
        read -rp "$msg [$default]: " input
        input=${input:-$default}
    else
        read -rp "$msg: " input
    fi
    [[ -z "$input" ]] && error "Input cannot be empty."
    eval "$var=\"$input\""
}

prompt_password() {
    while true; do
        read -rsp "Root password: " root_pass; echo
        read -rsp "Confirm root password: " root_pass_confirm; echo
        [[ "$root_pass" == "$root_pass_confirm" ]] && break
        warn "Root passwords do not match. Try again."
    done
    root_password="$root_pass"
}

prompt_user_password() {
    while true; do
        read -rsp "Password for $user: " user_pass; echo
        read -rsp "Confirm password for $user: " user_pass_confirm; echo
        [[ "$user_pass" == "$user_pass_confirm" ]] && break
        warn "User passwords do not match. Try again."
    done
    user_password="$user_pass"
}

# ==============================
# Disk helper
# ==============================
_part() {
    [[ "$disk" == *nvme* || "$disk" == *mmcblk* ]] \
        && echo "${disk}p${1}" || echo "${disk}${1}"
}

# ==============================
# User input
# ==============================
section "User configuration"

lsblk

prompt disk "Disk to install on (e.g. /dev/sda)"
[[ -b "$disk" ]] || error "Disk not found."

prompt hostname "Hostname"
prompt user "Username"

# Prompt for root password and user password
prompt_password
prompt_user_password

prompt keyboard "Keyboard layout" "us"
prompt locale "Locale" "en_GB.UTF-8"
prompt timezone "Timezone" "Europe/London"

echo "CPU microcode:"
echo "1) intel"
echo "2) amd"
echo "3) auto"
read -rp "Choice [1-3]: " cpu_choice

case "$cpu_choice" in
    1) cpu="intel" ;;
    2) cpu="amd" ;;
    3)
        if grep -qi intel /proc/cpuinfo; then cpu="intel"
        elif grep -qi amd /proc/cpuinfo; then cpu="amd"
        else error "CPU detection failed"; fi
        log "Detected CPU: $cpu"
        ;;
    *) error "Invalid choice" ;;
esac

ip -brief link
default_net=$(ip route | awk '/default/ {print $5}' | head -n1)
prompt network "Network interface" "$default_net"

ip link show "$network" &>/dev/null || error "Invalid interface."

# ==============================
# Preflight checks
# ==============================
section "Pre-flight checks"

[[ $EUID -ne 0 ]] && error "Run as root."

[[ -d /sys/firmware/efi/efivars ]] \
    || error "Not booted in UEFI mode."

for t in wipefs sgdisk mkfs.fat mkswap mkfs.ext4 pacstrap genfstab arch-chroot; do
    command -v "$t" &>/dev/null || error "Missing tool: $t"
done

# Network test
section "Network check"
for host in 1.1.1.1 archlinux.org google.com; do
    if ping -c2 -W2 "$host" &>/dev/null; then
        log "Network OK ($host)"
        break
    fi
done || error "No internet connection."

timedatectl set-ntp true || warn "Time sync failed"

# ==============================
# Partitioning
# ==============================
section "Partitioning $disk"

PART_EFI="$(_part 1)"
PART_SWAP="$(_part 2)"
PART_ROOT="$(_part 3)"

warn "ALL DATA ON $disk WILL BE DESTROYED"
read -rp "Type 'yes' to continue: " confirm
[[ "$confirm" == "yes" ]] || error "Aborted."

wipefs -a "$disk"
sgdisk --zap-all "$disk"

sgdisk -n 1:0:+1G  -t 1:ef00 -c 1:"EFI"  "$disk"
sgdisk -n 2:0:+8G  -t 2:8200 -c 2:"swap" "$disk"
sgdisk -n 3:0:0    -t 3:8300 -c 3:"root" "$disk"

partprobe "$disk"
udevadm settle

log "Partitions created:"
log "EFI:  $PART_EFI"
log "SWAP: $PART_SWAP"
log "ROOT: $PART_ROOT"

# ==============================
# Formatting
# ==============================
section "Formatting"

mkfs.fat -F32 "$PART_EFI"
mkswap "$PART_SWAP"
swapon "$PART_SWAP"
mkfs.ext4 "$PART_ROOT"

# ==============================
# Mounting
# ==============================
section "Mounting"

mount "$PART_ROOT" /mnt
mkdir -p /mnt/boot
mount "$PART_EFI" /mnt/boot

# ==============================
# Install system
# ==============================
section "Installing base system"

pacstrap -K /mnt base base-devel linux linux-headers linux-firmware \
    grub efibootmgr sudo nano networkmanager iwd seatd \
    "$cpu"-ucode

genfstab -U /mnt >> /mnt/etc/fstab

# ==============================
# System configuration
# ==============================
section "Configuring system"

arch-chroot /mnt <<EOF
set -euo pipefail

ln -sf /usr/share/zoneinfo/$timezone /etc/localtime
hwclock --systohc

echo "$locale UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=$locale" > /etc/locale.conf
echo "KEYMAP=$keyboard" > /etc/vconsole.conf

echo "$hostname" > /etc/hostname

echo "root:$root_password" | chpasswd

useradd -m -G wheel $user
echo "$user:$user_password" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
systemctl enable iwd.service
sudo systemctl enable systemd-networkd
sudo systemctl enable systemd-resolved 
systemctl enable NetworkManager 
systemctl enable seatd

cat > /etc/systemd/network/20-wired.network <<NET
[Match]
Name=$network
[Network]
DHCP=yes
NET

EOF

# ==============================
# Finish
# ==============================
section "Finalizing"

umount -R /mnt

log "Installation complete. Rebooting..."
sleep 2
reboot
