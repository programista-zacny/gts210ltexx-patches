#!/usr/bin/env bash
# Standard health check of the tablet after flashing a build. Read-only on the device,
# except for the optional launch test. Results go to logs/check-<time>/ and a
# PASS/WARN/FAIL/SKIP/INFO summary is printed.
#
# Usage: scripts/device-check.sh [--baseline DIR] [--launch] [--out DIR] [--label TEXT]
#   --baseline DIR   earlier check directory; result levels, the kernel feature table, SELinux
#                    denials and failed init commands are compared against it
#   --launch         also measure 5 cold starts of Settings (screen must be on and unlocked;
#                    opens and closes Settings, then returns to the home screen)
#   --out DIR        output directory (default logs/check-YYYYmmdd-HHMMSS)
#   --label TEXT     free text stored in the summary (for example the build name)
#
# Levels: PASS healthy; WARN worth a look, or a feature of the next build that is not there;
#         FAIL broken; SKIP cannot be judged (no root adb, or the logs no longer reach back
#         to boot); INFO state only.
#
# Needs adb with the device in normal (booted) state. Kernel log, debugfs and /data checks
# need root adb, which bring-up builds have from boot; without it they are reported as SKIP.
#
# The log buffers on this device are short (logcat 256 KiB each, dmesg 15-40 minutes), so
# run the check within a few minutes of boot when the boot-time results matter. Results
# taken from a buffer that no longer covers boot say so in their line.
#
# Privacy: logcat holds the owner's account address, name and tokens. Everything that is
# saved or printed goes through redact(); "dumpsys account" is never called and dropbox
# entries are only listed, never printed. The output directory is re-scanned at the end.
# shellcheck disable=SC2015,SC2016
set -u
W=${GTS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
BASE="" ; LAUNCH=0 ; OUT="" ; LABEL=""
while [ $# -gt 0 ]; do
    case "$1" in
        --baseline) BASE="${2:?--baseline needs a directory}"; shift 2 ;;
        --launch)   LAUNCH=1; shift ;;
        --out)      OUT="${2:?--out needs a directory}"; shift 2 ;;
        --label)    LABEL="${2:?--label needs a text}"; shift 2 ;;
        -h|--help)  awk 'NR == 1 { next } /^# shellcheck/ { exit } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
[ -n "$OUT" ] || OUT="$W/logs/check-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT" || exit 2
SUM="$OUT/summary.txt"
: > "$SUM"
NFAIL=0; NWARN=0; NSKIP=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/device-check.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/timeouts"

# Every adb call runs under timeout(1), so a blocked read on the device cannot hang the check.
ADB_T=25
adb_() {  # adb_ SECONDS adb-args...   (output on stdout, CR removed; a timeout is recorded)
    local t=$1 rc; shift
    timeout -k 5 "$t" adb "$@" </dev/null 2>/dev/null | tr -d '\r\001\002'
    rc=${PIPESTATUS[0]}
    [ "$rc" = 124 ] || [ "$rc" = 137 ] && printf '%s\n' "$(printf '%s' "$*" | tr '\n' ' ' | cut -c1-70)" >> "$TMP/timeouts"
    return 0
}
sh_() { adb_ "$ADB_T" shell "$@"; }
shl() { local t=$1; shift; adb_ "$t" shell "$@"; }

num() { local v; v=$(printf '%s' "${1:-}" | tr -dc '0-9'); echo "${v:-0}"; }
kv()  { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }                    # kv BLOB key
sec() { printf '%s\n' "$1" | awk -v s="##$2" '$0 == s { f = 1; next } /^##/ { f = 0 } f'; }  # sec BLOB name
cnt() { local n; n=$(grep -a -c -E -- "$1" "$2" 2>/dev/null); echo "${n:-0}"; }   # cnt REGEX file
ts2s() { date -d "$1" +%s 2>/dev/null || echo 0; }
dur() {  # seconds -> 1h 02m 03s
    local s; s=$(num "${1:-0}")
    if [ "$s" -ge 3600 ]; then printf '%dh %02dm %02ds' $((s/3600)) $((s%3600/60)) $((s%60))
    elif [ "$s" -ge 60 ]; then printf '%dm %02ds' $((s/60)) $((s%60))
    else printf '%ds' "$s"; fi
}

# Keep account data out of everything that is saved or printed: microG logs addresses, names
# and tokens. Lines from GmsHttpFormClient and lines over 1500 bytes are dropped; the rest is
# rewritten. Byte-wise (LC_ALL=C), so that a multi-byte character cannot hide part of a match.
# The two control characters protect "name@1.0" HAL versions and "x@com.package.name" from the
# e-mail rule (an address at a domain that starts with digits "N.N" or with the labels
# com./org./android./androidx. followed by two more labels is therefore not recognised).
redact() {
    LC_ALL=C grep -a -v -F 'GmsHttpFormClient' | LC_ALL=C awk 'length($0) <= 1500' | LC_ALL=C sed -E \
        -e 's/\x01|\x02//g' \
        -e 's/(https?:\/\/[A-Za-z0-9.-]*(google[a-z]*|youtube|gstatic|ggpht|android)\.com[^ ?"]*)\?[^ "]*/\1?<query>/g' \
        -e 's/((Authorization|Cookie|Set-Cookie|X-PS-RH|X-DFE-[A-Za-z-]+|X-Goog-[A-Za-z-]+): *).*/\1<redacted>/' \
        -e 's/ya29\.[A-Za-z0-9_.-]+/<token>/g' \
        -e 's/(oauth2rt_|aas_et\/)[A-Za-z0-9_\/.+=-]*/<token>/g' \
        -e 's/eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)?/<token>/g' \
        -e 's/(jwt: *)[^ ]+/\1<token>/g' \
        -e 's/Bearer +[A-Za-z0-9._~+\/=-]{8,}/Bearer <token>/g' \
        -e 's/1\/\/[A-Za-z0-9_-]{20,}/<token>/g' \
        -e 's/((firstName|lastName|displayName|givenName|familyName|first_name|last_name|display_name)=)[^,&;})]*/\1<redacted>/g' \
        -e 's/((Auth|Token|EncryptedPasswd|Passwd|auth|token|SID|LSID|accountId|accountName|Email|email|droidguard_results|dg_response|access_token|refresh_token|id_token|oauth_token|authToken|password)=)[^& ]+/\1<redacted>/g' \
        -e 's/("(email|Email|firstName|lastName|displayName|givenName|familyName|name|access_token|refresh_token|id_token|token|Token|Auth|password)" *: *)"[^"]*"/\1"<redacted>"/g' \
        -e 's/(Account *\{name=)[^,}]*/\1<account>/g' \
        -e 's/@([0-9]+\.[0-9]+)([^A-Za-z0-9]|$)/\x01\1\2/g' \
        -e 's/@((com|org|android|androidx)\.[A-Za-z0-9_-]+\.[A-Za-z0-9_])/\x02\1/g' \
        -e 's/[A-Za-z0-9._%+\x80-\xff-]+(@|%40)[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/<account>/g' \
        -e 's/\x01|\x02/@/g' \
    | LC_ALL=C awk '{   # opaque blobs (base64 and the like) of 100+ characters; file paths are kept
        out = ""; s = $0
        while (match(s, /[A-Za-z0-9+\/_-]{100,}=?=?/)) {
            t = substr(s, RSTART, RLENGTH); keep = 0
            if (index(t, "/") && !index(t, "+") && t !~ /=$/) {
                keep = 1; n = split(t, seg, "/")
                for (i = 1; i <= n; i++) if (length(seg[i]) > 40) keep = 0
            }
            out = out substr(s, 1, RSTART - 1) (keep ? t : "<long-string>")
            s = substr(s, RSTART + RLENGTH)
        }
        print out s }'
}
# The filter needs interval expressions in awk and \xHH in sed (gawk, GNU sed): refuse to run
# rather than save unfiltered logs.
if [ "$(printf 'k=%0120d a@b.cd\n' 0 | redact 2>/dev/null)" != "k=<long-string> <account>" ]; then
    echo "the privacy filter does not work with this awk/sed (GNU awk and GNU sed are needed)" >&2; exit 2
fi
# What must never be left in a saved file (used by the final scan of the output directory).
LEAK_RE='GmsHttpFormClient|jwt: *eyJ|X-PS-RH: *[^< ]|ya29\.[A-Za-z0-9_-]|oauth2rt_[A-Za-z0-9]|aas_et/[A-Za-z0-9]|(^|[^A-Za-z])(Auth|Token|SID|LSID|firstName|lastName|accountId|Email)=[^<& ]|[A-Za-z0-9._%+-]+(@|%40)[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'
leaks() {  # leaks file -> number of lines that still match LEAK_RE or are too long
    local a b
    a=$(LC_ALL=C sed -E -e 's/@([0-9]+\.[0-9]+)([^A-Za-z0-9]|$)/\x01\1\2/g' \
                        -e 's/@((com|org|android|androidx)\.[A-Za-z0-9_-]+\.[A-Za-z0-9_])/\x02\1/g' "$1" \
        | LC_ALL=C grep -a -c -E -- "$LEAK_RE")
    b=$(LC_ALL=C awk 'length($0) > 1500 { n++ } END { print n + 0 }' "$1")
    echo $(( ${a:-0} + ${b:-0} ))
}

