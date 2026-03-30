#!/bin/bash

set -e

# =============================================================================
# GENTOO INSTALL SCRIPT
# =============================================================================

# --- Internet Check -----------------------------------------------------------
echo "Checking internet connectivity..."

hosts=(gnu.org gentoo.org kernel.org archlinux.org debian.org ubuntu.com google.com)
connected=0
for host in "${hosts[@]}"; do
    if ping -c 1 -W 2 "$host" &>/dev/null; then
        echo "  Internet reachable via: $host"
        connected=1
        break
    fi
done

if [[ "$connected" -ne 1 ]]; then
    echo "ERROR: No internet connection. Exiting." >&2
    exit 1
fi

echo "Internet confirmed."

# --- Date/Time Setup ----------------------------------------------------------
echo
echo "Current date/time: $(date)"
read -rp "Set date/time manually? (y/N): " choice
if [[ "$choice" =~ ^[Yy]$ ]]; then
    read -rp "Enter date in MMDDhhmmYYYY format (e.g., 033015302026): " newdate
    sudo date "$newdate"
    echo "Date/time updated to: $(date)"
fi

# --- Disk Selection -----------------------------------------------------------
echo
echo "Available disks:"
lsblk -d -o NAME,SIZE,TYPE
echo

read -rp "Enter disk to format (e.g., sda or nvme0n1): " disk
device="/dev/$disk"

# --- Swap Size Suggestion -----------------------------------------------------
ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
ram_gb=$(( ram_kb / 1024 / 1024 ))

if   (( ram_gb < 2  )); then swap_suggest=4
elif (( ram_gb <= 8 )); then swap_suggest=$(( ram_gb * 2 ))
elif (( ram_gb <= 64)); then swap_suggest=16
else                         swap_suggest=8
fi

# --- Partition Layout ---------------------------------------------------------
echo
echo "Suggested partition layout for $device:"
echo "  1) EFI System Partition : 1G   (type: EFI System)"
echo "  2) Swap                 : ~${swap_suggest}G (type: Linux swap)"
echo "  3) Root                 : rest  (type: Linux filesystem)"
echo
read -rp "Press Enter to launch cfdisk..."
cfdisk "$device"

# Partition naming: NVMe uses 'p' suffix (e.g., nvme0n1p1), SATA does not
if [[ "$disk" == nvme* ]]; then
    part_prefix="p"
else
    part_prefix=""
fi

part1="${device}${part_prefix}1"
part2="${device}${part_prefix}2"
part3="${device}${part_prefix}3"

# --- Format & Mount -----------------------------------------------------------
echo
echo "Formatting partitions..."
mkfs.vfat -F 32 "$part1"
mkswap     "$part2"
mkfs.ext4  "$part3"

echo "Mounting partitions..."
swapon "$part2"
mkdir -p /mnt/gentoo
mount "$part3" /mnt/gentoo
mkdir -p /mnt/gentoo/boot/efi
mount "$part1" /mnt/gentoo/boot/efi

# --- Generate fstab -----------------------------------------------------------
echo "Generating /etc/fstab..."

uuid1=$(blkid -s UUID -o value "$part1")
uuid2=$(blkid -s UUID -o value "$part2")
uuid3=$(blkid -s UUID -o value "$part3")

mkdir -p /mnt/gentoo/etc
cat > /mnt/gentoo/etc/fstab << FSTAB
# <fs>                                      <mountpoint>  <type>  <opts>            <dump> <pass>
UUID=${uuid3}  /             ext4    defaults,noatime  0      1
UUID=${uuid1}  /boot/efi     vfat    defaults,noatime  0      2
UUID=${uuid2}  none          swap    sw                0      0
FSTAB

echo "fstab written:"
cat /mnt/gentoo/etc/fstab

# --- Stage 3 Tarball ----------------------------------------------------------
echo
echo "Downloading and extracting stage3 tarball..."
cd /mnt/gentoo
wget https://distfiles.gentoo.org/releases/amd64/autobuilds/20260329T161601Z/stage3-amd64-openrc-20260329T161601Z.tar.xz
tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo

# --- make.conf ----------------------------------------------------------------
nproc=$(nproc)
cat > /mnt/gentoo/etc/portage/make.conf << EOF
COMMON_FLAGS="-march=native -O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"
RUSTFLAGS="\${RUSTFLAGS} -C target-cpu=native"

USE="elogind pipewire dbus wayland X -systemd -kde -gnome -bluetooth"
FEATURES="candy parallel-fetch parallel-install"
MAKEOPTS="-j${nproc} -l$(( nproc + 1 ))"

LC_MESSAGES=C.utf8
EOF

# --- Chroot Preparation -------------------------------------------------------
echo "Preparing chroot environment..."
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/

mount --types proc              /proc /mnt/gentoo/proc
mount --rbind                   /sys  /mnt/gentoo/sys  && mount --make-rslave /mnt/gentoo/sys
mount --rbind                   /dev  /mnt/gentoo/dev  && mount --make-rslave /mnt/gentoo/dev
mount --bind                    /run  /mnt/gentoo/run  && mount --make-slave  /mnt/gentoo/run

