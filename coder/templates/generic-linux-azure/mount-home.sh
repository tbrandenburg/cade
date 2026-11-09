#!/bin/bash
set -euo pipefail
umask 077

device=/dev/disk/azure/scsi1/lun10
home=/home/coder
fail() { printf '%s\n' "$1" >&2; exit 1; }

# Attachment is created after the VM; never fall back to the OS/temp disk.
for ((attempt = 0; attempt < 180; attempt++)); do
  [ ! -b "$device" ] || break
  sleep 2
done
[ -b "$device" ] || fail 'Persistent home disk did not attach.'
device=$(readlink -f "$device")
devices=$(lsblk -nr -o NAME "$device")
[ "$(printf '%s\n' "$devices" | wc -l)" -eq 1 ] || fail 'Partitioned home disk requires operator recovery.'
mounts=$(lsblk -nr -o MOUNTPOINT "$device")
[ -z "$mounts" ] || fail 'Home disk is unexpectedly mounted.'
mkdir -p "$home"
mountpoint -q "$home" && fail 'Home is unexpectedly mounted.'

status=0
filesystem=$(blkid -p -s TYPE -o value "$device") || status=$?
case "$status:$filesystem" in
  0:ext4) ;;
  2:)
    # No signature alone is NOT evidence of a new disk (it may be damaged).
    signatures=$(wipefs --no-act --noheadings --output TYPE "$device")
    [ -z "$signatures" ] || fail 'Unrecognized disk signatures; refusing format.'
    bytes=$(blockdev --getsize64 "$device")
    [ "$bytes" -gt 0 ] || fail 'Invalid disk size; refusing format.'
    cmp --silent --bytes="$bytes" "$device" /dev/zero || fail 'Nonblank disk without ext4; refusing format.'
    mkfs.ext4 -L coder_home "$device"
    ;;
  *) fail 'Unsupported or unreadable filesystem; refusing format.' ;;
esac

# Mount failure is terminal: no repair/reformat fallback, no agent on OS home.
mount -t ext4 -o nodev,nosuid "$device" "$home"
mountpoint -q "$home" || fail 'Persistent home mount verification failed.'
chown coder:coder "$home"
chmod 0750 "$home"
