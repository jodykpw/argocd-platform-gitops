#!/usr/bin/env bash
# Prepare ONE worker node for Longhorn (V1 engine). Run on each worker, as a user with sudo.
#
#   ./longhorn-node-prep.sh            # dry run: checks and prints what it would do
#   ./longhorn-node-prep.sh --apply    # does it
#
# What it does (see platform-gitops/docs/storage-longhorn.md):
#   1. loads the iscsi_tcp kernel module and makes it load at boot
#   2. blacklists /dev/sd* in multipath so multipathd cannot grab Longhorn volumes
#   3. formats the raw disk /dev/sdb (ext4) and mounts it at /mnt/longhorn (by UUID, in /etc/fstab)
#   4. deletes the OLD Longhorn data in /var/lib/longhorn (September 2025 leftovers)
#
# It refuses to run if: iSCSI sessions exist, anything is mounted from longhorn paths,
# /dev/sdb already has a filesystem or partitions, or /dev/sdb is the root disk.
set -euo pipefail

DISK=/dev/sdb
MNT=/mnt/longhorn
OLD=/var/lib/longhorn
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

say()  { printf '%s\n' "$*"; }
doit() { say "+ $*"; [ "$APPLY" = 1 ] && eval "$@"; return 0; }
die()  { say "ABORT: $*"; exit 1; }

say "host: $(hostname)   mode: $([ "$APPLY" = 1 ] && echo APPLY || echo dry-run)"
sudo -n true 2>/dev/null || die "passwordless sudo needed"

# ---- guards --------------------------------------------------------------------------
[ -b "$DISK" ] || die "$DISK does not exist"
ROOT_SRC=$(findmnt -no SOURCE /)
case "$ROOT_SRC" in "$DISK"*) die "$DISK holds the root filesystem" ;; esac
if sudo -n iscsiadm -m session >/dev/null 2>&1; then die "active iSCSI sessions: Longhorn volumes in use"; fi
if findmnt -rn | grep -q -E 'longhorn|pvc-'; then die "a Longhorn/pvc volume is mounted"; fi
if [ -n "$(lsblk -no FSTYPE,MOUNTPOINT "$DISK" | tr -d '[:space:]')" ] || [ "$(lsblk -no NAME "$DISK" | wc -l)" -gt 1 ]; then
  die "$DISK already has a filesystem, mount or partitions; look at it by hand"
fi
if [ -n "$(sudo -n wipefs -n "$DISK")" ]; then die "$DISK has signatures (wipefs -n); look at it by hand"; fi
if mountpoint -q "$MNT" 2>/dev/null; then die "$MNT is already a mount point"; fi
say "guards passed"

# ---- 1. iscsi_tcp -----------------------------------------------------------------------
say; say "== 1. iscsi_tcp"
doit "sudo modprobe iscsi_tcp"
doit "echo iscsi_tcp | sudo tee /etc/modules-load.d/longhorn.conf >/dev/null"

# ---- 2. multipath blacklist -------------------------------------------------------------
say; say "== 2. multipath blacklist"
if sudo -n grep -q 'sd\[a-z0-9\]' /etc/multipath.conf 2>/dev/null; then
  say "already blacklisted"
else
  doit "sudo cp -a /etc/multipath.conf /etc/multipath.conf.bak-\$(date +%F)"
  doit "printf 'blacklist {\n    devnode \"^sd[a-z0-9]+\"\n}\n' | sudo tee -a /etc/multipath.conf >/dev/null"
  doit "sudo systemctl restart multipathd"
fi

# ---- 3. disk ----------------------------------------------------------------------------
say; say "== 3. format $DISK and mount at $MNT"
doit "sudo mkfs.ext4 -F -L longhorn $DISK"
doit "sudo mkdir -p $MNT"
if [ "$APPLY" = 1 ]; then
  UUID=$(sudo blkid -s UUID -o value "$DISK")
  echo "UUID=$UUID $MNT ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab >/dev/null
  say "+ fstab entry for UUID=$UUID"
  sudo mount "$MNT"
else
  say "+ add 'UUID=<new> $MNT ext4 defaults,nofail 0 2' to /etc/fstab, then mount $MNT"
fi

# ---- 4. old data --------------------------------------------------------------------------
say; say "== 4. old Longhorn data in $OLD"
if [ -d "$OLD" ]; then
  sudo -n ls -la "$OLD" || true
  doit "sudo find $OLD -mindepth 1 -delete"
else
  say "$OLD does not exist"
fi

# ---- result -------------------------------------------------------------------------------
say; say "== result"
lsmod | grep -E '^iscsi_tcp' || say "iscsi_tcp: not loaded (expected in dry-run)"
findmnt "$MNT" || say "$MNT: not mounted (expected in dry-run)"
systemctl is-active multipathd || true
ls -A "$OLD" 2>/dev/null | wc -l | xargs -I{} echo "{} entries left in $OLD"