# Fix /dev/shm if it's a symlink
if [[ -L /dev/shm ]]; then
    rm /dev/shm && mkdir /dev/shm
fi
mount --types tmpfs --options nosuid,nodev,noexec shm /dev/shm

# --- Chroot Script ------------------------------------------------------------
cat > /mnt/gentoo/root/chroot-install.sh << 'CHROOT_EOF'
#!/bin/bash
set -e

source /etc/profile
export PS1="(chroot) ${PS1}"

# Sync portage tree
emerge-webrsync

# Select profile
eselect profile list | less
read -rp "Pick a profile number: " prof
eselect profile set "$prof"

# Select mirrors
emerge --ask --verbose --oneshot app-portage/mirrorselect
mirrorselect -i -o >> /etc/portage/make.conf

# Full world update
emerge --sync --quiet
emerge --ask --verbose --update --deep --changed-use @world

# Essential tools
emerge -q app-editors/vim dev-vcs/git
emerge --ask --oneshot app-portage/cpuid2cpuflags
echo "*/* $(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags

# Timezone
read -rp "Enter timezone (e.g., Europe/London): " tz
ln -sf "/usr/share/zoneinfo/$tz" /etc/localtime

# --- Locale Setup -------------------------------------------------------------
mapfile -t all_locales < <(grep -E '^\s*#?\s*[A-Za-z]' /etc/locale.gen \
    | sed 's/^\s*#\s*//' \
    | awk '{print $1}' \
    | sort -u)

echo
echo "Available locales:"
echo "-------------------"
for i in "${!all_locales[@]}"; do
    if grep -qE "^\s*${all_locales[$i]}" /etc/locale.gen; then
        printf "  [%3d] %s  *\n" "$(( i + 1 ))" "${all_locales[$i]}"
    else
        printf "  [%3d] %s\n" "$(( i + 1 ))" "${all_locales[$i]}"
    fi
done
echo "  (* = already enabled)"
echo

read -rp "Enter locale numbers to enable (space-separated, e.g. 42 43): " -a picks

for i in "${!all_locales[@]}"; do
    locale="${all_locales[$i]}"
    num="$(( i + 1 ))"
    if [[ " ${picks[*]} " == *" ${num} "* ]]; then
        sed -i "s|^\s*#\s*\(${locale}\s\)|\1|" /etc/locale.gen
        echo "  Enabled:  $locale"
    else
        sed -i "s|^\(\s*${locale}\s\)|# \1|" /etc/locale.gen
    fi
done

echo
echo "locale.gen configured. Running locale-gen..."
locale-gen

eselect locale list
read -rp "Pick a locale number from the list above: " lc
eselect locale set "$lc"
env-update && source /etc/profile && export PS1="(chroot) ${PS1}"

# --- Kernel & Firmware --------------------------------------------------------
echo 'sys-kernel/linux-firmware @BINARY-REDISTRIBUTABLE' >> /etc/portage/package.license
emerge -q sys-kernel/linux-firmware
emerge -q sys-firmware/sof-firmware
echo "sys-kernel/installkernel dracut grub" >> /etc/portage/package.use/installkernel
emerge -q sys-kernel/installkernel
emerge -q sys-kernel/gentoo-kernel-bin

# --- Hostname & Hosts File ----------------------------------------------------
read -rp "Hostname: " hn
cat > /etc/conf.d/hostname << HOSTNAME
hostname="$hn"
HOSTNAME

sed -i "s/^\(127\.0\.0\.1\s\+localhost\)$/\1\n127.0.0.1   $hn/" /etc/hosts
sed -i "s/^\(::1\s\+localhost\)/\1 $hn/" /etc/hosts

# --- Network ------------------------------------------------------------------
emerge -q net-misc/dhcpcd
emerge -q --noreplace net-misc/netifrc

ip link
read -rp "Pick your network interface (e.g. eth0, enp3s0): " iface
cat > /etc/conf.d/net << NET
config_${iface}="dhcp"
NET

cd /etc/init.d
ln -s net.lo "net.${iface}"
rc-update add "net.${iface}" default
cd

# --- Users --------------------------------------------------------------------
passwd
read -rp "Username: " un
useradd -m -G users,wheel,audio,video -s /bin/bash "$un"
passwd "$un"

emerge -q app-admin/sudo

# Sudoers — enable wheel group
sed -i 's/^#\s*\(%wheel\s\+ALL=(ALL:ALL)\s\+ALL\)/\1/' /etc/sudoers

# --- Bootloader ---------------------------------------------------------------
echo 'GRUB_PLATFORMS="efi-64"' >> /etc/portage/make.conf
emerge -q sys-boot/grub sys-boot/efibootmgr app-misc/neofetch

grub-install --target=x86_64-efi --efi-directory=/boot/efi
grub-mkconfig -o /boot/grub/grub.cfg

echo
echo "Installation complete. Exiting chroot..."
CHROOT_EOF

chmod +x /mnt/gentoo/root/chroot-install.sh

echo
echo "Entering chroot and running install script..."
echo
chroot /mnt/gentoo /bin/bash /root/chroot-install.sh

umount -R /mnt/gentoo
reboot
