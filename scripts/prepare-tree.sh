#!/usr/bin/env bash
# Copies the gts210ltexx device tree, proprietary blobs and kernel defconfig
# from this project into the LineageOS source tree, and applies local patches.
# Safe to re-run.
set -euo pipefail
# Project root: GTS_ROOT, else the directory above this script. LineageOS tree: LINEAGE_ROOT,
# else lineage/ in the project root.
W=${GTS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
L=${LINEAGE_ROOT:-$W/lineage}
# Samsung blobs: a checkout of proprietary_vendor_samsung_gts210ltexx (see README.md).
VENDOR_BLOBS=${VENDOR_BLOBS:-$W/vendor/gts210ltexx}
K=$L/kernel/samsung/universal5433

if [ ! -f "$VENDOR_BLOBS/gts210ltexx-vendor.mk" ]; then
    echo "no Samsung blobs in $VENDOR_BLOBS: clone proprietary_vendor_samsung_gts210ltexx there, or set VENDOR_BLOBS" >&2
    exit 1
fi
# The two prebuilt APKs are not kept in git; scripts/fetch-prebuilts.sh downloads them.
for apk in device/gts210ltexx/prebuilt/AuroraStore/AuroraStore.apk \
           tree-overrides/vendor/partner_gms/GmsCore/GmsCore.apk; do
    if [ ! -f "$W/$apk" ]; then
        echo "$apk is missing: run scripts/fetch-prebuilts.sh" >&2
        exit 1
    fi
done

mkdir -p "$L/device/samsung/gts210ltexx" "$L/vendor/samsung/gts210ltexx"
rsync -a --delete "$W/device/gts210ltexx/" "$L/device/samsung/gts210ltexx/"
rsync -a --delete --exclude=/.git --exclude=/README.md "$VENDOR_BLOBS/" "$L/vendor/samsung/gts210ltexx/"
cp "$W/kernel/lineage_gts210ltexx_defconfig" "$K/arch/arm/configs/lineage_gts210ltexx_defconfig"

# local patches: patches/<name>/*.patch applied to the repo listed in patches/<name>/TARGET
for dir in "$W"/patches/*/; do
    [ -f "$dir/TARGET" ] || continue
    repo="$L/$(cat "$dir/TARGET")"
    for p in "$dir"/*.patch; do
        [ -e "$p" ] || continue
        if git -C "$repo" apply --reverse --check "$p" 2>/dev/null; then
            echo "already applied: $(basename "$p")"
        else
            git -C "$repo" apply "$p"
            echo "applied: $(basename "$p")"
        fi
    done
done
# file overrides: tree-overrides/<path> replaces lineage/<path> (see tree-overrides/README)
if [ -d "$W/tree-overrides" ]; then
    rsync -a --exclude=README "$W/tree-overrides/" "$L/"
    echo "tree overrides copied: $(cd "$W/tree-overrides" && find . -type f ! -name README | sed 's|^\./||' | tr '\n' ' ')"
fi

# --- own signing keys: opt-in with OWN_KEYS=1 (see "Own signing keys" in README.md) -----------
# OWN_KEYS=1 copies keys/ to vendor/lineage-priv/keys; vendor/lineage/config/common.mk includes
# keys.mk from there and the build signs with these keys instead of the public test keys.
# Without OWN_KEYS a copy left by an earlier OWN_KEYS=1 run is removed again, so the build is a
# test-keys build as before; when there is no such copy, nothing is done and nothing is printed.
PRIV=$L/vendor/lineage-priv
case "${OWN_KEYS:-}" in
    1)
        if [ ! -f "$W/keys/keys.mk" ] || [ ! -f "$W/keys/testkey.pk8" ]; then
            echo "OWN_KEYS=1, but $W/keys is missing or incomplete" >&2
            exit 1
        fi
        mkdir -p "$PRIV/keys"
        chmod 700 "$PRIV" "$PRIV/keys"
        rsync -a --delete --exclude=/README "$W/keys/" "$PRIV/keys/"
        touch "$PRIV/.installed-by-prepare-tree"
        echo "own signing keys installed: vendor/lineage-priv/keys"
        ;;
    ""|0)
        if [ -e "$PRIV/keys" ]; then
            if [ ! -f "$PRIV/.installed-by-prepare-tree" ]; then
                echo "vendor/lineage-priv/keys exists but was not put there by this script; remove it by hand" >&2
                exit 1
            fi
            rm -rf "$PRIV/keys" "$PRIV/.installed-by-prepare-tree"
            rmdir "$PRIV" 2>/dev/null || true
            echo "own signing keys removed from the tree: vendor/lineage-priv/keys"
        fi
        ;;
    *)
        echo "OWN_KEYS must be 1, 0 or unset (got '$OWN_KEYS')" >&2
        exit 1
        ;;
esac
# --- end of own signing keys --------------------------------------------------------------------

echo "tree prepared for gts210ltexx"
