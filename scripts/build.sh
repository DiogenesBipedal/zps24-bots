#!/bin/sh
# Build the ZPS 2.4 (Source 2007 / "orangebox") versions of Metamod:Source and NavBot.
#
# Fetches the pinned upstream sources into $WORK (default ~/zps24-dev), applies this repo's
# patches and builds:
#   - Metamod:Source 1.12 (commit 75dd7b2) in the Steam Runtime sniper SDK container (i686 GCC 10),
#     the same toolchain AlliedModders uses for official builds;
#   - NavBot 0.1.2-pr2 on the host with GCC 13+ (NavBot needs C++20) using -m32.
# SourceMod is not rebuilt: the official 1.12 build works once Metamod is fixed.
set -e
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
WORK="${WORK:-$HOME/zps24-dev}"
SNIPER=registry.gitlab.steamos.cloud/steamrt/sniper/sdk:latest
mkdir -p "$WORK" && cd "$WORK"

clone() { # dir url ref
	[ -d "$1" ] || git clone -q --recursive "$2" "$1"
	git -C "$1" fetch -q --tags origin
	git -C "$1" checkout -q "$3"
	git -C "$1" submodule update -q --init --recursive
}
clone ambuild          https://github.com/alliedmodders/ambuild          01212cb
clone hl2sdk-orangebox https://github.com/alliedmodders/hl2sdk           88bc34ab
clone metamod-source   https://github.com/alliedmodders/metamod-source   75dd7b2
clone sourcemod        https://github.com/alliedmodders/sourcemod        03865e00c
clone NavBot           https://github.com/caxanga334/NavBot              0.1.2-pr2

apply() { # dir patch
	git -C "$1" checkout -q -- .
	git -C "$1" apply --whitespace=nowarn "$2"
}
apply metamod-source "$REPO/patches/metamod-zps24.patch"
apply NavBot         "$REPO/patches/navbot-zps24.patch"

echo "== Metamod:Source (sniper container)"
podman run --rm -v "$WORK:/work:Z" -w /work/metamod-source "$SNIPER" sh -c '
	export PYTHONPATH=/work/ambuild
	rm -rf build && mkdir build && cd build
	CC=i686-linux-gnu-gcc-10 CXX=i686-linux-gnu-g++-10 python3 ../configure.py --sdks=orangebox \
		--hl2sdk-root=/work --targets=x86 --enable-optimize >/dev/null
	python3 -c "from ambuild2.run import cli_run; cli_run()" | tail -1'

echo "== NavBot (host GCC)"
gcc -dumpversion | awk -F. '$1 < 13 { print "NavBot needs GCC 13 or newer"; exit 1 }'
cd "$WORK/NavBot" && rm -rf build && mkdir build && cd build
PYTHONPATH="$WORK/ambuild" CC=gcc CXX=g++ python3 ../configure.py --sdks=orangebox --hl2sdk-root="$WORK" \
	--sm-path="$WORK/sourcemod" --mms-path="$WORK/metamod-source" --targets=x86 --enable-optimize >/dev/null
PYTHONPATH="$WORK/ambuild" python3 -c "from ambuild2.run import cli_run; cli_run()" | tail -1

echo "Built:"
ls "$WORK/metamod-source/build/package/addons/metamod/bin/metamod.2.ep2.so" \
   "$WORK/NavBot/build/package/addons/sourcemod/extensions/navbot.ext.2.ep2.so"
