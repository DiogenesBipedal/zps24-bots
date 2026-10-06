#!/bin/sh
# Install a ZPS 2.4 bot server: the legacy2.4 Linux dedicated server, official SourceMod 1.12,
# the patched Metamod:Source and NavBot from build.sh, this repo's gamedata, plugins and configs.
#
#   install.sh [server_dir]      (default ~/zps24-server)
#
# Safe to re-run: SteamCMD's validate restores the original game files first, then every fix
# below is applied again.
set -e
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
WORK="${WORK:-$HOME/zps24-dev}"
SERVER="${1:-$HOME/zps24-server}"
STEAMCMD="${STEAMCMD:-$HOME/.local/share/steamcmd}"
SM_URL=https://sm.alliedmods.net/smdrop/1.12
MM_BIN="$WORK/metamod-source/build/package/addons/metamod"
NB_PKG="$WORK/NavBot/build/package/addons/sourcemod"
SPCOMP_INC="$SERVER/zps/addons/sourcemod/scripting/include"

[ -f "$MM_BIN/bin/metamod.2.ep2.so" ] && [ -f "$NB_PKG/extensions/navbot.ext.2.ep2.so" ] || {
	echo "Run scripts/build.sh first."; exit 1; }

echo "== 1. ZPS 2.4 dedicated server (SteamCMD, anonymous, beta legacy2.4)"
if [ ! -x "$STEAMCMD/steamcmd.sh" ]; then
	mkdir -p "$STEAMCMD"
	curl -sfL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz | tar xz -C "$STEAMCMD"
fi
"$STEAMCMD/steamcmd.sh" +force_install_dir "$SERVER" +login anonymous \
	+app_update 17505 -beta legacy2.4 validate +quit | grep -E 'Success|ERROR' || true

echo "== 2. glibc 2.41+: clear the executable-stack flag on the 2007-era libraries"
python3 "$REPO/tools/clear_execstack.py" "$SERVER"/bin/*.so "$SERVER"/zps/bin/*.so

echo "== 3. Current steamclient (the bundled 2007 one crashes once SourceMod is loaded)"
cp -n "$SERVER/bin/steamclient_i486.so" "$SERVER/bin/steamclient_i486.so.orig" 2>/dev/null || true
for c in "$HOME/.steam/sdk32/steamclient.so" "$STEAMCMD/linux32/steamclient.so"; do
	[ -f "$c" ] && { cp "$c" "$SERVER/bin/steamclient_i486.so"; break; }
done

echo "== 4. SourceMod 1.12 (official build)"
tmp=$(mktemp -d)
sm=$(curl -sf "$SM_URL/sourcemod-latest-linux")
curl -sfL "$SM_URL/$sm" | tar xz -C "$tmp"
mkdir -p "$SERVER/zps/addons" "$SERVER/zps/cfg"
cp -a "$tmp/addons/sourcemod" "$SERVER/zps/addons/"
cp -an "$tmp/cfg/." "$SERVER/zps/cfg/" 2>/dev/null || true  # keep existing configs
rm -rf "$tmp"
sed -i 's/"DisableAutoUpdate"\s*"no"/"DisableAutoUpdate"\t\t"yes"/' "$SERVER/zps/addons/sourcemod/configs/core.cfg"

echo "== 5. Patched Metamod:Source"
mkdir -p "$SERVER/zps/addons/metamod/bin"
cp -a "$MM_BIN/." "$SERVER/zps/addons/metamod/"
rm -f "$SERVER/zps/addons/metamod_x64.vdf" "$SERVER/zps/addons/metamod/bin/linux64" 2>/dev/null || true
printf '"Plugin"\n{\n\t"file"\t"addons/metamod/bin/server"\n}\n' > "$SERVER/zps/addons/metamod.vdf"
printf '"Metamod Plugin"\n{\n\t"alias"\t\t"sourcemod"\n\t"file"\t\t"addons/sourcemod/bin/sourcemod_mm"\n}\n' \
	> "$SERVER/zps/addons/metamod/sourcemod.vdf"

echo "== 6. Patched NavBot"
SMD="$SERVER/zps/addons/sourcemod"
cp "$NB_PKG/extensions/navbot.ext.2.ep2.so" "$NB_PKG/extensions/navbot.autoload" "$SMD/extensions/"
for d in gamedata configs data translations scripting; do
	[ -d "$NB_PKG/$d" ] && cp -a "$NB_PKG/$d/." "$SMD/$d/"
done

echo "== 7. ZPS 2.4 gamedata"
cp "$REPO/gamedata/navbot.games-game.zps.txt"      "$SMD/gamedata/navbot.games/game.zps.txt"
cp "$REPO/gamedata/sdktools.games-game.zpanic.txt" "$SMD/gamedata/sdktools.games/game.zpanic.txt"
cp "$REPO/gamedata/sdkhooks.games-game.zpanic.txt" "$SMD/gamedata/sdkhooks.games/game.zpanic.txt"
mkdir -p "$SMD/gamedata/core.games/custom"
cp "$REPO/gamedata/core.games-custom-zps24.txt"    "$SMD/gamedata/core.games/custom/zps24.txt"
cp "$REPO/gamedata/zps24_ai.games.txt"             "$SMD/gamedata/"
cp "$REPO/configs/navbot/weapons.cfg"              "$SMD/configs/navbot/zps/weapons.cfg"

echo "== 8. Plugins and configs"
for p in zps24_compat zps24_botprobe zps24_ammorespawn zps24_survivors zps24_zombies zps24_admin zps24_radio navbot_quota; do
	"$SMD/scripting/spcomp" -i"$SPCOMP_INC" -i"$REPO/plugins" "$REPO/plugins/$p.sp" \
		-o "$SMD/plugins/$p.smx" >/dev/null
done
mkdir -p "$SERVER/zps/cfg/sourcemod"
cp -n "$REPO/configs/plugin.navbot_quota.cfg" "$SERVER/zps/cfg/sourcemod/" 2>/dev/null || true
cp -n "$REPO/configs/server.cfg" "$SERVER/zps/cfg/" 2>/dev/null || true
cp -n "$REPO/configs/mapcycle_bots.txt" "$SERVER/zps/" 2>/dev/null || true
# Make the local machine admin (LAN Steam IDs are all STEAM_ID_LAN, so match by IP).
LANIP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
grep -q "\"!$LANIP\"" "$SMD/configs/admins_simple.ini" || printf '"!%s"\t"99:z"\n' "$LANIP" >> "$SMD/configs/admins_simple.ini"

echo "Installed into $SERVER. Start it with scripts/zps24-server.sh start"
