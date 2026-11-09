#!/usr/bin/env bash
# Read-only report of what changed upstream since the tree was last synced:
#   - the LineageOS lineage-24.0 manifest and its AOSP tag (a new tag = big, monthly update),
#   - every project on a branch (LineageOS repos, rINanDO's forks): new commits since our revision,
#     with the commit subjects for the projects we patch,
#   - rINanDO's gts210wifi-patches repository,
#   - microG GmsCore and Aurora Store releases against what the image ships.
# Nothing in the tree is fetched or changed; it uses `git ls-remote`, the GitHub API (gh) and
# the GitLab API. Output goes to stdout and logs/updates/updates-<date>.txt.
# Usage: scripts/check-updates.sh [-v]     (-v: list commit subjects for every changed project)
set -uo pipefail
W=${GTS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
L=${LINEAGE_ROOT:-$W/lineage}
VERBOSE=0; [ "${1:-}" = "-v" ] && VERBOSE=1
BRANCH=lineage-24.0
command -v gh >/dev/null || { echo "needs the GitHub CLI (gh), logged in" >&2; exit 1; }
[ -f "$W/env.sh" ] && source "$W/env.sh"
command -v repo >/dev/null || { echo "needs repo in PATH (source env.sh)" >&2; exit 1; }

OUTDIR="$W/logs/updates"; mkdir -p "$OUTDIR"
OUT="$OUTDIR/updates-$(date +%Y%m%d-%H%M).txt"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
exec > >(tee "$OUT") 2>&1

echo "Upstream update check, $(date '+%Y-%m-%d %H:%M')"
echo

# --- 1. manifest and AOSP tag --------------------------------------------------------------
ours_manifest=$(git -C "$L/.repo/manifests" rev-parse HEAD)
remote_manifest=$(git ls-remote https://github.com/LineageOS/android "refs/heads/$BRANCH" | cut -f1)
ours_tag=$(grep -o 'revision="refs/tags/android-[^"]*"' "$L/.repo/manifests/default.xml" | head -1 | sed 's/.*tags\///; s/"//')
remote_tag=$(gh api "repos/LineageOS/android/contents/default.xml?ref=$BRANCH" --jq .content 2>/dev/null \
             | base64 -d | grep -o 'revision="refs/tags/android-[^"]*"' | head -1 | sed 's/.*tags\///; s/"//')
echo "== LineageOS manifest ($BRANCH)"
echo "   synced:  ${ours_manifest:0:12}   upstream: ${remote_manifest:0:12}"
if [ "$ours_manifest" != "$remote_manifest" ]; then
    gh api "repos/LineageOS/android/compare/$ours_manifest...$BRANCH" \
        --jq '"   \(.ahead_by) new manifest commit(s):", (.commits[] | "     \(.commit.committer.date[0:10]) \(.commit.message | split("\n")[0])")' 2>/dev/null | head -12
fi
echo "   AOSP tag: synced $ours_tag, upstream ${remote_tag:-?}"
if [ -n "$remote_tag" ] && [ "$remote_tag" != "$ours_tag" ]; then
    echo "   >>> NEW AOSP TAG: a big update (security release); rINanDO's series may need rebasing."
fi
echo

# --- 2. projects on branches ----------------------------------------------------------------
# projects we patch: ours (patches/*/TARGET) and rINanDO's series (directory names = repo names)
: > "$TMP/patched"
for t in "$W"/patches/*/TARGET; do echo "$(cat "$t")" >> "$TMP/patched"; done
ls "$W/patches-rinando/LOS-24.0" 2>/dev/null | grep '^android_' > "$TMP/rinando_series"

(cd "$L" && repo forall -c 'r=$(git rev-parse -q --verify m/'"$BRANCH"' 2>/dev/null || git rev-parse HEAD); echo "$REPO_PROJECT|$REPO_PATH|$REPO_REMOTE|$REPO_RREV|$r"') \
    2>/dev/null | awk -F'|' '$3=="github" && $4 !~ /^refs\/tags\// && $4 !~ /^[0-9a-f]{40}$/' > "$TMP/projects"
echo "== Projects on branches: $(wc -l < "$TMP/projects") (AOSP projects pinned to tags are skipped)"

check_one() {  # name|path|remote|rrev|ours
    IFS='|' read -r name path remote rrev ours <<< "$1"
    ref=${rrev#refs/heads/}
    up=$(git ls-remote "https://github.com/$name" "refs/heads/$ref" 2>/dev/null | cut -f1)
    [ -n "$up" ] && [ "$up" != "$ours" ] && echo "$name|$path|$ref|$ours|$up"
}
export -f check_one
xargs -a "$TMP/projects" -d '\n' -P 16 -I{} bash -c 'check_one "$@"' _ {} > "$TMP/changed"
echo "   changed upstream: $(wc -l < "$TMP/changed")"
echo

sort -t'|' -k2 "$TMP/changed" | while IFS='|' read -r name path ref ours up; do
    mark=""
    grep -qx "$path" "$TMP/patched" && mark="$mark [our patch]"
    grep -qx "${name#*/}" "$TMP/rinando_series" && mark="$mark [rINanDO series]"
    case "$name" in rINanDO/*|rinando/*) mark="$mark [rINanDO fork]";; esac
    n=$(gh api "repos/$name/compare/$ours...$ref" --jq .ahead_by 2>/dev/null || echo "?")
    echo "-- $path ($name): $n new commit(s)$mark"
    if [ -n "$mark" ] || [ "$VERBOSE" = 1 ]; then
        gh api "repos/$name/compare/$ours...$ref" \
            --jq '.commits[] | "     \(.commit.committer.date[0:10]) \(.commit.message | split("\n")[0])"' 2>/dev/null | tail -15
    fi
done
echo

# --- 3. rINanDO's patch repository -----------------------------------------------------------
echo "== rINanDO gts210wifi-patches"
ours_p=$(git -C "$W/patches-rinando" rev-parse HEAD 2>/dev/null)
up_p=$(git ls-remote https://github.com/rINanDO/gts210wifi-patches HEAD | cut -f1)
echo "   local ${ours_p:0:12}, upstream ${up_p:0:12}"
if [ -n "$up_p" ] && [ "$ours_p" != "$up_p" ]; then
    gh api "repos/rINanDO/gts210wifi-patches/compare/$ours_p...$up_p" \
        --jq '.commits[] | "     \(.commit.committer.date[0:10]) \(.commit.message | split("\n")[0])"' 2>/dev/null | tail -20
fi
echo

# --- 4. prebuilt apps ------------------------------------------------------------------------
echo "== Prebuilt apps (shipped, from scripts/fetch-prebuilts.sh)"
grep -E '^ *"[^"|]+\|[^|]+\|https://' "$W/scripts/fetch-prebuilts.sh" | sed -E 's/^ *"([^|]*)\|.*/   shipped: \1/'
echo "   microG GmsCore latest releases:"
gh api "repos/microg/GmsCore/releases?per_page=3" --jq '.[] | "     \(.published_at[0:10]) \(.tag_name)\(if .prerelease then " (pre-release)" else "" end)"' 2>/dev/null
echo "   microG issue #3853 (Aurora login): $(gh api repos/microg/GmsCore/issues/3853 --jq .state 2>/dev/null)"
echo "   Aurora Store latest release: $(curl -fsS 'https://gitlab.com/api/v4/projects/AuroraOSS%2FAuroraStore/releases?per_page=1' 2>/dev/null \
      | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r[0]["tag_name"], r[0]["released_at"][:10]) if r else print("?")' 2>/dev/null || echo '?')"
echo
echo "Report saved to $OUT"
