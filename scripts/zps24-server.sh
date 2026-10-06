#!/bin/sh
# ZPS 2.4 bot server (Linux dedicated server + Metamod/SourceMod/NavBot ported to Source 2007).
#
#   zps24-server.sh start [map]   start in the background (default map: zps_deadend)
#   zps24-server.sh stop          stop it
#   zps24-server.sh status        show players
#   zps24-server.sh cmd "..."     run a server console command
#   zps24-server.sh navgen        generate the bot nav mesh for the current map (once per map)
#   zps24-server.sh log           follow the server console
#
# Join from the ZPS 2.4 client console with:  connect 127.0.0.1
set -e
SERVER="${ZPS24_SERVER:-$HOME/zps24-server}"
CONF="$HOME/.config/zps24"
LOG="$SERVER/server.log"
HERE="$(dirname "$(readlink -f "$0")")"
export ZPS24_RCON_PW_FILE="$CONF/rcon.pw"

rcon() { python3 "$HERE/rcon.py" "$@"; }
running() { pgrep -x srcds_i486 >/dev/null; }

case "${1:-}" in
start)
	running && { echo "Server already running."; exit 0; }
	mkdir -p "$CONF"
	[ -s "$CONF/rcon.pw" ] || { umask 077; python3 -c 'import secrets;print(secrets.token_hex(16))' > "$CONF/rcon.pw"; }
	map="${2:-zps_deadend}"
	cd "$SERVER"
	# -insecure: SourceMod needs it. sv_lan 1: the ancient server can't do Steam auth, LAN mode skips it.
	LD_LIBRARY_PATH="$SERVER/bin:$SERVER" setsid ./srcds_i486 -game zps -console -insecure \
		+ip 127.0.0.1 +sv_lan 1 +maxplayers 12 +rcon_password "$(cat "$CONF/rcon.pw")" +map "$map" \
		< /dev/null > "$LOG" 2>&1 &
	printf 'Starting'
	for i in $(seq 60); do sleep 2; printf '.'; rcon "echo ready" 2>/dev/null | grep -q ready && break; done
	echo; running && echo "Server up on $map. In ZPS 2.4 open the console and type: connect 127.0.0.1" || { echo "Server failed; see $LOG"; exit 1; }
	;;
stop)
	running || { echo "Not running."; exit 0; }
	rcon quit >/dev/null 2>&1 || true
	sleep 3; pkill -x srcds_i486 2>/dev/null || true
	echo "Stopped."
	;;
status) rcon status ;;
cmd) shift; rcon "$@" ;;
navgen)
	map=$(rcon status | awk '/^map/{print $3}')
	nav="$SERVER/zps/addons/sourcemod/data/navbot/zps/$map.smnav"
	rm -f "$nav"
	rcon "sv_cheats 1" "sm_nav_generate" >/dev/null
	printf 'Generating nav mesh for %s' "$map"
	for i in $(seq 300); do sleep 2; printf '.'; [ -s "$nav" ] && break; done
	rcon "sv_cheats 0" >/dev/null
	echo; [ -s "$nav" ] && echo "Saved $nav" || echo "Nav generation did not finish; see $LOG"
	;;
log) tail -f "$LOG" ;;
*) sed -n '2,12p' "$0"; exit 1 ;;
esac
