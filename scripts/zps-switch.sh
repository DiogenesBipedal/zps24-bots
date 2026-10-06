#!/bin/sh
# Swap Zombie Panic! Source between 3.x (native Linux + NavBot) and 2.4 legacy (Proton).
# Usage: zps-switch.sh 3 | 2.4 | status
# Each version's full game folder and Steam manifest are kept in ~/.local/share/zps-versions/.
set -e
V="$HOME/.local/share/zps-versions"
APPS="$HOME/.local/share/Steam/steamapps"
GAME="$APPS/common/Zombie Panic Source"
CFG="$HOME/.local/share/Steam/config/config.vdf"
active=$(cat "$V/active" 2>/dev/null || echo 3)

case "$1" in
  status) echo "active: $active"; ls "$V"; exit 0 ;;
  3|2.4) want=$1 ;;
  *) echo "usage: $0 3|2.4|status"; exit 1 ;;
esac
[ "$want" = "$active" ] && { echo "ZPS $want is already active"; exit 0; }
[ -d "$V/zps$want" ] || { echo "no saved copy of ZPS $want in $V"; exit 1; }
if pgrep -x zps_linux >/dev/null || pgrep -f 'Zombie Panic Source/(zps|hl2)\.exe' >/dev/null; then
  echo "Close Zombie Panic! Source first."; exit 1
fi

echo "Stopping Steam..."
steam -shutdown >/dev/null 2>&1 || true
for i in $(seq 60); do pgrep -x steam >/dev/null || break; sleep 1; done

# Park the active version, bring in the wanted one (same filesystem, so these are instant renames).
mv "$GAME" "$V/zps$active"
cp -p "$APPS/appmanifest_17500.acf" "$V/appmanifest_17500.zps$active.acf"
mv "$V/zps$want" "$GAME"
cp -p "$V/appmanifest_17500.zps$want.acf" "$APPS/appmanifest_17500.acf"

# 3.x runs natively (no compat tool); 2.4 is Windows-only and needs Proton.
python3 - "$CFG" "$want" <<'EOF'
import re, sys
p, want = sys.argv[1], sys.argv[2]
s = open(p).read()
s = re.sub(r'\n(\t+)"17500"\n\1\{\n\1\t"name"[^\n]*\n(?:\1\t[^\n]*\n)*?\1\}', '', s, count=1)
if want == "2.4":
    m = re.search(r'\n(\t+)"CompatToolMapping"\n\1\{\n', s)
    ind = m.group(1) + "\t"
    entry = (f'{ind}"17500"\n{ind}{{\n{ind}\t"name"\t\t"proton_8"\n{ind}\t"config"\t\t""\n'
             f'{ind}\t"priority"\t\t"250"\n{ind}}}\n')
    s = s[:m.end()] + entry + s[m.end():]
open(p, "w").write(s)
EOF

echo "$want" > "$V/active"
(setsid steam >/dev/null 2>&1 &)
echo "Switched to ZPS $want. Steam is restarting."
