# ZPS 2.4 Bots

NavBot bots for **Zombie Panic! Source 2.4**, the legacy Source 2007 build that Steam still ships
as the `legacy2.4` beta branch.

Modern Metamod:Source, SourceMod and NavBot don't work on the 2.4 engine. This repo holds the
patches, gamedata, plugins and scripts that make them work, running on the Linux 2.4 dedicated
server. You play from the normal ZPS 2.4 client (Windows build under Proton) and join your own
local server.

No game files are included. `install.sh` downloads the official 2.4 dedicated server with SteamCMD.

## Quick start

```sh
scripts/build.sh                 # fetch pinned upstream sources, apply patches, build (needs podman + GCC 13+)
scripts/install.sh               # download the 2.4 server to ~/zps24-server and install everything
scripts/zps24-server.sh start    # start the bot server (default map zps_deadend)
scripts/zps24-server.sh navgen   # first time on each map: generate the bot nav mesh (a few minutes)
```

Then, in ZPS 2.4, open the console and type `connect <your LAN IP>`. `start` prints the exact
command. (The 2007 engine drops real network packets from 127.x addresses, so the server binds
to your LAN address; `sv_lan 1` keeps internet players out.)

| Command | What it does |
|---|---|
| `zps24-server.sh start [map]` | Start the server in the background (LAN mode, on this PC's LAN address) |
| `zps24-server.sh stop` | Stop it |
| `zps24-server.sh status` | List players and bots |
| `zps24-server.sh cmd "changelevel zps_town"` | Run any server console command |
| `zps24-server.sh navgen` | Generate and save the nav mesh for the current map |
| `zps24-server.sh log` | Follow the server console |

To change the bot count, edit `sm_navbot_quota_target` in `zps/cfg/sourcemod/plugin.navbot_quota.cfg`
(the default is 11 bots on a 12-slot server).

## What had to be fixed

| Problem on ZPS 2.4 | Fix | Where |
|---|---|---|
| Libraries won't load on glibc 2.41+ ("cannot enable executable stack") | Clear the `PT_GNU_STACK` exec bit | `tools/clear_execstack.py` |
| Metamod 1.11+ wipes the engine's whole console command list (`Unknown command "exec"`) | Don't reset `m_pNext` on commands that are already registered | `patches/metamod-zps24.patch` |
| The bundled 2007 `steamclient` crashes once SourceMod runs | Use the current `steamclient.so` | `install.sh` |
| SourceMod can't find the entity list (`NULL g_EntList`) | Add the ZPS 2.4 `gEntList` symbol lookup | `gamedata/core.games-custom-zps24.txt` |
| No `IBotManager` (`Could not find interface: BotManager001`) | Make it optional: bots use `CreateFakeClient` and `CBasePlayer::ProcessUsercmds` | `patches/navbot-zps24.patch` |
| All vtable offsets are for ZPS 3.x | Translate them by function name from the 3.x binary to the 2.4 binary | `tools/port_gamedata.py`, `gamedata/` |
| ZPS 2.4's `CUserCmd` is 84 bytes, not the SDK's 64 (extra `CUtlVector`) | Pass a zero-filled buffer the size of the game's struct (`CUserCmdSize`) | NavBot patch |
| `JoinRound` parses every Steam ID as `STEAM_X:Y:Z`; a bot's `BOT` underflows a `memmove` | Give bots a well-formed fake ID (`SpoofBotNetworkID`) | NavBot patch |
| The game uses `CreateEvent()` results without NULL checks; events nobody listens to crash it | Listen to every game event | `plugins/zps24_compat.sp` |
| NavBot refuses nav commands on dedicated servers | Allow them; only the console/RCON can run them | NavBot patch |
| The server never answers on `127.0.0.1` (the engine treats 127.x as internal loopback) | Bind to the LAN address | `zps24-server.sh` |

## Layout

```
patches/    Metamod:Source and NavBot changes, against the pinned commits in build.sh
gamedata/   SourceMod/NavBot gamedata for the 2.4 server_i486.so
plugins/    zps24_compat (event listeners), zps24_botprobe (headless bot logging), navbot_quota
tools/      vtable.py (dump vtables), port_gamedata.py (3.x -> 2.4 offsets), clear_execstack.py
scripts/    build.sh, install.sh, zps24-server.sh, rcon.py, zps-switch.sh (swap the client between 3.x and 2.4)
configs/    default bot quota
docs/       the manual
```

## Status

Bots spawn, join both teams (including the Carrier), pick up weapons and navigate. Their behavior
still uses NavBot's ZPS 3.x logic, so 2.4-specific things like 2.4 weapons and barricading need
tuning. On shutdown the server sometimes segfaults; this doesn't affect play.

## Credits and license

Built on [NavBot](https://github.com/caxanga334/NavBot) by caxanga334 (GPLv3),
[Metamod:Source](https://github.com/alliedmodders/metamod-source) and
[SourceMod](https://github.com/alliedmodders/sourcemod) by AlliedModders. This repo's code is GPLv3.
Zombie Panic! Source is © Zombie Panic! Team.
