# ZPS 2.4 Bots

Bots for **Zombie Panic! Source 2.4**, the classic version Steam still offers as the `legacy2.4`
beta. Run a small Linux server on your own PC, fill it with bots, and play survivors vs. zombies
against them from your normal ZPS 2.4 game.

- **Survivor bots** defend the house they spawn in: they head upstairs (upper floors, roofs,
  balconies), shove furniture into the ground-floor doors with bare hands, keep back from windows,
  and shoot zombies from a safe distance, falling back when one gets close. They never break
  windows, doors or barricades.
- **Bots learn from you:** while you play, they record your hold-out spots, the routes you take
  between floors and the distances you fight at, and copy them.
- **Zombie bots** hunt survivors down, follow them upstairs and smash through anything breakable.
- Bots on both teams, including the Carrier. Up to 24 players and bots.
- An **admin menu** (M) to add or remove bots, set their skill, change maps and spawn items, and a
  **grappling hook** (V) for getting around.
- Extras: ammo that respawns on the bot maps, and an optional server-wide music radio.

It's built on [NavBot](https://github.com/caxanga334/NavBot), with fixes that make modern
Metamod:Source, SourceMod and NavBot run on the 2007-era ZPS 2.4 engine.

> **Status: early (v0.1).** Bots play full rounds, but they barricade with furniture only (no
> hammer yet) and some maps need tuning. See [Known issues](#known-issues).

## What you need

- **A Linux PC to host the server.** Tested on x86-64 Linux with glibc 2.41. Windows hosting isn't
  supported yet ([details](#windows)). Players can join from any OS.
- **32-bit libraries** for the 2007 server and SteamCMD. On Debian/Ubuntu:
  `sudo dpkg --add-architecture i386 && sudo apt install lib32gcc-s1 lib32stdc++6 libc6-i386`.
  On other distros, install the equivalent 32-bit glibc and libstdc++ packages.
- `curl`, `tar`, `python3` and `ip` (iproute2). `ffmpeg` too, but only if you use the radio.
- About 7 GB of disk space for the server.
- **ZPS 2.4 on the PC you play from:** in Steam, right-click Zombie Panic! Source → Properties →
  Betas → choose `legacy2.4`.

You don't need to own anything extra: the installer downloads the official ZPS 2.4 dedicated server
anonymously through SteamCMD.

## Install

1. Download `zps24-bots-<version>-linux.tar.gz` from the
   [Releases](../../releases) page and unpack it:
   ```sh
   tar xzf zps24-bots-*-linux.tar.gz
   cd zps24-bots-*
   ```
2. Run the installer. It sets everything up in `~/zps24-server`, or pass another folder:
   ```sh
   scripts/install.sh
   ```
   This downloads the server (about 6 GB, the longest step), installs SourceMod and the patched
   Metamod:Source and NavBot, and adds the plugins and settings. It's safe to run again: it restores
   the original game files first, then reapplies everything.

Want to build the patched Metamod and NavBot yourself instead of using the release binaries? See
[docs/BUILDING.md](docs/BUILDING.md).

## Play

```sh
scripts/zps24-server.sh start      # starts on the cabin map; prints the address to join
```

Then start ZPS 2.4, open the console (enable it in Options → Keyboard → Advanced) and type the
`connect` command that `start` printed, for example `connect 192.168.1.20`.

**First time on a map**, the bots need a navigation mesh. Generate it once while the map is
running (a few minutes; the server saves it):

```sh
scripts/zps24-server.sh navgen
```

The included map rotation (cabin and church) switches map every 2 rounds. Change maps any time
from the admin menu or with `scripts/zps24-server.sh cmd "changelevel <map>"`.

### Server commands

| Command | What it does |
|---|---|
| `zps24-server.sh start [map]` | Start the server in the background |
| `zps24-server.sh stop` | Stop it |
| `zps24-server.sh status` | List players and bots |
| `zps24-server.sh cmd "<command>"` | Run a server console command |
| `zps24-server.sh navgen` | Build the bot navigation mesh for the current map |
| `zps24-server.sh log` | Watch the server console |

The server has 24 slots and fills 23 with bots, leaving one for you. For fewer, start it with
`ZPS24_MAXPLAYERS=12 scripts/zps24-server.sh start`.

### In game

The host PC is set up as the server admin. Admins get these keys bound automatically:

| Key | What it does |
|---|---|
| **M** | Admin menu: add zombie/survivor bots, bot count and skill, kick bots, change or restart the map, noclip, god mode, give yourself weapons, spawn ammo/health/weapons/furniture at your crosshair, spectate with bot info, radio |
| **V** (hold) | Grappling hook |

Anyone can type `!radiomute` in chat to mute or unmute the radio for themselves.

To make a friend on your network an admin, add their IP to
`~/zps24-server/zps/addons/sourcemod/configs/admins_simple.ini` as `"!192.168.1.30" "99:z"`.
LAN players all share the same Steam ID, so admins are matched by IP.

### Music radio (optional)

```sh
scripts/radio-import.sh ~/Music/zps-radio
```

Each subfolder becomes a station. Tracks are converted to MP3 and copied to the server, and players
download them when they join. Use music you're allowed to play: none ships with this project.

## Settings

Everything can be changed in `~/zps24-server/zps/cfg/server.cfg` or live with
`zps24-server.sh cmd "<setting> <value>"`. The most useful ones:

| Setting | Default | What it does |
|---|---|---|
| `sm_navbot_quota_target` | 23 | How many bots (set automatically from the slot count) |
| `sm_zps24ai_give_weapons` | 1 | Survivor bots start with a random gun |
| `sm_zps24ai_infinite_ammo` | 1 | Survivor bots never run dry |
| `sm_zps24ai_engage_range` | 700 | How far survivor bots shoot zombies from |
| `sm_zps24_humans_survive` | 1 | Human players always start as survivors |
| `sm_ammorespawn_maps` | `cabin,church` | Maps where ammo respawns (empty = all) |
| `sm_ammorespawn_delay` | 30 | Seconds before picked-up ammo comes back |
| `mp_maxrounds` | 2 | Rounds before the next map in the rotation |

Every setting and command is in [docs/SETTINGS.md](docs/SETTINGS.md).

## Troubleshooting

- **The game can't connect.** Use the exact address `start` printed, not `localhost` or
  `127.0.0.1`. The 2007 engine ignores those for real connections, so the server listens on your
  LAN address. Joining from another PC? Make sure your firewall allows UDP port 27015.
- **Bots stand still or walk into walls.** The map has no navigation mesh yet: run
  `zps24-server.sh navgen`.
- **The server didn't start.** Check `~/zps24-server/server.log`. Missing 32-bit libraries are
  the usual cause.
- **Something crashes.** Start with `ZPS24_GDB=1 scripts/zps24-server.sh start` (needs `gdb`) to
  get a backtrace in `server.log`, and include it when you report the problem.

## Known issues

- Survivor bots barricade with furniture only. The barricade hammer is off: the game's weight
  limit stops armed bots from carrying it.
- Bots can't climb the church map's ladders.
- Bots occasionally post random text in chat.
- The server sometimes crashes when it shuts down. It doesn't affect play.

See [docs/ROADMAP.md](docs/ROADMAP.md) for what's planned.

## Windows

Players on Windows can join a Linux-hosted server normally. Hosting on Windows isn't supported
yet. Running the server inside WSL2 should work but hasn't been tested.

## Uninstall

Stop the server and delete `~/zps24-server` (plus `~/.config/zps24`, which holds the remote
console password). Nothing else on your system is changed.

## For developers

- [docs/BUILDING.md](docs/BUILDING.md): building from source, what was patched and why.
- [docs/MANUAL.md](docs/MANUAL.md): a long, hands-on guide to how the port works. It covers
  vtables, gamedata, debugging with gdb and writing SourcePawn plugins, using this project as
  the worked example.

## Credits and license

Built on [NavBot](https://github.com/caxanga334/NavBot) by caxanga334 (GPLv3),
[Metamod:Source](https://github.com/alliedmodders/metamod-source) and
[SourceMod](https://github.com/alliedmodders/sourcemod) by AlliedModders. This project's code is
GPLv3 (see [LICENSE](LICENSE)). No game files are included. Zombie Panic! Source is © Zombie Panic!
Team; this is an unofficial community project.
