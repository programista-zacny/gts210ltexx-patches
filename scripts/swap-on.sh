#!/usr/bin/env bash
# Extra swap for LineageOS builds: the Soong/Kati analysis peaks far above 30 GB of RAM.
#
#   scripts/swap-on.sh        enable it, creating it first if needed (asks for sudo)
#   scripts/swap-on.sh off    disable it again
#
# The file is /swap/swapfile (16 GiB) in its own btrfs subvolume /swap. On btrfs a swap file
# must not be copy-on-write; snapshots of / (snapper, limine-snapper-sync) share its blocks and
# make swapon fail with "Invalid argument" ("swapfile must not be copy-on-write" in dmesg).
# Snapshots of / do not include nested subvolumes, so a file in /swap stays usable. If the file
# is unusable anyway, it is recreated (it never holds data across a swapoff).
# It is enabled with priority -2, below zram, so it is only used when zram is full.
# Override with SWAP_SUBVOL=/path and SWAP_SIZE=24g.
set -euo pipefail
SUBVOL=${SWAP_SUBVOL:-/swap}
FILE=$SUBVOL/swapfile
SIZE=${SWAP_SIZE:-16g}
PRIO=-2

active() { swapon --show=NAME --noheadings | grep -qx "$FILE"; }

case "${1:-on}" in
    off)
        if active; then sudo swapoff "$FILE" && echo "swap off: $FILE"; else echo "not active: $FILE"; fi
        exit 0 ;;
    on) ;;
    *) echo "usage: $0 [on|off]" >&2; exit 1 ;;
esac

if active; then
    echo "already active: $FILE"; swapon --show; exit 0
fi

fstype=$(findmnt -n -o FSTYPE -T "$(dirname "$SUBVOL")")
if [ ! -d "$SUBVOL" ]; then
    if [ "$fstype" = btrfs ]; then
        sudo btrfs subvolume create "$SUBVOL"
    else
        sudo mkdir -p "$SUBVOL"
    fi
elif [ "$fstype" = btrfs ] && ! sudo btrfs subvolume show "$SUBVOL" >/dev/null 2>&1; then
    echo "$SUBVOL exists but is not a btrfs subvolume: snapshots of / would break a swap file in it" >&2
    exit 1
fi

if [ -f "$FILE" ] && sudo swapon -p "$PRIO" "$FILE" 2>/dev/null; then
    :
else
    if [ -f "$FILE" ]; then
        echo "$FILE cannot be enabled ($(sudo dmesg 2>/dev/null | grep -i swapfile | tail -1 | sed 's/^\[[^]]*\] //'))"
        echo "recreating it"
        sudo rm -f "$FILE"
    fi
    if [ "$(findmnt -n -o FSTYPE -T "$SUBVOL")" = btrfs ]; then
        sudo btrfs filesystem mkswapfile --size "$SIZE" "$FILE"
    else
        sudo fallocate -l "$SIZE" "$FILE"
        sudo chmod 600 "$FILE"
        sudo mkswap "$FILE" >/dev/null
    fi
    sudo swapon -p "$PRIO" "$FILE"
fi
echo "swap on: $FILE"
swapon --show
if [ -e /swapfile-build ]; then
    echo "note: the old /swapfile-build is no longer used; remove it with: sudo rm /swapfile-build"
fi
