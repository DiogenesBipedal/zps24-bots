#!/bin/sh
# Import music into the ZPS 2.4 server radio.
#
#   radio-import.sh /path/to/music [server_dir]
#
# Each subfolder of the music folder becomes a station; loose files go to a station named after
# the folder. Every track (mp3/ogg/flac/wav/m4a/opus) is converted to 44.1 kHz MP3, the format the
# Source 2007 engine plays reliably, with a safe lowercase filename, and copied to:
#   - the server:          zps/sound/zps24radio/<station>/<track>.mp3  (players download it)
#   - this PC's ZPS client: the same path, so the local player doesn't have to download anything
# Then writes addons/sourcemod/configs/zps24_radio.cfg (stations, tracks, lengths in seconds).
set -e
SRC="$1"
SERVER="${2:-$HOME/zps24-server}"
CLIENT="${ZPS24_CLIENT:-$HOME/.local/share/Steam/steamapps/common/Zombie Panic Source}"
[ -d "$SRC" ] || { echo "usage: $0 /path/to/music [server_dir]"; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg is required"; exit 1; }

# Safe engine filename: lowercase ASCII, Cyrillic transliterated, extension dropped.
safe() {
	python3 - "$1" <<'PY'
import re, sys, unicodedata
cyr = dict(zip("абвгдеёжзийклмнопрстуфхцчшщъыьэюя",
	["a","b","v","g","d","e","e","zh","z","i","y","k","l","m","n","o","p","r","s","t","u","f","kh","ts","ch","sh","shch","","y","","e","yu","ya"]))
name = re.sub(r"\.[^.]*$", "", sys.argv[1]).lower()
name = "".join(cyr.get(c, c) for c in name)
name = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode()
print(re.sub(r"[^a-z0-9]+", "_", name).strip("_")[:48])
PY
}

OUT="$SERVER/zps/sound/zps24radio"
CFG="$SERVER/zps/addons/sourcemod/configs/zps24_radio.cfg"
mkdir -p "$OUT"
tmp=$(mktemp)
printf '"Radio"\n{\n' > "$tmp"

import_dir() { # dir station
	dir="$1"; station=$(safe "$2"); [ -n "$station" ] || station=music
	found=0
	# All audio in the folder and its subfolders (albums inside an artist folder).
	find "$dir" ${MAXDEPTH:+-maxdepth $MAXDEPTH} -type f | sort > "$tmp.list"
	while IFS= read -r f; do
		case "$(printf '%s' "$f" | tr 'A-Z' 'a-z')" in
			*.mp3|*.ogg|*.flac|*.wav|*.m4a|*.opus|*.aac) ;;
			*) continue ;;
		esac
		[ $found -eq 0 ] && { printf '\t"%s"\n\t{\n' "$station" >> "$tmp"; mkdir -p "$OUT/$station"; }
		found=$((found + 1))
		name=$(safe "$(basename "$f")"); [ -n "$name" ] || name=track$found
		[ -e "$OUT/$station/$name.mp3" ] && grep -q "\"zps24radio/$station/$name.mp3\"" "$tmp" && name="${name}_$found"
		dst="$OUT/$station/$name.mp3"
		if [ ! -s "$dst" ]; then
			ffmpeg -nostdin -loglevel error -y -i "$f" -vn -ar 44100 -ac 2 -codec:a libmp3lame -b:a 160k "$dst"
		fi
		len=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$dst" < /dev/null | cut -d. -f1)
		title=$(basename "$f" | sed 's/\.[^.]*$//; s/"//g')
		printf '\t\t"%d"\n\t\t{\n\t\t\t"file"\t"zps24radio/%s/%s.mp3"\n\t\t\t"length"\t"%s"\n\t\t\t"title"\t"%s"\n\t\t}\n' \
			"$found" "$station" "$name" "$len" "$title" >> "$tmp"
		echo "  $station: $title (${len}s)"
	done < "$tmp.list"
	rm -f "$tmp.list"
	[ $found -gt 0 ] && printf '\t}\n' >> "$tmp"
	return 0
}

echo "Importing from $SRC"
MAXDEPTH=1 import_dir "$SRC" "$(basename "$SRC")"     # loose files: one station
for d in "$SRC"/*/; do
	[ -d "$d" ] && import_dir "${d%/}" "$(basename "$d")"
done
printf '}\n' >> "$tmp"
mv "$tmp" "$CFG"

# Local client copy (same machine): no download needed.
if [ -d "$CLIENT/zps" ]; then
	mkdir -p "$CLIENT/zps/sound/zps24radio"
	cp -ru "$OUT/." "$CLIENT/zps/sound/zps24radio/"
	echo "Copied to the local ZPS client."
fi
echo "Wrote $CFG. In game: M -> Radio, or reload with: sm_radio_reload"
