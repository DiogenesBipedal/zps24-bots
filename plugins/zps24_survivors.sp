// ZPS 2.4 survivor brain for NavBot bots.
//
// NavBot's ZPS survivor AI only roams. This plugin gives survivor bots the classic 2.4 game plan:
//
//   1. Gear up    (first sm_zps24ai_equip_time seconds of a round): NavBot runs on its own and
//                 collects weapons and ammo (with E).
//   2. Hold out   Every bot defends the house it spawned in (its "home": the doors and windows
//                 around its spawn). Up to sm_zps24ai_barricaders bots per house block its
//                 ground-floor doors, shoving furniture into them with bare hands (H, right
//                 click), or nailing boards with the barricade tool (sm_zps24ai_need_tool 1).
//   3. Defend     Everyone else holds a spot upstairs or in a corner, away from the windows,
//                 watching the doors and windows, and shoots what comes in.
//
// Always: bots never break windows, doors or barricades (no shooting through them, no smashing
// them on the way); a bot holding a gun backs away from zombies closer than
// sm_zps24ai_safe_distance; furniture in the way gets shoved aside; closed doors get opened with E.
//
// Bots are steered through NavBot's scripted plugin command: OnScriptedUpdate() runs every bot
// update and returns where the bot should walk.
#include <sourcemod>
#pragma dynamic 1048576   // 4 MB heap: Doors_LoadButtons reads the map's entity lump
#include <sdktools>
#include <navbot>
#undef REQUIRE_EXTENSIONS
#include <sdkhooks>                       // optional: SDKHooks_DropWeapon for melee weapons "dropweapon" won't drop
#define REQUIRE_EXTENSIONS
#include "include/zps24_unstick.inc"
#include "include/zps24_stairs.inc"
#include "include/zps24_doors.inc"

public Plugin myinfo =
{
	name = "ZPS 2.4 survivor AI",
	author = "Dead Apocalypse",
	description = "Hold out, barricade, kite and open doors for NavBot survivors on ZPS 2.4",
	version = "1.0"
};

#define TEAM_SURVIVORS 2
#define TEAM_ZOMBIES   3
#define AMMO_BARRICADE 7          // ammo index of barricade boards (see GetAmmoDef in the manual)
#define MAX_OPENINGS   64

ConVar g_giveWeapons, g_infiniteAmmo, g_needTool, g_engageRange;
ConVar g_enable, g_equipTime, g_radius, g_safeDist, g_barricaders, g_boardsPerOpening, g_debug, g_upperHeight, g_furniture, g_learnedStyle, g_builders;

// Builders: a few survivor bots per house that trade their melee weapon for the barricade hammer
// and nail boards where the main player nailed them (zps24_learn "boards").
bool  g_builder[MAXPLAYERS + 1];
int   g_buildLesson[MAXPLAYERS + 1] = { -1, ... };
int   g_buildTries[MAXPLAYERS + 1];
int   g_dropTries[MAXPLAYERS + 1];
int   g_buildScan[MAXPLAYERS + 1];   // which aim offset DoBuild is trying
int   g_buildAmmo[MAXPLAYERS + 1];   // boards carried when the hammering started
float g_nextNail[MAXPLAYERS + 1];
float g_clickUntil[MAXPLAYERS + 1];  // a builder's left click, held until then
int   g_closeBtn[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };   // Close button we're going to press
float g_closeUntil[MAXPLAYERS + 1];
bool  g_closeWalking[MAXPLAYERS + 1];
int   g_breakDoor[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };   // basement door being smashed
float g_breakUntil[MAXPLAYERS + 1];         // "dropweapon" sent for the melee weapon in hand
int   g_hammerFails[MAXPLAYERS + 1];       // offered the hammer and still don't have it
int   g_spawnedHammer[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };
float g_buildRecheck[MAXPLAYERS + 1];
int   g_boardClaim[LEARN_MAX_BOARDS];      // builder working on it (0 = nobody)
bool  g_boardGiveUp[LEARN_MAX_BOARDS];     // couldn't nail it this round

// Distances to fight at: the settings, or what the main player does (zps24_learn).
float EngageRange()
{
	float r = g_engageRange.FloatValue;
	if (g_learnedStyle.BoolValue && g_ln_shootN >= 20)
		r = ClampF(Learned_ShootDist(r) * 1.15, 250.0, 1200.0);
	return r;
}

float SafeDist()
{
	float d = g_safeDist.FloatValue;
	if (g_learnedStyle.BoolValue && g_ln_retreatN >= 10)
		d = ClampF(Learned_RetreatDist(d), 120.0, 500.0);
	return d;
}

float ClampF(float v, float lo, float hi)
{
	return v < lo ? lo : v > hi ? hi : v;
}

Handle g_canAttach;               // SDKCall: bool CWeapon_Barricade::CanAttachBarricade()

// Homes: the buildings the bots hold out in. Every bot defends the house it spawned in, so bots
// spawning in different houses defend different houses.
#define MAX_HOMES  4
#define MAX_DEFEND 32
int   g_homeCount;
bool  g_homeValid[MAX_HOMES];
float g_homePos[MAX_HOMES][3];
float g_homeChosenAt[MAX_HOMES];
int   g_homeDeaths[MAX_HOMES];           // survivor bot deaths there since it was chosen
// Defend spots inside each home: upper floors / roofs / balconies first, then corners, never
// next to a window.
int   g_defendCount[MAX_HOMES];
int   g_upperCount[MAX_HOMES];           // the first g_upperCount defend spots are upstairs
float g_floorZ[MAX_HOMES];               // the home's ground floor height
float g_defendPos[MAX_HOMES][MAX_DEFEND][3];

// Doors and windows of all homes.
int   g_openingCount;
float g_openingPos[MAX_OPENINGS][3];
float g_openingInside[MAX_OPENINGS][3];  // unit vector pointing from the opening into the building
int   g_openingEnt[MAX_OPENINGS];        // the door/window entity
int   g_openingHome[MAX_OPENINGS];       // home it belongs to (-1 = home abandoned)
bool  g_openingWindow[MAX_OPENINGS];     // window (kept clear of furniture and bots) or door
int   g_openingBoards[MAX_OPENINGS];     // furniture/boards successfully placed
int   g_openingClaim[MAX_OPENINGS];      // client working on it (0 = nobody)
bool  g_openingDone[MAX_OPENINGS];
float g_roundStart;
float g_badHoldout[8][3];                // homes we were overrun at this round
// Per-map hold-out (configs/zps24_maps.cfg) for maps where the best place isn't the spawn building.
bool  g_mapHome;
float g_mapHomePos[3];
float g_mapRadius;                       // 0 = sm_zps24ai_holdout_radius
float g_mapGround;                       // street level heights are measured from
bool  g_mapPreferUp;
bool  g_mapSpread;                        // spots all over the building, every floor, far apart
float g_mapPatrol;                        // share of the bots that patrol between spots (0-1)
bool  g_patrolArrived[MAXPLAYERS + 1];
int   g_badHoldoutCount;

// Per-bot state
enum BotJob { JOB_NONE, JOB_BARRICADE, JOB_PLACE, JOB_BUILD }   // JOB_PLACE: copy a learned furniture placement; JOB_BUILD: nail the main player's boards
BotJob g_job[MAXPLAYERS + 1];
int    g_jobOpening[MAXPLAYERS + 1];
int    g_jobPlace[MAXPLAYERS + 1];       // learned placement being copied (JOB_PLACE)
int    g_placeHome[LEARN_MAX_PLACES];    // home a learned furniture placement belongs to this round (-1 = none)
int    g_placeClaim[LEARN_MAX_PLACES];
bool   g_placeDone[LEARN_MAX_PLACES];
float  g_jobStarted[MAXPLAYERS + 1];
int    g_aimTry[MAXPLAYERS + 1];
float  g_hammerUntil[MAXPLAYERS + 1];
float  g_hammerStart[MAXPLAYERS + 1];
int    g_hammerMode[MAXPLAYERS + 1];
int    g_modeNext;                       // round-robin over hammer input patterns until one works
int    g_modeWorks = 0;                  // hold attack through the animation: verified to place boards    // holding attack on a locked aim point until this time
float  g_hammerAim[MAXPLAYERS + 1][3];
int    g_hammerBoardsBefore[MAXPLAYERS + 1];
int    g_carryProp[MAXPLAYERS + 1];      // furniture being carried (entity reference) or INVALID_ENT_REFERENCE
float  g_nextUse[MAXPLAYERS + 1];
float  g_restockUntil[MAXPLAYERS + 1];
bool   g_scripted[MAXPLAYERS + 1];
float  g_lastPos[MAXPLAYERS + 1][3];
int    g_givenGun[MAXPLAYERS + 1];
int    g_armTries[MAXPLAYERS + 1];       // failed gun handovers (weight limit) since the last success
float  g_armPauseUntil[MAXPLAYERS + 1];
int    g_defendIdx[MAXPLAYERS + 1];      // which defend spot the bot holds
float  g_defendSwitch[MAXPLAYERS + 1];   // when to move to another spot
int    g_hurtBy[MAXPLAYERS + 1];         // zombie that last hit this bot (client index)
float  g_hurtUntil[MAXPLAYERS + 1];      // react to that hit until then
float  g_lookAround[MAXPLAYERS + 1];     // next time to turn and watch another door/window
int    g_home[MAXPLAYERS + 1] = { -1, ... };   // home the bot defends
float  g_spawnPos[MAXPLAYERS + 1][3];
bool   g_haveSpawn[MAXPLAYERS + 1];
float  g_handsUntil[MAXPLAYERS + 1];     // holding bare hands to shove furniture: don't switch back yet
int    g_shoveProp[MAXPLAYERS + 1];      // furniture in the way, being shoved aside (entity reference)
float  g_shoveUntil[MAXPLAYERS + 1];
float  g_shoveFrom[MAXPLAYERS + 1][3];   // where that furniture was when the bot started shoving it
int    g_pushes[MAXPLAYERS + 1];         // shoves at the current piece of furniture
float  g_pushBest[MAXPLAYERS + 1];       // its closest distance to the door so far
int    g_pushStuck[MAXPLAYERS + 1];      // shoves without getting it closer
int    g_badProp[16];                    // furniture that wouldn't budge (entity references)
int    g_badPropCount;
char   g_state[MAXPLAYERS + 1][48];      // last decision of the scripted update, for sm_zps24ai_bots

static const char g_guns[][] = { "weapon_glock", "weapon_glock18c", "weapon_usp", "weapon_ppk", "weapon_revolver",
	"weapon_870", "weapon_supershorty", "weapon_winchester", "weapon_ak47", "weapon_m4", "weapon_mp5" };

public void OnPluginStart()
{
	g_enable           = CreateConVar("sm_zps24ai_enable", "1", "Enable the ZPS 2.4 survivor AI");
	g_equipTime        = CreateConVar("sm_zps24ai_equip_time", "0", "Seconds at round start bots spend collecting weapons/ammo before holding out (not needed with sm_zps24ai_give_weapons)");
	g_giveWeapons      = CreateConVar("sm_zps24ai_give_weapons", "1", "Give every survivor bot a random gun");
	g_infiniteAmmo     = CreateConVar("sm_zps24ai_infinite_ammo", "1", "Keep survivor bots' reserve ammo topped up (no resupplying)");
	g_engageRange      = CreateConVar("sm_zps24ai_engage_range", "700", "Survivor bots aim at and shoot visible zombies within this range");
	g_needTool         = CreateConVar("sm_zps24ai_need_tool", "0", "Barricaders must fetch a weapon_barricade first (0 = they push furniture into the openings instead)");
	g_radius           = CreateConVar("sm_zps24ai_holdout_radius", "550", "Doors/windows within this distance of the hold-out get barricaded");
	g_safeDist         = CreateConVar("sm_zps24ai_safe_distance", "260", "Bots with guns back away from zombies closer than this");
	g_barricaders      = CreateConVar("sm_zps24ai_barricaders", "2", "How many survivor bots barricade the ground floor at once (0 = off)");
	g_boardsPerOpening = CreateConVar("sm_zps24ai_boards", "3", "Boards to put on each door/window");
	g_debug            = CreateConVar("sm_zps24ai_debug", "0", "Log AI decisions");
	g_upperHeight      = CreateConVar("sm_zps24ai_upper_height", "80", "Nav areas this much above the hold-out floor count as upper floor / roof / balcony");
	g_builders         = CreateConVar("sm_zps24ai_builders", "2", "Survivor bots (in total, at most one per house) that swap their melee weapon for the barricade hammer and nail boards where the main player nailed them (0 = off)");
	g_learnedStyle     = CreateConVar("sm_zps24ai_learned_style", "1", "Use the shooting and backing-off distances learned from the main player (zps24_learn) once there are enough samples");
	g_furniture        = CreateConVar("sm_zps24ai_furniture", "1", "Barricaders without a barricade tool carry furniture to the openings");
	AutoExecConfig(true, "zps24_survivors");

	// The barricade hammer's own fit check. Optional: the Windows server.dll doesn't have it (the
	// game never calls it, so the linker dropped it); without it bots barricade with furniture.
	GameData gd = new GameData("zps24_ai.games");
	if (gd != null)
	{
		StartPrepSDKCall(SDKCall_Entity);
		if (PrepSDKCall_SetFromConf(gd, SDKConf_Signature, "CanAttachBarricade"))
		{
			PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
			g_canAttach = EndPrepSDKCall();
		}
		delete gd;
	}
	if (g_canAttach == null)
		LogMessage("CanAttachBarricade not available: barricading with furniture only");

	HookEventEx("game_round_restart", Event_RoundRestart, EventHookMode_PostNoCopy);
	HookEventEx("player_death", Event_PlayerDeath, EventHookMode_Post);
	HookEventEx("player_hurt", Event_PlayerHurt, EventHookMode_Post);
	HookEventEx("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
	RegServerCmd("sm_zps24ai_status", Cmd_Status, "Show the hold-out and barricade progress");
	RegServerCmd("sm_zps24ai_bots", Cmd_Bots, "What each survivor bot is doing");
	RegServerCmd("sm_zps24ai_doors", Cmd_Doors, "List every door with its size and the headroom on both sides");
	ResetRound();
}

void LoadMapConfig()
{
	g_mapHome = false;
	g_mapRadius = 0.0;
	g_mapPreferUp = false;
	g_mapSpread = false;
	g_mapPatrol = 0.0;
	char path[PLATFORM_MAX_PATH], map[64];
	BuildPath(Path_SM, path, sizeof(path), "configs/zps24_maps.cfg");
	GetCurrentMap(map, sizeof(map));
	KeyValues kv = new KeyValues("Maps");
	if (kv.ImportFromFile(path) && kv.JumpToKey(map))
	{
		float none[3] = { 999999.0, 0.0, 0.0 };
		kv.GetVector("home", g_mapHomePos, none);
		g_mapHome = g_mapHomePos[0] != 999999.0;
		g_mapRadius = kv.GetFloat("radius", 0.0);
		g_mapGround = kv.GetFloat("ground", g_mapHomePos[2]);
		char prefer[16];
		kv.GetString("prefer", prefer, sizeof(prefer), "both");
		g_mapPreferUp = StrEqual(prefer, "up");
		g_mapSpread = kv.GetNum("spread", 0) != 0;
		g_mapPatrol = kv.GetFloat("patrol", 0.0);
		if (g_mapHome)
			LogMessage("%s: survivors hold out at %.0f %.0f %.0f (from configs/zps24_maps.cfg)", map, g_mapHomePos[0], g_mapHomePos[1], g_mapHomePos[2]);
	}
	delete kv;
}

public void OnMapStart()
{
	Doors_LoadButtons();
	LoadMapConfig();
	Stairs_OnMapStart();          // hand-made stair routes, plus what the bots learned from you
	ResetRound();
	CreateTimer(1.0, Timer_Think, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void Event_RoundRestart(Event event, const char[] name, bool dontBroadcast)
{
	Stairs_Relearn();
	ResetRound();
}

void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	if (victim > 0 && IsClientInGame(victim) && GetClientTeam(victim) == TEAM_SURVIVORS)
	{
		int h = g_home[victim];
		if (h >= 0 && h < MAX_HOMES)
			g_homeDeaths[h]++;
	}
}

// Remember where each survivor bot spawned: that's the house it defends.
void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client < 1 || !IsClientInGame(client))
		return;
	g_home[client] = -1;
	g_haveSpawn[client] = false;
	g_builder[client] = false;
	g_hammerFails[client] = 0;
	CreateTimer(0.2, Timer_RecordSpawn, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_RecordSpawn(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client > 0 && IsClientInGame(client) && IsPlayerAlive(client) && GetClientTeam(client) == TEAM_SURVIVORS)
	{
		GetClientAbsOrigin(client, g_spawnPos[client]);
		g_haveSpawn[client] = true;
	}
	return Plugin_Stop;
}

// A zombie hit a survivor bot: for the next 3 s it turns on that zombie, backs off to a safe
// distance and keeps shooting, even if the zombie came from behind.
void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
	int victim = GetClientOfUserId(event.GetInt("userid"));
	if (victim < 1 || !IsClientInGame(victim) || !IsFakeClient(victim) || GetClientTeam(victim) != TEAM_SURVIVORS)
		return;
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	if (attacker < 1 || !IsClientInGame(attacker) || GetClientTeam(attacker) != TEAM_ZOMBIES)
	{
		// No attacker reported: blame the nearest zombie within claw reach.
		float d;
		attacker = NearestZombie(victim, 140.0, d);
		if (!attacker)
			return;
	}
	g_hurtBy[victim] = attacker;
	g_hurtUntil[victim] = GetGameTime() + 3.0;
	Debug("%N hit by %N (%d hp left): backing off", victim, attacker, event.GetInt("health"));
}

