#!/bin/bash

set -e

# Optional sudo flag
SUDO=""
if [[ "$1" == "-sudo" ]]; then
    SUDO="sudo"
fi

# Check for internet
hosts=(gnu.org gentoo.org kernel.org archlinux.org debian.org ubuntu.com google.com)
connected=0
for host in "${hosts[@]}"; do
    if ping -c 1 -W 2 "$host" > /dev/null 2>&1; then
        echo "Internet reachable via: $host"
        connected=1
    fi
done

if [ "$connected" -ne 1 ]; then
    echo "No internet connection. Exiting."
    exit 1
fi

echo
echo "Internet confirmed."

# === Date/Time Setup ===
echo
echo "Current date and time: $(date)"
read -rp "Do you want to set the date/time manually? (y/N): " choice
if [[ "$choice" =~ ^[Yy]$ ]]; then
    read -rp "Enter date in MMDDhhmmYYYY format (e.g., 033015302026 for Mar 30 15:30 2026): " newdate
    sudo date "$newdate"
    echo "Date/time updated to: $(date)"
else
    echo "Keeping current date/time."
fi

# Show available disks
echo "Available disks:"
lsblk -d -o NAME,SIZE,TYPE
echo

# Ask user which disk to format
read -rp "Enter the disk to format (e.g., sda or nvme0n1): " disk
device="/dev/$disk"

# Calculate swap suggestion based on RAM
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_GB=$((RAM_KB / 1024 / 1024))

if [ "$RAM_GB" -lt 2 ]; then
    swap_suggest=4
elif [ "$RAM_GB" -le 8 ]; then
    swap_suggest=$((RAM_GB * 2))
elif [ "$RAM_GB" -le 64 ]; then
    swap_suggest=16
else
    swap_suggest=8
fi

echo
echo "Partitioning suggestion for $device:"
echo "-----------------------------------"
echo "1) EFI System Partition (boot): 1G, type 'EFI System'"
echo "2) Swap: ~${swap_suggest}G, type 'Linux swap'"
echo "3) Root: remainder of disk, type 'Linux filesystem'"
echo
echo "The script will now launch cfdisk for manual partitioning."
echo "Follow the suggestions above when creating the partitions."
read -rp "Press Enter to launch cfdisk..." 

# Launch cfdisk
$SUDO cfdisk "$device"

# Determine partition suffix for NVMe vs non-NVMe devices
if [[ "$disk" == nvme* ]]; then
    part_prefix="p"
else
    part_prefix=""
fi

part1="${device}${part_prefix}1"
part2="${device}${part_prefix}2"
part3="${device}${part_prefix}3"

echo
echo "Formatting partitions..."
$SUDO mkfs.vfat -F 32 "$part1"
$SUDO mkfs.ext4 "$part3"
$SUDO mkswap "$part2"

echo
echo "Mounting partitions..."
$SUDO swapon "$part2"
$SUDO mkdir -p /mnt/gentoo
$SUDO mount "$part3" /mnt/gentoo
#$SUDO mkdir -p /mnt/gentoo/boot
#$SUDO mount "$part1" /mnt/gentoo/boot

echo "Partitioning, formatting, and mounting complete."

cd /mnt/gentoo
wget https://distfiles.gentoo.org/releases/amd64/autobuilds/20260329T161601Z/stage3-amd64-openrc-20260329T161601Z.tar.xz
tar xpvf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner -C /mnt/gentoo
