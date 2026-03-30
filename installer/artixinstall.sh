#!/bin/bash

set -ae

next_steps() {
    echo "Internet confirmed."

    echo "Available disks:"
    lsblk -d -o NAME,SIZE,TYPE

    echo
    read -rp "Enter the disk to format (e.g. sda or nvme0n1): " disk
    device="/dev/$disk"
    echo
    read -rp "We will add swap" disk
    
    cfdisk $device

    if [[ $disk == "nvme0n1"]] then
        part1="p1"
        part2="p2"
        part3="p3"
    else
        part1="1"
        part2="2"
        part3="3"
    fi

    mkfs.ext4 $device$part3
    mkfs.fat -F 32 $device$part1
    mkswap $device$par2

    echo "Done."
}

hosts=(
  gnu.org
  gentoo.org
  kernel.org
  archlinux.org
  debian.org
  ubuntu.com
  google.com
)

connected=0

for host in "${hosts[@]}"; do
  if ping -c 1 -W 2 "$host" > /dev/null 2>&1; then
    echo "Internet reachable via: $host"
    connected=1
  fi
done

if [ "$connected" -eq 1 ]; then
  next_steps
else
  echo "No internet connection. Exiting."
  exit 1
fi