// Overrun: 3+ survivors died at a home and 3+ zombies are inside it. Remember it as bad; its
// bots move to the nearest other house.
void CheckOverrun()
{
	for (int h = 0; h < g_homeCount; h++)
	{
		if (!g_homeValid[h] || g_homeDeaths[h] < 3)
			continue;
		int inside = 0;
		float pos[3];
		for (int i = 1; i <= MaxClients; i++)
		{
			if (!IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) != TEAM_ZOMBIES)
				continue;
			GetClientAbsOrigin(i, pos);
			if (GetVectorDistance(pos, g_homePos[h]) < g_radius.FloatValue)
				inside++;
		}
		if (inside < 3)
			continue;
		if (g_badHoldoutCount < sizeof(g_badHoldout))
			g_badHoldout[g_badHoldoutCount++] = g_homePos[h];
		Debug("Overrun at home %d (%.0f %.0f %.0f, %d deaths, %d zombies inside): relocating", h, g_homePos[h][0], g_homePos[h][1], g_homePos[h][2], g_homeDeaths[h], inside);
		AbandonHome(h);
	}
}

void AbandonHome(int h)
{
	g_homeValid[h] = false;
	for (int k = 0; k < LEARN_MAX_PLACES; k++)
		if (g_placeHome[k] == h)
			g_placeHome[k] = -1;
	for (int o = 0; o < g_openingCount; o++)
		if (g_openingHome[o] == h)
			g_openingHome[o] = -1;
	for (int i = 1; i <= MaxClients; i++)
		if (g_home[i] == h)
		{
			if (g_job[i] != JOB_NONE) ReleaseJob(i, false);
			g_home[i] = -1;
			g_haveSpawn[i] = false;          // pick the house nearest to where it is now
		}
}

void ResetRound()
{
	g_homeCount = 0;
	g_openingCount = 0;
	g_badHoldoutCount = 0;
	g_badPropCount = 0;
	g_roundStart = GetGameTime();
	for (int k = 0; k < LEARN_MAX_PLACES; k++)
	{
		g_placeHome[k] = -1;
		g_placeClaim[k] = 0;
		g_placeDone[k] = false;
	}
	for (int b = 0; b < LEARN_MAX_BOARDS; b++)
	{
		g_boardClaim[b] = 0;
		g_boardGiveUp[b] = false;
	}
	for (int i = 0; i <= MaxClients; i++)
	{
		g_builder[i] = false;
		g_buildLesson[i] = -1;
		g_hammerFails[i] = 0;
	}
	for (int i = 0; i <= MaxClients; i++)
	{
		g_job[i] = JOB_NONE;
		g_carryProp[i] = INVALID_ENT_REFERENCE;
		g_givenGun[i] = INVALID_ENT_REFERENCE;
		g_shoveProp[i] = INVALID_ENT_REFERENCE;
		g_home[i] = -1;
		Unstick_Reset(i);
		g_scripted[i] = false;
		g_restockUntil[i] = 0.0;
	}
}

void Debug(const char[] fmt, any ...)
{
	if (!g_debug.BoolValue)
		return;
	char buf[256];
	VFormat(buf, sizeof(buf), fmt, 2);
	LogMessage("%s", buf);   // SourceMod log file: not delayed like the console under gdb
}

// ---------------------------------------------------------------------------------------------
// Hold-out selection

// World-space center of a (brush) entity.
void EntityCenter(int ent, float out[3])
{
	float origin[3], mins[3], maxs[3];
	GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", origin);
	GetEntPropVector(ent, Prop_Send, "m_vecMins", mins);
	GetEntPropVector(ent, Prop_Send, "m_vecMaxs", maxs);
	for (int i = 0; i < 3; i++)
		out[i] = origin[i] + (mins[i] + maxs[i]) * 0.5;
}

// Height of the open space above a point: short = under a roof (inside), long/sky = outside.
float SpaceAbove(const float from[3])
{
	float to[3];
	to = from;
	to[2] += 2000.0;
	TR_TraceRayFilter(from, to, MASK_SOLID_BRUSHONLY, RayType_EndPoint, TraceIgnoreSelf, 0);
	if (!TR_DidHit() || (TR_GetSurfaceFlags() & SURF_SKY))
		return 2000.0;
	float hit[3];
	TR_GetEndPosition(hit);
	return hit[2] - from[2];
}

// Is this a window or door in an outside wall? On success, inside = unit vector into the building.
// The opening's thin horizontal axis is its facing; one side must be roofed and the other open.
bool IsExteriorOpening(int ent, const float center[3], float inside[3])
{
	char cls[64];
	GetEntityClassname(ent, cls, sizeof(cls));
	float mins[3], maxs[3];
	GetEntPropVector(ent, Prop_Send, "m_vecMins", mins);
	GetEntPropVector(ent, Prop_Send, "m_vecMaxs", maxs);
	float sx = maxs[0] - mins[0], sy = maxs[1] - mins[1], sz = maxs[2] - mins[2];

	bool isDoor = StrContains(cls, "door") != -1;
	bool isGlass = StrEqual(cls, "func_breakable_surf");
	// Window/door shaped: thin in one horizontal axis, a sensible height.
	float thin = sx < sy ? sx : sy, wide = sx < sy ? sy : sx;
	if (thin > 16.0 || wide < 24.0 || sz < 24.0 || sz > 140.0)
		return false;
	if (!isDoor && !isGlass && !StrEqual(cls, "func_breakable"))
		return false;
	if (isDoor && sz < 70.0)
		return false;

	float n[3];
	n[0] = sx < sy ? 1.0 : 0.0;
	n[1] = sx < sy ? 0.0 : 1.0;
	n[2] = 0.0;
	// Headroom just beside it: one side under a roof (< 400 units), the other open or much higher.
	float a[3], b[3];
	for (int i = 0; i < 3; i++) { a[i] = center[i] + n[i] * 48.0; b[i] = center[i] - n[i] * 48.0; }
	float ua = SpaceAbove(a), ub = SpaceAbove(b);
	if (ua < 400.0 && ub > ua + 300.0)       { inside = n; return true; }
	if (ub < 400.0 && ua > ub + 300.0)       { for (int i = 0; i < 3; i++) inside[i] = -n[i]; return true; }
	// Doors often open onto a porch, roofed on both sides. Look farther out: open sky within a
	// few steps on one side only means the other side is indoors.
	if (!isDoor)
		return false;
	bool skyA = false, skyB = false;
	for (float dist = 128.0; dist <= 208.0; dist += 80.0)
	{
		for (int i = 0; i < 3; i++) { a[i] = center[i] + n[i] * dist; b[i] = center[i] - n[i] * dist; }
		if (SpaceAbove(a) > 400.0) skyA = true;
		if (SpaceAbove(b) > 400.0) skyB = true;
	}
	if (skyA == skyB)
		return false;
	if (skyB) inside = n; else for (int i = 0; i < 3; i++) inside[i] = -n[i];
	return true;
}

int CollectOpenings(float pos[][3], float inside[][3], bool[] isWindow, int[] ents, int max)
{
	static const char classes[][] = { "func_door_rotating", "func_door", "prop_door_rotating", "func_breakable_surf", "func_breakable" };
	int n = 0;
	for (int c = 0; c < sizeof(classes); c++)
	{
		int ent = -1;
		while ((ent = FindEntityByClassname(ent, classes[c])) != -1 && n < max)
		{
			EntityCenter(ent, pos[n]);
			if (IsExteriorOpening(ent, pos[n], inside[n]))
			{
				isWindow[n] = c >= 3;
				ents[n] = ent;
				// Wooden func_breakables of door size are doors too (the church's main doors).
				if (c == 4)
				{
					float mins[3], maxs[3];
					GetEntPropVector(ent, Prop_Send, "m_vecMins", mins);
					GetEntPropVector(ent, Prop_Send, "m_vecMaxs", maxs);
					if (GetEntProp(ent, Prop_Data, "m_Material") != 0 && maxs[2] - mins[2] >= 70.0)
						isWindow[n] = false;
				}
				n++;
			}
		}
	}
	return n;
}

bool IsBadHoldout(const float pos[3])
{
	for (int k = 0; k < g_badHoldoutCount; k++)
		if (GetVectorDistance(pos, g_badHoldout[k]) < g_radius.FloatValue)
			return true;
	return false;
}

// Home for a bot: the house it spawned in (or, after an overrun, the nearest other house).
// Bots of the same house share it.
void AssignHome(int client)
{
	float from[3];
	if (g_haveSpawn[client])
		from = g_spawnPos[client];
	else
		GetClientAbsOrigin(client, from);
	if (g_mapHome && !IsBadHoldout(g_mapHomePos))
		from = g_mapHomePos;               // this map's hold-out, wherever they spawned
	float r = g_radius.FloatValue;

	// A home we already have that this spot is in or right next to.
	int best = -1;
	float bestDist = r;
	for (int h = 0; h < g_homeCount; h++)
	{
		if (!g_homeValid[h])
			continue;
		float d = GetVectorDistance(from, g_homePos[h]);
		if (d < bestDist) { bestDist = d; best = h; }
	}
	if (best == -1)
		best = CreateHome(from);
	if (best == -1)
		return;
	g_home[client] = best;
	g_defendIdx[client] = GetRandomInt(0, 7);
	g_defendSwitch[client] = 0.0;
	g_patrolArrived[client] = false;
	Debug("%N defends home %d", client, best);
}

// Make a home of the building nearest to `from`: the exterior door or window closest to it and
// every other one within sm_zps24ai_holdout_radius of that. Returns the home or -1.
int CreateHome(const float from[3])
{
	static float all[MAX_OPENINGS * 4][3], allInside[MAX_OPENINGS * 4][3];
	static bool allWindow[MAX_OPENINGS * 4];
	static int allEnt[MAX_OPENINGS * 4];
	int count = CollectOpenings(all, allInside, allWindow, allEnt, sizeof(all));
	if (count == 0)
		return -1;
	float r = g_radius.FloatValue;

	int seed = -1;
	float seedDist = 999999.0;
	for (int i = 0; i < count; i++)
	{
		if (IsBadHoldout(all[i]))
			continue;
		float d = GetVectorDistance(from, all[i]);
		if (d < seedDist) { seedDist = d; seed = i; }
	}
	if (seed == -1)
		return -1;

	int h = -1;
	for (int k = 0; k < g_homeCount; k++)
		if (!g_homeValid[k]) { h = k; break; }
	if (h == -1)
	{
		if (g_homeCount >= MAX_HOMES)
		{
			// Out of slots: join the nearest home.
			float bd = 999999.0;
			for (int k = 0; k < g_homeCount; k++)
				if (g_homeValid[k] && GetVectorDistance(from, g_homePos[k]) < bd) { bd = GetVectorDistance(from, g_homePos[k]); h = k; }
			return h;
		}
		h = g_homeCount++;
	}

	// Its doors and windows; the home's center is their average, snapped to the nav mesh.
	float sum[3];
	int members = 0;
	for (int j = 0; j < count; j++)
	{
		if (GetVectorDistance(all[seed], all[j]) > r)
			continue;
		AddVectors(sum, all[j], sum);
		members++;
		bool known = false;
		for (int o = 0; o < g_openingCount; o++)
			if (GetVectorDistance(g_openingPos[o], all[j]) < 1.0)
			{
				known = true;
				if (g_openingHome[o] == -1) g_openingHome[o] = h;
				break;
			}
		if (known || g_openingCount >= MAX_OPENINGS)
			continue;
		int o = g_openingCount++;
		g_openingPos[o] = all[j];
		g_openingInside[o] = allInside[j];
		g_openingWindow[o] = allWindow[j];
		g_openingEnt[o] = allEnt[j];
		g_openingHome[o] = h;
		g_openingBoards[o] = 0;
		g_openingClaim[o] = 0;
		g_openingDone[o] = false;
	}
	ScaleVector(sum, 1.0 / float(members));

	// Center on the spawn when the bot spawned indoors there, else on the openings.
	// (If the spawn's bit of nav mesh is a small island, e.g. a closet, use the openings instead.)
	bool indoors = SpaceAbove(from) < 400.0 && seedDist < r;
	for (int attempt = indoors ? 0 : 1; attempt < 2; attempt++)
	{
		Address area = NavBotNavMesh.GetNearestNavArea(attempt == 0 ? from : sum, 600.0, false, true);
		if (area == Address_Null)
			continue;
		NavBotNavArea.GetCenter(area, g_homePos[h]);
		if (BuildDefendSpots(h, area) >= 12 || attempt == 1)
			break;
	}
	if (g_defendCount[h] == 0)
	{
		for (int o = 0; o < g_openingCount; o++)
			if (g_openingHome[o] == h) g_openingHome[o] = -1;
		return -1;
	}
	g_homeValid[h] = true;
	for (int k = 0; k < g_ln_placeCount; k++)
		if (g_placeHome[k] == -1 && GetVectorDistance(g_ln_placeTo[k], g_homePos[h]) < g_radius.FloatValue * 1.3)
			g_placeHome[k] = h;
	g_homeChosenAt[h] = GetGameTime();
	g_homeDeaths[h] = 0;
	Debug("Home %d at %.0f %.0f %.0f with %d doors/windows (%d on the map)", h, g_homePos[h][0], g_homePos[h][1], g_homePos[h][2], members, count);
	return h;
}

// Is there a window of home h within dist (same floor)?
bool NearWindow(int h, const float pos[3], float dist)
{
	for (int o = 0; o < g_openingCount; o++)
	{
		if (!g_openingWindow[o] || (h != -1 && g_openingHome[o] != h))
			continue;
		if (FloatAbs(pos[2] - g_openingPos[o][2]) > 90.0)
			continue;
		float dx = pos[0] - g_openingPos[o][0], dy = pos[1] - g_openingPos[o][1];
		if (dx * dx + dy * dy < dist * dist)
			return true;
	}
	return false;
}

