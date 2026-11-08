#!/usr/bin/env bash
# Runs a command inside the build container with the project mounted at the same path.
# Usage: scripts/docker-run.sh <command...>
# OWN_KEYS (own signing keys, see "Own signing keys" in README.md) is passed into the container
# when it is set; when it is not, the docker command line is the same as without that line.
# LINEAGE_ROOT and VENDOR_BLOBS are passed in only when they are set, and mounted at the same
# path when they lie outside the project root.
W=${GTS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# scripts/dk.sh, where present, is a local helper that runs docker through newgrp when the
# session predates the docker group membership; without it docker is called directly.
DOCKER=docker
[ -x "$W/scripts/dk.sh" ] && DOCKER="$W/scripts/dk.sh"
extra=()
[ -f "$W/gitconfig" ] && extra+=(-e GIT_CONFIG_GLOBAL="$W/gitconfig")
for v in LINEAGE_ROOT VENDOR_BLOBS; do
    p=${!v:-}
    [ -n "$p" ] || continue
    p=$(cd "$p" && pwd) || exit 1
    case "$p/" in "$W"/*) ;; *) extra+=(-v "$p:$p") ;; esac
    extra+=(-e "$v=$p")
done
exec "$DOCKER" run --rm --init \
     -v "$W:$W" -w "$W" \
     "${extra[@]}" \
     ${OWN_KEYS:+-e OWN_KEYS="$OWN_KEYS"} \
     --ulimit nofile=1048576:1048576 \
     --name gts210ltexx-build \
     gts210ltexx-build:latest "$@"
