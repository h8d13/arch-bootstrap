#!/bin/bash
# Fast iterative test: wipe a block device, bootstrap Arch onto it, chroot in.
# Usage: sudo ./test_wrapper.sh /dev/sdX
# Re-runnable: unmounts stale mounts, forces mkfs.
set -eu

DEV=${1:-}
MNT=${MNT:-/mnt}

# No device (or not a block device): show what's available and bail
if [ -z "$DEV" ] || [ ! -b "$DEV" ]; then
  [ -n "$DEV" ] && echo "Not a block device: $DEV"
  echo "Usage: sudo $0 <block-device>"
  lsblk
  exit 1
fi

# Idempotent: drop any prior mount so re-runs don't fail on a busy target
mountpoint -q "$MNT" && umount -R "$MNT" || true
trap 'mountpoint -q "$MNT" && umount -R "$MNT" || true' EXIT

mkfs.ext4 -F "$DEV"
mount "$DEV" "$MNT"

./arch-bootstrap.sh "$MNT"      # bootstrap onto the device
./arch-bootstrap.sh -c "$MNT"   # drop into the new system