// Rank the home's walkable areas: highest first (upper floors, roofs, balconies), then
// "corners" (areas with few neighbours). Areas next to windows are left out: bots hold back and
// shoot whatever climbs in. Each defending bot gets its own spot.
int BuildDefendSpots(int h, Address start)
{
	// Walkable areas around the home. Bots defend from inside buildings, so if the search finds
	// few roofed areas (a home picked from a street spawn, like zps_cinema's), widen it until it
	// reaches the building.
	static float scores[512], centers[512][3];
	static bool roofed[512];
	NavBotNavAreaVector v = null;
	int n = 0, indoor = 0;
	float limit = (g_mapHome && g_mapRadius > 0.0 ? g_mapRadius : g_radius.FloatValue) * 1.6;
	for (int pass = 0; pass < 3; pass++)
	{
		if (v != null) delete v;
		NavBotNavAreaCollector c = new NavBotNavAreaCollector();
		c.SetSearchStartArea(start);
		c.TravelLimit = limit;
		c.SearchLadder = true;
		c.Execute();
		v = c.GetCollectedAreas();
		delete c;
		n = v.Size > 512 ? 512 : v.Size;
		indoor = 0;
		for (int i = 0; i < n; i++)
		{
			NavBotNavArea.GetCenter(v.At(i), centers[i]);
			roofed[i] = SpaceAbove(centers[i]) < 400.0;
			if (roofed[i]) indoor++;
		}
		if (indoor >= 16)
			break;
		limit *= 1.8;
	}

	// Heights are measured from the home's own ground level: upper floors, roofs and balconies
	// above it, and basements below it, are both good places to fight from.
	float floorZ = g_mapHome && GetVectorDistance(g_homePos[h], g_mapHomePos) < 600.0 ? g_mapGround : g_homePos[h][2];
	for (int i = 0; i < n; i++)
	{
		Address a = v.At(i);
		float dz = centers[i][2] - floorZ;
		float height = g_mapPreferUp ? dz : FloatAbs(dz);   // "up": basements don't count
		int neighbours = 0;
		for (int d = 0; d < 4; d++)
			neighbours += NavBotNavArea.GetAdjacentAreaCount(a, view_as<NavBotNavDirType>(d));
		// Off the ground floor (up or down) dominates; few neighbours (a corner) breaks ties; stay
		// fairly close; never next to a window; indoors only, unless there's hardly any indoors.
		scores[i] = (g_mapSpread ? GetRandomFloat(0.0, 300.0)   // spread: every floor counts the same
				: (height >= g_upperHeight.FloatValue ? 1000.0 + (height > 400.0 ? 400.0 : height) : 0.0))
			+ (neighbours <= 2 ? 200.0 : 0.0)
			- GetVectorDistance(centers[i], g_homePos[h]) * 0.1
			- (NearWindow(h, centers[i], 150.0) ? 5000.0 : 0.0)
			- (AtEdge(centers[i]) ? 5000.0 : 0.0)      // a roof edge with no railing: they fall off
			- (roofed[i] ? 0.0 : (indoor >= 6 ? 5000.0 : 600.0));
	}
	delete v;

	// The main player's hold spots in this house come first (most-held first); they count with
	// the upstairs spots as the preferred ones.
	g_defendCount[h] = 0;
	g_upperCount[h] = 0;
	g_floorZ[h] = floorZ;
	bool taken[LEARN_MAX_SPOTS];
	for (;;)
	{
		int pick = -1;
		for (int i = 0; i < g_ln_spotCount; i++)
		{
			if (taken[i] || GetVectorDistance(g_ln_spots[i], g_homePos[h]) > g_radius.FloatValue * 1.3)
				continue;
			if (pick == -1 || g_ln_spotSecs[i] > g_ln_spotSecs[pick])
				pick = i;
		}
		if (pick == -1 || g_defendCount[h] >= MAX_DEFEND / 2)
			break;
		taken[pick] = true;
		bool tooClose = false;
		for (int k = 0; k < g_defendCount[h]; k++)
			if (GetVectorDistance(g_ln_spots[pick], g_defendPos[h][k]) < 64.0) { tooClose = true; break; }
		if (tooClose)
			continue;
		g_defendPos[h][g_defendCount[h]++] = g_ln_spots[pick];
		g_upperCount[h]++;
	}
	int learned = g_defendCount[h];

	// Then the best of the rest, at least 96 units apart so bots don't stack (spread: 220, so
	// the spots cover the whole building).
	float apart = g_mapSpread ? 220.0 : 96.0;
	bool used[512];
	while (g_defendCount[h] < MAX_DEFEND)
	{
		int best = -1;
		for (int i = 0; i < n; i++)
		{
			if (used[i] || scores[i] < -2000.0 || (best != -1 && scores[i] <= scores[best]))
				continue;
			bool tooClose = false;
			for (int k = 0; k < g_defendCount[h]; k++)
				if (GetVectorDistance(centers[i], g_defendPos[h][k]) < apart) { tooClose = true; break; }
			if (!tooClose)
				best = i;
		}
		if (best == -1)
			break;
		used[best] = true;
		g_defendPos[h][g_defendCount[h]] = centers[best];
		g_defendCount[h]++;
		if ((g_mapPreferUp ? centers[best][2] - floorZ : FloatAbs(centers[best][2] - floorZ)) >= g_upperHeight.FloatValue)
			g_upperCount[h]++;          // spots are picked best-first, so upstairs/basement ones come first
	}
	Debug("Home %d: %d defend spots (%d learned from the main player) from %d areas (best %.0f units above the ground floor)", h, g_defendCount[h], learned, n, g_defendCount[h] ? g_defendPos[h][0][2] - floorZ : 0.0);
	return n;
}

// ---------------------------------------------------------------------------------------------
// Helpers

bool IsGun(int weapon)
{
	if (weapon <= 0 || !IsValidEntity(weapon))
		return false;
	char cls[64];
	GetEntityClassname(weapon, cls, sizeof(cls));
	for (int i = 0; i < sizeof(g_guns); i++)
		if (StrEqual(cls, g_guns[i]))
			return true;
	return false;
}

int FindOwnedWeapon(int client, const char[] classname)
{
	char cls[64];
	int size = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
	for (int i = 0; i < size; i++)
	{
		int w = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
		if (w > 0 && IsValidEntity(w))
		{
			GetEntityClassname(w, cls, sizeof(cls));
			if (StrEqual(cls, classname))
				return w;
		}
	}
	return -1;
}

bool HasGunAmmo(int client)
{
	char cls[64];
	int size = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
	bool hasGun = false;
	for (int i = 0; i < size; i++)
	{
		int w = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
		if (!IsGun(w))
			continue;
		hasGun = true;
		GetEntityClassname(w, cls, sizeof(cls));
		int type = GetEntProp(w, Prop_Send, "m_iPrimaryAmmoType");
		if (GetEntProp(w, Prop_Send, "m_iClip1") > 0 || (type > 0 && GetEntProp(client, Prop_Send, "m_iAmmo", _, type) > 0))
			return true;
	}
	return !hasGun;   // melee-only bots aren't "out of ammo"
}

int NearestZombie(int client, float maxDist, float &dist)
{
	float me[3], them[3];
	GetClientAbsOrigin(client, me);
	int best = 0;
	dist = maxDist;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == client || !IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) != TEAM_ZOMBIES)
			continue;
		GetClientAbsOrigin(i, them);
		float d = GetVectorDistance(me, them);
		if (d < dist) { dist = d; best = i; }
	}
	return best;
}

int NearestFreeBarricade(int client, float &dist)
{
	float me[3], pos[3];
	GetClientAbsOrigin(client, me);
	int best = -1;
	dist = 3000.0;
	int ent = -1;
	while ((ent = FindEntityByClassname(ent, "weapon_barricade")) != -1)
	{
		if (GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity") != -1)
			continue;
		GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", pos);
		float d = GetVectorDistance(me, pos);
		if (d < dist) { dist = d; best = ent; }
	}
	return best;
}

bool TraceIgnoreSelf(int entity, int mask, int self)
{
	return entity != self;
}

// Press E on a closed door right in front of the bot.
void OpenDoorAhead(int client, NavBot bot)
{
	if (GetGameTime() < g_nextUse[client])
		return;
	float eye[3], ang[3], fwd[3], end[3];
	GetClientEyePosition(client, eye);
	GetClientEyeAngles(client, ang);
	ang[0] = 0.0;
	GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
	ScaleVector(fwd, 72.0);
	AddVectors(eye, fwd, end);
	TR_TraceRayFilter(eye, end, MASK_SOLID, RayType_EndPoint, TraceIgnoreSelf, client);
	int hit = TR_GetEntityIndex();
	if (hit <= MaxClients || !IsValidEntity(hit))
		return;
	char cls[64];
	GetEntityClassname(hit, cls, sizeof(cls));
	if (StrContains(cls, "door") == -1)
		return;
	Address ctrl = bot.GetPlayerControllerInterface();
	float center[3];
	EntityCenter(hit, center);
	NavBotPlayerControllerInterface.AimAtPos(ctrl, center, LOOK_USE, 0.5, "Opening door");
	NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_USE, 0.2);
	g_nextUse[client] = GetGameTime() + 1.5;
	Debug("%N opens %s", client, cls);
}

// NavBot breaks breakable obstacles before it considers pressing E on them. In ZPS doors and
// barricades are breakable, so survivors smashed doors and their own barricades. For survivors:
// open doors with E, never break boards, windows, props or barricades. Zombies keep the default.
public Action OnNavBotObstacleOnPath(NavBot bot, int entity, bool hitWorld, const float goal[3])
{
	int client = bot.Index;
	if (hitWorld || entity <= MaxClients || !IsValidEntity(entity) || !IsClientInGame(client) || GetClientTeam(client) != TEAM_SURVIVORS)
		return Plugin_Continue;

	char cls[64];
	GetEntityClassname(entity, cls, sizeof(cls));

	if (Doors_IsHinged(entity) && Doors_IsClosed(entity) && !Doors_IsLocked(entity))
	{
		Doors_Use(client, bot, entity);   // not physics: E, never bump or break it
		return Plugin_Handled;
	}

	if (StrContains(cls, "door") != -1)
	{
		if (GetGameTime() >= g_nextUse[client])
		{
			Address ctrl = bot.GetPlayerControllerInterface();
			float center[3];
			EntityCenter(entity, center);
			NavBotPlayerControllerInterface.AimAtPos(ctrl, center, LOOK_USE, 0.6, "Opening door");
			NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_USE, 0.2);
			g_nextUse[client] = GetGameTime() + 1.2;
			Debug("%N opens %s (on path)", client, cls);
		}
		return Plugin_Handled;
	}

	// Loose furniture in the way: shove it aside with bare hands (right click), like a player
	// would, instead of bumping into it. Never barricades or furniture blocking a door.
	if (StrContains(cls, "prop_physics") != -1 && !IsBarricadeProp(entity) && !IsBadProp(entity)
		&& EntIndexToEntRef(entity) != g_carryProp[client] && GetGameTime() > g_shoveUntil[client] + 2.0)
	{
		float zd, pos[3];
		GetEntPropVector(entity, Prop_Data, "m_vecAbsOrigin", pos);
		if (EntIndexToEntRef(entity) == g_shoveProp[client] && GetVectorDistance(pos, g_shoveFrom[client]) < 10.0)
		{
			// Shoved it last time and it didn't budge: too heavy or wedged. Walk around it.
			if (g_badPropCount < sizeof(g_badProp))
				g_badProp[g_badPropCount++] = g_shoveProp[client];
			Debug("%N: furniture %d won't move, walking around it", client, entity);
		}
		else if (NearestZombie(client, 400.0, zd) == 0 && FindOwnedWeapon(client, "weapon_emptyhand") != -1)
		{
			g_shoveProp[client] = EntIndexToEntRef(entity);
			g_shoveFrom[client] = pos;
			g_shoveUntil[client] = GetGameTime() + 3.0;
			Debug("%N shoves furniture %d out of the way", client, entity);
		}
	}

	// Basement doors: the one kind of door survivors break, with a melee weapon. A door-shaped
	// func_breakable below the ground floor of the bot's home (church: its basement doors).
	if (StrEqual(cls, "func_breakable") && GetGameTime() > g_breakUntil[client] + 2.0 && IsBasementDoor(client, entity))
	{
		g_breakDoor[client] = EntIndexToEntRef(entity);
		g_breakUntil[client] = GetGameTime() + 20.0;
		Debug("%N breaks the basement door %d", client, entity);
		return Plugin_Handled;
	}

	if (StrContains(cls, "breakable") != -1 || StrContains(cls, "prop_physics") != -1 || StrContains(cls, "physbox") != -1
		|| StrContains(cls, "barricade") != -1)
		return Plugin_Handled;   // walk around (or shove) it instead of smashing it

	return Plugin_Continue;
}

// ---------------------------------------------------------------------------------------------
// Barricading

// A door of the bot's home to block with furniture. Windows are left alone: bots keep away from
// them and shoot what comes through.
int ClaimOpening(int client)
{
	int h = g_home[client];
	if (h < 0)
		return -1;
	float me[3];
	GetClientAbsOrigin(client, me);
	int best = -1;
	float bestDist = 999999.0;
	for (int i = 0; i < g_openingCount; i++)
	{
		if (g_openingHome[i] != h || g_openingWindow[i] || g_openingDone[i] || (g_openingClaim[i] != 0 && g_openingClaim[i] != client))
			continue;
		if (g_defendCount[h] > 0 && g_openingPos[i][2] - g_floorZ[h] >= g_upperHeight.FloatValue)
			continue;               // barricade the ground floor; upstairs is where we fight from
		float d = GetVectorDistance(me, g_openingPos[i]);
		if (d < bestDist) { bestDist = d; best = i; }
	}
	if (best != -1)
		g_openingClaim[best] = client;
	return best;
}

// A furniture placement the main player made in the bot's home, not done yet.
int ClaimPlacement(int client)
{
	int h = g_home[client];
	if (h < 0)
		return -1;
	float me[3];
	GetClientAbsOrigin(client, me);
	int best = -1;
	float bestDist = 999999.0;
	for (int k = 0; k < g_ln_placeCount; k++)
	{
		if (g_ln_placeTeam[k] != TEAM_SURVIVORS || g_placeHome[k] != h || g_placeDone[k] || (g_placeClaim[k] != 0 && g_placeClaim[k] != client))
			continue;
		float d = GetVectorDistance(me, g_ln_placeTo[k]);
		if (d < bestDist) { bestDist = d; best = k; }
	}
	if (best != -1)
		g_placeClaim[best] = client;
	return best;
}

int CountBarricaders(int h)
{
	int n = 0;
	for (int i = 1; i <= MaxClients; i++)
		if (g_job[i] != JOB_NONE && g_job[i] != JOB_BUILD && g_home[i] == h && IsClientInGame(i) && IsPlayerAlive(i))
			n++;
	return n;
}

void ReleaseJob(int client, bool done)
{
	int o = g_jobOpening[client];
	int k = g_jobPlace[client];
	if (g_job[client] == JOB_PLACE && k >= 0 && k < LEARN_MAX_PLACES)
	{
		g_placeClaim[k] = 0;
		if (done)
			g_placeDone[k] = true;
	}
	int bl = g_buildLesson[client];
	if (g_job[client] == JOB_BUILD && bl >= 0 && bl < LEARN_MAX_BOARDS)
	{
		g_boardClaim[bl] = 0;
		g_buildLesson[client] = -1;
	}
	if (g_job[client] == JOB_BARRICADE && o >= 0 && o < g_openingCount)
	{
		g_openingClaim[o] = 0;
		if (done)
			g_openingDone[o] = true;
	}
	g_job[client] = JOB_NONE;
	g_carryProp[client] = INVALID_ENT_REFERENCE;
	g_hammerUntil[client] = 0.0;
}

// Move goals must be on the nav mesh or NavBot can't path to them (door/window centers sit
// mid-wall). Snap a point to the closest walkable spot.
void SnapToNav(const float pos[3], float out[3])
{
	Address area = NavBotNavMesh.GetNearestNavArea(pos, 400.0, false, true);
	if (area == Address_Null)
	{
		out = pos;
		return;
	}
	NavBotNavArea.GetClosestPointOnArea(area, pos, out);
}

// Where to stand to board an opening: just inside, on the hold-out side.
void StandPoint(int o, float out[3])
{
	float dir[3];
	dir = g_openingInside[o];               // stand indoors, facing out through the opening
	ScaleVector(dir, 56.0);
	float raw[3];
	AddVectors(g_openingPos[o], dir, raw);
	SnapToNav(raw, out);
}

// Barricade boards, and furniture already blocking a door or where the main player puts it:
// leave those alone.
bool IsBarricadeProp(int ent)
{
	char model[128];
	if (HasEntProp(ent, Prop_Data, "m_ModelName"))
	{
		GetEntPropString(ent, Prop_Data, "m_ModelName", model, sizeof(model));
		if (StrContains(model, "barricade", false) != -1)
			return true;
	}
	float pos[3];
	GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", pos);
	for (int o = 0; o < g_openingCount; o++)
		if (!g_openingWindow[o] && g_openingHome[o] != -1 && GetVectorDistance(pos, g_openingPos[o]) < 90.0)
			return true;
	for (int k = 0; k < g_ln_placeCount; k++)          // where the main player puts furniture
		if (g_ln_placeTeam[k] == TEAM_SURVIVORS && GetVectorDistance(pos, g_ln_placeTo[k]) < 40.0)
			return true;
	return false;
}

bool IsBadProp(int ent)
{
	int ref = EntIndexToEntRef(ent);
	for (int i = 0; i < g_badPropCount; i++)
		if (g_badProp[i] == ref)
			return true;
	return false;
}

