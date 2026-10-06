// Respawns ammo pickups on chosen maps.
//
// ZPS 2.4 has no ammo respawn setting. At round start this plugin records every ammo item on the
// map (including the ones random_ammo spawners created), then checks every few seconds which were
// picked up and recreates each one at its original spot after a delay.
#include <sourcemod>
#include <sdktools>

public Plugin myinfo =
{
	name = "ZPS 2.4 ammo respawn",
	author = "Dead Apocalypse",
	description = "Respawns picked-up ammo on selected maps",
	version = "1.0"
};

ConVar g_maps;      // comma-separated map name fragments, e.g. "cabin,church"
ConVar g_delay;     // seconds before a picked-up item comes back

enum struct AmmoSpot
{
	char classname[64];
	float pos[3];
	float ang[3];
	int ref;           // entity reference of the item currently there, or INVALID_ENT_REFERENCE
	float respawnAt;   // game time to recreate it, 0 when the item is present
}

ArrayList g_spots;
bool g_active;

public void OnPluginStart()
{
	g_maps = CreateConVar("sm_ammorespawn_maps", "cabin,church", "Comma-separated map name fragments where ammo respawns (empty = all maps)");
	g_delay = CreateConVar("sm_ammorespawn_delay", "30", "Seconds before picked-up ammo respawns", _, true, 1.0);
	AutoExecConfig(true, "zps24_ammorespawn");

	g_spots = new ArrayList(sizeof(AmmoSpot));
	HookEventEx("game_round_restart", Event_RoundRestart, EventHookMode_PostNoCopy);
}

public void OnConfigsExecuted()   // runs every map, after cfg/sourcemod/*.cfg so the cvars are set
{
	g_spots.Clear();
	g_active = MapMatches();
	CreateTimer(2.0, Timer_Check, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	if (g_active)
		CreateTimer(5.0, Timer_Record, _, TIMER_FLAG_NO_MAPCHANGE);
}

void Event_RoundRestart(Event event, const char[] name, bool dontBroadcast)
{
	// The map's entities are reset on a new round; record the fresh ones once they've spawned.
	g_spots.Clear();
	if (g_active)
		CreateTimer(5.0, Timer_Record, _, TIMER_FLAG_NO_MAPCHANGE);
}

bool MapMatches()
{
	char maps[256], map[64];
	g_maps.GetString(maps, sizeof(maps));
	GetCurrentMap(map, sizeof(map));
	if (maps[0] == '\0')
		return true;

	char parts[16][64];
	int n = ExplodeString(maps, ",", parts, sizeof(parts), sizeof(parts[]));
	for (int i = 0; i < n; i++)
	{
		TrimString(parts[i]);
		if (parts[i][0] != '\0' && StrContains(map, parts[i], false) != -1)
			return true;
	}
	return false;
}

bool IsAmmoClass(const char[] cls)
{
	return StrContains(cls, "item_ammo", false) == 0 || StrContains(cls, "item_box_buckshot", false) == 0;
}

Action Timer_Record(Handle timer)
{
	g_spots.Clear();
	int ent = -1;
	char cls[64];
	while ((ent = FindEntityByClassname(ent, "item_*")) != -1)
	{
		GetEntityClassname(ent, cls, sizeof(cls));
		if (!IsAmmoClass(cls))
			continue;
		// Skip ammo someone is carrying or that was dropped by a player.
		if (GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity") != -1)
			continue;

		AmmoSpot spot;
		strcopy(spot.classname, sizeof(spot.classname), cls);
		GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", spot.pos);
		GetEntPropVector(ent, Prop_Data, "m_angAbsRotation", spot.ang);
		spot.ref = EntIndexToEntRef(ent);
		spot.respawnAt = 0.0;
		g_spots.PushArray(spot);
	}
	LogMessage("Tracking %d ammo spawn points", g_spots.Length);
	return Plugin_Stop;
}

Action Timer_Check(Handle timer)
{
	if (!g_active)
		return Plugin_Continue;

	float now = GetGameTime();
	for (int i = 0; i < g_spots.Length; i++)
	{
		AmmoSpot spot;
		g_spots.GetArray(i, spot);

		if (spot.respawnAt == 0.0)
		{
			if (EntRefToEntIndex(spot.ref) == INVALID_ENT_REFERENCE)
			{
				spot.respawnAt = now + g_delay.FloatValue;   // picked up: schedule the respawn
				g_spots.SetArray(i, spot);
			}
			continue;
		}

		if (now < spot.respawnAt)
			continue;

		int ent = CreateEntityByName(spot.classname);
		if (ent == -1)
			continue;
		TeleportEntity(ent, spot.pos, spot.ang, NULL_VECTOR);
		DispatchSpawn(ent);
		spot.ref = EntIndexToEntRef(ent);
		spot.respawnAt = 0.0;
		g_spots.SetArray(i, spot);
	}
	return Plugin_Continue;
}
