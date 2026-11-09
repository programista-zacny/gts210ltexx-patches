#!/usr/bin/env bash
# Builds LineageOS 24.0 for gts210ltexx (SM-T815, Wi-Fi only, with microG).
# Usage: scripts/build.sh [make goals...]   (default: brunch = full OTA zip)
set -uo pipefail
# Project root: GTS_ROOT, else the directory above this script. LineageOS tree: LINEAGE_ROOT,
# else lineage/ in the project root. An env.sh in the project root, if there is one, is sourced.
W=${GTS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
if [ -f "$W/env.sh" ]; then source "$W/env.sh"; fi
L=${LINEAGE_ROOT:-$W/lineage}
"$W/scripts/prepare-tree.sh" || exit 1
cd "$L" || exit 1
export WITH_GMS="${WITH_GMS:-true}"      # microG + F-Droid from vendor/partner_gms
# adb is secured by default, as in official LineageOS (userdebug): authorize the computer once
# on the tablet, then "Rooted debugging" in Developer options gives `adb root`. For a bring-up
# build whose boot may hang before the UI, pass WITH_ADB_INSECURE=true: adb then works without
# authorization and as root from the first start. Never publish such a build.
export WITH_ADB_INSECURE="${WITH_ADB_INSECURE-}"
[ -n "$WITH_ADB_INSECURE" ] || unset WITH_ADB_INSECURE
# Keep ro.debuggable=1 (userdebug) with secured adb, so "Rooted debugging" stays available for
# diagnosis; LineageOS would set ro.debuggable=0 (patches/vendor_lineage/0001 adds this switch).
# Pass LINEAGE_KEEP_DEBUGGABLE_IN_USERDEBUG= (empty) for the official behaviour.
export LINEAGE_KEEP_DEBUGGABLE_IN_USERDEBUG="${LINEAGE_KEEP_DEBUGGABLE_IN_USERDEBUG-true}"

# --- own signing keys: opt-in with OWN_KEYS=1 (see "Own signing keys" in README.md) -----------
# With OWN_KEYS=1 prepare-tree.sh (above) has installed keys/ as vendor/lineage-priv/keys and the
# build signs with them (ro.build.tags=release-keys) instead of the public test keys. Meant for
# the published builds (adb secured by default, see above). Without OWN_KEYS this
# block does nothing.
if [ "${OWN_KEYS:-}" = 1 ]; then
    if [ ! -f vendor/lineage-priv/keys/keys.mk ]; then
        echo "OWN_KEYS=1, but vendor/lineage-priv/keys/keys.mk is not in the tree" >&2
        exit 1
    fi
    echo "OWN_KEYS=1: signing with own keys from vendor/lineage-priv/keys"
    if [ -n "${WITH_ADB_INSECURE:-}" ]; then
        echo "WARNING: OWN_KEYS=1 with WITH_ADB_INSECURE=$WITH_ADB_INSECURE: adb stays open without authorization." >&2
        echo "         Do not publish this build." >&2
    fi
fi
# --- end of own signing keys --------------------------------------------------------------------

export LC_ALL=C
export USE_CCACHE=0
# Parallelism: 20 jobs on 30 GB RAM ran the host out of memory in the Java/dex phase
# (2026-11-06, ~73%); 12 jobs finished cleanly. Override with BUILD_JOBS=N.
JOBS="${BUILD_JOBS:-12}"
# Heavy "highmem" steps (metalava, R8, ...) one at a time; Soong's default for <=32 GB is 2.
export NINJA_HIGHMEM_NUM_JOBS="${NINJA_HIGHMEM_NUM_JOBS:-1}"
# Memory trace every 30 s, so the real peak is known after the build.
mkdir -p "$W/logs"
( while :; do
      printf '%s %s\n' "$(date +%T)" "$(awk '/MemAvailable|SwapFree/ {printf "%s %d MB  ", $1, $2/1024}' /proc/meminfo)"
      sleep 30
  done ) >> "$W/logs/build-mem.log" 2>/dev/null &
MEMLOG_PID=$!
trap 'kill $MEMLOG_PID 2>/dev/null' EXIT
set +u
source build/envsetup.sh || exit 1
[ $# -gt 0 ] || set -- bacon          # bacon = full OTA zip (what brunch builds)
breakfast gts210ltexx userdebug && m -j"$JOBS" "$@"