// Physics props near a door that a survivor can shove: roughly chair to cabinet sized, on the
// same floor, not a barricade, not already found to be too heavy.
int FindFurniture(int o, float maxDist)
{
	static const char classes[][] = { "prop_physics_multiplayer", "prop_physics", "prop_physics_override", "prop_physics_respawnable" };
	int best = -1;
	float bestDist = maxDist;
	for (int c = 0; c < sizeof(classes); c++)
	{
		int ent = -1;
		while ((ent = FindEntityByClassname(ent, classes[c])) != -1)
		{
			if (GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity") != -1 || IsBadProp(ent) || IsBarricadeProp(ent))
				continue;
			float mins[3], maxs[3], pos[3];
			GetEntPropVector(ent, Prop_Send, "m_vecMins", mins);
			GetEntPropVector(ent, Prop_Send, "m_vecMaxs", maxs);
			float size = (maxs[0] - mins[0]) + (maxs[1] - mins[1]) + (maxs[2] - mins[2]);
			if (size < 50.0 || size > 260.0)
				continue;
			GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", pos);
			if (FloatAbs(pos[2] - g_openingPos[o][2]) > 90.0)     // same floor
				continue;
			bool reserved = false;                              // the main player uses it elsewhere
			for (int k = 0; k < g_ln_placeCount && !reserved; k++)
				reserved = g_ln_placeTeam[k] == TEAM_SURVIVORS && GetVectorDistance(pos, g_ln_placeFrom[k]) < 32.0;
			if (reserved)
				continue;
			// Must be indoors, on the home side of the door.
			float rel[3];
			SubtractVectors(pos, g_openingPos[o], rel);
			if (GetVectorDotProduct(rel, g_openingInside[o]) < 0.0)
				continue;
			float d = GetVectorDistance(pos, g_openingPos[o]);
			if (d < bestDist) { bestDist = d; best = ent; }
		}
	}
	return best;
}

// Hold bare hands (ZPS's H key). Returns true once they're out.
bool HoldHands(int client, NavBot bot)
{
	int hands = FindOwnedWeapon(client, "weapon_emptyhand");
	if (hands == -1)
		return false;
	g_handsUntil[client] = GetGameTime() + 2.0;
	if (GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon") == hands)
		return true;
	if (GetGameTime() >= g_nextUse[client])
	{
		bot.DelayedFakeClientCommand("use weapon_emptyhand");
		g_nextUse[client] = GetGameTime() + 0.5;
	}
	return false;
}

// One right-click shove at a point (bare hands punt physics objects along the aim). The hands'
// punt barely moves heavier furniture, so the shove also gives the prop a push of its own, in
// `dir` (flat), as long as it's really within arm's reach.
void Shove(int client, NavBot bot, const float at[3], int prop, const float dir[3])
{
	Address ctrl = bot.GetPlayerControllerInterface();
	NavBotPlayerControllerInterface.AimAtPos(ctrl, at, LOOK_PRIORITY, 0.5, "Shoving furniture");
	if (!HoldHands(client, bot) || !NavBotPlayerControllerInterface.IsAimOnTarget(ctrl) || GetGameTime() < g_nextUse[client])
		return;
	NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_ATTACKSEC, 0.15);
	g_nextUse[client] = GetGameTime() + 0.9;
	g_pushes[client]++;

	float eye[3], c[3];
	GetClientEyePosition(client, eye);
	EntityCenter(prop, c);
	if (GetVectorDistance(eye, c) > 85.0)
		return;
	DataPack pack;
	CreateDataTimer(0.25, Timer_ShoveImpulse, pack, TIMER_FLAG_NO_MAPCHANGE);   // as the hands connect
	pack.WriteCell(EntIndexToEntRef(prop));
	pack.WriteFloat(dir[0]);
	pack.WriteFloat(dir[1]);
}

Action Timer_ShoveImpulse(Handle timer, DataPack pack)
{
	pack.Reset();
	int prop = EntRefToEntIndex(pack.ReadCell());
	if (prop == INVALID_ENT_REFERENCE)
		return Plugin_Stop;
	float vel[3];
	vel[0] = pack.ReadFloat() * 220.0;
	vel[1] = pack.ReadFloat() * 220.0;
	vel[2] = 40.0;                          // a little lift so it slides instead of digging in
	TeleportEntity(prop, NULL_VECTOR, NULL_VECTOR, vel);
	return Plugin_Stop;
}

#define PUSH_WORKING 0      // standing at it, shoving (hold still)
#define PUSH_MOVING  1      // walking to the spot behind it (path to moveGoal)
#define PUSH_DONE    2      // it's there
#define PUSH_GIVEUP  3      // too heavy, wedged or out of reach

// Shove a piece of furniture to `dest`: stand behind it (the side away from dest), bare hands
// out, right click, repeat. Furniture that doesn't get closer after several shoves is too heavy.
int PushProp(int client, NavBot bot, int prop, const float target[3], float moveGoal[3], float doneDist)
{
	float me[3], dest[3], propPos[3], center[3];
	GetClientAbsOrigin(client, me);
	GetEntPropVector(prop, Prop_Data, "m_vecAbsOrigin", propPos);
	EntityCenter(prop, center);
	dest = target;
	dest[2] = propPos[2];
	float d = GetVectorDistance(propPos, dest);
	if (d < doneDist)
		return PUSH_DONE;
	if (d < g_pushBest[client] - 8.0)
	{
		g_pushBest[client] = d;
		g_pushStuck[client] = 0;
	}

	// Stand behind it, on the line from the destination through the furniture.
	float back[3], push[3];
	SubtractVectors(propPos, dest, back);
	back[2] = 0.0;
	NormalizeVector(back, back);
	ScaleVector(back, 50.0);
	AddVectors(center, back, push);
	push[2] = me[2];
	if (GetVectorDistance(me, push) > 36.0)
	{
		SnapToNav(push, moveGoal);
		if (GetVectorDistance(me, moveGoal) > 36.0)
			return PUSH_MOVING;
		// The push spot is off the mesh (furniture against a wall): shove from as close as we can.
	}
	// Bare hands only reach about 70 units: step in until the furniture is within reach.
	float eye[3];
	GetClientEyePosition(client, eye);
	if (GetVectorDistance(eye, center) > 70.0)
	{
		float step[3];
		SubtractVectors(center, me, step);
		step[2] = 0.0;
		NormalizeVector(step, step);
		ScaleVector(step, 30.0);
		AddVectors(me, step, step);
		if (++g_pushStuck[client] > 40)
		{
			Debug("%N: can't get within reach of furniture %d", client, prop);
			return PUSH_GIVEUP;
		}
		NavBotMovementInterface.MoveTowards(bot.GetMovementInterface(), step, 100);
		return PUSH_WORKING;
	}

	int before = g_pushes[client];
	center[2] -= 4.0;
	float toward[3];
	SubtractVectors(dest, propPos, toward);
	toward[2] = 0.0;
	NormalizeVector(toward, toward);
	Shove(client, bot, center, prop, toward);
	if (g_pushes[client] > before)
		Debug("%N shove #%d: furniture %d is %.0f from where it should go", client, g_pushes[client], prop, d);
	if (g_pushes[client] > before && (g_pushStuck[client] += 6) > 36)
	{
		Debug("%N: furniture %d won't move", client, prop);
		return PUSH_GIVEUP;
	}
	return PUSH_WORKING;
}

void StartPush(int client, int prop)
{
	g_carryProp[client] = EntIndexToEntRef(prop);
	g_pushes[client] = 0;
	g_pushStuck[client] = 0;
	g_pushBest[client] = 999999.0;
}

// Barricade a door of the home: shove the nearest suitable furniture against it, just inside.
// Returns true while the bot should walk to moveGoal.
bool DoFurniture(int client, NavBot bot, float moveGoal[3])
{
	int o = g_jobOpening[client];
	int prop = EntRefToEntIndex(g_carryProp[client]);
	if (prop == INVALID_ENT_REFERENCE)
	{
		prop = FindFurniture(o, 650.0);
		if (prop == -1)
		{
			ReleaseJob(client, true);   // nothing to use here
			return false;
		}
		StartPush(client, prop);
	}
	float dest[3];
	for (int i = 0; i < 3; i++)
		dest[i] = g_openingPos[o][i] + g_openingInside[o][i] * 20.0;
	switch (PushProp(client, bot, prop, dest, moveGoal, 45.0))
	{
		case PUSH_MOVING: return true;
		case PUSH_DONE:
		{
			g_openingBoards[o]++;
			Debug("%N shoved furniture into door %d (%d/%d)", client, o, g_openingBoards[o], g_boardsPerOpening.IntValue);
			g_carryProp[client] = INVALID_ENT_REFERENCE;
			if (g_openingBoards[o] >= g_boardsPerOpening.IntValue)
				ReleaseJob(client, true);
		}
		case PUSH_GIVEUP:
		{
			if (g_badPropCount < sizeof(g_badProp))
				g_badProp[g_badPropCount++] = g_carryProp[client];
			g_carryProp[client] = INVALID_ENT_REFERENCE;   // try another piece
		}
	}
	return false;
}

// Put a piece of furniture where the main player put it (learned placement).
bool DoPlace(int client, NavBot bot, float moveGoal[3])
{
	int k = g_jobPlace[client];
	if (GetGameTime() - g_jobStarted[client] > 60.0)
	{
		ReleaseJob(client, true);
		return false;
	}
	int prop = EntRefToEntIndex(g_carryProp[client]);
	if (prop == INVALID_ENT_REFERENCE)
	{
		prop = Learned_FindPlaceProp(k);
		if (prop == -1)
		{
			ReleaseJob(client, true);   // broken or gone this round
			return false;
		}
		StartPush(client, prop);
	}
	switch (PushProp(client, bot, prop, g_ln_placeTo[k], moveGoal, 32.0))
	{
		case PUSH_MOVING: return true;
		case PUSH_DONE:
		{
			Debug("%N put furniture where the main player puts it (placement %d)", client, k);
			ReleaseJob(client, true);
		}
		case PUSH_GIVEUP: ReleaseJob(client, true);
	}
	return false;
}

// Doors worked by buttons (cabin's garage): when one is open, the nearest free survivor bot goes
// to its Close button and presses E, unless zombies are right there. Once a second.
void AssignDoorClosers()
{
	if (!NavBotNavMesh.IsLoaded())
		return;
	int b = -1;
	while ((b = FindEntityByClassname(b, "func_button")) != -1)
	{
		if (Doors_ButtonAction(b) >= 0)
			continue;                     // not a Close button
		int door = Doors_ButtonDoor(b);
		if (door == -1 || !HasEntProp(door, Prop_Data, "m_toggle_state"))
			continue;
		int st = GetEntProp(door, Prop_Data, "m_toggle_state");
		if (st != 0 && st != 2)
			continue;                     // closed or closing
		int ref = EntIndexToEntRef(b);
		bool taken = false;
		for (int i = 1; i <= MaxClients && !taken; i++)
			taken = g_closeBtn[i] == ref && GetGameTime() < g_closeUntil[i];
		if (taken)
			continue;
		float c[3], zd;
		EntityCenter(b, c);
		int best = 0;
		float bestDist = 900.0;
		for (int i = 1; i <= MaxClients; i++)
		{
			if (!IsClientInGame(i) || !IsFakeClient(i) || !IsPlayerAlive(i) || GetClientTeam(i) != TEAM_SURVIVORS || !NavBotManager.IsNavBot(i))
				continue;
			if (g_job[i] != JOB_NONE || g_builder[i] || GetGameTime() < g_closeUntil[i])
				continue;
			float me[3];
			GetClientAbsOrigin(i, me);
			float d = GetVectorDistance(me, c);
			if (d < bestDist && FloatAbs(me[2] - c[2]) < 150.0) { bestDist = d; best = i; }
		}
		if (best == 0 || NearestZombieTo(c, 300.0, zd) != 0)
			continue;
		g_closeBtn[best] = ref;
		g_closeUntil[best] = GetGameTime() + 15.0;
		Debug("%N goes to close door %d (button %d)", best, door, b);
	}
}

int NearestZombieTo(const float pos[3], float radius, float &dist)
{
	int best = 0;
	dist = radius;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) != TEAM_ZOMBIES)
			continue;
		float p[3];
		GetClientAbsOrigin(i, p);
		float d = GetVectorDistance(p, pos);
		if (d < dist) { dist = d; best = i; }
	}
	return best;
}

bool CloseDoorButton(int client, NavBot bot, float moveGoal[3])
{
	int b = EntRefToEntIndex(g_closeBtn[client]);
	if (b == INVALID_ENT_REFERENCE || GetGameTime() > g_closeUntil[client])
	{
		g_closeBtn[client] = INVALID_ENT_REFERENCE;
		return false;
	}
	int door = Doors_ButtonDoor(b);
	int st = door != -1 ? GetEntProp(door, Prop_Data, "m_toggle_state") : 1;
	float c[3], eye[3], zd;
	EntityCenter(b, c);
	if ((st != 0 && st != 2) || NearestZombieTo(c, 250.0, zd) != 0)
	{
		if (st == 3 || st == 1) Debug("%N closed the door", client);
		g_closeBtn[client] = INVALID_ENT_REFERENCE;
		g_closeUntil[client] = GetGameTime() + 5.0;   // (not straight back to it)
		return false;                    // closing / closed, or zombies there: fight instead
	}
	GetClientEyePosition(client, eye);
	if (GetVectorDistance(eye, c) > 64.0)
	{
		Address a = NavBotNavMesh.GetNearestNavArea(c, 200.0, false, true);
		if (a != Address_Null)
			NavBotNavArea.GetClosestPointOnArea(a, c, moveGoal);
		else
			moveGoal = c;
		float me[3];
		GetClientAbsOrigin(client, me);
		if (GetVectorDistance(me, moveGoal) > 24.0)
		{
			g_closeWalking[client] = true;
			return true;
		}
	}
	g_closeWalking[client] = false;
	Address ctrl = bot.GetPlayerControllerInterface();
	NavBotPlayerControllerInterface.AimAtPos(ctrl, c, LOOK_PRIORITY, 0.4, "Closing the door");
	NavBotMovementInterface.MoveTowards(bot.GetMovementInterface(), c, 100);
	if (NavBotPlayerControllerInterface.IsAimOnTarget(ctrl))
		NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_USE, 0.1);
	return true;
}

// A door-shaped func_breakable (thin, at least door height) whose middle is well below the
// ground floor of the bot's home: a basement door.
bool IsBasementDoor(int client, int ent)
{
	if (!HasEntProp(ent, Prop_Send, "m_vecMins") || GetEntProp(ent, Prop_Data, "m_iHealth") <= 0)
		return false;
	float mins[3], maxs[3], c[3];
	GetEntPropVector(ent, Prop_Send, "m_vecMins", mins);
	GetEntPropVector(ent, Prop_Send, "m_vecMaxs", maxs);
	EntityCenter(ent, c);
	float sx = maxs[0] - mins[0], sy = maxs[1] - mins[1], sz = maxs[2] - mins[2];
	if ((sx < sy ? sx : sy) > 16.0 || sz < 70.0)
		return false;
	int h = g_home[client];
	float ground = h >= 0 ? (g_mapHome && GetVectorDistance(g_homePos[h], g_mapHomePos) < 600.0 ? g_mapGround : g_homePos[h][2]) : 0.0;
	float me[3];
	GetClientAbsOrigin(client, me);
	if (h < 0) ground = me[2];
	return c[2] < ground - 60.0;
}

