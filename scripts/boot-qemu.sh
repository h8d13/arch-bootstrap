#!/bin/bash
# boot-qemu.sh: boot an installed qcow2 disk directly in QEMU under UEFI (OVMF).
# usage: ./boot-qemu.sh [disk.qcow2]   # default /tmp/test-disk.qcow2

DISK="${1:-/tmp/test-disk.qcow2}"
OVMF_VARS="/tmp/ovmf_vars.fd"

[ ! -f "$DISK" ] && {
	echo "Disk not found: $DISK"
	exit 1
}

# Find OVMF firmware (check multiple paths and extensions)
OVMF_CODE=""
for path in /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/x64/OVMF_CODE.fd /usr/share/edk2/x64/OVMF_CODE.4m.fd; do
	[ -f "$path" ] && {
		OVMF_CODE="$path"
		break
	}
done

[ -z "$OVMF_CODE" ] && {
	echo "OVMF firmware not found. Install edk2-ovmf package."
	exit 1
}

# Find corresponding VARS file
OVMF_VARS_SRC=""
for path in "${OVMF_CODE%OVMF_CODE*}OVMF_VARS${OVMF_CODE#*OVMF_CODE}" /usr/share/edk2/x64/OVMF_VARS.4m.fd; do
	[ -f "$path" ] && {
		OVMF_VARS_SRC="$path"
		break
	}
done

[ -z "$OVMF_VARS_SRC" ] && {
	echo "OVMF_VARS not found."
	exit 1
}

[ ! -f "$OVMF_VARS" ] && cp "$OVMF_VARS_SRC" "$OVMF_VARS"

qemu-system-x86_64 \
	-enable-kvm \
	-machine q35,accel=kvm \
	-device intel-iommu \
	-cpu host \
	-smp 2 \
	-m 2G \
	-drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
	-drive if=pflash,format=raw,file="$OVMF_VARS" \
	-drive file="$DISK",format=qcow2,if=virtio \
	-nic user \
	-display gtk
