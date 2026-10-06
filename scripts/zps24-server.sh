#!/bin/sh
# ZPS 2.4 bot server (Linux dedicated server + Metamod/SourceMod/NavBot ported to Source 2007).
#
#   zps24-server.sh start [map]   start in the background (default map: cabin; set ZPS24_MAXPLAYERS to change the 24 slots)
#   zps24-server.sh stop          stop it
#   zps24-server.sh status        show players
#   zps24-server.sh cmd "..."     run a server console command
#   zps24-server.sh navgen        generate the bot nav mesh for the current map (once per map)
#   zps24-server.sh log           follow the server console
#   ZPS24_GDB=1 zps24-server.sh start   run under gdb: crash backtraces in server.log
#
# Join from the ZPS 2.4 client console with:  connect <your LAN IP>   (start prints it)
#
# The server binds to this PC's LAN address, not 127.0.0.1: the 2007 engine treats every 127.x
# address as its internal loopback and silently drops real UDP packets from it. sv_lan 1 keeps
# internet players out; RCON is protected by a random password in ~/.config/zps24/rcon.pw.
set -e
SERVER="${ZPS24_SERVER:-$HOME/zps24-server}"
CONF="$HOME/.config/zps24"
LOG="$SERVER/server.log"
HERE="$(dirname "$(readlink -f "$0")")"
export ZPS24_RCON_PW_FILE="$CONF/rcon.pw"
LANIP="${ZPS24_IP:-$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')}"
export ZPS24_RCON_HOST="$LANIP"

rcon() { python3 "$HERE/rcon.py" "$@"; }
running() { pgrep -x srcds_i486 >/dev/null; }

case "${1:-}" in
start)
	running && { echo "Server already running."; exit 0; }
	mkdir -p "$CONF"
	[ -s "$CONF/rcon.pw" ] || { umask 077; python3 -c 'import secrets;print(secrets.token_hex(16))' > "$CONF/rcon.pw"; }
	map="${2:-zpo_cabin_outbreak_b8_com}"
	maxp="${ZPS24_MAXPLAYERS:-24}"   # ZPS 2.4 caps this at 24
	# Fill every slot but one (yours) with bots.
	sed -i "s/^sm_navbot_quota_target .*/sm_navbot_quota_target \"$((maxp - 1))\"/" \
		"$SERVER/zps/cfg/sourcemod/plugin.navbot_quota.cfg" 2>/dev/null || true
	cd "$SERVER"
	# -insecure: SourceMod needs it. sv_lan 1: LAN clients only, and no Steam auth.
	set -- -game zps -console -insecure +ip "$LANIP" +sv_lan 1 +maxplayers "$maxp" \
		+rcon_password "$(cat "$CONF/rcon.pw")" +map "$map"
	if [ -n "${ZPS24_GDB:-}" ]; then
		# Debug mode: crash backtraces, plus a backtrace for every chat message (Host_Say).
		cat > "$CONF/debug.gdb" <<'GDB'
set pagination off
set breakpoint pending on
handle SIGPIPE nostop noprint
break Host_Say
commands
silent
printf "== Host_Say from:\n"
bt 8
continue
end
run
printf "== CRASH\n"
bt 40
info registers
GDB
		LD_LIBRARY_PATH="$SERVER/bin:$SERVER" setsid gdb -batch -x "$CONF/debug.gdb" --args ./srcds_i486 "$@" \
			< /dev/null > "$LOG" 2>&1 &
	else
		LD_LIBRARY_PATH="$SERVER/bin:$SERVER" setsid ./srcds_i486 "$@" < /dev/null > "$LOG" 2>&1 &
	fi
	printf 'Starting'
	for i in $(seq 60); do sleep 2; printf '.'; rcon "echo ready" 2>/dev/null | grep -q ready && break; done
	echo; running && echo "Server up on $map. In ZPS 2.4 open the console and type: connect $LANIP" || { echo "Server failed; see $LOG"; exit 1; }
	;;
stop)
	running || { echo "Not running."; exit 0; }
	rcon quit >/dev/null 2>&1 || true
	sleep 3; pkill -x srcds_i486 2>/dev/null || true; pkill -x gdb 2>/dev/null || true
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