// Smash the basement door in the way with a melee weapon (bare hands if none), until it breaks.
// Returns true while busy.
bool BreakBasementDoor(int client, NavBot bot)
{
	int door = EntRefToEntIndex(g_breakDoor[client]);
	if (door == INVALID_ENT_REFERENCE || GetGameTime() > g_breakUntil[client] || GetEntProp(door, Prop_Data, "m_iHealth") <= 0)
	{
		g_breakDoor[client] = INVALID_ENT_REFERENCE;
		return false;
	}
	float c[3], eye[3];
	EntityCenter(door, c);
	GetClientEyePosition(client, eye);
	Address ctrl = bot.GetPlayerControllerInterface();
	NavBotPlayerControllerInterface.AimAtPos(ctrl, c, LOOK_PRIORITY, 0.4, "Breaking the basement door");
	// Shoot it up (the main player: "that's easier"); melee only without a gun.
	if (IsGun(GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon")))
	{
		if (GetVectorDistance(eye, c) > 400.0)
			NavBotMovementInterface.MoveTowards(bot.GetMovementInterface(), c, 100);
		else if (NavBotPlayerControllerInterface.IsAimOnTarget(ctrl))
			NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_ATTACKPRIM, 0.1);
		return true;
	}
	int melee = MeleeWeapon(client);
	int weapon = melee != -1 ? melee : FindOwnedWeapon(client, "weapon_emptyhand");
	if (weapon != -1 && GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon") != weapon && GetGameTime() >= g_nextUse[client])
	{
		char cls[64], cmd[80];
		GetEntityClassname(weapon, cls, sizeof(cls));
		Format(cmd, sizeof(cmd), "use %s", cls);
		bot.DelayedFakeClientCommand(cmd);
		g_nextUse[client] = GetGameTime() + 0.5;
	}
	g_handsUntil[client] = GetGameTime() + 2.0;   // HoldBestGun: not now
	if (GetVectorDistance(eye, c) > 70.0)
		NavBotMovementInterface.MoveTowards(bot.GetMovementInterface(), c, 100);
	else if (NavBotPlayerControllerInterface.IsAimOnTarget(ctrl))
		NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_ATTACKPRIM, 0.2);
	return true;
}

// ---------------------------------------------------------------------------------------------
// Builders: nail boards where the main player nailed them

// The main player's boards in this home that aren't up right now (never built, or broken by
// zombies) and that nobody is working on.
int NextBoardLesson(int client)
{
	int h = g_home[client];
	if (h < 0)
		return -1;
	float me[3];
	GetClientAbsOrigin(client, me);
	float r = (g_mapHome && g_mapRadius > 0.0 ? g_mapRadius : g_radius.FloatValue) * 1.3;
	int best = -1;
	float bestDist = 999999.0;
	for (int b = 0; b < g_ln_boardCount; b++)
	{
		if (g_boardGiveUp[b] || (g_boardClaim[b] != 0 && g_boardClaim[b] != client))
			continue;
		if (GetVectorDistance(g_ln_boardPos[b], g_homePos[h]) > r)
			continue;
		if (CountBoardsNear(g_ln_boardPos[b], 90.0) > 0)   // already barricaded: ignore it, do another
			continue;                        // it's up
		float d = GetVectorDistance(me, g_ln_boardStand[b]);
		if (d < bestDist) { bestDist = d; best = b; }
	}
	return best;
}

// The builder's melee weapon (keyboard, frying pan, ...): anything that isn't a gun, the hands,
// the phone or the hammer.
int MeleeWeapon(int client)
{
	char cls[64];
	int size = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
	for (int i = 0; i < size; i++)
	{
		int w = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
		if (w <= 0 || !IsValidEntity(w) || IsGun(w))
			continue;
		GetEntityClassname(w, cls, sizeof(cls));
		if (!StrEqual(cls, "weapon_emptyhand") && !StrEqual(cls, "weapon_phone") && !StrEqual(cls, "weapon_barricade"))
			return w;
	}
	return -1;
}

// Get the hammer: drop the melee weapon (and, if the hammer still won't come, the main gun too:
// ZPS 2.4's weight limit), then take a hammer lying nearby or a fresh one, through the real E
// key (equipping it directly crashes in CWeapon_Barricade::Deploy).
// Returns true while walking to moveGoal.
bool GetHammer(int client, NavBot bot, float moveGoal[3])
{
	if (GetGameTime() < g_nextUse[client])
		return false;
	int melee = MeleeWeapon(client);
	if (melee != -1)
	{
		if (GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon") != melee)
		{
			char cls[64], cmd[80];
			GetEntityClassname(melee, cls, sizeof(cls));
			Format(cmd, sizeof(cmd), "use %s", cls);
			bot.DelayedFakeClientCommand(cmd);
		}
		else
		{
			// Hand it in: drop it through the game's own Weapon_Drop (keeps ZPS's weight
			// bookkeeping right) and remove it, or the bot standing on it picks it right back up.
			char cls[64];
			GetEntityClassname(melee, cls, sizeof(cls));
			if (GetFeatureStatus(FeatureType_Native, "SDKHooks_DropWeapon") == FeatureStatus_Available)
				SDKHooks_DropWeapon(client, melee);
			else
				RemovePlayerItem(client, melee);
			AcceptEntityInput(melee, "Kill");
			Debug("%N (builder) hands in %s for the hammer", client, cls);
		}
		g_nextUse[client] = GetGameTime() + 0.6;
		return false;
	}
	g_dropTries[client] = 0;
	if (g_hammerFails[client] >= 3 && ShedWeight(client, bot))
		return false;                        // still too heavy: drop the main gun as well

	int hammer = EntRefToEntIndex(g_spawnedHammer[client]);
	if (hammer != INVALID_ENT_REFERENCE && GetEntPropEnt(hammer, Prop_Send, "m_hOwnerEntity") != -1)
		hammer = INVALID_ENT_REFERENCE;      // someone took it
	if (hammer == INVALID_ENT_REFERENCE)
	{
		float dist;
		int free = NearestFreeBarricade(client, dist);
		if (free != -1 && dist < 600.0)
		{
			if (dist > 140.0)
			{
				float toolPos[3];
				GetEntPropVector(free, Prop_Data, "m_vecAbsOrigin", toolPos);
				SnapToNav(toolPos, moveGoal);
				return true;
			}
			hammer = free;
		}
		else
		{
			hammer = CreateEntityByName("weapon_barricade");
			if (hammer == -1)
				return false;
			DispatchSpawn(hammer);
		}
		g_spawnedHammer[client] = EntIndexToEntRef(hammer);
	}
	else
		g_hammerFails[client]++;             // offered last time, still not ours

	float eye[3], ang[3], fwd[3], spot[3];
	GetClientEyePosition(client, eye);
	GetClientEyeAngles(client, ang);
	ang[0] = 0.0;
	GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
	ScaleVector(fwd, 30.0);
	AddVectors(eye, fwd, spot);
	spot[2] -= 20.0;
	TeleportEntity(hammer, spot, NULL_VECTOR, view_as<float>({0.0, 0.0, 0.0}));
	Address ctrl = bot.GetPlayerControllerInterface();
	NavBotPlayerControllerInterface.AimAtPos(ctrl, spot, LOOK_USE, 0.6, "Picking up the hammer");
	NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_USE, 0.3);
	g_nextUse[client] = GetGameTime() + 1.2;
	return false;
}

// The build job: hammer in hand, go where the main player stood, aim where they aimed, hold attack
// through the whole hammer animation (the board only goes up at its end), check it went up.
// Returns true while walking to moveGoal.
// ZPS 2.4's hammer only nails a board while m_bCanAttachBoard is set, and that flag is kept up to
// date by the player's game client (it draws the board where it fits). A bot has no client, so
// its flag stayed 0 and no board ever went up. Set it for them from the game's own fit check.
// (Logged side by side: the teacher's hammer reads 1 there while aiming at a window; on attack
// m_bAttachBarricade goes 1 and a board is used up.)
bool HammerReady(int tool, bool keep = false)
{
	if (!HasEntProp(tool, Prop_Send, "m_bCanAttachBoard"))
		return g_canAttach != null && SDKCall(g_canAttach, tool);
	// Mid-attach (m_bAttachBarricade) the fit check reads "no"; clearing the flag then cancels the
	// board (seen: 1 0 1 ... then all zeros, no board used). A player's flag stays 1 throughout.
	if (keep || (HasEntProp(tool, Prop_Send, "m_bAttachBarricade") && GetEntProp(tool, Prop_Send, "m_bAttachBarricade")))
	{
		SetEntProp(tool, Prop_Send, "m_bCanAttachBoard", 1);
		return true;
	}
	bool fits = g_canAttach != null && SDKCall(g_canAttach, tool);
	SetEntProp(tool, Prop_Send, "m_bCanAttachBoard", fits ? 1 : 0);
	return fits;
}

bool DoBuild(int client, NavBot bot, float moveGoal[3])
{
	int tool = FindOwnedWeapon(client, "weapon_barricade");
	if (tool == -1)
		return GetHammer(client, bot, moveGoal);
	HammerReady(tool, GetGameTime() < g_hammerUntil[client]);   // hammering: keep it set
	g_hammerFails[client] = 0;
	g_spawnedHammer[client] = INVALID_ENT_REFERENCE;

	int b = g_buildLesson[client];
	if (b < 0 || CountBoardsNear(g_ln_boardPos[b], 90.0) > 0)   // that window/door already has boards: another one
	{
		if (b >= 0) g_boardClaim[b] = 0;
		b = NextBoardLesson(client);
		g_buildLesson[client] = b;
		g_buildTries[client] = 0;
		g_hammerUntil[client] = 0.0;
		if (b < 0)
		{
			ReleaseJob(client, true);        // all of them are up
			return false;
		}
		g_boardClaim[b] = client;
		g_jobStarted[client] = GetGameTime();
	}
	if (GetGameTime() - g_jobStarted[client] > 60.0)
	{
		g_boardGiveUp[b] = true;             // can't get there or can't nail it
		ReleaseJob(client, false);
		return false;
	}

	float me[3], stand[3];
	GetClientAbsOrigin(client, me);
	SnapToNav(g_ln_boardStand[b], stand);
	if (GetVectorDistance(me, stand) > 32.0 && g_hammerUntil[client] == 0.0)
	{
		moveGoal = stand;
		return true;
	}
	if (GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon") != tool)
	{
		if (GetGameTime() >= g_nextUse[client])
		{
			bot.DelayedFakeClientCommand("use weapon_barricade");
			g_nextUse[client] = GetGameTime() + 0.5;
		}
		return false;
	}
	Address ctrl = bot.GetPlayerControllerInterface();
	// Aim where the main player aimed; if the game says no board fits from where we stand (we
	// may stand lower than they did), sweep the aim around it until one does.
	static const float offs[][2] = { {0.0, 0.0}, {0.0, 10.0}, {0.0, -10.0}, {0.0, 20.0}, {0.0, -20.0}, {12.0, 0.0}, {-12.0, 0.0},
		{12.0, 10.0}, {-12.0, 10.0}, {12.0, -10.0}, {-12.0, -10.0}, {0.0, 30.0}, {0.0, -30.0}, {20.0, 0.0}, {-20.0, 0.0} };
	int k = g_buildScan[client] % sizeof(offs);
	float aim[3], side[3], toAim[3];
	SubtractVectors(g_ln_boardAim[b], me, toAim);
	toAim[2] = 0.0;
	NormalizeVector(toAim, toAim);
	side[0] = -toAim[1]; side[1] = toAim[0]; side[2] = 0.0;
	aim = g_ln_boardAim[b];
	aim[0] += side[0] * offs[k][0];
	aim[1] += side[1] * offs[k][0];
	aim[2] += offs[k][1];
	NavBotPlayerControllerInterface.AimAtPos(ctrl, aim, LOOK_PRIORITY, 0.5, "Nailing a board");
	if (g_hammerUntil[client] == 0.0)
	{
		if (!NavBotPlayerControllerInterface.IsAimOnTarget(ctrl))
			return false;
		if (g_canAttach != null && !HammerReady(tool))
		{
			if (++g_buildScan[client] % sizeof(offs) == 0)
			{
				Debug("%N: no spot for board %d fits from here", client, b);
				g_hammerUntil[client] = GetGameTime();   // counts as a failed try below
				g_hammerBoardsBefore[client] = CountBoardsNear(g_ln_boardPos[b], 60.0);
			}
			return false;
		}
		g_buildAmmo[client] = GetEntProp(client, Prop_Send, "m_iAmmo", _, 7) + GetEntProp(tool, Prop_Send, "m_iClip1");
		Debug("%N: board %d fits (aim offset %.0f %.0f), hammering (%d boards)", client, b, offs[k][0], offs[k][1], g_buildAmmo[client]);
		g_hammerUntil[client] = GetGameTime() + 6.0;
		g_hammerBoardsBefore[client] = CountBoardsNear(g_ln_boardPos[b], 60.0);
	}
	if (GetGameTime() < g_hammerUntil[client])
	{
		g_handsUntil[client] = GetGameTime() + 1.5;   // HoldBestGun: keep the hammer out
		// Separate clicks, one per nail: a held button only counts once.
		if (GetGameTime() >= g_nextNail[client])
		{
			// Straight into the bot's usercmd (OnPlayerRunCmd): the hammer reads the real buttons.
			g_clickUntil[client] = GetGameTime() + 0.15;
			g_nextNail[client] = GetGameTime() + 0.6;
		}
		return false;
	}
	g_hammerUntil[client] = 0.0;
	int left = GetEntProp(client, Prop_Send, "m_iAmmo", _, 7) + GetEntProp(tool, Prop_Send, "m_iClip1");
	Debug("%N: after hammering board %d: %d boards left (had %d), %d boards within 60 / 150 of it: %d / %d", client, b, left, g_buildAmmo[client],
		0, CountBoardsNear(g_ln_boardPos[b], 60.0), CountBoardsNear(g_ln_boardPos[b], 150.0));
	if (CountBoardsNear(g_ln_boardPos[b], 60.0) > g_hammerBoardsBefore[client] || left < g_buildAmmo[client])
	{
		Debug("%N nailed the main player's board %d", client, b);
		g_boardClaim[b] = 0;
		g_buildLesson[client] = -1;          // next one
	}
	else if (++g_buildTries[client] >= 3)
	{
		Debug("%N: board %d won't go up, skipping it this round", client, b);
		g_boardGiveUp[b] = true;
		g_boardClaim[b] = 0;
		g_buildLesson[client] = -1;
	}
	return false;
}

// ZPS 2.4 has a carry-weight limit; a bot with a main gun and melee weapons can't pick up the
// barricade hammer. Drop the main gun and melee weapons (keep the pistol, hands and phone) through
// the game's own "dropweapon" so ZPS updates the weight. Returns true while still dropping.
bool ShedWeight(int client, NavBot bot)
{
	char cls[64];
	int size = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
	for (int i = 0; i < size; i++)
	{
		int w = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
		if (w <= 0 || !IsValidEntity(w))
			continue;
		GetEntityClassname(w, cls, sizeof(cls));
		if (StrEqual(cls, "weapon_emptyhand") || StrEqual(cls, "weapon_phone") || StrEqual(cls, "weapon_barricade") || (IsGun(w) && IsPistol(w)))
			continue;
		if (GetGameTime() < g_nextUse[client])
			return true;
		if (GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon") != w)
		{
			char cmd[80];
			Format(cmd, sizeof(cmd), "use %s", cls);
			bot.DelayedFakeClientCommand(cmd);
		}
		else
		{
			bot.DelayedFakeClientCommand("dropweapon");
			Debug("%N drops %s to make room for the hammer", client, cls);
		}
		g_nextUse[client] = GetGameTime() + 0.6;
		return true;
	}
	return false;
}

// Boards nailed up so far around an opening (models/zp_props/barricades/barricade_*.mdl).
int CountBoardsNear(const float pos[3], float radius)
{
	int n = 0;
	char model[128];
	for (int ent = MaxClients + 1; ent < GetMaxEntities(); ent++)
	{
		if (!IsValidEntity(ent) || !HasEntProp(ent, Prop_Data, "m_ModelName"))
			continue;
		GetEntPropString(ent, Prop_Data, "m_ModelName", model, sizeof(model));
		if (StrContains(model, "barricades/barricade_", false) == -1)
			continue;
		float o[3];
		GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", o);
		if (GetVectorDistance(o, pos) <= radius)
			n++;
	}
	return n;
}

// Returns true while the bot should keep moving towards moveGoal.
bool DoBarricade(int client, NavBot bot, float moveGoal[3])
{
	int o = g_jobOpening[client];
	if (o < 0 || g_openingDone[o] || GetGameTime() - g_jobStarted[client] > 75.0)
	{
		ReleaseJob(client, o >= 0 && GetGameTime() - g_jobStarted[client] > 75.0);  // give up after 75 s
		return false;
	}

	// 1. Get a barricade tool if we don't have one (dropping heavy items first).
	int tool = FindOwnedWeapon(client, "weapon_barricade");
	if (tool != -1) HammerReady(tool);
	if (g_canAttach == null)
		return g_furniture.BoolValue ? DoFurniture(client, bot, moveGoal) : false;   // no hammer support
	if (tool == -1 && !g_needTool.BoolValue && g_furniture.BoolValue)
		return DoFurniture(client, bot, moveGoal);   // no hammer needed: push furniture into the opening
	if (tool == -1 && g_needTool.BoolValue)
	{
		if (ShedWeight(client, bot))
			return false;
		float dist;
		int free = NearestFreeBarricade(client, dist);
		if (free == -1)
		{
			if (g_furniture.BoolValue)
				return DoFurniture(client, bot, moveGoal);
			ReleaseJob(client, false);
			return false;
		}
		float toolPos[3];
		GetEntPropVector(free, Prop_Data, "m_vecAbsOrigin", toolPos);
		SnapToNav(toolPos, moveGoal);
		if (dist < 140.0 && GetGameTime() >= g_nextUse[client])
		{
			// Tools often lie on tables or sills just outside E's reach from the nearest walkable
			// spot. Move the tool right in front of the bot and press the real E button, so the
			// game's own pickup code runs. (Equipping it directly skips ZPS's pickup setup and
			// crashes in CWeapon_Barricade::Deploy.)
			float eye[3], ang[3], fwd[3], spot[3];
			GetClientEyePosition(client, eye);
			GetClientEyeAngles(client, ang);
			ang[0] = 0.0;
			GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
			ScaleVector(fwd, 30.0);
			AddVectors(eye, fwd, spot);
			spot[2] -= 20.0;
			TeleportEntity(free, spot, NULL_VECTOR, view_as<float>({0.0, 0.0, 0.0}));
			Address ctrl = bot.GetPlayerControllerInterface();
			NavBotPlayerControllerInterface.AimAtPos(ctrl, spot, LOOK_USE, 0.6, "Picking up barricade");
			NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_USE, 0.3);
			g_nextUse[client] = GetGameTime() + 1.0;
			Debug("%N picks up a barricade tool", client);
		}
		return true;
	}

	// Out of boards: drop the job (another bot with a fresh tool can finish).
	if (tool != -1 && g_needTool.BoolValue && GetEntProp(tool, Prop_Send, "m_iClip1") <= 0 && GetEntProp(client, Prop_Send, "m_iAmmo", _, AMMO_BARRICADE) <= 0)
	{
		ReleaseJob(client, false);
		return false;
	}

	// 2. Walk to the opening.
	float stand[3], me[3];
	StandPoint(o, stand);
	GetClientAbsOrigin(client, me);
	moveGoal = stand;
	if (GetVectorDistance(me, stand) > 60.0)
		return true;

	// 3. Hold the barricade, aim at spots across the opening, hammer where the game says it fits.
	if (tool == -1)
		return false;
	if (GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon") != tool)
	{
		bot.DelayedFakeClientCommand("use weapon_barricade");
		return false;
	}
	Address ctrl = bot.GetPlayerControllerInterface();

	// Hammering: the game re-checks CanAttachBarricade() every frame of the hammer animation and
	// only attaches the board at the end, so keep the aim locked and hold attack the whole time.
	if (g_hammerUntil[client] > 0.0)
	{
		if (GetGameTime() < g_hammerUntil[client])
		{
			NavBotPlayerControllerInterface.AimAtPos(ctrl, g_hammerAim[client], LOOK_PRIORITY, 0.5, "Hammering a board");
			float t = GetGameTime() - g_hammerStart[client];
			static float lastProbe[MAXPLAYERS + 1];
			if ((t > 1.0 && lastProbe[client] < 1.0) || (t > 3.0 && lastProbe[client] < 3.0))
			{
				char active[64] = "-";
				int aw = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
				if (aw > 0) GetEntityClassname(aw, active, sizeof(active));
				Debug("%N hammer t=%.1f holding %s canAttach=%d", client, t, active, aw == tool ? SDKCall(g_canAttach, tool) : -1);
			}
			lastProbe[client] = t;
			switch (g_hammerMode[client])
			{
				case 0: NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_ATTACKPRIM, 0.3);   // hold attack
				case 1: if (t < 0.3 || (t > 1.5 && t < 1.8)) NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_ATTACKPRIM, 0.2); // click, click again
				case 2: { if (t < 0.3) NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_ATTACKPRIM, 0.2);
					else if (t > 1.0 && t < 1.3) NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_ATTACKSEC, 0.2); } // click, then attack2
				case 3: { if (t < 0.3) NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_ATTACKPRIM, 0.2);
					else if (t > 1.0 && t < 1.3) NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_RELOAD, 0.2); }    // click, then reload
				case 4: if (t < 0.3) NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_ATTACKPRIM, 0.2);                 // single click, wait
			}
			return false;
		}
		g_hammerUntil[client] = 0.0;
		int now = CountBoardsNear(g_openingPos[o], 160.0);
		if (now > g_hammerBoardsBefore[client])
		{
			if (g_modeWorks != g_hammerMode[client])
				LogMessage("Hammer input pattern %d places boards", g_hammerMode[client]);
			g_modeWorks = g_hammerMode[client];
			g_openingBoards[o]++;
			Debug("%N nailed a board on opening %d (%d/%d)", client, o, g_openingBoards[o], g_boardsPerOpening.IntValue);
			if (g_openingBoards[o] >= g_boardsPerOpening.IntValue)
			{
				ReleaseJob(client, true);
				return false;
			}
		}
		else
		{
			Debug("%N hammered (pattern %d) but no board appeared at opening %d", client, g_hammerMode[client], o);
			g_aimTry[client]++;
		}
	}

	static const float offsets[][3] = { {0.0, 0.0, 0.0}, {0.0, 0.0, 20.0}, {0.0, 0.0, -20.0}, {0.0, 0.0, 36.0}, {0.0, 0.0, -36.0} };
	float aim[3];
	int t = g_aimTry[client] % sizeof(offsets);
	AddVectors(g_openingPos[o], offsets[t], aim);

	NavBotPlayerControllerInterface.AimAtPos(ctrl, aim, LOOK_PRIORITY, 0.5, "Barricading");
	if (!NavBotPlayerControllerInterface.IsAimOnTarget(ctrl))
		return false;

	if (SDKCall(g_canAttach, tool))
	{
		// Start hammering here and keep at it for the whole animation.
		g_hammerAim[client] = aim;
		g_hammerMode[client] = g_modeWorks >= 0 ? g_modeWorks : (g_modeNext++ % 5);
		g_hammerStart[client] = GetGameTime();
		g_hammerUntil[client] = GetGameTime() + 4.5;
		g_hammerBoardsBefore[client] = CountBoardsNear(g_openingPos[o], 160.0);
		NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_ATTACKPRIM, 0.3);
		return false;
	}
	g_aimTry[client]++;
	if (g_aimTry[client] > 40)          // nothing fits here (open space, wrong side...): skip it
	{
		g_aimTry[client] = 0;
		ReleaseJob(client, true);
	}
	return false;
}