res() {  # res LEVEL name detail...   (printed and stored through the filter)
    local lvl=$1 name=$2; shift 2
    printf '%-5s %-28s %s\n' "$lvl" "$name" "$(printf '%s' "$*" | tr '\n\t' '  ' | cut -c1-700)" | redact | tee -a "$SUM"
    case "$lvl" in FAIL) NFAIL=$((NFAIL+1)) ;; WARN) NWARN=$((NWARN+1)) ;; SKIP) NSKIP=$((NSKIP+1)) ;; esac
}
note() { printf '        %s\n' "$*" | redact | tee -a "$SUM"; }   # indented continuation line
tops() { sort | uniq -c | sort -rn | head -n "${1:-4}" | sed -E 's/^ +//' | tr '\n' ';' | sed -E 's/;$//; s/;/; /g'; }

state=$(adb_ 15 get-state)
if [ "$state" != "device" ]; then
    res FAIL adb "device not in normal state (adb get-state: ${state:-none})"
    exit 1
fi

{ echo "check $(date '+%F %T')  label: ${LABEL:-none}"; echo "output: $OUT"; echo; } | redact | tee -a "$SUM"

# ---------------------------------------------------------------- identity, clocks, logcat first
# One device shell per group of reads: fewer adbd lines pushed into the short logcat buffers.
ID=$(sh_ 'echo "uid=$(id -u)"; echo "now=$(date "+%Y-%m-%d %H:%M:%S")"; echo "uptime=$(cut -d. -f1 /proc/uptime)"
echo "tainted=$(cat /proc/sys/kernel/tainted 2>/dev/null)"; echo "version=$(cat /proc/version)"
for p in ro.lineage.version ro.build.date ro.build.tags ro.build.type sys.boot_completed sys.system_server.start_count; do echo "$p=$(getprop $p)"; done
echo "##logcat_g"; logcat -g 2>/dev/null')
ROOT=$(kv "$ID" uid)
VER=$(kv "$ID" ro.lineage.version)
BDATE=$(kv "$ID" ro.build.date)
TAGS=$(kv "$ID" ro.build.tags)
BTYPE=$(kv "$ID" ro.build.type)
KERN=$(kv "$ID" version | cut -c1-110)
UP=$(num "$(kv "$ID" uptime)")
UPMIN=$((UP / 60))
BOOTC=$(kv "$ID" sys.boot_completed)
STARTS=$(kv "$ID" sys.system_server.start_count)
TAINT=$(kv "$ID" tainted)
DEVNOW=$(kv "$ID" now)
# Device wall-clock strings are compared in the workstation's zone: only differences matter.
NOW_W=$(ts2s "$DEVNOW"); [ "$NOW_W" -gt 0 ] || NOW_W=$(date +%s)
BOOT_W=$((NOW_W - UP))
BOOT_STR=$(date -d "@$BOOT_W" '+%F %T')

# Logcat is taken before the remaining checks add their own adbd lines. adbd logs every adb
# shell command line, so the analysis below works on a copy without adbd lines ($LC): a check
# must not find its own search pattern.
adb_ 90 logcat -b all -v threadtime -v year -d | redact > "$OUT/logcat-filtered.txt"
adb_ 60 logcat -b kernel -v threadtime -v year -d | redact > "$OUT/logcat-kernel.txt"
LC="$TMP/logcat-noadbd"
grep -a -v -E '^[0-9-]+ +[0-9:.]+ +[0-9]+ +[0-9]+ [A-Z] adbd *:' "$OUT/logcat-filtered.txt" > "$LC"
LOGOK=1; [ -s "$OUT/logcat-filtered.txt" ] || LOGOK=0

res INFO build "$VER, built $BDATE, $BTYPE/$TAGS"
res INFO kernel "$KERN"
res INFO uptime "${UP}s ($(dur "$UP")), booted $BOOT_STR device time, adb uid $ROOT"
[ "$BOOTC" = 1 ] && res PASS boot_completed "sys.boot_completed=1" || res FAIL boot_completed "sys.boot_completed='$BOOTC'"

# ---------------------------------------------------------------- how far back the logs reach
declare -A REACH FIRSTS WRAPPED COV
while read -r b size used; do
    [ -n "$b" ] || continue
    if [ "$size" -gt 0 ] && [ $((used * 100)) -lt $((size * 70)) ]; then WRAPPED[$b]=0; else WRAPPED[$b]=1; fi
done < <(sec "$ID" logcat_g | awk 'function kib(v, u) { return u ~ /^Mi/ ? v * 1024 : (u ~ /^Gi/ ? v * 1048576 : (u ~ /^Ki/ ? v : v / 1024)) }
    / ring buffer is / { b = $1; sub(/:$/, "", b); c = $7; sub(/^\(/, "", c); printf "%s %d %d\n", b, kib($5, $6), kib(c, $8) }')
while read -r b d t; do
    s=$(ts2s "$d $t"); [ "$s" -gt 0 ] || continue
    FIRSTS[$b]=$s; REACH[$b]=$(( (NOW_W - s) / 60 ))
done < <(awk '/^--------- beginning of / { b = $NF; if ((getline l) > 0) { split(l, a, " "); print b, a[1], substr(a[2], 1, 8) } }' "$OUT/logcat-filtered.txt")
RL=""
for b in main system crash events kernel radio; do
    if [ "${WRAPPED[$b]:-1}" = 0 ]; then COV[$b]=1                                   # never filled up
    elif [ -n "${FIRSTS[$b]:-}" ]; then [ $((FIRSTS[$b] - BOOT_W)) -le 120 ] && COV[$b]=1 || COV[$b]=0
    else COV[$b]=1; fi                                                               # empty buffer
    if [ -n "${REACH[$b]:-}" ]; then
        RL="$RL$b ${REACH[$b]} min$([ "${COV[$b]}" = 1 ] && echo ' (covers boot)'), "
    fi
done
if [ "$LOGOK" = 1 ]; then
    res INFO logcat_reach "${RL%, } of $UPMIN min uptime"
else
    res FAIL logcat_reach "logcat dump is empty: every logcat-based result below is void"
fi
lpass() {  # lpass name buffer detail -> PASS for "nothing found in logcat"; SKIP when there is no dump
    if [ "$LOGOK" = 1 ]; then res PASS "$1" "$3$(lim "$2")"; else res SKIP "$1" "no logcat dump to search"; fi
}
lim() {  # lim buffer -> note for a result line when that buffer no longer covers boot
    if [ "$LOGOK" = 0 ]; then printf ' [no logcat dump]'; return; fi
    [ "${COV[$1]:-1}" = 1 ] && return
    printf ' [logcat %s buffer reaches back only %s of %s min uptime]' "$1" "${REACH[$1]:-?}" "$UPMIN"
}

# ---------------------------------------------------------------- kernel log
: > "$OUT/dmesg.txt"; : > "$OUT/last_kmsg.txt"
if [ "$ROOT" = 0 ]; then
    shl 60 dmesg | redact > "$OUT/dmesg.txt"
    shl 60 cat /proc/last_kmsg | redact > "$OUT/last_kmsg.txt"
fi
DM_FIRST=$(sed -n -E 's/^\[ *([0-9]+)\.[0-9]+\].*/\1/p' "$OUT/dmesg.txt" | head -n 1)
DM_REACH=""; DM_COV=0
if [ -n "$DM_FIRST" ]; then
    DM_REACH=$(( (UP - DM_FIRST) / 60 )); [ "$DM_REACH" -ge 0 ] || DM_REACH=0
    [ "$DM_FIRST" -le 2 ] && DM_COV=1
fi
LK_REACH=${REACH[kernel]:-}; LK_COV=0
[ -s "$OUT/logcat-kernel.txt" ] && [ "${COV[kernel]:-0}" = 1 ] && LK_COV=1
K_COV=0; { [ "$DM_COV" = 1 ] || [ "$LK_COV" = 1 ]; } && K_COV=1
# $KLONG: the kernel log source that reaches further back (for counting lines);
# $KALL: both sources (for "is it there at all" and for lists of distinct lines).
if [ -n "$DM_REACH" ] && { [ -z "$LK_REACH" ] || [ "$DM_COV" = 1 ] || [ "$DM_REACH" -ge "$LK_REACH" ]; }; then
    KLONG="$OUT/dmesg.txt"; K_REACH=$DM_REACH; KSRC=dmesg
else
    KLONG="$OUT/logcat-kernel.txt"; K_REACH=${LK_REACH:-0}; KSRC="logcat kernel buffer"
fi
KALL="$TMP/kernel-all"; cat "$OUT/dmesg.txt" "$OUT/logcat-kernel.txt" > "$KALL"
KOK=1; [ -s "$KALL" ] || KOK=0
kmax() {  # kmax REGEX -> the larger line count of the two kernel log sources (never a double count)
    local a b; a=$(cnt "$1" "$OUT/dmesg.txt"); b=$(cnt "$1" "$OUT/logcat-kernel.txt"); [ "$a" -ge "$b" ] && echo "$a" || echo "$b"
}
if [ "$KOK" = 0 ]; then KWIN="(no kernel log could be read)"; KLIM=" [no kernel log read]"
elif [ "$K_COV" = 1 ]; then KWIN="since boot"; KLIM=""
else KWIN="in the last $K_REACH min"; KLIM=" [kernel log reaches back only $K_REACH of $UPMIN min uptime]"; fi
if [ "$KOK" = 1 ]; then
    res INFO kernel_log_reach "dmesg: $([ -n "$DM_REACH" ] && echo "last $DM_REACH min (first line at ${DM_FIRST}s)" || echo "not read"); logcat kernel buffer: $([ -n "$LK_REACH" ] && echo "last $LK_REACH min" || echo "empty"); uptime $UPMIN min; boot period covered: $([ "$K_COV" = 1 ] && echo yes || echo no)"
else
    res SKIP kernel_log_reach "no kernel log could be read (adb uid $ROOT)"
fi

KE_RE='Unable to handle kernel|kernel BUG|Internal error|Kernel panic'
KW_RE='WARNING: at|WARNING: CPU|BUG: |EXT4-fs error|EXT4-fs warning'
TAINT_N=""; [ -n "$TAINT" ] && TAINT_N=$(num "$TAINT")
T_D=0; T_W=0
if [ -n "$TAINT_N" ]; then [ $((TAINT_N & 128)) -ne 0 ] && T_D=1; [ $((TAINT_N & 512)) -ne 0 ] && T_W=1; fi
TTXT="taint ${TAINT_N:-unreadable}"
KE=$(kmax "$KE_RE"); KW=$(kmax "$KW_RE")
if [ "$KE" -gt 0 ]; then res FAIL kernel_errors "$KE oops/BUG/panic lines $KWIN, see dmesg.txt / logcat-kernel.txt ($TTXT)"
elif [ "$T_D" = 1 ]; then res FAIL kernel_errors "taint flag D is set ($TTXT): an oops or BUG happened since boot, its lines are no longer in the log$KLIM"
elif [ "$K_COV" = 1 ]; then res PASS kernel_errors "0 oops/BUG/panic lines since boot ($TTXT)"
elif [ -n "$TAINT_N" ]; then res PASS kernel_errors "taint flag D clear since boot ($TTXT); 0 oops/BUG/panic lines $KWIN"
else res SKIP kernel_errors "boot period not covered and taint flags unreadable; 0 lines $KWIN"; fi
KW1=$(grep -a -h -m1 -E 'WARNING: (at|CPU)' "$OUT/logcat-kernel.txt" "$OUT/dmesg.txt" 2>/dev/null | head -n 1 \
    | sed -E 's/.*WARNING: //; s#at /[^ ]*/(arch|block|crypto|drivers|fs|init|ipc|kernel|lib|mm|net|security|sound)/#at \1/#' | cut -c1-110)
if [ "$KW" -gt 0 ]; then res WARN kernel_warnings "$KW WARNING/BUG/EXT4 lines $KWIN ($TTXT)${KW1:+; first: $KW1}"
elif [ "$T_W" = 1 ]; then res WARN kernel_warnings "taint flag W is set ($TTXT): a WARNING happened since boot, its lines are no longer in the log$KLIM"
elif [ "$K_COV" = 1 ]; then res PASS kernel_warnings "0 WARNING/BUG/EXT4 lines since boot ($TTXT)"
elif [ -n "$TAINT_N" ]; then res PASS kernel_warnings "taint flag W clear since boot ($TTXT); 0 WARNING/BUG lines $KWIN; EXT4 messages are only visible $KWIN"
else res SKIP kernel_warnings "boot period not covered and taint flags unreadable; 0 lines $KWIN"; fi
if [ "$ROOT" = 0 ]; then
    LP=$(cnt 'Unable to handle kernel|kernel BUG|Kernel panic' "$OUT/last_kmsg.txt")
    if [ ! -s "$OUT/last_kmsg.txt" ]; then res INFO previous_boot_panic "/proc/last_kmsg is empty or missing"
    elif [ "$LP" = 0 ]; then res PASS previous_boot_panic "none in last_kmsg"
    else res FAIL previous_boot_panic "$LP panic lines in last_kmsg.txt"; fi
else
    res SKIP previous_boot_panic "adb is not root"
fi

# ---------------------------------------------------------------- dropbox (since-boot record)
# Listing only (tag, time, size); entry contents are never requested.
shl 60 dumpsys dropbox | grep -a -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} ' | redact > "$OUT/dropbox.txt"
DBOK=1; [ -s "$OUT/dropbox.txt" ] || DBOK=0
awk -v b="$BOOT_STR" '($1 " " $2) >= b' "$OUT/dropbox.txt" > "$TMP/dropbox-boot"
db() { awk -v re="^($1)\$" '$3 ~ re { n++ } END { print n + 0 }' "$TMP/dropbox-boot"; }   # db TAG-REGEX -> entries since boot
dbt() { awk -v re="^($1)\$" '$3 ~ re { print $2 }' "$TMP/dropbox-boot" | head -n 4 | tr '\n' ' ' | sed 's/ $//'; }
if [ "$DBOK" = 1 ]; then
    res INFO dropbox_since_boot "$(wc -l < "$TMP/dropbox-boot") entries: $(awk '{ print $3 }' "$TMP/dropbox-boot" | grep -v -E '^(SYSTEM_BOOT|SYSTEM_AUDIT|SYSTEM_LAST_KMSG|event_data|storage_|keymaster)|_PROTO_WITH_HEADERS$' | tops 12)"
else
    res SKIP dropbox_since_boot "dumpsys dropbox returned no entries"
fi

# ---------------------------------------------------------------- system_server
SSR=$(db 'SYSTEM_RESTART'); WD_DB=$(db 'system_server_watchdog'); SSC=$(db 'system_server_crash|system_server_native_crash')
WD_LOG=$(cnt 'WATCHDOG KILLING SYSTEM PROCESS' "$LC")
SSDET="start_count=$STARTS; dropbox since boot: SYSTEM_RESTART $SSR, system_server_watchdog $WD_DB, system_server crash $SSC"
if [ "$(num "$STARTS")" -le 1 ] && [ "$SSR" = 0 ]; then res PASS system_server_restarts "$SSDET"
else res FAIL system_server_restarts "$SSDET (Android restarted since boot)"; fi
if [ "$WD_DB" -gt 0 ] || [ "$WD_LOG" -gt 0 ]; then
    res FAIL watchdog "$WD_DB watchdog kills since boot in dropbox (at $(dbt 'system_server_watchdog')), $WD_LOG in logcat$(lim system)"
elif [ "$DBOK" = 1 ]; then res PASS watchdog "0 watchdog kills since boot (dropbox), 0 in logcat"
elif [ "${COV[system]:-1}" = 1 ] && [ "$LOGOK" = 1 ]; then res PASS watchdog "0 watchdog kills in logcat (covers boot)"
else res SKIP watchdog "dropbox not readable and$(lim system)"; fi
PWD_DB=$(db 'system_server_pre_watchdog')
[ "$PWD_DB" -gt 0 ] && res WARN watchdog_half "$PWD_DB half-watchdog reports since boot in dropbox (at $(dbt 'system_server_pre_watchdog'))"

# ---------------------------------------------------------------- services
SV=$(sh_ 'for p in zygote system_server android.hardware.power-service.lineage-libperfmgr android.hardware.vibrator-service.samsung tombstoned lmkd surfaceflinger gpsd; do echo "$p=$(pidof $p)"; done
echo "##restarting"; getprop | grep -E "^\[init\.svc\..*\]: \[restarting\]"')
for s in "zygote:zygote" "system_server:system_server" \
         "power HAL:android.hardware.power-service.lineage-libperfmgr" \
         "vibrator HAL:android.hardware.vibrator-service.samsung" \
         "tombstoned:tombstoned" "lmkd:lmkd" "surfaceflinger:surfaceflinger" "gpsd:gpsd"; do
    n=${s%%:*}; p=${s#*:}
    pid=$(kv "$SV" "$p")
    [ -n "$pid" ] && res PASS "service $n" "pid $pid" || res FAIL "service $n" "not running"
done
RST=$(sec "$SV" restarting | sed -E 's/^\[init\.svc\.([^]]*)\].*/\1/' | tr '\n' ' ')
[ -z "${RST// /}" ] && res PASS services_restarting "none" || res FAIL services_restarting "$RST"

# ---------------------------------------------------------------- crashes
# Tombstone files give the full process name and survive the logcat buffers (the store keeps
# the newest 32); logcat only has the 15-character thread name in its "Fatal signal" line.
TB=""
[ "$ROOT" = 0 ] && TB=$(sh_ 'B=$(( $(date +%s) - $(cut -d. -f1 /proc/uptime) ))
for f in /data/tombstones/tombstone_*; do case "$f" in *.pb|*"*") continue ;; esac
t=$(stat -c %Y "$f" 2>/dev/null); [ -n "$t" ] || continue
if [ "$t" -ge "$B" ]; then s=boot; else s=old; fi
echo "tomb $s $(grep -a -m1 "^Cmdline:" "$f" | cut -d" " -f2)"; done
echo "anr=$(ls /data/anr 2>/dev/null | wc -l)"')
TOMB=$(printf '%s\n' "$TB" | grep -c '^tomb ')
TOMB_B=$(printf '%s\n' "$TB" | grep -c '^tomb boot')
ANR=$(num "$(kv "$TB" anr)")
FS=$(cnt 'F libc    : Fatal signal' "$LC")
NC_DB=$(db 'SYSTEM_TOMBSTONE|[a-z_]*_native_crash')
if [ "$TOMB_B" -gt 0 ]; then NC_NAMES=$(printf '%s\n' "$TB" | sed -n 's/^tomb boot //p' | sed 's/^$/(no Cmdline line)/' | tops 4)
else NC_NAMES=$(grep -a -E ' F DEBUG   : Cmdline: ' "$LC" | sed -E 's/.*Cmdline: ([^ ]*).*/\1/' | tops 4); fi
NC_DET="$TOMB_B tombstone files since boot$([ "$ROOT" = 0 ] || echo ' (not root: unread)')$([ "$TOMB" -ge 32 ] && echo ' (store is full at 32, older ones were rotated out)'), dropbox SYSTEM_TOMBSTONE entries since boot: $NC_DB (dropbox rate-limits repeats), logcat fatal signals: $FS$(lim crash)"
if [ "$TOMB_B" -gt 0 ] || [ "$NC_DB" -gt 0 ] || [ "$FS" -gt 0 ]; then res WARN native_crashes "$NC_DET${NC_NAMES:+: $NC_NAMES}"
elif [ "$ROOT" != 0 ] && [ "$DBOK" = 0 ] && [ "$LOGOK" = 0 ]; then res SKIP native_crashes "no source readable (tombstones need root, dropbox and logcat are empty)"
else res PASS native_crashes "$NC_DET"; fi

# Java crashes: a crash before the process is bound has "PID: n" but no "Process:" line (for
# example an app_process command such as svc or cmd); name those by their main class.
FE=$(cnt 'FATAL EXCEPTION' "$LC")
JNAMES=$(awk '
    function flush() {
        if (cur == "") return
        if (proc != "") print proc
        else if (cmd != "") print "command " cmd " (no Process: line)"
        else print "pid " cur " (no Process: line)"
        cur = ""; proc = ""; cmd = ""
    }
    / [EF] AndroidRuntime: / {
        pid = $3; msg = $0; sub(/^.* [EF] AndroidRuntime: /, "", msg)
        if (msg ~ /FATAL EXCEPTION/) { flush(); cur = pid; if (msg ~ /IN SYSTEM PROCESS/) proc = "system_server"; next }
        if (cur == "" || pid != cur) next
        if (msg ~ /^Process: /) { p = msg; sub(/^Process: /, "", p); sub(/,.*/, "", p); proc = p }
        else if (cmd == "" && msg ~ /^[ \t]*at .*\.main\(/ && msg !~ /com\.android\.internal\.os\.|android\.app\.ActivityThread/) {
            c = msg; sub(/^[ \t]*at /, "", c); sub(/\.main\(.*/, "", c); cmd = c }
    }
    END { flush() }' "$LC" | tops 5)
JC_DB="dropbox since boot: system_app_crash $(db 'system_app_crash'), data_app_crash $(db 'data_app_crash'), system_server_crash $(db 'system_server_crash')"
if [ "$FE" -gt 0 ] || [ "$(db '[a-z_]*_crash')" -gt "$(db '[a-z_]*_native_crash')" ]; then
    res WARN java_crashes "$FE fatal exceptions in logcat$(lim crash)${JNAMES:+: $JNAMES}; $JC_DB"
elif [ "$DBOK" = 0 ] && [ "$LOGOK" = 0 ]; then res SKIP java_crashes "no source readable (dropbox and logcat are empty)"
else res PASS java_crashes "0 fatal exceptions in logcat$(lim crash); $JC_DB"; fi
res INFO tombstones_anr "$TOMB tombstones, $ANR ANR files on the device (cumulative); ANR entries in dropbox since boot: $(db '[a-z_]*_anr')"

# ---------------------------------------------------------------- SELinux
ENF=$(sh_ getenforce)
[ "$ENF" = Enforcing ] && res PASS selinux_mode "$ENF" || res WARN selinux_mode "$ENF"
# The same denial is in dmesg, in the kernel buffer and (through logd's auditd) in the main
# or events buffer (there with time 0.0): count each audit record once, by its serial number.
cat "$KALL" "$LC" | grep -a -E 'avc: +denied' \
    | awk '{ if (match($0, /audit\([0-9.]+:[0-9]+\)/)) { k = substr($0, RSTART, RLENGTH); sub(/.*:/, "", k); if (seen[k]++) next } print }' > "$TMP/avc"
sed -E 's/.*avc: +denied +\{ ([^}]*) \}.*scontext=u:r:([^:]*):.*tcontext=u:(object_)?r:([^:]*):.*tclass=([a-z_0-9]*).*/\2 -> \4 [\5] {\1}/' "$TMP/avc" \
    | grep -v -E '^(shell|su) ->' | sort | uniq -c | sort -k2 > "$OUT/denials.txt"
ND=$(wc -l < "$OUT/denials.txt")
if [ "$KOK" = 0 ] && [ "$LOGOK" = 0 ]; then res SKIP selinux_denials "neither kernel log nor logcat could be read"
else res INFO selinux_denials "$ND distinct (excluding adb shell), see denials.txt$KLIM$(lim main)"; fi

# ---------------------------------------------------------------- init
grep -a -E "init: Command '.*' action=.* failed" "$KALL" \
    | sed -E "s/.*init: Command '([^']*)' action=([^ ]*) .*failed: (.*)/\1 | \2 | \3/" | sort -u > "$OUT/init-failed.txt"
NIF=$(wc -l < "$OUT/init-failed.txt")
if [ "$KOK" = 0 ]; then res SKIP init_failed_commands "no kernel log (adb uid $ROOT)"
elif [ "$K_COV" = 1 ]; then res INFO init_failed_commands "$NIF distinct since boot, see init-failed.txt"
else res SKIP init_failed_commands "boot period is no longer in the kernel log (reach $K_REACH of $UPMIN min uptime); $NIF later ones visible"; fi

# ---------------------------------------------------------------- storage
ST=$(sh_ 'echo "##data"; grep " /data ext4" /proc/mounts | head -n 1
echo "##ra"; cat /sys/block/mmcblk0/queue/read_ahead_kb
echo "##df"; df -h /data | tail -n 1')
MD=$(sec "$ST" data)
case "$MD" in *discard*) res WARN data_mount "has 'discard': $(echo "$MD" | cut -d' ' -f4)" ;; "") res FAIL data_mount "/data not mounted as ext4" ;; *) res PASS data_mount "no discard" ;; esac
RA=$(sec "$ST" ra)
[ "$RA" = 1024 ] && res PASS read_ahead "1024 KB" || res WARN read_ahead "$RA KB (expected 1024)"
res INFO data_usage "$(sec "$ST" df | awk '{print $3" used, "$4" free"}')"

# ---------------------------------------------------------------- memory
# Kernel 3.10 has no MemAvailable: show MemFree and the page cache instead, and swap in use.
MEMRAW=$(sh_ cat /proc/meminfo)
mi() { printf '%s\n' "$MEMRAW" | awk -v k="$1:" '$1 == k { print int($2 / 1024) }'; }
MAV=$(mi MemAvailable); SWT=$(mi SwapTotal); SWF=$(mi SwapFree)
res INFO memory "MemTotal $(mi MemTotal) MB, MemFree $(mi MemFree) MB, Cached $(mi Cached) MB, Buffers $(mi Buffers) MB, MemAvailable $([ -n "$MAV" ] && echo "$MAV MB" || echo 'n/a (not in this kernel)'), swap used $(( ${SWT:-0} - ${SWF:-0} )) of ${SWT:-0} MB"

# lmkd: which pressure source it can use follows from what the kernel offers (same order as
# lmkd's own start-up test), so this does not depend on its one log line from boot.
LM=$(sh_ 'e() { [ -e "$2" ] && echo "$1=yes" || echo "$1=no"; }
e psi /proc/pressure/memory; e lmk_driver /sys/module/lowmemorykiller/parameters/minfree; e memcg_pressure /dev/memcg/memory.pressure_level
echo "minfree=$(cat /sys/module/lowmemorykiller/parameters/minfree 2>/dev/null)"
echo "props=$(getprop | grep -E "^\[(ro|sys|persist)\.lmk\." | tr -d "[]" | sed "s/: /=/" | tr "\n" " ")"')
LMLINE=$(grep -a -m1 -E 'lowmemorykiller: (Using|PSI|psi)' "$LC" | sed -E 's/.*lowmemorykiller: //' | cut -c1-80)
if [ "$(kv "$LM" lmk_driver)" = yes ]; then LMMODE="in-kernel lowmemorykiller driver (minfree $(kv "$LM" minfree))"
elif [ "$(kv "$LM" psi)" = yes ]; then LMMODE="userspace, PSI monitors"
elif [ "$(kv "$LM" memcg_pressure)" = yes ]; then LMMODE="userspace, vmpressure events (no PSI)"
else LMMODE="no pressure source found (no lowmemorykiller driver, no PSI, no memcg pressure_level)"; fi
res INFO lmkd_mode "$LMMODE; props: $(kv "$LM" props | cut -c1-200); lmkd's own line: ${LMLINE:-not in logcat$(lim main)}"

# ---------------------------------------------------------------- CPU and GPU
CG=$(sh_ 'echo "online=$(cat /sys/devices/system/cpu/online)"; echo "gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"; echo "temp=$(cat /sys/class/thermal/thermal_zone0/temp)"
for f in dvfs_min_lock dvfs_max_lock; do p=/sys/devices/14ac0000.mali/$f; if [ -r $p ]; then echo "$f=$(cat $p | tr "\n" " ")"; else echo "$f=missing"; fi; done')
ONLINE=$(kv "$CG" online)
res INFO cpu "online $ONLINE, governor $(kv "$CG" gov), SoC $(( $(num "$(kv "$CG" temp)") / 1000 )) C"
res INFO gpu_dvfs_locks "dvfs_min_lock=$(kv "$CG" dvfs_min_lock | sed 's/ *$//') dvfs_max_lock=$(kv "$CG" dvfs_max_lock | sed 's/ *$//') (current values)"

# ---------------------------------------------------------------- power HAL
PW=$(cnt 'libperfmgr: Failed to write to node' "$LC")
if [ "$PW" = 0 ]; then lpass powerhal_writes main "0 failed node writes in logcat"; else res WARN powerhal_writes "$PW failed node writes in logcat$(lim main)"; fi
PH=$(sh_ 'p=$(pidof android.hardware.power-service.lineage-libperfmgr | cut -d" " -f1); echo "pid=$p"
[ -n "$p" ] && echo "ticks=$(sed "s/.*) //" /proc/$p/stat | cut -d" " -f20)"')
PHPID=$(kv "$PH" pid); PHT=$(kv "$PH" ticks)
PH_TOMB=$(printf '%s\n' "$TB" | grep -c -E '^tomb boot .*power')
if [ -z "$PHPID" ]; then res FAIL powerhal_restarts "power HAL is not running; $PH_TOMB of its tombstones since boot"
elif [ -z "$PHT" ]; then res SKIP powerhal_restarts "pid $PHPID, start time unreadable; $PH_TOMB of its tombstones since boot"
else
    PHS=$(( $(num "$PHT") / 100 ))
    if [ "$PHS" -gt 120 ] || [ "$PH_TOMB" -gt 0 ]; then res WARN powerhal_restarts "pid $PHPID started ${PHS}s after boot: restarted since boot; $PH_TOMB power HAL tombstones since boot"
    else res PASS powerhal_restarts "pid $PHPID running since boot (started at ${PHS}s), 0 power HAL tombstones since boot"; fi
fi
PHN=$(grep -a -E '[0-9]+ Nodes parsed successfully' "$LC" | tail -n 1 | sed -E 's/.* ([0-9]+ Nodes parsed) successfully.*/\1/')
PHA=$(grep -a -E '[0-9]+ actions parsed successfully' "$LC" | tail -n 1 | sed -E 's/.* ([0-9]+ actions parsed) successfully.*/\1/')
PHO=$(cnt 'old node path format detected' "$LC")
if [ "$PHO" -gt 0 ]; then res WARN powerhal_config "$PHO 'old node path format' warnings; ${PHN:-no 'Nodes parsed' line}, ${PHA:-no 'actions parsed' line}$(lim main)"
elif [ -n "$PHN" ] || [ -n "$PHA" ]; then res PASS powerhal_config "${PHN:-no 'Nodes parsed' line}, ${PHA:-no 'actions parsed' line}, 0 'old node path format' warnings$(lim main)"
else res INFO powerhal_config "no 'Nodes parsed' / 'actions parsed' line in logcat, 0 'old node path format' warnings$(lim main)"; fi

# ---------------------------------------------------------------- kernel features (present / absent, for tracking backports)
KF=$(sh_ 'echo "##syms"; grep -E " [Ss]y[Ss]_(memfd_create|bpf|userfaultfd|pidfd_open|pidfd_send_signal|close_range|process_madvise)\$| (binder_ioctl_freeze|binder_ioctl_get_freezer_info)\$" /proc/kallsyms | cut -d" " -f3 | sort -u
echo "##kv"; echo "nsyms=$(wc -l < /proc/kallsyms)"
e() { [ -e "$2" ] && echo "$1=yes" || echo "$1=no"; }
e psi /proc/pressure/memory; e memfd_class /sys/fs/selinux/policy_capabilities/memfd_class; e metadata_dir /metadata; e cpuset_dir /dev/cpuset; e freezer_dir /dev/freezer
echo "use_memfd=$(getprop sys.use_memfd)"; echo "vendor_api=$(getprop ro.vendor.api_level)"
echo "##cgroups"; cat /proc/cgroups
echo "##mounts"; grep -E " (/dev/cpuset|/dev/freezer|/dev/cpuctl|/metadata|/sys/fs/cgroup) " /proc/mounts
echo "##config"; (zcat /proc/config.gz || gzip -dc /proc/config.gz) 2>/dev/null | grep -E "CONFIG_(CPUSETS|PROC_PID_CPUSET|CGROUP_FREEZER|PSI|USERFAULTFD|BPF_SYSCALL)(=| is not set)"')
NSYMS=$(num "$(kv "$KF" nsyms)")
SYMS=$(sec "$KF" syms)
MOUNTS=$(sec "$KF" mounts)
sym() {  # sym NAME... -> yes / no / unknown (kallsyms unreadable)
    local s
    [ "$NSYMS" -gt 1000 ] || { echo unknown; return; }
    for s in "$@"; do printf '%s\n' "$SYMS" | grep -q -x -E "([Ss]y[Ss]_)?$s" && { echo yes; return; }; done
    echo no
}
yn() { [ -n "$1" ] && echo yes || echo no; }
CPUSET_MNT=$(printf '%s\n' "$MOUNTS" | grep -m1 -E ' /dev/cpuset cgroup2? ')
FREEZER_MNT=$(printf '%s\n' "$MOUNTS" | grep -m1 -E ' /dev/freezer cgroup2? ')
META_MNT=$(printf '%s\n' "$MOUNTS" | grep -m1 -E ' /metadata ')
HAS_UFFD=$(sym userfaultfd); HAS_PIDFD=$(sym pidfd_open)
# memfd_seal: whether Android's libcutils creates sealed memfd regions instead of ashmem. Its
# rule in this Android version: sys.use_memfd=true, or the SELinux memfd_class capability with
# vendor API level >= 202604 (and then only for apps targeting SDK 37+). It logs nothing.
UMF=$(kv "$KF" use_memfd); VAPI=$(num "$(kv "$KF" vendor_api)")
if [ "$(sym memfd_create)" != yes ]; then MEMFD_SEAL=no
elif [ "$UMF" = true ] || [ "$UMF" = 1 ]; then MEMFD_SEAL=yes
elif [ "$(kv "$KF" memfd_class)" = yes ] && [ "$VAPI" -ge 202604 ]; then MEMFD_SEAL=yes
else MEMFD_SEAL=no; fi
F="memfd_seal=$MEMFD_SEAL memfd_create=$(sym memfd_create) cpusets=$(yn "$CPUSET_MNT") psi=$(kv "$KF" psi)"
F="$F freezer_cgroup=$(yn "$FREEZER_MNT") bpf=$(sym bpf) userfaultfd=$HAS_UFFD pidfd=$HAS_PIDFD close_range=$(sym close_range)"
F="$F metadata=$(yn "$META_MNT") cpuset_controller=$(yn "$(sec "$KF" cgroups | grep -E '^cpuset[[:space:]]')")"
F="$F freezer_controller=$(yn "$(sec "$KF" cgroups | grep -E '^freezer[[:space:]]')") binder_freeze=$(sym binder_ioctl_freeze binder_ioctl_get_freezer_info)"
F="$F process_madvise=$(sym process_madvise)"
res INFO kernel_features "$F"
res INFO memfd "kernel memfd_create: $(sym memfd_create); userspace rule: sys.use_memfd='${UMF}', SELinux memfd_class capability: $(kv "$KF" memfd_class), ro.vendor.api_level=$(kv "$KF" vendor_api) -> libcutils uses $([ "$MEMFD_SEAL" = yes ] && echo memfd || echo ashmem)"
KCONF=$(sec "$KF" config | sed -E 's/^# (CONFIG_[A-Z_]+) is not set/\1=n/' | tr '\n' ' ' | sed 's/ $//')
[ -n "$KCONF" ] && res INFO kernel_config "$KCONF (/proc/config.gz; an option not listed does not exist in this kernel)"
case "$HAS_PIDFD" in
    yes) res PASS pidfd "sys_pidfd_open in /proc/kallsyms (pidfd_send_signal: $(sym pidfd_send_signal))" ;;
    no)  res INFO pidfd "absent: no sys_pidfd_open among $NSYMS kernel symbols" ;;
    *)   res SKIP pidfd "/proc/kallsyms unreadable" ;;
esac

# ---------------------------------------------------------------- suspend
# /sys/power/wakeup_count is deliberately not read: it blocks while a wakeup source is active.
if [ "$ROOT" = 0 ]; then
    SU=$(sh_ 'echo "##stats"; cat /sys/kernel/debug/suspend_stats 2>/dev/null
echo "##kv"; echo "uptime=$(cut -d" " -f1 /proc/uptime)"; echo "mono_ns=$(grep -m1 "^now at" /proc/timer_list | tr -dc 0-9)"
echo "boot_offset_ns=$(grep -m1 -A1 "ktime_get_boottime" /proc/timer_list | grep offset | tr -dc 0-9)"
echo "##irq"; grep -E "ss333_active|lli_cp2ap_wakeup|lli_cp2ap_status" /proc/interrupts')
    SST=$(sec "$SU" stats)
    ss() { printf '%s\n' "$SST" | awk -v k="$1:" '$1 == k { print $2; exit }'; }
    S_OK=$(ss success); S_FAIL=$(ss fail)
    # Time suspended = boot-time clock minus monotonic clock. The kernel keeps that difference as
    # the offset of the boot-time timer base; fall back to /proc/uptime minus "now at".
    SUSP=""
    OFF=$(kv "$SU" boot_offset_ns); MONO=$(kv "$SU" mono_ns); UPF=$(kv "$SU" uptime)
    if [ -n "$OFF" ]; then SUSP=$((OFF / 1000000000))
    elif [ -n "$MONO" ] && [ -n "$UPF" ]; then SUSP=$(( ${UPF%%.*} - MONO / 1000000000 )); [ "$SUSP" -lt 2 ] && SUSP=0; fi
    if [ -z "$S_OK" ] || [ -z "$S_FAIL" ]; then
        res SKIP suspend "/sys/kernel/debug/suspend_stats unreadable"
    else
        SDET="success $S_OK, fail $S_FAIL (failed_freeze $(ss failed_freeze), failed_prepare $(ss failed_prepare), failed_suspend $(ss failed_suspend), failed_suspend_late $(ss failed_suspend_late), failed_suspend_noirq $(ss failed_suspend_noirq), failed_resume $(ss failed_resume))"
        if [ $((S_OK + S_FAIL)) -eq 0 ]; then res INFO suspend "no suspend attempt since boot; $SDET"
        elif [ "$S_OK" -eq 0 ]; then res WARN suspend "none of $S_FAIL suspend attempts succeeded; $SDET"
        else res PASS suspend "$SDET"; fi
    fi
    if [ -n "$SUSP" ]; then
        res INFO suspend_time "$(dur "$SUSP") suspended of $(dur "$UP") since boot ($(( UP > 0 ? SUSP * 100 / UP : 0 ))%)"
    else
        res SKIP suspend_time "/proc/timer_list unreadable"
    fi
    SA=$(cnt 'suspend aborted' "$KLONG"); FA=$(cnt 'Freezing of tasks aborted' "$KLONG")
    WIRQ=$(grep -a -o -E 'Wakeup IRQ [0-9]+ [^ ]+ pending' "$KLONG" | awk '{ print $4 " (irq " $3 ")" }' | tops 6)
    LWS=$(grep -a -o -E 'last active wakeup source: [^ ]+' "$KLONG" | awk '{ print $NF }' | tops 4)
    [ "$KOK" = 1 ] && res INFO suspend_aborts "$KSRC, last $K_REACH min: $SA 'suspend aborted' lines, Wakeup IRQ pending: ${WIRQ:-none}; $FA 'Freezing of tasks aborted'; last active wakeup source: ${LWS:-none logged}"
    IRQS=$(sec "$SU" irq | awk '{ s = 0; for (i = 2; i <= NF; i++) { if ($i ~ /^[0-9]+$/) s += $i; else break } printf "%s=%d ", $NF, s }')
    res INFO modem_irqs "${IRQS:-none of ss333_active, lli_cp2ap_wakeup, lli_cp2ap_status is registered; }(interrupt counts since boot, /proc/interrupts)"
else
    res SKIP suspend "adb is not root (debugfs)"
fi

# ---------------------------------------------------------------- cpusets
CS=$(shl 40 'echo "##cpus"; for g in "" top-app foreground system-background background restricted; do d=/dev/cpuset${g:+/$g}; f=$d/cpus; [ -f $f ] || f=$d/cpuset.cpus; [ -f $f ] && echo "${g:-root}=$(cat $f)"; done
echo "##kv"; a=$(dumpsys activity activities 2>/dev/null | grep -m1 -E "ResumedActivity:|topResumedActivity=")
p=$(echo "$a" | sed -E "s/.* u[0-9]+ ([^ \/]+)\/.*/\1/"); echo "pkg=$p"
pid=$(pidof "$p" 2>/dev/null | cut -d" " -f1); echo "pid=$pid"
[ -n "$pid" ] && echo "cpuset=$(cat /proc/$pid/cpuset 2>/dev/null || echo unreadable)"
echo "wake=$(dumpsys power 2>/dev/null | grep -m1 -o "mWakefulness=[A-Za-z]*")"')
CPUS=$(sec "$CS" cpus | tr '\n' ' ')
FGPKG=$(kv "$CS" pkg); FGPID=$(kv "$CS" pid); FGSET=$(kv "$CS" cpuset); WAKE=$(kv "$CS" wake)
CS_MNTFAIL=$(kmax 'Failed to mount controller cpuset')
CS_EACCES=$(cnt 'libprocessgroup.*(Permission denied|EACCES)' "$LC"); CS_EACCES_K=$(kmax 'libprocessgroup.*(Permission denied|EACCES)')
CS_ENOENT=$(cnt 'libprocessgroup.*/dev/cpuset/.*No such file' "$LC")
if [ -z "$CPUSET_MNT" ]; then
    res INFO cpusets "absent: /dev/cpuset is not a mounted cgroup (directory exists: $(kv "$KF" cpuset_dir), kernel controller: $(yn "$(sec "$KF" cgroups | grep -E '^cpuset[[:space:]]')")); $CS_ENOENT libprocessgroup 'No such file' lines for /dev/cpuset in logcat$(lim main)"
else
    BAD=""
    for e in top-app:0-7 foreground:0-7 system-background:0-7 background:0-3 restricted:0-3; do
        g=${e%%:*}; want=${e#*:}; got=$(sec "$CS" cpus | sed -n "s/^$g=//p")
        [ "$got" = "$want" ] || BAD="$BAD $g='${got:-missing}' (expected $want)"
    done
    if [ -z "$BAD" ]; then res PASS cpusets "mounted; $CPUS"
    elif [ "$ONLINE" != 0-7 ]; then res WARN cpusets "mounted; differs while CPUs are offline (online $ONLINE):$BAD; all: $CPUS"
    else res FAIL cpusets "mounted; wrong masks:$BAD; all: $CPUS"; fi
    if [ -z "$FGPID" ]; then res SKIP cpuset_foreground_app "no resumed activity found (${FGPKG:-none}, $WAKE)"
    elif [ "$FGSET" = /top-app ]; then res PASS cpuset_foreground_app "$FGPKG (pid $FGPID) is in /top-app"
    elif [ "$WAKE" != "mWakefulness=Awake" ]; then res INFO cpuset_foreground_app "$FGPKG (pid $FGPID) is in ${FGSET:-?}; screen is not on ($WAKE), so not judged"
    else res WARN cpuset_foreground_app "$FGPKG (pid $FGPID) is in ${FGSET:-?}, expected /top-app"; fi
fi
if [ "$CS_MNTFAIL" -gt 0 ] || [ "$CS_EACCES" -gt 0 ] || [ "$CS_EACCES_K" -gt 0 ]; then
    res FAIL cgroup_errors "'Failed to mount controller cpuset': $CS_MNTFAIL; libprocessgroup permission errors: $CS_EACCES in logcat, $CS_EACCES_K in the kernel log$KLIM$(lim main)"
elif [ "$KOK" = 0 ] && [ "$LOGOK" = 0 ]; then res SKIP cgroup_errors "neither kernel log nor logcat could be read"
else
    res PASS cgroup_errors "no 'Failed to mount controller cpuset', no libprocessgroup permission errors$KLIM$(lim main)"
fi

# ---------------------------------------------------------------- cgroup attach rule
TM=$(sh_ 'for f in /dev/cpuctl/tasks /dev/cpuctl/bg_cached/tasks /dev/cpuctl/bg_abnormal/tasks; do if [ -e $f ]; then stat -c "%a %U:%G %n" $f; else echo "missing - $f"; fi; done')
TMW=$(printf '%s\n' "$TM" | awk '$1 ~ /^[0-9]+$/ && substr($1, length($1), 1) ~ /[2367]/ { print $3 }' | tr '\n' ' ')
TMS=$(printf '%s\n' "$TM" | awk 'NF >= 3 { print $3 " " $1 " " $2 }' | tr '\n' ';' | sed 's/;$//; s/;/; /g')
if [ -z "$TM" ]; then res SKIP cgroup_tasks_modes "no answer from the device"
elif [ -n "$TMW" ]; then res WARN cgroup_tasks_modes "world-writable: $TMW($TMS)"
else res PASS cgroup_tasks_modes "none world-writable ($TMS)"; fi
SN=$(cnt 'denied +\{[^}]*sys_nice[^}]*\}' "$TMP/avc")
SNC=$(grep -a -E 'denied +\{[^}]*sys_nice[^}]*\}' "$TMP/avc" | sed -E 's/.*scontext=u:r:([^:]*):.*/\1/' | tops 4)
if [ "$SN" -gt 0 ]; then res WARN sys_nice_denials "$SN avc denied { sys_nice }: $SNC$KLIM"
elif [ "$KOK" = 0 ] && [ "$LOGOK" = 0 ]; then res SKIP sys_nice_denials "neither kernel log nor logcat could be read"
else res PASS sys_nice_denials "0 avc denied { sys_nice } in the logs$KLIM"; fi

# ---------------------------------------------------------------- app freezer
# The framework's own view ("Freezer settings" block) is in "dumpsys activity cao" in this
# Android version; "settings" is asked as well for versions that print it there.
FZ=$(shl 40 'echo "##files"; for f in /dev/freezer/frozen/freezer.killable /dev/freezer/frozen/freezer.state /dev/freezer/freezer.state; do [ -f $f ] && echo "$f=$(cat $f 2>/dev/null)"; done
[ -f /dev/freezer/frozen/cgroup.procs ] && echo "frozen_pids=$(wc -l < /dev/freezer/frozen/cgroup.procs)"
echo "##settings"; (dumpsys activity cao; dumpsys activity settings) 2>/dev/null | grep -E "^ *use_freezer=|^ *Apps frozen:" | sed "s/^ *//"')
USEFZ=$(sec "$FZ" settings | sed -n 's/^use_freezer=//p' | head -n 1)
APPSFZ=$(sec "$FZ" settings | sed -n 's/^Apps frozen: *//p' | head -n 1)
FZFILES=$(sec "$FZ" files | sed 's#^/dev/freezer/##' | tr '\n' ' ')
FZSTATE=$(sec "$FZ" files | sed -n 's#^/dev/freezer/frozen/freezer.state=##p')
FZLOG=$(grep -a -o -E 'Freezer (enabled|disabled)' "$LC" | tail -n 1)
FZDET="use_freezer=${USEFZ:-?} (dumpsys activity cao), apps frozen: ${APPSFZ:-?}, ${FZFILES:-no files under /dev/freezer}; log: ${FZLOG:-no 'Freezer enabled/disabled' line}$(lim system)"
BFZ=$(kmax 'ioctl (400c620e|c00c620f) [0-9a-f]+ returned -22')
if [ -n "$FREEZER_MNT" ] && [ "$USEFZ" = true ]; then
    if [ "$BFZ" -gt 0 ]; then res FAIL app_freezer "enabled, but $BFZ BINDER_FREEZE / BINDER_GET_FROZEN_INFO ioctls returned -22; $FZDET"
    elif [ -n "$FZSTATE" ] && [ "$FZSTATE" != FROZEN ]; then res FAIL app_freezer "enabled, but /dev/freezer/frozen/freezer.state is '$FZSTATE'; $FZDET"
    else res PASS app_freezer "enabled: /dev/freezer mounted, $FZDET"; fi
elif [ -n "$FREEZER_MNT" ]; then
    res FAIL app_freezer "/dev/freezer is mounted but the framework does not use it: $FZDET"
elif [ "$USEFZ" = true ]; then
    res FAIL app_freezer "framework reports the freezer enabled but /dev/freezer is not mounted: $FZDET"
else
    res INFO app_freezer "absent: /dev/freezer not mounted (directory exists: $(kv "$KF" freezer_dir)), $FZDET"
fi
BINV=$(grep -a -o -E 'ioctl [0-9a-f]+ [0-9a-f]+ returned -22' "$KLONG" | awk '{ c = $2
    n = (c == "40046210") ? "BINDER_ENABLE_ONEWAY_SPAM_DETECTION" : (c == "400c620e") ? "BINDER_FREEZE" : (c == "c00c620f") ? "BINDER_GET_FROZEN_INFO" : "?"
    print c " (" n ")" }' | tops 5)
if [ "$KOK" = 1 ]; then res INFO binder_einval "binder 'ioctl ... returned -22' lines, $KSRC, last $K_REACH min: ${BINV:-none}"
else res SKIP binder_einval "no kernel log could be read"; fi

# ---------------------------------------------------------------- /metadata
if [ -z "$META_MNT" ]; then
    res INFO metadata "absent: /metadata is not mounted (directory exists: $(kv "$KF" metadata_dir))"
else
    ME=$(sh_ 'echo "label=$(ls -dZ /metadata 2>/dev/null | cut -d" " -f1)"; echo "aconfig=$(find /metadata/aconfig -type f 2>/dev/null | wc -l)"')
    MTYPE=$(echo "$META_MNT" | awk '{ print $3 }'); MLABEL=$(kv "$ME" label); MAC=$(num "$(kv "$ME" aconfig)")
    MDET="type $MTYPE, label ${MLABEL:-unreadable}, $MAC files under /metadata/aconfig"
    if [ "$MTYPE" != tmpfs ]; then res INFO metadata "mounted, but not the tmpfs of this build: $MDET"
    elif [ -n "$MLABEL" ] && ! printf '%s' "$MLABEL" | grep -q ':metadata_file:'; then res FAIL metadata "tmpfs with the wrong label: $MDET"
    elif [ "$ROOT" = 0 ] && [ "$MAC" = 0 ]; then res WARN metadata "tmpfs mounted but /metadata/aconfig is empty: $MDET"
    else res PASS metadata "$MDET"; fi
fi

# ---------------------------------------------------------------- ART
AR=$(shl 40 'echo "uffd=$(getprop ro.dalvik.vm.enable_uffd_gc)"
echo "apex_kb=$(du -sk /data/misc/apexdata/com.android.art/dalvik-cache 2>/dev/null | cut -f1)"; echo "data_kb=$(du -sk /data/dalvik-cache 2>/dev/null | cut -f1)"')
UFFDP=$(kv "$AR" uffd)
A_KB=$(kv "$AR" apex_kb); D_KB=$(kv "$AR" data_kb)
if [ "$HAS_UFFD" = unknown ]; then res SKIP art_uffd_gc "ro.dalvik.vm.enable_uffd_gc='$UFFDP', kernel userfaultfd unknown (/proc/kallsyms unreadable)"
elif [ "$UFFDP" = true ] && [ "$HAS_UFFD" = no ]; then res WARN art_uffd_gc "ro.dalvik.vm.enable_uffd_gc=true but the kernel has no userfaultfd: the build flag does not match the kernel (odrefresh's check fails)"
elif [ "$UFFDP" = true ]; then res PASS art_uffd_gc "ro.dalvik.vm.enable_uffd_gc=true and the kernel has userfaultfd"
elif [ "$HAS_UFFD" = no ]; then res PASS art_uffd_gc "ro.dalvik.vm.enable_uffd_gc='${UFFDP}' matches the kernel (no userfaultfd)"
else res INFO art_uffd_gc "ro.dalvik.vm.enable_uffd_gc='${UFFDP}' although the kernel has userfaultfd"; fi
UF=$(cnt 'Userfaultfd GC check failed' "$LC"); RB=$(cnt 'Read barrier state mismatch' "$LC")
if [ "$UF" -gt 0 ] || [ "$RB" -gt 0 ]; then res WARN art_log "$UF 'Userfaultfd GC check failed', $RB 'Read barrier state mismatch' lines in logcat$(lim main)"
else lpass art_log main "0 'Userfaultfd GC check failed', 0 'Read barrier state mismatch' lines in logcat"; fi
kb2mb() { [ -n "$1" ] && echo "$(( $(num "$1") / 1024 )) MB" || echo "unreadable"; }
res INFO art_cache "/data/misc/apexdata/com.android.art/dalvik-cache $(kb2mb "$A_KB") (on-device compiled boot image), /data/dalvik-cache $(kb2mb "$D_KB")"

# ---------------------------------------------------------------- Bluetooth audio
BT=$(shl 40 'service list 2>/dev/null | grep -F "android.hardware.bluetooth.audio" | sed -E "s/^[0-9]+[[:space:]]+//; s/:.*//"')
BTD=$(cnt 'Failed to dlopen android\.hardware\.bluetooth\.audio-impl\.so' "$LC")
if [ -n "$BT" ] && [ "$BTD" = 0 ]; then res PASS bluetooth_audio "registered: $(echo "$BT" | tr '\n' ' ')"
elif [ -n "$BT" ]; then res WARN bluetooth_audio "registered ($(echo "$BT" | tr '\n' ' ')) but $BTD 'Failed to dlopen android.hardware.bluetooth.audio-impl.so' lines in logcat$(lim main)"
elif [ "$BTD" -gt 0 ]; then res WARN bluetooth_audio "absent: no android.hardware.bluetooth.audio service registered; $BTD 'Failed to dlopen android.hardware.bluetooth.audio-impl.so' lines in logcat$(lim main)"
else res INFO bluetooth_audio "absent: no android.hardware.bluetooth.audio service registered; 0 dlopen failures in logcat$(lim main)"; fi

# ---------------------------------------------------------------- persistent logging
# Size only. /data/.logs holds unfiltered logcat and is never read.
PL=$(sh_ 'echo "svc=$(getprop init.svc.persistentLogging)"; echo "prop=$(getprop persist.logcat.enabled)"; echo "kb=$(du -sk /data/.logs 2>/dev/null | cut -f1)"')
PLS=$(kv "$PL" svc); PLK=$(kv "$PL" kb)
PLDET="persist.logcat.enabled='$(kv "$PL" prop)', /data/.logs: $([ -n "$PLK" ] && echo "$(( $(num "$PLK") / 1024 )) MB" || echo 'absent or unreadable')"
if [ "$PLS" = running ]; then res WARN persistent_logging "service persistentLogging is running: unfiltered logcat is being written to /data/.logs; $PLDET"
else res PASS persistent_logging "service persistentLogging is ${PLS:-not defined}; $PLDET"; fi

# ---------------------------------------------------------------- vibrator
VL=$(sh_ "ls -Z /sys/devices/virtual/timed_output/vibrator/enable 2>/dev/null")
case "$VL" in *sysfs_vibrator*) res PASS vibrator_label "sysfs_vibrator" ;; *) res FAIL vibrator_label "${VL:-node missing}" ;; esac

# ---------------------------------------------------------------- apps and DRM
AP=$(shl 40 'echo "microg=$(dumpsys package com.google.android.gms | grep -m1 versionName | tr -d " ")"
for p in com.aurora.store org.fdroid.fdroid com.android.vending; do echo "$p=$(pm path $p 2>/dev/null | head -n 1)"; done
echo "drm=$(ps -A -o NAME 2>/dev/null | grep -i -E "widevine|drm" | tr "\n" " ")"
echo "oemcrypto=$(ls /vendor/lib/liboemcrypto.so /vendor/lib64/liboemcrypto.so 2>/dev/null | tr "\n" " ")"')
res INFO microg "$(kv "$AP" microg)"
for p in com.aurora.store org.fdroid.fdroid com.android.vending; do
    case "$(kv "$AP" "$p")" in package:*) res PASS "package $p" installed ;; *) res FAIL "package $p" "missing" ;; esac
done
WV=$(grep -a -E 'OEMCrypto_Initialize Level [0-9] success|Falling Back to L3' "$LC" | tail -n 1 | sed -E 's/.*(OEMCrypto_Initialize Level [0-9] success|Falling Back to L3).*/\1/')
res INFO widevine "DRM processes: $(kv "$AP" drm | sed 's/ *$//'); liboemcrypto: $(o=$(kv "$AP" oemcrypto | sed 's/ *$//'); echo "${o:-not found}"); OEMCrypto init line: ${WV:-not in logcat (logged on first use)$(lim main)}"

# ---------------------------------------------------------------- optional launch test
if [ "$LAUNCH" = 1 ]; then
    AW=$(sh_ "dumpsys power | grep -m1 -o 'mWakefulness=[A-Za-z]*'")
    LK=$(sh_ "dumpsys window | grep -m1 -o 'mDreamingLockscreen=[a-z]*'")
    if [ "$AW" != "mWakefulness=Awake" ] || [ "$LK" = "mDreamingLockscreen=true" ]; then
        res SKIP launch_test "screen must be on and unlocked ($AW, $LK)"
    else
        T=""
        for _ in 1 2 3 4 5; do
            sh_ am force-stop com.android.settings >/dev/null
            sh_ sleep 8
            v=$(shl 40 "am start -W -n com.android.settings/.Settings" | grep TotalTime | tr -dc '0-9')
            T="$T ${v:-x}"
        done
        sh_ am force-stop com.android.settings >/dev/null
        sh_ input keyevent KEYCODE_HOME >/dev/null
        MEAN=$(echo "$T" | tr ' ' '\n' | grep -E '^[0-9]+$' | sed 1d | awk '{s+=$1; n++} END {if (n) printf "%d", s/n; else print "n/a"}')
        res INFO launch_test "Settings cold start ms:$T (mean without the first: $MEAN)"
    fi
fi

# ---------------------------------------------------------------- bookkeeping, baseline
if [ -s "$TMP/timeouts" ]; then
    res WARN adb_timeouts "$(wc -l < "$TMP/timeouts") adb calls hit their timeout, the results that depend on them are incomplete: $(tr '\n' ';' < "$TMP/timeouts" | cut -c1-300)"
fi
{
    echo "label=$LABEL"; echo "build=$VER"; echo "device_time=$DEVNOW"; echo "boot_time=$BOOT_STR"; echo "uptime_s=$UP"
    echo "kernel_boot_covered=$K_COV"; echo "kernel_log_reach_min=$K_REACH"
    for b in main system crash events kernel; do echo "logcat_${b}_reach_min=${REACH[$b]:-}"; echo "logcat_${b}_boot_covered=${COV[$b]:-}"; done
} | redact > "$OUT/meta.txt"

# ---------------------------------------------------------------- privacy: re-scan what was saved
LEAKY=""
for f in "$OUT"/*; do
    [ -f "$f" ] || continue
    n=$(leaks "$f")
    if [ "$n" -gt 0 ]; then
        LEAKY="$LEAKY $(basename "$f"):$n"
        redact < "$f" > "$TMP/refilter" && cat "$TMP/refilter" > "$f"     # filter it again in place
    fi
done
if [ -z "$LEAKY" ]; then res PASS privacy_scan "no address, token or name pattern left in $(find "$OUT" -maxdepth 1 -type f | wc -l) saved files"
else res FAIL privacy_scan "pattern found and filtered again in:$LEAKY (lines per file; check redact())"; fi

compare() {  # compare file label [note]   (lists of distinct lines: new / gone)
    local f=$1 lbl=$2 nt=${3:-}
    [ -n "$BASE" ] && [ -f "$BASE/$f" ] || return 0
    local strip='s/^ *[0-9]+ //'
    local new gone
    new=$(comm -13 <(sed -E "$strip" "$BASE/$f" | sort -u) <(sed -E "$strip" "$OUT/$f" | sort -u))
    gone=$(comm -23 <(sed -E "$strip" "$BASE/$f" | sort -u) <(sed -E "$strip" "$OUT/$f" | sort -u))
    if [ -z "$new" ]; then res PASS "${lbl}_vs_baseline" "nothing new ($(printf '%s' "$gone" | grep -c . ) gone)$nt"
    else
        res WARN "${lbl}_vs_baseline" "$(printf '%s\n' "$new" | grep -c .) new, $(printf '%s' "$gone" | grep -c .) gone$nt"
        printf '%s\n' "$new" | head -n 15 | while IFS= read -r l; do note "new: $l"; done
    fi
}
base_boot_covered() {  # was the boot period in the baseline's kernel log?
    if [ -f "$BASE/meta.txt" ]; then [ "$(sed -n 's/^kernel_boot_covered=//p' "$BASE/meta.txt")" = 1 ]; return; fi
    local first; first=$(sed -n -E 's/^\[ *([0-9]+)\.[0-9]+\].*/\1/p' "$BASE/dmesg.txt" 2>/dev/null | head -n 1)
    [ -n "$first" ] && [ "$first" -le 2 ]
}
sumtab() {  # summary.txt -> name TAB level TAB detail, without the lines of the comparison itself
    awk '/^(PASS|WARN|FAIL|INFO|SKIP) / { n = substr($0, 7, 28); sub(/ +$/, "", n)
        if (n ~ /^baseline|_vs_baseline$/) next; print n "\t" $1 "\t" substr($0, 36) }' "$1"
}
compare_summary() {  # result levels and the feature table against the baseline's summary.txt
    [ -f "$BASE/summary.txt" ] || { res SKIP baseline_levels "no summary.txt in $BASE"; return; }
    sumtab "$BASE/summary.txt" > "$TMP/sum-base"; sumtab "$SUM" > "$TMP/sum-now"
    awk -F'\t' 'function rk(l) { return l == "FAIL" ? 2 : (l == "WARN" ? 1 : 0) }
        NR == FNR { bl[$1] = $2; next }
        { seen[$1] = 1
          if (!($1 in bl)) print "new\t" $1 " " $2
          else if (bl[$1] != $2) print (rk($2) > rk(bl[$1]) ? "worse" : (rk($2) < rk(bl[$1]) ? "better" : "changed")) "\t" $1 ": " bl[$1] " -> " $2 }
        END { for (n in bl) if (!(n in seen)) print "gone\t" n " (was " bl[n] ")" }' "$TMP/sum-base" "$TMP/sum-now" | sort > "$TMP/sum-diff"
    local nw nb nc nn ng
    nw=$(grep -c '^worse' "$TMP/sum-diff"); nb=$(grep -c '^better' "$TMP/sum-diff"); nc=$(grep -c '^changed' "$TMP/sum-diff")
    nn=$(grep -c '^new' "$TMP/sum-diff"); ng=$(grep -c '^gone' "$TMP/sum-diff")
    if [ "$nw" -gt 0 ]; then res WARN baseline_levels "$nw worse, $nb better, $nc otherwise changed; $nn checks not in the baseline, $ng only in the baseline"
    else res PASS baseline_levels "none worse, $nb better, $nc otherwise changed; $nn checks not in the baseline, $ng only in the baseline"; fi
    grep -E '^(worse|better|changed)' "$TMP/sum-diff" | while IFS=$'\t' read -r k l; do note "$k: $l"; done
    [ "$nn" -gt 0 ] && note "not in the baseline: $(sed -n 's/^new\t//p' "$TMP/sum-diff" | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
    [ "$ng" -gt 0 ] && note "only in the baseline: $(sed -n 's/^gone\t//p' "$TMP/sum-diff" | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
    # kernel feature table, key by key
    local fd
    fd=$(awk -F'\t' '$1 == "kernel_features" { n = split($3, t, " "); for (i = 1; i <= n; i++) { split(t[i], p, "="); if (NR == FNR) b[p[1]] = p[2]; else c[p[1]] = p[2] } }
        END { for (k in c) { if (!(k in b)) printf "%s: (not in baseline) -> %s\n", k, c[k]; else if (b[k] != c[k]) printf "%s: %s -> %s\n", k, b[k], c[k] }
              for (k in b) if (!(k in c)) printf "%s: %s -> (gone)\n", k, b[k] }' "$TMP/sum-base" "$TMP/sum-now" | sort | tr '\n' ';' | sed 's/;$//; s/;/; /g')
    res INFO features_vs_baseline "${fd:-no difference}"
}
if [ -n "$BASE" ]; then
    if [ ! -d "$BASE" ]; then res WARN baseline "not a directory: $BASE"
    else
        res INFO baseline "$BASE ($(sed -n '1p' "$BASE/summary.txt" 2>/dev/null))"
        DNOTE=""
        { [ "$K_COV" != 1 ] || [ "${COV[main]:-1}" != 1 ]; } && DNOTE=" [the logs of this run do not reach back to boot (kernel $K_REACH min, logcat main ${REACH[main]:-?} min): 'gone' may only mean out of reach]"
        compare denials.txt denials "$DNOTE"
        if [ "$K_COV" != 1 ]; then res SKIP init_failed_vs_baseline "boot period is not in the kernel log of this run"
        elif ! base_boot_covered; then res SKIP init_failed_vs_baseline "boot period is not in the kernel log of the baseline"
        else compare init-failed.txt init_failed; fi
        compare_summary
    fi
fi

echo | tee -a "$SUM"
echo "result: $NFAIL FAIL, $NWARN WARN, $NSKIP SKIP   (details in $OUT)" | tee -a "$SUM"
[ "$NFAIL" = 0 ]
