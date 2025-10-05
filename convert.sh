#!/usr/bin/env bash
set -Eeuo pipefail

# Patch disk.sh to use DISK_FMT for boot/system images (if not already patched)
if grep -E 'BOOT.*"raw"|SYSTEM.*"raw"' /run/disk.sh >/dev/null 2>&1; then
  # shellcheck disable=SC2016
  sed -i 's/createDevice "\$BOOT" "\$DISK_TYPE" "1" "0xa" "raw"/createDevice "\$BOOT" "\$DISK_TYPE" "1" "0xa" "\$DISK_FMT"/' /run/disk.sh
  # shellcheck disable=SC2016
  sed -i 's/createDevice "\$SYSTEM" "\$DISK_TYPE" "2" "0xb" "raw"/createDevice "\$SYSTEM" "\$DISK_TYPE" "2" "0xb" "\$DISK_FMT"/' /run/disk.sh
fi

# Convert boot and system images to qcow2 format if DISK_FMT is qcow2
# This runs after install.sh extracts the PAT and creates raw boot/system images

if [[ "${DISK_FMT}" == "qcow2" && -f "$STORAGE/dsm.ver" ]]; then
  BASE=$(cat "$STORAGE/dsm.ver")

  if [[ -f "$STORAGE/${BASE}.boot.img" ]]; then
    BOOT_FORMAT=$(qemu-img info "$STORAGE/${BASE}.boot.img" | grep "file format:" | awk '{print $3}')
    if [[ "$BOOT_FORMAT" == "raw" ]]; then
      info "Converting boot image to qcow2..."
      if ! qemu-img convert -f raw -O qcow2 "$STORAGE/${BASE}.boot.img" "$STORAGE/${BASE}.boot.img.tmp"; then
        rm -f "$STORAGE/${BASE}.boot.img.tmp"
        error "Failed to convert boot image"
        exit 1
      fi
      mv "$STORAGE/${BASE}.boot.img.tmp" "$STORAGE/${BASE}.boot.img"
    fi
  fi

  if [[ -f "$STORAGE/${BASE}.system.img" ]]; then
    SYSTEM_FORMAT=$(qemu-img info "$STORAGE/${BASE}.system.img" | grep "file format:" | awk '{print $3}')
    if [[ "$SYSTEM_FORMAT" == "raw" ]]; then
      info "Converting system image to qcow2..."
      if ! qemu-img convert -f raw -O qcow2 "$STORAGE/${BASE}.system.img" "$STORAGE/${BASE}.system.img.tmp"; then
        rm -f "$STORAGE/${BASE}.system.img.tmp"
        error "Failed to convert system image"
        exit 1
      fi
      mv "$STORAGE/${BASE}.system.img.tmp" "$STORAGE/${BASE}.system.img"
    fi
  fi
fi

return 0