// ---------------------------------------------------------------------------------------------
// Free guns and unlimited ammo

// Main guns handed out on top of the pistol ZPS gives everyone at spawn.
static const char g_giveList[][] = { "weapon_ak47", "weapon_m4", "weapon_mp5", "weapon_870", "weapon_supershorty",
	"weapon_winchester", "weapon_revolver" };

bool IsPistol(int weapon)
{
	char cls[64];
	GetEntityClassname(weapon, cls, sizeof(cls));
	return StrEqual(cls, "weapon_glock") || StrEqual(cls, "weapon_glock18c") || StrEqual(cls, "weapon_usp") || StrEqual(cls, "weapon_ppk");
}

bool HasGun(int client)
{
	return BestGun(client) != -1;
}

// Best gun the bot owns: a main gun if it has one, else a pistol, else -1.
int BestGun(int client)
{
	int pistol = -1;
	int size = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
	for (int i = 0; i < size; i++)
	{
		int w = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
		if (!IsGun(w))
			continue;
		if (!IsPistol(w))
			return w;
		pistol = w;
	}
	return pistol;
}

bool HasMainGun(int client)
{
	int w = BestGun(client);
	return w != -1 && !IsPistol(w);
}

// Survivor bots that aren't barricading hold their best gun (NavBot only switches when a fight
// starts, so they walked around with keyboards and brooms).
void HoldBestGun(int client, NavBot bot)
{
	if (g_job[client] != JOB_NONE || GetGameTime() < g_nextUse[client] || GetGameTime() < g_handsUntil[client])
		return;
	float zd;
	if (NearestZombie(client, 600.0, zd) != 0)
		return;   // don't fight NavBot's weapon choice mid-combat (constant switching = no shooting)
	int best = BestGun(client);
	if (best == -1 || GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon") == best)
		return;
	char cls[64], cmd[80];
	GetEntityClassname(best, cls, sizeof(cls));
	Format(cmd, sizeof(cmd), "use %s", cls);
	bot.DelayedFakeClientCommand(cmd);
}

// Weapons in 2.4 are picked up with E. Spawn a random gun right in front of the bot's face and
// press the real E button, so the game's normal pickup code runs.
// Returns true while the bot should stand still and finish picking it up.
bool ArmBot(int client, NavBot bot)
{
	static float lastLog[MAXPLAYERS + 1];
	bool logNow = GetGameTime() - lastLog[client] > 5.0;
	if (logNow) lastLog[client] = GetGameTime();

	if (g_job[client] != JOB_NONE || GetGameTime() < g_armPauseUntil[client])
		return false;   // barricaders travel light; bots too heavy to take a gun wait a minute
	if (!g_giveWeapons.BoolValue || HasMainGun(client))
	{
		g_armTries[client] = 0;
		g_givenGun[client] = INVALID_ENT_REFERENCE;
		return false;
	}
	if (GetGameTime() < g_nextUse[client])
	{
		if (logNow) Debug("%N: ArmBot waiting %.1f s", client, g_nextUse[client] - GetGameTime());
		return true;
	}

	int gun = EntRefToEntIndex(g_givenGun[client]);
	// Not picked up after two tries: probably the weight limit. Drop the melee weapon in hand
	// (keyboard, frying pan...) to make room.
	if (gun != INVALID_ENT_REFERENCE && GetEntPropEnt(gun, Prop_Send, "m_hOwnerEntity") == -1 && g_armTries[client] == 2)
	{
		int held = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
		char hc[64] = "";
		if (held > 0)
			GetEntityClassname(held, hc, sizeof(hc));
		if (held > 0 && !IsGun(held) && !StrEqual(hc, "weapon_emptyhand") && !StrEqual(hc, "weapon_phone"))
		{
			bot.DelayedFakeClientCommand("dropweapon");
			Debug("%N drops %s to make room for a gun", client, hc);
		}
	}
	if (gun != INVALID_ENT_REFERENCE && GetEntPropEnt(gun, Prop_Send, "m_hOwnerEntity") == -1 && ++g_armTries[client] > 5)
	{
		// Still on the floor after several E presses: the bot is at its weight limit.
		AcceptEntityInput(gun, "Kill");
		g_givenGun[client] = INVALID_ENT_REFERENCE;
		g_armTries[client] = 0;
		g_armPauseUntil[client] = GetGameTime() + 60.0;
		return false;
	}
	if (gun == INVALID_ENT_REFERENCE || GetEntPropEnt(gun, Prop_Send, "m_hOwnerEntity") != -1)
	{
		gun = CreateEntityByName(g_giveList[GetRandomInt(0, sizeof(g_giveList) - 1)]);
		if (gun == -1)
			return false;
		DispatchSpawn(gun);
		g_givenGun[client] = EntIndexToEntRef(gun);
	}

	float eye[3], ang[3], fwd[3], spot[3];
	GetClientEyePosition(client, eye);
	GetClientEyeAngles(client, ang);
	ang[0] = 0.0;
	GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
	ScaleVector(fwd, 30.0);
	AddVectors(eye, fwd, spot);
	spot[2] -= 20.0;
	TeleportEntity(gun, spot, NULL_VECTOR, view_as<float>({0.0, 0.0, 0.0}));
	Address ctrl = bot.GetPlayerControllerInterface();
	NavBotPlayerControllerInterface.AimAtPos(ctrl, spot, LOOK_PRIORITY, 0.6, "Taking a gun");
	NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_USE, 0.3);
	g_nextUse[client] = GetGameTime() + 1.0;
	char cls[64];
	GetEntityClassname(gun, cls, sizeof(cls));
	Debug("%N: offering %s (weight check: owns %d weapons)", client, cls, GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons"));
	return true;
}

void RefillAmmo(int client)
{
	if (!g_infiniteAmmo.BoolValue)
		return;
	for (int type = 1; type <= 4; type++)          // LightPistol, Magnum, Shotgun, Rifle
		if (GetEntProp(client, Prop_Send, "m_iAmmo", _, type) < 120)
			SetEntProp(client, Prop_Send, "m_iAmmo", 120, _, type);
	if (FindOwnedWeapon(client, "weapon_barricade") != -1 && GetEntProp(client, Prop_Send, "m_iAmmo", _, AMMO_BARRICADE) < 6)
		SetEntProp(client, Prop_Send, "m_iAmmo", 6, _, AMMO_BARRICADE);
}

// ---------------------------------------------------------------------------------------------
// Self-defence: aim at the nearest zombie in sight and shoot

bool TraceOnlyWorldAndZombies(int entity, int mask, int self)
{
	if (entity == self)
		return false;
	if (entity >= 1 && entity <= MaxClients)
		return GetClientTeam(entity) == TEAM_ZOMBIES;   // other survivors don't block the shot
	return true;
}

// Can the bot shoot zombie i without hitting anything of ours? Doors, barricade boards and intact
// windows are in the way (shooting would wreck them); shattered windows are not.
bool ClearShot(int client, int i)
{
	float eye[3], target[3];
	GetClientEyePosition(client, eye);
	GetClientEyePosition(i, target);
	target[2] -= 12.0;
	TR_TraceRayFilter(eye, target, MASK_SHOT, RayType_EndPoint, TraceOnlyWorldAndZombies, client);
	int hit = TR_GetEntityIndex();
	if (!TR_DidHit() || hit == i)
		return true;
	if (hit <= MaxClients || !IsValidEntity(hit))
		return false;
	char cls[64];
	GetEntityClassname(hit, cls, sizeof(cls));
	return StrEqual(cls, "func_breakable_surf") && HasEntProp(hit, Prop_Send, "m_bIsBroken") && GetEntProp(hit, Prop_Send, "m_bIsBroken") != 0;
}

// Nearest living zombie the bot has a clear shot at.
int NearestVisibleZombie(int client, float range, float &dist)
{
	float eye[3], target[3];
	GetClientEyePosition(client, eye);
	int best = 0;
	dist = range;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) != TEAM_ZOMBIES)
			continue;
		GetClientEyePosition(i, target);
		target[2] -= 12.0;
		float d = GetVectorDistance(eye, target);
		if (d < dist && ClearShot(client, i)) { dist = d; best = i; }
	}
	return best;
}

