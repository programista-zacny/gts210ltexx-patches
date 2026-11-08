#!/usr/bin/env bash
# After an OWN_KEYS=1 build: checks that the build outputs are signed with the keys in keys/
# and not with the public test keys. Read-only; runs on the host with the tree's prebuilt JDK
# and apksigner (takes a few seconds).
# Usage: scripts/check-own-keys.sh [keys-dir]        (default: keys/)
set -uo pipefail
W=${GTS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
L=${LINEAGE_ROOT:-$W/lineage}
O=$L/out/target/product/gts210ltexx
K=${1:-$W/keys}
JAVA=$L/prebuilts/jdk/jdk21/linux-x86/bin/java
APKSIGNER=$L/prebuilts/sdk/tools/linux/lib/apksigner.jar
APKCERTS=$O/obj/PACKAGING/target_files_intermediates/lineage_gts210ltexx-target_files/META/apkcerts.txt
APEXKEYS=$O/obj/PACKAGING/apexkeys_intermediates/apexkeys.txt
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok()  { echo "ok:   $*"; }
bad() { echo "FAIL: $*"; fail=1; }
der_sha() { openssl x509 -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1; }

# 1. build tags (what Trust looks at)
tags=$(sed -n 's/^ro\.build\.tags=//p' "$O/system/build.prop")
if [ "$tags" = release-keys ]; then ok "ro.build.tags=$tags"; else bad "ro.build.tags=$tags (expected release-keys)"; fi

# 2. signer of the OTA zip, and the certificates the system and the recovery accept for updates
want=$(der_sha < "$K/testkey.x509.pem")
zip=$(ls -t "$O"/lineage-*.zip 2>/dev/null | head -1)
if [ -n "$zip" ] && [ "$(unzip -p "$zip" META-INF/com/android/otacert | der_sha)" = "$want" ]; then
    ok "$(basename "$zip") is signed with keys/testkey"
else
    bad "${zip:-no lineage-*.zip in $O} is not signed with keys/testkey"
fi
for z in system/etc/security/otacerts.zip recovery/root/system/etc/security/otacerts.zip; do
    members=$(unzip -Z1 "$O/$z" 2>/dev/null)
    good=1
    [ -n "$members" ] || good=0
    for m in $members; do
        [ "$(unzip -p "$O/$z" "$m" | der_sha)" = "$want" ] || good=0
    done
    if [ $good = 1 ]; then ok "$z holds only keys/testkey"; else bad "$z holds: $(echo $members)"; fi
done

# 3. every APK and APEX of the image is signed with a certificate from keys/, or is one of the
#    prebuilts that the build leaves presigned (microG, F-Droid, Aurora Store, CTS shim)
for c in "$K"/*.x509.pem; do der_sha < "$c"; done | sort -u > "$tmp/known"
{ sed -n 's/^name="\([^"]*\)" certificate="PRESIGNED".*/\1/p' "$APKCERTS"
  sed -n 's/^name="\([^"]*\)" public_key="PRESIGNED".*/\1/p' "$APEXKEYS"; } | sort -u > "$tmp/presigned"
roots=("$O/system" "$O/recovery/root")
while read -r a; do   # contents of the image's APEXes, as unpacked by the build under $O/apex/<name>
    d=$O/apex/$(basename "${a%.*}")
    [ -d "$d" ] && roots+=("$d")
done < <(find "$O/system" -type f \( -name '*.apex' -o -name '*.capex' \))
find "${roots[@]}" -type f \( -name '*.apk' -o -name '*.apex' -o -name '*.capex' \) |
    xargs -P "$(nproc)" -I{} sh -c '
        d=$("$1" -jar "$2" verify --print-certs "$3" 2>/dev/null | sed -n "s/^Signer #1 certificate SHA-256 digest: //p")
        echo "${d:-none} $3"' _ "$JAVA" "$APKSIGNER" {} | sort -k2 > "$tmp/signers"
own=0; kept=""; other=0
while read -r digest path; do
    if grep -qx "$digest" "$tmp/known"; then
        own=$((own + 1))
    elif grep -qx "$(basename "$path")" "$tmp/presigned"; then
        kept="$kept $(basename "$path")"
    else
        other=$((other + 1))
        [ $other -le 15 ] && echo "      not signed with a key from keys/: ${path#"$O"/} ($digest)"
    fi
done < "$tmp/signers"
[ $other -gt 15 ] && echo "      ... and $((other - 15)) more"
if [ $other = 0 ] && [ $own -gt 0 ]; then
    ok "$own APKs/APEXes signed with keys from keys/"
else
    bad "$other APKs/APEXes not signed with a key from keys/ ($own are)"
fi
echo "      left presigned:${kept:- none}"

# 4. APEX payload keys: the public key packed into each APEX is the one from keys/
n=0; wrong=""
while read -r name pub; do
    apex=$(find "$O/system" -type f -name "$name" | head -1)
    [ -n "$apex" ] || continue
    n=$((n + 1))
    unzip -p "$apex" apex_pubkey 2>/dev/null | cmp -s - "$K/$(basename "$pub")" || wrong="$wrong $name"
done < <(sed -n 's/^name="\([^"]*\)" public_key="\([^"]*\)".*/\1 \2/p' "$APEXKEYS" | grep -v ' PRESIGNED$')
if [ -z "$wrong" ] && [ $n -gt 0 ]; then
    ok "$n APEX payloads signed with keys from keys/"
else
    bad "APEX payload key not from keys/:${wrong:- (no APEX found)}"
fi

if [ $fail = 0 ]; then echo "RESULT: build is signed with the keys in $K"; else echo "RESULT: NOT a clean own-keys build"; fi
exit $fail
