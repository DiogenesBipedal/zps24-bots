# Settings and commands

Set these in `~/zps24-server/zps/cfg/server.cfg` (loaded on every map) or change them live with
`scripts/zps24-server.sh cmd "<setting> <value>"`. Bot-count settings live in
`zps/cfg/sourcemod/plugin.navbot_quota.cfg`.

## Bot count (navbot_quota)

| Setting | Default here | What it does |
|---|---|---|
| `sm_navbot_quota_target` | 23 | Number of bots. `zps24-server.sh start` sets it to the slot count minus one |
| `sm_navbot_quota_fixed` | 1 | Always keep exactly that many bots, even while no human is playing |
| `sm_navbot_quota_empty_server` | 0 | 1 = kick every bot when the server is empty |
| `sm_navbot_quota_ignore_other_bots` | 1 | Don't count non-NavBot bots |
| `sm_navbot_quota_use_smart_kick` | 1 | When removing bots, pick the least disruptive ones |
| `sm_navbot_quota_check_teams` | 1 | Don't count players in spectator or unassigned |

## Survivor bots (zps24_survivors)

| Setting | Default | What it does |
|---|---|---|
| `sm_zps24ai_enable` | 1 | Turn the survivor AI on or off (off = plain NavBot behavior) |
| `sm_zps24ai_give_weapons` | 1 | Give every survivor bot a random gun at spawn |
| `sm_zps24ai_infinite_ammo` | 1 | Keep survivor bots' reserve ammo topped up |
| `sm_zps24ai_equip_time` | 0 | Seconds bots spend collecting weapons and ammo at round start (only useful with `give_weapons 0`) |
| `sm_zps24ai_engage_range` | 700 | Distance at which bots aim at and shoot visible zombies |
| `sm_zps24ai_safe_distance` | 260 | Bots stand and shoot until a zombie is this close, then fall back (upstairs when there is one) |
| `sm_zps24ai_upper_height` | 80 | How much higher a spot must be to count as an upper floor, roof or balcony |
| `sm_zps24ai_barricaders` | 2 | How many bots barricade the ground floor at once (0 = off) |
| `sm_zps24ai_boards` | 3 | Boards per door or window when barricading |
| `sm_zps24ai_holdout_radius` | 550 | Doors and windows within this distance of the hold-out get barricaded |
| `sm_zps24ai_need_tool` | 0 | 1 = barricaders fetch the barricade hammer (unfinished); 0 = they push furniture into doors and windows |
| `sm_zps24ai_furniture` | 1 | Barricaders without a hammer push furniture into openings |
| `sm_zps24ai_debug` | 0 | Log survivor AI decisions to the server console |

Distances are in game units (a player is about 72 units tall).

## Zombie bots (zps24_zombies)

| Setting | Default | What it does |
|---|---|---|
| `sm_zps24zombies_enable` | 1 | Turn the zombie AI on or off |
| `sm_zps24zombies_debug` | 0 | Log zombie AI decisions |
| `sm_zps24zombies_force_target` | 0 | Debugging: every zombie hunts this player slot (0 = normal) |

## Admin tools (zps24_admin)

| Setting | Default | What it does |
|---|---|---|
| `sm_zps24_humans_survive` | 1 | Human players start every round as survivors |
| `sm_zps24_autobind` | 1 | Bind M (menu) and V (hook) for admins when they join |
| `sm_zps24_hook_speed` | 900 | Grappling hook pull speed |
| `sm_zps24_volunteer_value` | -1 | Experimental, leave at -1 |

| Command | Who | What it does |
|---|---|---|
| `sm_zpsmenu` | admin | Open the admin menu (bound to M) |
| `+zpshook` | admin | Grappling hook while held (bound to V) |
| `sm_here` (`!here` in chat) | anyone | Log your position, for reporting bot movement problems |

## Ammo respawn (zps24_ammorespawn)

| Setting | Default | What it does |
|---|---|---|
| `sm_ammorespawn_maps` | `cabin,church` | Map name fragments where ammo respawns (empty = every map) |
| `sm_ammorespawn_delay` | 30 | Seconds before picked-up ammo comes back |

## Radio (zps24_radio)

| Setting | Default | What it does |
|---|---|---|
| `sm_radio_volume` | 0.5 | Volume, 0 to 1 |
| `sm_radio_autostart` | 1 | Start playing on every map |
| `sm_radio_shuffle` | 1 | Play tracks in random order |

| Command | Who | What it does |
|---|---|---|
| `sm_radio` | admin | Radio menu: next track, change station, volume (also in the M menu) |
| `sm_radio_reload` | admin | Reload the station list after running `radio-import.sh` |
| `!radiomute` / `!radiooff` | anyone | Mute or unmute the radio for yourself |

Stations and tracks are listed in `addons/sourcemod/configs/zps24_radio.cfg`, which
`scripts/radio-import.sh` writes.

## Debugging (zps24_botprobe)

| Setting | Default | What it does |
|---|---|---|
| `sm_botprobe_interval` | 0 | Seconds between bot state logs in the server console (0 = off) |

## Nav mesh tools (zps24_navdebug)

Server console / RCON only (`zps24-server.sh cmd "..."`). For finding out why bots can't get
somewhere on a map.

| Command | What it does |
|---|---|
| `sm_navdump x1 y1 z1 x2 y2 z2` | Every nav area in the box: extent, neighbors (with height change and gap), ladder/jump links |
| `sm_navreach x y z x1 y1 z1 x2 y2 z2` | Which areas in the box can be reached from the area at x y z |
| `sm_floormap x1 y1 x2 y2 ztop step` | Floor heights on a grid (traces down from ztop): shows stairs, holes and ledges |
| `sm_where <team>` | Positions of a team's living players (2 = survivors, 3 = zombies) |
| `sm_navtp <client> x y z [1]` | Move a player there, optionally pinned in place (1) |
| `sm_navseed x y z` | Add a generation seed. **Crashes NavBot when used outside generation; don't use** |

## Map rotation

`server.cfg` points `mapcyclefile` at `mapcycle_bots.txt` (cabin and church) and sets
`mp_maxrounds 2`, so the map changes every 2 rounds. Add maps to `zps/mapcycle_bots.txt` and run
`zps24-server.sh navgen` once on each new map.

## Environment variables for the scripts

| Variable | Used by | Default | What it does |
|---|---|---|---|
| `ZPS24_MAXPLAYERS` | `zps24-server.sh start` | 24 | Server slots (ZPS 2.4's maximum is 24) |
| `ZPS24_SERVER` | `zps24-server.sh` | `~/zps24-server` | Where the server is installed |
| `ZPS24_IP` | `zps24-server.sh` | your LAN address | Address to listen on |
| `ZPS24_GDB` | `zps24-server.sh start` | unset | 1 = run under gdb, writing crash backtraces to `server.log` |
| `STEAMCMD` | `install.sh` | `~/.local/share/steamcmd` | Where SteamCMD lives (downloaded if missing) |
| `ZPS24_CLIENT` | `radio-import.sh` | Steam's ZPS folder | Your local ZPS install, so you don't have to download the tracks |
| `WORK` | `build.sh`, `install.sh`, `package.sh` | `~/zps24-dev` | Source build folder |
