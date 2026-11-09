#!/usr/bin/env bash
# Publishes a built OTA package as a GitHub release and points the LineageOS Updater at it.
#
#   scripts/release.sh <tag> [<ota.zip>] [<recovery.img>]            dry run: checks and prints
#   scripts/release.sh --publish <tag> [<ota.zip>] [<recovery.img>]  creates the release, writes
#                                                                    ota/gts210ltexx.json, commits
#                                                                    and pushes it
# <tag> names the release, e.g. build14. The package defaults to the newest
# lineage-24.0-*-UNOFFICIAL-gts210ltexx.zip in the build output, recovery.img to the one next to it.
#
# The Updater reads lineage.updater.uri (set in device/gts210ltexx/device.mk) and expects a JSON
# list as described in packages/apps/Updater/README.md; "type" and "version" must match
# ro.lineage.releasetype and ro.lineage.build.version, "datetime" must be newer than the
# installed build.
#
# Refuses to publish: a build with adb open without authorization (WITH_ADB_INSECURE), a build
# not signed with the keys in keys/ (scripts/check-own-keys.sh), a package whose name or device
# does not match.
set -euo pipefail
W=${GTS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
L=${LINEAGE_ROOT:-$W/lineage}
OUT=$L/out/target/product/gts210ltexx
PUB=${PUBLISH_REPO:-$W/publish/gts210ltexx-patches}
GH_REPO=programista-zacny/gts210ltexx-patches
BRANCH=lineage-24.0
JSON_REL=ota/gts210ltexx.json

PUBLISH=0
[ "${1:-}" = "--publish" ] && { PUBLISH=1; shift; }
TAG=${1:?usage: scripts/release.sh [--publish] <tag> [<ota.zip>] [<recovery.img>]}
ZIP=${2:-$(ls -t "$OUT"/lineage-24.0-*-UNOFFICIAL-gts210ltexx.zip 2>/dev/null | head -1)}
REC=${3:-$OUT/recovery.img}
[ -f "$ZIP" ] || { echo "no OTA package found" >&2; exit 1; }
[ -f "$REC" ] || { echo "no recovery.img found" >&2; exit 1; }
FILENAME=$(basename "$ZIP")
case "$FILENAME" in lineage-24.0-*-UNOFFICIAL-gts210ltexx.zip) ;; *)
    echo "unexpected package name: $FILENAME" >&2; exit 1;; esac

meta=$(unzip -p "$ZIP" META-INF/com/android/metadata)
# The build leaves the same package under several dated names (hard links). Publish it under
# the name LineageOS gives it on its build day (UTC), whichever link was picked above.
canon="lineage-24.0-$(date -u -d @"$(printf '%s\n' "$meta" | sed -n 's/^post-timestamp=//p' | head -1)" +%Y%m%d)-UNOFFICIAL-gts210ltexx.zip"
if [ "$FILENAME" != "$canon" ]; then
    if [ -f "$(dirname "$ZIP")/$canon" ] && [ "$(dirname "$ZIP")/$canon" -ef "$ZIP" ]; then
        ZIP="$(dirname "$ZIP")/$canon"; FILENAME=$canon
    else
        echo "package name $FILENAME does not match its build date ($canon); pass the right file" >&2; exit 1
    fi
fi
get() { printf '%s\n' "$meta" | sed -n "s/^$1=//p" | head -1; }
device=$(get pre-device); ts=$(get post-timestamp)
spl=$(get post-security-patch-level); sdk=$(get post-sdk-level)
case ",$device," in *,gts210ltexx,*) ;; *) echo "package is for '$device'" >&2; exit 1;; esac
[ -n "$ts" ] || { echo "no post-timestamp in the package metadata" >&2; exit 1; }

# adb must be secured. The package does not expose build.prop directly, so check the build output
# it was made from: it must be at least as new as the package's timestamp.
prop() { grep -h "^$1=" "$OUT"/system/build.prop "$OUT"/system/product/etc/build.prop \
         "$OUT"/system/system_ext/etc/build.prop "$OUT"/system/vendor/build.prop 2>/dev/null | tail -1 | cut -d= -f2-; }
out_ts=$(prop ro.build.date.utc)
if [ "$out_ts" != "$ts" ]; then
    echo "the build output (ro.build.date.utc=$out_ts) is not the build of this package ($ts);" >&2
    echo "cannot check its adb settings, refusing" >&2; exit 1
fi
if [ "$(prop service.adb.root)" = 1 ] || [ "$(prop ro.adb.secure)" = 0 ]; then
    echo "this build has adb open without authorization (WITH_ADB_INSECURE): never publish it" >&2; exit 1
fi
if ! "$W/scripts/check-own-keys.sh" 2>/dev/null | grep -q '^RESULT: build is signed with the keys in'; then
    echo "scripts/check-own-keys.sh does not confirm own-key signing for this package" >&2; exit 1
fi

sha=$(sha256sum "$ZIP" | cut -d' ' -f1); size=$(stat -c %s "$ZIP")
rsha=$(sha256sum "$REC" | cut -d' ' -f1)
URL="https://github.com/$GH_REPO/releases/download/$TAG/$FILENAME"
JSON=$(python3 - "$ts" "$FILENAME" "$spl" "$sdk" "$sha" "$size" "$URL" <<'EOF'
import json, sys
ts, fn, spl, sdk, sha, size, url = sys.argv[1:]
f = {"filename": fn, "sha256": sha, "size": int(size), "url": url}
if spl: f["os_patch_level"] = spl
if sdk: f["os_sdk_level"] = int(sdk)
print(json.dumps([{"datetime": int(ts), "files": [f], "type": "UNOFFICIAL", "version": "24.0"}], indent=2))
EOF
)
NOTES="LineageOS 24.0 (Android 17) for the Samsung Galaxy Tab S2 9.7 LTE (SM-T815), Wi-Fi only, microG.
Built from branch $BRANCH at $(git -C "$PUB" rev-parse --short HEAD 2>/dev/null || echo '?').

- $FILENAME: sha256 $sha
- recovery.img (Lineage Recovery): sha256 $rsha

Signed with the maintainer's own keys; installing over a build with other keys needs a clean flash.
Devices on an earlier build from this page get it through Settings > System > Updater."

echo "release tag:   $TAG"
echo "package:       $ZIP ($size bytes)"
echo "               sha256 $sha, built $(date -d @"$ts" '+%Y-%m-%d %H:%M %Z'), patch level $spl, sdk $sdk"
echo "recovery:      $REC (sha256 $rsha)"
echo "adb:           secured; keys: own"
echo "download URL:  $URL"
echo "$JSON_REL:"; echo "$JSON"
if [ "$PUBLISH" != 1 ]; then
    echo; echo "dry run: nothing published (add --publish)"; exit 0
fi

[ -z "$(git -C "$PUB" status --porcelain)" ] || { echo "$PUB has uncommitted changes" >&2; exit 1; }
gh release create "$TAG" "$ZIP" "$REC#recovery.img" --repo "$GH_REPO" --target "$BRANCH" \
    --title "LineageOS 24.0 for SM-T815, $TAG" --notes "$NOTES"
mkdir -p "$PUB/ota"
printf '%s\n' "$JSON" > "$PUB/$JSON_REL"
git -C "$PUB" add "$JSON_REL"
git -C "$PUB" commit -q -m "OTA: $TAG

Points the LineageOS Updater at $FILENAME of release $TAG."
git -C "$PUB" push origin "$BRANCH"
echo "published $TAG; the Updater sees it at the next check"