// Out with the best gun if the bot is holding hands, a tool or a melee weapon.
void DrawGun(int client, NavBot bot)
{
	int best = BestGun(client);
	if (best == -1 || GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon") == best || GetGameTime() < g_nextUse[client])
		return;
	if (IsGun(GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon")))
		return;
	char cls[64], cmd[80];
	GetEntityClassname(best, cls, sizeof(cls));
	Format(cmd, sizeof(cmd), "use %s", cls);
	bot.DelayedFakeClientCommand(cmd);
	g_nextUse[client] = GetGameTime() + 0.5;
	g_handsUntil[client] = 0.0;
}

// Returns true while fighting (the caller then only moves if the zombie is right on top of us).
bool SelfDefence(int client, NavBot bot, int &zombie, float &zdist)
{
	zombie = NearestVisibleZombie(client, EngageRange(), zdist);
	if (!zombie)
		return false;
	DrawGun(client, bot);
	int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	Address ctrl = bot.GetPlayerControllerInterface();
	NavBotPlayerControllerInterface.AimAtEntity(ctrl, zombie, LOOK_COMBAT, 0.4, "Shooting zombie");
	if (IsGun(weapon) && GetEntProp(weapon, Prop_Send, "m_iClip1") <= 0)
		NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_RELOAD, 0.2);
	else if (NavBotPlayerControllerInterface.IsAimOnTarget(ctrl) && (IsGun(weapon) || zdist < 90.0))
		NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_ATTACKPRIM, 0.1);
	return true;
}

// ---------------------------------------------------------------------------------------------
// Main loop

bool TraceWorldOnlyS(int entity, int mask)
{
	return entity == 0;
}

// Floor height straight below a point (or -99999 if nothing within 400 units).
float FloorAt(const float p[3])
{
	float a[3], b[3];
	a = p; b = p;
	a[2] += 16.0;
	b[2] -= 400.0;
	TR_TraceRayFilter(a, b, MASK_PLAYERSOLID_BRUSHONLY, RayType_EndPoint, TraceWorldOnlyS);
	if (!TR_DidHit())
		return -99999.0;
	float hit[3];
	TR_GetEndPosition(hit);
	return hit[2];
}

// Walking from `from` to `to` (and a step past it) runs off a drop: somewhere along the way the
// floor is more than 64 units below our feet. Roof and balcony edges: bots fell off backing away.
bool DropAlong(const float from[3], const float to[3])
{
	float dir[3];
	SubtractVectors(to, from, dir);
	dir[2] = 0.0;
	float len = GetVectorLength(dir);
	if (len < 1.0)
		return false;
	NormalizeVector(dir, dir);
	for (float t = 16.0; t <= len + 24.0; t += 16.0)
	{
		float p[3];
		for (int i = 0; i < 2; i++) p[i] = from[i] + dir[i] * t;
		p[2] = from[2] + 8.0;
		if (FloorAt(p) < from[2] - 64.0)
			return true;
	}
	return false;
}

// An unrailed edge within 40 units: nothing solid at step height between us and a drop.
bool AtEdge(const float pos[3])
{
	for (int k = 0; k < 8; k++)
	{
		float a = float(k) * 45.0, dir[3], from[3], to[3];
		dir[0] = Cosine(DegToRad(a)); dir[1] = Sine(DegToRad(a)); dir[2] = 0.0;
		from = pos; from[2] += 20.0;
		for (int i = 0; i < 2; i++) to[i] = from[i] + dir[i] * 40.0;
		to[2] = from[2];
		TR_TraceHullFilter(from, to, view_as<float>({-8.0, -8.0, 0.0}), view_as<float>({8.0, 8.0, 24.0}), MASK_PLAYERSOLID_BRUSHONLY, TraceWorldOnlyS);
		if (TR_DidHit())
			continue;               // a wall or a railing that way
		if (FloorAt(to) < pos[2] - 64.0)
			return true;
	}
	return false;
}

// Three or more zombies on top of us: then jumping off is fair.
bool Surrounded(int client)
{
	float me[3], p[3];
	GetClientAbsOrigin(client, me);
	int n = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) != TEAM_ZOMBIES)
			continue;
		GetClientAbsOrigin(i, p);
		if (GetVectorDistance(me, p) < 160.0)
			n++;
	}
	return n >= 3;
}

// A walkable spot about 220 units away from a zombie: straight away if that's open, else the
// direction (up to 90 degrees off) that ends farthest from it. Avoids backing into walls.
bool RetreatSpot(int client, const float them[3], float out[3])
{
	float me[3], away[3], ang[3];
	GetClientAbsOrigin(client, me);
	SubtractVectors(me, them, away);
	away[2] = 0.0;
	NormalizeVector(away, away);
	GetVectorAngles(away, ang);
	static const float offsets[] = { 0.0, 35.0, -35.0, 70.0, -70.0, 90.0, -90.0 };
	float best = -1.0;
	for (int i = 0; i < sizeof(offsets); i++)
	{
		float a[3], dir[3], end[3], spot[3];
		a = ang;
		a[1] += offsets[i];
		GetAngleVectors(a, dir, NULL_VECTOR, NULL_VECTOR);
		// How far we can actually walk that way before hitting a wall.
		float from[3];
		from = me;
		from[2] += 24.0;
		ScaleVector(dir, 220.0);
		AddVectors(from, dir, end);
		TR_TraceHullFilter(from, end, view_as<float>({-16.0, -16.0, 0.0}), view_as<float>({16.0, 16.0, 40.0}), MASK_PLAYERSOLID, TraceIgnoreSelf, client);
		TR_GetEndPosition(end);
		if (GetVectorDistance(from, end) < 60.0)
			continue;
		Address area = NavBotNavMesh.GetNearestNavArea(end, 80.0, false, true);
		if (area == Address_Null)
			continue;
		NavBotNavArea.GetClosestPointOnArea(area, end, spot);
		if (NearWindow(g_home[client], spot, 100.0))
			continue;               // don't back into a window
		if (DropAlong(me, spot) && !Surrounded(client))
			continue;               // don't back off a roof or balcony
		float d = GetVectorDistance(spot, them);
		if (d > best + 40.0)        // prefer the straighter direction unless another is clearly better
		{
			best = d;
			out = spot;
		}
	}
	return best > 0.0;
}

Action MoveTo(int client, float moveGoal[3])
{
	float me[3];
	GetClientAbsOrigin(client, me);
	Unstick_WantMove(client, me, moveGoal);
	return Plugin_Changed;
}

Action Hold(int client)
{
	g_us_wantMove[client] = false;
	return Plugin_Continue;
}

Action OnScriptedUpdate(NavBot bot, float moveGoal[3], NavBotRouteType& routeType)
{
	int client = bot.Index;
	if (!g_enable.BoolValue || !IsClientInGame(client) || !IsPlayerAlive(client) || GetClientTeam(client) != TEAM_SURVIVORS)
	{
		Debug("stop script for client %d (not a live survivor)", client);
		g_scripted[client] = false;
		return Plugin_Stop;
	}
	if (g_restockUntil[client] > GetGameTime())
	{
		g_scripted[client] = false;
		return Plugin_Stop;                      // let NavBot go collect ammo
	}

	ArmBot(client, bot);                     // runs alongside whatever the bot does: no standing still for a gun
	if (Unstick_Goal(client, moveGoal))
	{
		strcopy(g_state[client], sizeof(g_state[]), "unsticking");
		routeType = NAVBOT_FASTEST_ROUTE;
		return Plugin_Changed;              // detour around whatever we're stuck on
	}

	OpenDoorAhead(client, bot);
	float me[3];
	GetClientAbsOrigin(client, me);

	// Fight first: aim at and shoot the nearest zombie in sight, standing our ground while it's
	// farther than the safe distance. Closer than that, or after being hit, back off and keep shooting.
	float zdist;
	int zombie;
	bool fighting = SelfDefence(client, bot, zombie, zdist);
	if (!fighting)
		zombie = 0;

	// Just got hit: that zombie is the threat, wherever it is (behind us, beside a door, ...).
	bool hurt = false;
	int attacker = g_hurtBy[client];
	if (GetGameTime() < g_hurtUntil[client] && attacker > 0 && IsClientInGame(attacker) && IsPlayerAlive(attacker) && GetClientTeam(attacker) == TEAM_ZOMBIES)
	{
		float them[3];
		GetClientAbsOrigin(attacker, them);
		float d = GetVectorDistance(me, them);
		if (d < SafeDist())
		{
			hurt = true;
			zombie = attacker;
			zdist = d;
			DrawGun(client, bot);
			Address ctrl = bot.GetPlayerControllerInterface();
			NavBotPlayerControllerInterface.AimAtEntity(ctrl, attacker, LOOK_CRITICAL, 0.4, "Hit by a zombie");
			int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
			if (IsGun(weapon) && GetEntProp(weapon, Prop_Send, "m_iClip1") <= 0)
				NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_RELOAD, 0.2);
			else if (NavBotPlayerControllerInterface.IsAimOnTarget(ctrl) && ClearShot(client, attacker))
				NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_ATTACKPRIM, 0.1);
		}
		else
			g_hurtUntil[client] = 0.0;      // already at a safe distance
	}

	if (fighting && !hurt && zdist > SafeDist())
	{
		strcopy(g_state[client], sizeof(g_state[]), "standing and shooting");
		return Hold(client);
	}                // stand our ground and shoot

	if (zombie && (hurt || IsGun(GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon"))))
	{
		float them[3];
		GetClientAbsOrigin(zombie, them);
		// Fall back inside the hold-out: the defend spot farthest from the zombie, if it's a real
		// step back; otherwise the best open direction away from it.
		int best = -1;
		int h = g_home[client];
		float bestScore = GetVectorDistance(me, them) + 150.0;
		int candidates = h < 0 ? 0 : g_upperCount[h] > 0 ? g_upperCount[h] : g_defendCount[h];   // never fall back downstairs
		for (int i = 0; i < candidates; i++)
		{
			float d = GetVectorDistance(g_defendPos[h][i], them);
			if (d > bestScore && GetVectorDistance(g_defendPos[h][i], me) < 700.0) { bestScore = d; best = i; }
		}
		if (best != -1)
		{
			moveGoal = g_defendPos[h][best];
			g_defendIdx[client] = best;
			g_defendSwitch[client] = GetGameTime() + 20.0;
		}
		else if (!RetreatSpot(client, them, moveGoal))
		{
			float away[3];
			SubtractVectors(me, them, away);
			away[2] = 0.0;
			NormalizeVector(away, away);
			ScaleVector(away, 200.0);
			AddVectors(me, away, moveGoal);
		}
		// Up on a roof or balcony with the way back over the edge: hold here and shoot them below,
		// unless they're all over us.
		if (DropAlong(me, moveGoal) && !Surrounded(client))
		{
			strcopy(g_state[client], sizeof(g_state[]), "holding the edge, shooting down");
			NavBotPlayerControllerInterface.AimAtPos(bot.GetPlayerControllerInterface(), them, LOOK_PRIORITY, 0.3, "Shooting down");
			if (IsGun(GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon")))
				NavBotPlayerControllerInterface.PressButtonByID(bot.GetPlayerControllerInterface(), NAVBOT_BUTTON_ATTACKPRIM, 0.1);
			return Hold(client);
		}
		routeType = NAVBOT_FASTEST_ROUTE;
		strcopy(g_state[client], sizeof(g_state[]), "falling back");
		return MoveTo(client, moveGoal);
	}

	// A closed hinged door in front of us: bumping it does nothing, open it with E.
	if (Doors_UseAhead(client, bot))
	{
		strcopy(g_state[client], sizeof(g_state[]), "opening a door (E)");
		g_us_wantMove[client] = false;
		return Plugin_Continue;
	}

	// Closing a door the zombies opened from inside (cabin's garage): its Close button, E.
	if (CloseDoorButton(client, bot, moveGoal))
	{
		if (g_closeWalking[client])
		{
			strcopy(g_state[client], sizeof(g_state[]), "closing a door: walking");
			return MoveTo(client, moveGoal);
		}
		strcopy(g_state[client], sizeof(g_state[]), "closing a door: pressing E");
		g_us_wantMove[client] = false;
		return Plugin_Continue;
	}

	// A basement door in the way: break it (melee).
	if (BreakBasementDoor(client, bot))
	{
		strcopy(g_state[client], sizeof(g_state[]), "breaking the basement door");
		g_us_wantMove[client] = false;
		return Plugin_Continue;
	}

	// Furniture in the way (see OnNavBotObstacleOnPath): shove it aside, a bit off our line so it
	// ends up beside the path rather than further along it.
	if (GetGameTime() < g_shoveUntil[client])
	{
		int prop = EntRefToEntIndex(g_shoveProp[client]);
		if (prop != INVALID_ENT_REFERENCE)
		{
			float c[3], dir[3], ang[3], at[3];
			EntityCenter(prop, c);
			SubtractVectors(c, me, dir);
			float dist = GetVectorLength(dir);
			if (dist < 110.0)
			{
				GetVectorAngles(dir, ang);
				ang[1] += (client % 2 == 0) ? 20.0 : -20.0;
				GetAngleVectors(ang, dir, NULL_VECTOR, NULL_VECTOR);
				ScaleVector(dir, dist);
				GetClientAbsOrigin(client, at);
				AddVectors(at, dir, at);
				at[2] = c[2] - 4.0;
				dir[2] = 0.0;
				NormalizeVector(dir, dir);
				Shove(client, bot, at, prop, dir);
				strcopy(g_state[client], sizeof(g_state[]), "shoving furniture aside");
				return Hold(client);
			}
		}
		g_shoveUntil[client] = 0.0;
	}

	if (g_job[client] == JOB_BUILD)
	{
		if (DoBuild(client, bot, moveGoal))
		{
			strcopy(g_state[client], sizeof(g_state[]), "building: walking");
			routeType = NAVBOT_SAFEST_ROUTE;
			return MoveTo(client, moveGoal);
		}
		strcopy(g_state[client], sizeof(g_state[]), FindOwnedWeapon(client, "weapon_barricade") == -1 ? "building: getting the hammer" : "building: hammering");
		return Hold(client);
	}

	if (g_job[client] == JOB_PLACE)
	{
		if (DoPlace(client, bot, moveGoal))
		{
			strcopy(g_state[client], sizeof(g_state[]), "copying your furniture: walking");
			routeType = NAVBOT_SAFEST_ROUTE;
			return MoveTo(client, moveGoal);
		}
		strcopy(g_state[client], sizeof(g_state[]), "copying your furniture: shoving");
		return Hold(client);
	}

	if (g_job[client] == JOB_BARRICADE)
	{
		if (DoBarricade(client, bot, moveGoal))
		{
			routeType = NAVBOT_SAFEST_ROUTE;
			strcopy(g_state[client], sizeof(g_state[]), "barricading: walking");
			return MoveTo(client, moveGoal);
		}
		strcopy(g_state[client], sizeof(g_state[]), "barricading: working");
		return Hold(client);
	}

	// Defend: hold a spot (upper floor / roof / balcony / corner), move to another one every
	// 25-45 s, and keep turning to watch different doors and windows.
	int h = g_home[client];
	if (h < 0)
	{
		strcopy(g_state[client], sizeof(g_state[]), "no home");
		return Hold(client);
	}
	float spot[3];
	spot = g_homePos[h];
	if (g_defendCount[h] > 0)
	{
		float zd;
		bool calm = NearestZombie(client, 900.0, zd) == 0;
		if (IsPatroller(client) && GetGameTime() >= g_defendSwitch[client] && calm)
		{
			// Patrol: walk to another spot somewhere else in the building, look around a few
			// seconds there, move on.
			g_defendIdx[client] = PickPatrolSpot(client, h);
			g_defendSwitch[client] = GetGameTime() + 90.0;   // until we get there
			g_patrolArrived[client] = false;
		}
		else if (GetGameTime() >= g_defendSwitch[client] && calm)
		{
			// Upstairs whenever the building has an upper floor, roof or balcony.
			int top = g_upperCount[h] > 0 && !g_mapSpread ? g_upperCount[h] : g_defendCount[h];
			if (top < 4) top = g_defendCount[h] < 4 ? g_defendCount[h] : 4;   // don't all pile onto one spot
			if (top > 16 && !g_mapSpread) top = 16;
			g_defendIdx[client] = PickFreeSpot(client, h, top);
			g_defendSwitch[client] = GetGameTime() + GetRandomFloat(25.0, 45.0);
		}
		spot = g_defendPos[h][g_defendIdx[client] % g_defendCount[h]];
	}
	Action climb;
	if (Stairs_Update(client, bot, me, spot, moveGoal, routeType, climb, Unstick_StuckFor(client) > 2.5))
	{
		strcopy(g_state[client], sizeof(g_state[]), "taking the stairs");
		if (climb == Plugin_Continue) g_us_wantMove[client] = false;
		else Unstick_WantMove(client, me, moveGoal);
		return climb;
	}
	if (GetVectorDistance(me, spot) > 64.0)
	{
		moveGoal = spot;
		routeType = NAVBOT_SAFEST_ROUTE;
		strcopy(g_state[client], sizeof(g_state[]), "walking to defend spot");
		return MoveTo(client, moveGoal);
	}
	if (IsPatroller(client) && !g_patrolArrived[client])
	{
		g_patrolArrived[client] = true;
		g_defendSwitch[client] = GetGameTime() + GetRandomFloat(5.0, 12.0);
		g_lookAround[client] = 0.0;
	}
	// Holding one of the main player's spots: copy how they held it (crouched or not) and where
	// they watched from it.
	int ls = -1;
	for (int k = 0; k < g_ln_spotCount; k++)
		if (GetVectorDistance(g_ln_spots[k], spot) < 64.0) { ls = k; break; }
	if (ls != -1 && g_ln_spotCrouch[ls])
		NavBotPlayerControllerInterface.PressButtonByID(bot.GetPlayerControllerInterface(), NAVBOT_BUTTON_CROUCH, 0.3);
	if (ls != -1 && g_ln_spotLookN[ls] > 0 && GetGameTime() >= g_lookAround[client])
	{
		g_lookAround[client] = GetGameTime() + GetRandomFloat(2.5, 5.0);
		float watch[3];
		watch = g_ln_spotLook[ls][GetRandomInt(0, g_ln_spotLookN[ls] - 1)];
		NavBotPlayerControllerInterface.AimAtPos(bot.GetPlayerControllerInterface(), watch, LOOK_SEARCH, 2.0, "Watching where the main player watched");
	}
	if (GetGameTime() >= g_lookAround[client])
	{
		// Watch one of the home's doors or windows, gun ready.
		g_lookAround[client] = GetGameTime() + GetRandomFloat(3.0, 5.0);
		int pick[MAX_OPENINGS], n = 0;
		for (int o = 0; o < g_openingCount; o++)
			if (g_openingHome[o] == h && FloatAbs(g_openingPos[o][2] - me[2]) < 200.0)
				pick[n++] = o;
		if (n > 0)
		{
			float watch[3];
			watch = g_openingPos[pick[GetRandomInt(0, n - 1)]];
			NavBotPlayerControllerInterface.AimAtPos(bot.GetPlayerControllerInterface(), watch, LOOK_SEARCH, 2.0, "Watching an entrance");
		}
	}
	strcopy(g_state[client], sizeof(g_state[]), "holding defend spot");
	return Hold(client);
}

// Maps with "patrol" in zps24_maps.cfg: this share of the survivor bots (picked by client index,
// so the same bots all round) walks from spot to spot instead of holding one.
bool IsPatroller(int client)
{
	return g_mapPatrol > 0.0 && float((client * 37) % 100) < g_mapPatrol * 100.0;
}

// Next patrol stop: a free spot 250-1500 units from where we are (another room or floor), so the
// patrol covers the building; any free spot if none is that far.
int PickPatrolSpot(int client, int h)
{
	float me[3];
	GetClientAbsOrigin(client, me);
	int pick[MAX_DEFEND], n = 0;
	for (int i = 0; i < g_defendCount[h]; i++)
	{
		float d = GetVectorDistance(me, g_defendPos[h][i]);
		if (d < 250.0 || d > 1500.0)
			continue;
		bool taken = false;
		for (int o = 1; o <= MaxClients && !taken; o++)
			taken = o != client && g_home[o] == h && g_defendIdx[o] % g_defendCount[h] == i && IsClientInGame(o) && IsPlayerAlive(o);
		if (!taken)
			pick[n++] = i;
	}
	return n > 0 ? pick[GetRandomInt(0, n - 1)] : PickFreeSpot(client, h, g_defendCount[h]);
}

// A random one of the home's best `top` spots that no other bot of the home holds, so they spread
// out and hide in different places; if all are taken, any of them.
int PickFreeSpot(int client, int h, int top)
{
	int free[MAX_DEFEND], n = 0;
	for (int i = 0; i < top; i++)
	{
		bool taken = false;
		for (int o = 1; o <= MaxClients && !taken; o++)
			taken = o != client && g_home[o] == h && g_defendIdx[o] % g_defendCount[h] == i && IsClientInGame(o) && IsPlayerAlive(o);
		if (!taken)
			free[n++] = i;
	}
	return n > 0 ? free[GetRandomInt(0, n - 1)] : GetRandomInt(0, top - 1);
}

// Bots that haven't moved for a second next to a closed door get it opened, exactly what E does.
// (Bots look at enemies and watch spots while walking, so a "press E on what I'm looking at" check
// misses doors right next to them.) Only doors with the "Use opens" flag; button doors stay shut.
void UnstickFromDoors()
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !IsFakeClient(client) || !IsPlayerAlive(client) || GetClientTeam(client) != TEAM_SURVIVORS)
			continue;
		float pos[3];
		GetClientAbsOrigin(client, pos);
		float moved = GetVectorDistance(pos, g_lastPos[client]);
		g_lastPos[client] = pos;
		if (moved > 20.0 || GetGameTime() < g_nextUse[client])
			continue;

		int door = -1, best = -1;
		float bestDist = 96.0;
		while ((door = FindEntityByClassname(door, "func_door_rotating")) != -1)
		{
			if ((GetEntProp(door, Prop_Data, "m_spawnflags") & 256) == 0 || GetEntProp(door, Prop_Data, "m_toggle_state") != 1)
				continue;   // not use-able, or not closed (1 = TS_AT_BOTTOM)
			float center[3];
			EntityCenter(door, center);
			float d = GetVectorDistance(pos, center);
			if (d < bestDist) { bestDist = d; best = door; }
		}
		if (best != -1)
		{
			AcceptEntityInput(best, "Open", client, client);   // rotating doors swing away from the activator
			g_nextUse[client] = GetGameTime() + 2.0;
			Debug("%N unstuck: opened door %d", client, best);
		}
	}
}

Action Timer_Think(Handle timer)
{
	if (g_enable.BoolValue)
	{
		UnstickFromDoors();
		AssignDoorClosers();
	}

	if (!g_enable.BoolValue || !LibraryExists("navbot") || !NavBotNavMesh.IsLoaded())
		return Plugin_Continue;
	if (GetGameTime() - g_roundStart < g_equipTime.FloatValue)
		return Plugin_Continue;                  // gear-up phase
	CheckOverrun();

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !IsPlayerAlive(client) || GetClientTeam(client) != TEAM_SURVIVORS || !NavBotManager.IsNavBot(client))
		{
			if (client <= MaxClients) { if (g_job[client] != JOB_NONE) ReleaseJob(client, false); g_scripted[client] = false; }
			continue;
		}
		NavBot bot = NavBotManager.GetNavBotByIndex(client);

		if (g_home[client] == -1)
			AssignHome(client);
		if (g_home[client] == -1)
			continue;

		RefillAmmo(client);
		HoldBestGun(client, bot);
		Unstick_Track(client, bot);

		// Out of gun ammo: release the bot for 20 s so NavBot restocks (only without unlimited ammo).
		if (!g_infiniteAmmo.BoolValue && g_restockUntil[client] < GetGameTime() && !HasGunAmmo(client))
		{
			g_restockUntil[client] = GetGameTime() + 20.0;
			if (g_job[client] != JOB_NONE) ReleaseJob(client, false);
			bot.SendPluginCommand(NAVBOT_PLUGINCMD_STOPCMD);
			Debug("%N restocking", client);
			continue;
		}
		if (g_restockUntil[client] > GetGameTime())
			continue;

		// Hand out barricade jobs.
		// Builders: a few per house; they take the build job whenever one of the main player's
		// boards in the house is missing (never built, or broken by zombies).
		if (!g_builder[client] && g_builders.IntValue > 0 && g_job[client] == JOB_NONE)
		{
			int all = 0, here = 0;
			for (int o = 1; o <= MaxClients; o++)
				if (g_builder[o] && IsClientInGame(o) && IsPlayerAlive(o))
				{
					all++;
					if (g_home[o] == g_home[client]) here++;
				}
			if (all < g_builders.IntValue && here == 0)   // a few in total, one per house
			{
				g_builder[client] = true;
				Debug("%N is a builder", client);
			}
		}
		if (g_builder[client] && g_job[client] == JOB_NONE && GetGameTime() >= g_buildRecheck[client])
		{
			g_buildRecheck[client] = GetGameTime() + 10.0;
			// No hammer yet (trade the melee weapon for one right away), or a board to put up.
			if (FindOwnedWeapon(client, "weapon_barricade") == -1 || NextBoardLesson(client) != -1)
			{
				g_job[client] = JOB_BUILD;
				g_buildLesson[client] = -1;
				g_jobStarted[client] = GetGameTime();
				Debug("%N builds the main player's boards", client);
			}
		}
		if (g_job[client] == JOB_NONE && !g_builder[client] && CountBarricaders(g_home[client]) < g_barricaders.IntValue)
		{
			int k = ClaimPlacement(client);
			if (k != -1)
			{
				g_job[client] = JOB_PLACE;
				g_jobPlace[client] = k;
				g_jobStarted[client] = GetGameTime();
				g_carryProp[client] = INVALID_ENT_REFERENCE;
				Debug("%N copies the main player's furniture placement %d", client, k);
			}
		}
		if (g_job[client] == JOB_NONE && !g_builder[client] && CountBarricaders(g_home[client]) < g_barricaders.IntValue)
		{
			int o = ClaimOpening(client);
			if (o != -1)
			{
				g_job[client] = JOB_BARRICADE;
				g_jobOpening[client] = o;
				g_jobStarted[client] = GetGameTime();
				g_aimTry[client] = 0;
				Debug("%N barricades opening %d", client, o);
			}
		}

		if (!g_scripted[client] || !NavBotBehaviorInterface.IsRunningPluginCommand(bot.GetBehaviorInterface()))
		{
			// A scripted task left over from a previous load of this plugin would keep calling a
			// dead callback and leave the bot idle. Stop whatever is running, then start ours.
			if (NavBotBehaviorInterface.IsRunningPluginCommand(bot.GetBehaviorInterface()))
			{
				bot.SendPluginCommand(NAVBOT_PLUGINCMD_STOPCMD);
				continue;   // start ours on the next tick
			}
			bot.SendScriptedPluginCommand(OnScriptedUpdate);
			g_scripted[client] = true;
			char task[256];
			NavBotBehaviorInterface.GetTaskDebugString(bot.GetBehaviorInterface(), task, sizeof(task));
			Debug("%N: scripted command sent, running=%d task=%s", client, NavBotBehaviorInterface.IsRunningPluginCommand(bot.GetBehaviorInterface()), task);
		}
	}
	return Plugin_Continue;
}

