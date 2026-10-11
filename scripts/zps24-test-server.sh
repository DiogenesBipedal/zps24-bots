#!/bin/bash
# A second server instance from the same install, for testing and nav generation while someone
# plays on the main one. Port 27035, few slots, its own log; tracked by PID (never by name).
#   zps24-test-server.sh start [map] [slots] | stop | cmd "..." ["..."] | log
SERVER="${ZPS24_SERVER:-$HOME/zps24-server}"
CONF="$HOME/.config/zps24"
PORT=27035
PIDF="$CONF/test-server.pid"
LOG="$SERVER/test-server.log"
HERE="$(dirname "$(readlink -f "$0")")"
LANIP="${ZPS24_IP:-$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')}"
export ZPS24_RCON_PW_FILE="$CONF/rcon.pw" ZPS24_RCON_HOST="$LANIP" ZPS24_RCON_PORT="$PORT"
rcon() { python3 "$HERE/rcon.py" "$@"; }
case "$1" in
start)
	cd "$SERVER" || exit 1
	LD_LIBRARY_PATH="$SERVER/bin:$SERVER" setsid ./srcds_i486 -game zps -console -insecure -port $PORT +ip "$LANIP" \
		+sv_lan 1 +maxplayers "${3:-2}" +rcon_password "$(cat "$CONF/rcon.pw")" +map "${2:-zpo_cabin_outbreak_b8_com}" \
		< /dev/null > "$LOG" 2>&1 &
	echo $! > "$PIDF"
	for i in $(seq 40); do sleep 3; rcon "echo ready" 2>/dev/null | grep -q ready && break; done
	echo "test server up on $LANIP:$PORT" ;;
stop)
	[ -f "$PIDF" ] && kill "$(cat "$PIDF")" 2>/dev/null; rm -f "$PIDF"; echo stopped ;;
cmd) shift; rcon "$@" ;;
log) tail -${2:-40} "$LOG" ;;
*) sed -n '2,5p' "$0" ;;
esac
