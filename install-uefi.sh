#!/bin/bash
# install-uefi.sh: bootstrap Arch onto a disk and make it UEFI-bootable
# (kernel + GRUB), so it boots under host-qemu.sh or real OVMF firmware.
#
# WIPES the target device. Host needs: gptfdisk (sgdisk), parted (partprobe),
# dosfstools (mkfs.fat), plus the arch-bootstrap deps.
#
# Usage: sudo ./install-uefi.sh /dev/sdX
set -eu

DEV=${1:-}
MNT=${MNT:-/mnt}

if [ -z "$DEV" ] || [ ! -b "$DEV" ]; then
	[ -n "$DEV" ] && echo "Not a block device: $DEV"
	echo "Usage: sudo $0 <block-device>   (WIPES it)"
	lsblk
	exit 1
fi

# partition node naming: sdb -> sdb1, but nvme0n1/loop0 -> nvme0n1p1
part() { case "$1" in *[0-9]) echo "${1}p$2" ;; *) echo "${1}$2" ;; esac }
ESP=$(part "$DEV" 1)
ROOT=$(part "$DEV" 2)

# idempotent: drop any stale mount, and unmount on exit so the disk is flushed
mountpoint -q "$MNT" && umount -R "$MNT" || true
trap 'mountpoint -q "$MNT" && umount -R "$MNT" || true' EXIT

# GPT: 512M EFI System Partition + rest as root
sgdisk -Z "$DEV"
sgdisk -n1:0:+512M -t1:ef00 -c1:EFI "$DEV"
sgdisk -n2:0:0 -t2:8300 -c2:root "$DEV"
partprobe "$DEV"
udevadm settle || true

mkfs.fat -F32 "$ESP"
mkfs.ext4 -F "$ROOT"
mount "$ROOT" "$MNT"
mkdir -p "$MNT/boot"
mount "$ESP" "$MNT/boot"

# 1) base system onto the root partition
./arch-bootstrap.sh "$MNT"

# 2) kernel + bootloader inside the new system (reuse our own chroot).
#    --removable writes EFI/BOOT/BOOTX64.EFI so OVMF boots with no NVRAM entry.
#    Installing 'linux' triggers the mkinitcpio hook -> initramfs is built.
./arch-bootstrap.sh -c "$MNT" bash -c '
	set -eux
	pacman -S --noconfirm linux grub
	grub-install --target=x86_64-efi --efi-directory=/boot --removable
	grub-mkconfig -o /boot/grub/grub.cfg
'
