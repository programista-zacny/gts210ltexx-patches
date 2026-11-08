#!/usr/bin/env bash
# Downloads the two prebuilt APKs that are not kept in git into the places the build expects,
# and verifies them: the sha256 always, the signer certificate when apksigner is available.
#   device/gts210ltexx/prebuilt/AuroraStore/AuroraStore.apk   Aurora Store 4.8.4
#   tree-overrides/vendor/partner_gms/GmsCore/GmsCore.apk     microG GmsCore 0.3.16.252432
# A file that is already there with the right sha256 is not downloaded again.
# Usage: scripts/fetch-prebuilts.sh [--force]      (--force: download even if present)
# apksigner is looked for in this order: $APKSIGNER, the LineageOS tree's prebuilt JDK with
# prebuilts/sdk/tools/linux/lib/apksigner.jar, out/host/linux-x86/bin/apksigner, apksigner in PATH.
set -euo pipefail
W=${GTS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
L=${LINEAGE_ROOT:-$W/lineage}
FORCE=0
case "${1:-}" in
    "") ;;
    --force) FORCE=1 ;;
    *) echo "usage: $0 [--force]" >&2; exit 2 ;;
esac

# name | path under the project root | URL | sha256 | signer certificate SHA-256
PREBUILTS=(
    "Aurora Store 4.8.4 (versionCode 76)|device/gts210ltexx/prebuilt/AuroraStore/AuroraStore.apk|https://f-droid.org/repo/com.aurora.store_76.apk|fd9c75d90d0f4a7c132b9b4a5a2cf1992a45e03b8d8ff988b7dcfbc0db2c4d11|5c83c7672b929955dc0a1db89a5e6ae4389e2eae7ec939956041694e5815f532"
    "microG GmsCore 0.3.16.252432 (versionCode 252432032)|tree-overrides/vendor/partner_gms/GmsCore/GmsCore.apk|https://github.com/microg/GmsCore/releases/download/v0.3.16.252432/com.google.android.gms-252432032.apk|169a53df557e6577322e7cc8aa3389cb82b3d6408dd162433cc94f1d084a73d4|9bd06727e62796c0130eb6dab39b73157451582cbd138e86c468acc395d14165"
)

# apksigner as a command array, or empty when none is found
SIGNER=()
if [ -n "${APKSIGNER:-}" ]; then
    SIGNER=("$APKSIGNER")
elif [ -x "$L/prebuilts/jdk/jdk21/linux-x86/bin/java" ] && [ -f "$L/prebuilts/sdk/tools/linux/lib/apksigner.jar" ]; then
    SIGNER=("$L/prebuilts/jdk/jdk21/linux-x86/bin/java" -jar "$L/prebuilts/sdk/tools/linux/lib/apksigner.jar")
elif [ -x "$L/out/host/linux-x86/bin/apksigner" ]; then
    SIGNER=("$L/out/host/linux-x86/bin/apksigner")
elif command -v apksigner >/dev/null 2>&1; then
    SIGNER=(apksigner)
fi

download() {  # download URL FILE
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --connect-timeout 30 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$2" "$1"
    else
        echo "neither curl nor wget is installed" >&2
        return 1
    fi
}

fail=0
for entry in "${PREBUILTS[@]}"; do
    IFS='|' read -r name path url sha signer <<< "$entry"
    dest=$W/$path
    mkdir -p "$(dirname "$dest")"
    if [ "$FORCE" = 0 ] && [ -f "$dest" ] && [ "$(sha256sum < "$dest" | cut -d' ' -f1)" = "$sha" ]; then
        echo "present:    $path"
    else
        echo "downloading $name"
        tmp="$dest.part"
        rm -f "$tmp"
        if ! download "$url" "$tmp"; then
            rm -f "$tmp"
            echo "FAIL: download of $url failed" >&2
            fail=1
            continue
        fi
        got=$(sha256sum < "$tmp" | cut -d' ' -f1)
        if [ "$got" != "$sha" ]; then
            rm -f "$tmp"
            echo "FAIL: $path: sha256 $got, expected $sha; file not installed" >&2
            fail=1
            continue
        fi
        mv -f "$tmp" "$dest"
        echo "downloaded: $path"
    fi
    echo "  sha256 ok: $sha"
    if [ ${#SIGNER[@]} -gt 0 ]; then
        certs=$("${SIGNER[@]}" verify --print-certs "$dest" 2>/dev/null) || certs=""
        got=$(printf '%s\n' "$certs" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p')
        if printf '%s\n' "$certs" | grep -q '^Signer #2 '; then
            echo "FAIL: $path has more than one signer" >&2
            fail=1
        elif [ "$got" = "$signer" ]; then
            echo "  signer ok: $signer"
        else
            echo "FAIL: $path: signer ${got:-unreadable (apksigner verify failed)}, expected $signer" >&2
            fail=1
        fi
    else
        echo "  signer check skipped: no apksigner found (set APKSIGNER, or sync the LineageOS tree first)"
    fi
done
[ "$fail" = 0 ] || { echo "RESULT: not all prebuilts are in place" >&2; exit 1; }
echo "RESULT: prebuilts in place"
