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
| `sm_zps24ai_barricaders` | 2 | How many bots per house barricade its ground-floor doors at once (0 = off) |
| `sm_zps24ai_boards` | 3 | Pieces of furniture (or boards) per door |
| `sm_zps24ai_holdout_radius` | 550 | Size of a house: doors and windows within this distance of the one nearest a bot's spawn belong to its home |
| `sm_zps24ai_need_tool` | 0 | 1 = barricaders fetch the barricade hammer (unfinished); 0 = they shove furniture into doors |
| `sm_zps24ai_furniture` | 1 | Barricaders without a hammer shove furniture into doors (bare hands, right click) |
| `sm_zps24ai_learned_style` | 1 | Fight at the distances learned from the main player (below) once there are enough samples, instead of `engage_range` and `safe_distance` |
| `sm_zps24ai_debug` | 0 | Log survivor AI decisions to the server console |

Distances are in game units (a player is about 72 units tall).

## Learning from the main player (zps24_learn)

The bots watch one player, the host (server admins), and copy them. Per map, saved in
`addons/sourcemod/data/zps24_learn/<map>.cfg`:

- **Hold spots:** where you stay put for 10+ seconds as a survivor. Survivor bots defend from
  them first in whichever house they're in. Spots where you died count for less.
- **Routes:** paths you take between floors where the bots' nav mesh has no areas (steep
  stairs, jumps, climbs). Both teams walk them. Recorded on either team; ladders and noclip
  don't count.
- **Fighting distances:** how far the nearest zombie is when you open fire, and when you start
  backing away. Survivor bots copy them after 20 and 10 samples.
- **Furniture:** which pieces you shove or carry, and where you leave them (into a door, across
  the stairs, anywhere). Each round, a house's furniture-pushers put the same pieces in the same
  places before barricading the doors. Pieces are recognized by their map ID, so it works
  across rounds; putting a piece back where it started forgets it.
- **Entrances (as a zombie):** where you get into buildings, as the last point outside and the
  first point inside. Zombie bots attack houses through these first, more so the more often you
  used one.

The bots pick up new lessons at the next round.

| Setting / command | Default | What it does |
|---|---|---|
| `sm_zps24learn_enable` | 1 | Learn from the main player |
| `sm_zps24learn_teacher` | (empty) | Learn only from the player whose name contains this; empty = server admins |
| `sm_zps24learn_hold_time` | 10 | Seconds you must stay put for a hold spot |
| `sm_zps24learn_debug` | 1 | Log each lesson to the SourceMod log |
| `sm_zps24learn_status` | | What has been learned on this map |
| `sm_zps24learn_forget` | | Forget this map's lessons |
| `sm_zps24learn_drop <spot\|route\|furniture\|entry> <n>` | | Forget one lesson (numbers from `sm_zps24learn_status`) |

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
| `sm_radio_repeat` | 0 | Repeat the current song over and over (menu: **Repeat this song**; **Pick a song** chooses it) |

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

## Survivor AI inspection (zps24_survivors)

Server console / RCON only.

| Command | What it does |
|---|---|
| `sm_zps24ai_status [all]` | Each home (the house a group of bots defends): bots, doors, windows, defend spots, barricaders. With `all`, every door and window too |
| `sm_zps24ai_bots` | What each survivor bot is doing right now, how long it has been stuck, its weapon and NavBot task |
| `sm_zps24ai_doors` | Every door on the map with its headroom on both sides, and whether it counts as an outside door |

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
