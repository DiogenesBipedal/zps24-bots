#!/bin/sh
# Build the release download: this repo (as committed) plus the patched Metamod:Source and
# NavBot binaries from scripts/build.sh, so people can install without building anything.
#
#   package.sh [version]          (default: git describe)
#
# Writes dist/zps24-bots-<version>-linux.tar.gz. install.sh picks the binaries up from prebuilt/.
# The archive carries no game files and no music.
set -e
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
WORK="${WORK:-$HOME/zps24-dev}"
VER="${1:-$(git -C "$REPO" describe --tags --always)}"
NAME="zps24-bots-$VER"
MM="$WORK/metamod-source/build/package/addons/metamod"
NB="$WORK/NavBot/build/package/addons/sourcemod"

[ -f "$MM/bin/metamod.2.ep2.so" ] && [ -f "$NB/extensions/navbot.ext.2.ep2.so" ] || {
	echo "Build first: scripts/build.sh"; exit 1; }
[ -z "$(git -C "$REPO" status --porcelain)" ] || echo "Warning: uncommitted changes are not included."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git -C "$REPO" archive --prefix="$NAME/" HEAD | tar x -C "$tmp"
mkdir -p "$tmp/$NAME/prebuilt"
cp -a "$MM" "$tmp/$NAME/prebuilt/metamod"
cp -a "$NB" "$tmp/$NAME/prebuilt/navbot"
cat > "$tmp/$NAME/prebuilt/SOURCE.txt" <<EOF
Patched Metamod:Source and NavBot binaries for the ZPS 2.4 server.
Built by scripts/build.sh from the pinned upstream commits listed there, with patches/*.patch.
NavBot is GPLv3; its source and our changes are in this archive and at the project's repository.
EOF
# Never ship music: the radio plugin and importer are fine, the tracks (and their playlist) are not.
music=$(find "$tmp" -iregex '.*\.\(mp3\|ogg\|flac\|wav\|m4a\|opus\)' -o -name 'zps24_radio.cfg')
[ -z "$music" ] || { echo "Refusing to package audio/playlist files:"; echo "$music"; exit 1; }
mkdir -p "$REPO/dist"
tar czf "$REPO/dist/$NAME-linux.tar.gz" -C "$tmp" "$NAME"
echo "Wrote dist/$NAME-linux.tar.gz ($(du -h "$REPO/dist/$NAME-linux.tar.gz" | cut -f1))"