Action Cmd_Status(int args)
{
	int bots = 0, armed = 0;
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && IsFakeClient(i) && IsPlayerAlive(i) && GetClientTeam(i) == TEAM_SURVIVORS)
		{
			bots++;
			if (HasGun(i)) armed++;
		}
	PrintToServer("[zps24ai] survivor bots with a gun: %d/%d", armed, bots);
	if (g_homeCount == 0) { PrintToServer("[zps24ai] no homes yet"); return Plugin_Handled; }
	for (int h = 0; h < g_homeCount; h++)
	{
		int doors = 0, windows = 0, done = 0, defenders = 0;
		for (int o = 0; o < g_openingCount; o++)
		{
			if (g_openingHome[o] != h) continue;
			if (g_openingWindow[o]) windows++; else doors++;
			if (g_openingDone[o]) done++;
		}
		for (int i = 1; i <= MaxClients; i++)
			if (g_home[i] == h && IsClientInGame(i) && IsPlayerAlive(i)) defenders++;
		PrintToServer("[zps24ai] home %d%s at %.0f %.0f %.0f: %d bots, %d doors (%d done), %d windows, %d defend spots (%d upstairs), barricaders %d",
			h, g_homeValid[h] ? "" : " (abandoned)", g_homePos[h][0], g_homePos[h][1], g_homePos[h][2], defenders, doors, done, windows,
			g_defendCount[h], g_upperCount[h], CountBarricaders(h));
		for (int o = 0; o < g_openingCount && args > 0; o++)
		{
			if (g_openingHome[o] != h) continue;
			int e = g_openingEnt[o];
			char cls[64] = "?";
			float mins[3], maxs[3];
			if (IsValidEntity(e))
			{
				GetEntityClassname(e, cls, sizeof(cls));
				GetEntPropVector(e, Prop_Send, "m_vecMins", mins);
				GetEntPropVector(e, Prop_Send, "m_vecMaxs", maxs);
			}
			PrintToServer("    #%d %s %s at %.0f %.0f %.0f size %.0fx%.0fx%.0f mat %d", o, g_openingWindow[o] ? "window" : "door", cls,
				g_openingPos[o][0], g_openingPos[o][1], g_openingPos[o][2], maxs[0] - mins[0], maxs[1] - mins[1], maxs[2] - mins[2],
				IsValidEntity(e) && HasEntProp(e, Prop_Data, "m_Material") ? GetEntProp(e, Prop_Data, "m_Material") : -1);
		}
	}
	for (int i = 1; i <= MaxClients; i++)
	{
		if (g_job[i] != JOB_BARRICADE || !IsClientInGame(i))
			continue;
		int o = g_jobOpening[i];
		float me[3], stand[3], fdist;
		GetClientAbsOrigin(i, me);
		StandPoint(o, stand);
		NearestFreeBarricade(i, fdist);
		char active[64] = "-";
		int aw = GetEntPropEnt(i, Prop_Send, "m_hActiveWeapon");
		if (aw > 0) GetEntityClassname(aw, active, sizeof(active));
		PrintToServer("  %N -> door %d furniture %d | tool=%d nearest free tool %.0f | to stand %.0f | holding %s | aimtries %d",
			i, o, g_openingBoards[o], FindOwnedWeapon(i, "weapon_barricade") != -1, fdist, GetVectorDistance(me, stand), active, g_aimTry[i]);
	}
	return Plugin_Handled;
}


Action Cmd_Bots(int args)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsFakeClient(i) || !IsPlayerAlive(i) || GetClientTeam(i) != TEAM_SURVIVORS)
			continue;
		float me[3];
		GetClientAbsOrigin(i, me);
		char task[160] = "-", active[48] = "-";
		if (NavBotManager.IsNavBot(i))
			NavBotBehaviorInterface.GetTaskDebugString(NavBotManager.GetNavBotByIndex(i).GetBehaviorInterface(), task, sizeof(task));
		int aw = GetEntPropEnt(i, Prop_Send, "m_hActiveWeapon");
		if (aw > 0) GetEntityClassname(aw, active, sizeof(active));
		int h = g_home[i];
		char spot[48] = "";
		if (h >= 0 && g_defendCount[h] > 0)
		{
			int k = g_defendIdx[i] % g_defendCount[h];
			Format(spot, sizeof(spot), " -> spot %d (%.0f %.0f %.0f)%s", k, g_defendPos[h][k][0], g_defendPos[h][k][1], g_defendPos[h][k][2], IsPatroller(i) ? " patrol" : "");
		}
		PrintToServer("%N at %.0f %.0f %.0f home %d job %d%s%s | %s%s | stuck %.0f s | %s | %s", i, me[0], me[1], me[2], g_home[i], g_job[i],
			g_builder[i] ? " BUILDER" : "", FindOwnedWeapon(i, "weapon_barricade") != -1 ? " +hammer" : "",
			g_state[i], spot, Unstick_StuckFor(i), active, task);
	}
	return Plugin_Handled;
}

Action Cmd_Doors(int args)
{
	static const char classes[][] = { "func_door_rotating", "func_door", "prop_door_rotating" };
	for (int c = 0; c < sizeof(classes); c++)
	{
		int ent = -1;
		while ((ent = FindEntityByClassname(ent, classes[c])) != -1)
		{
			float center[3], mins[3], maxs[3], inside[3];
			EntityCenter(ent, center);
			GetEntPropVector(ent, Prop_Send, "m_vecMins", mins);
			GetEntPropVector(ent, Prop_Send, "m_vecMaxs", maxs);
			float sx = maxs[0] - mins[0], sy = maxs[1] - mins[1];
			float n[3], a[3], b[3];
			n[0] = sx < sy ? 1.0 : 0.0; n[1] = sx < sy ? 0.0 : 1.0;
			for (int i = 0; i < 3; i++) { a[i] = center[i] + n[i] * 48.0; b[i] = center[i] - n[i] * 48.0; }
			PrintToServer("%d %s at %.0f %.0f %.0f size %.0fx%.0fx%.0f headroom %.0f / %.0f exterior %d", ent, classes[c], center[0], center[1], center[2],
				sx, sy, maxs[2] - mins[2], SpaceAbove(a), SpaceAbove(b), IsExteriorOpening(ent, center, inside));
		}
	}
	return Plugin_Handled;
}

// Don't leave bots running a scripted task whose callback is about to disappear.
public void OnPluginEnd()
{
	if (!LibraryExists("navbot"))
		return;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client) && NavBotManager.IsNavBot(client) && g_scripted[client])
			NavBotManager.GetNavBotByIndex(client).SendPluginCommand(NAVBOT_PLUGINCMD_STOPCMD);
	}
}

// A builder's hammer click goes straight into its usercmd.
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
	if (client < 1 || client > MaxClients || !IsFakeClient(client))
		return Plugin_Continue;
	Action r = Plugin_Continue;
	// Hammering: no switching weapons (NavBot's own weapon choice put the hammer away right after
	// the click, which cancels the board).
	if (GetGameTime() < g_hammerUntil[client] + 1.0 && weapon != 0)
	{
		weapon = 0;
		r = Plugin_Changed;
	}
	if (GetGameTime() < g_clickUntil[client])
	{
		buttons |= IN_ATTACK;
		r = Plugin_Changed;
	}
	return r;
}
