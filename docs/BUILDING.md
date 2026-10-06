# Building from source

The release download already includes the patched Metamod:Source and NavBot binaries. Build them
yourself if you want to change the C++ side, audit what you run, or the release doesn't fit your
system.

## Requirements

- Linux x86-64 with **GCC 13 or newer** and 32-bit support (`gcc -m32` must work: on
  Debian/Ubuntu install `gcc-multilib g++-multilib`). NavBot needs C++20.
- **podman** (rootless is fine). Metamod:Source is built inside Valve's Steam Runtime "sniper"
  SDK container with i686 GCC 10, the same toolchain AlliedModders uses for official builds.
- `git`, `python3`.

## Build and install

```sh
scripts/build.sh          # fetch pinned sources into ~/zps24-dev (or $WORK), patch, build
scripts/install.sh        # install the server using what build.sh produced
```

`build.sh` checks out these exact upstream versions, applies `patches/`, and builds:

| Project | Version | Patch |
|---|---|---|
| Metamod:Source | commit `75dd7b2` (1.12) | `patches/metamod-zps24.patch` |
| NavBot | `0.1.2-pr2` | `patches/navbot-zps24.patch` |
| hl2sdk (orangebox) | `88bc34ab` | none |
| SourceMod (headers only) | `03865e00c` | none: the official 1.12 build runs as-is |
| AMBuild | `01212cb` | none |

To produce a release archive afterwards (repo + binaries, no game files, no music):

```sh
scripts/package.sh v0.2   # writes dist/zps24-bots-v0.2-linux.tar.gz
```

## Repository layout

```
patches/    Metamod:Source and NavBot changes, against the pinned commits above
gamedata/   SourceMod/NavBot gamedata (offsets and symbols) for the 2.4 server_i486.so
plugins/    SourcePawn plugins: the bot AI, admin tools, ammo respawn, radio, compatibility fixes
configs/    server.cfg, bot quota, map rotation, NavBot weapon definitions
scripts/    build, install, package, run the server, RCON client, radio importer
tools/      helpers used for the port (vtable dumper, 3.x -> 2.4 gamedata translator, execstack fix)
docs/       this file, settings reference, roadmap, the porting manual
```

Plugins are compiled by `install.sh` with the SourceMod compiler that comes with SourceMod. To
iterate on one, edit it, rerun `install.sh` (or compile it with `spcomp` into
`zps/addons/sourcemod/plugins/`), then change the map. Reloading AI plugins mid-map leaves stale
bot tasks behind.

## What had to be fixed for ZPS 2.4

ZPS 2.4 runs on the 2007 Source engine. Current Metamod:Source, SourceMod and NavBot target newer
games, so a lot broke. [MANUAL.md](MANUAL.md) walks through how each problem was found and fixed.

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

## Debugging

- `ZPS24_GDB=1 scripts/zps24-server.sh start` runs the server under gdb. Crash backtraces and a
  backtrace for every chat message (`Host_Say`) go to `server.log`.
- `sm_zps24ai_debug 1`, `sm_zps24zombies_debug 1` and `sm_botprobe_interval 5` log what the bots
  are doing.
- `scripts/rcon.py` sends console commands to the running server; `zps24-server.sh cmd` wraps it.
