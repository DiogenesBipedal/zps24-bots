// ZPS 2.4 survivor brain for NavBot bots.
//
// NavBot's ZPS survivor AI only roams. This plugin gives survivor bots the classic 2.4 game plan:
//
//   1. Gear up    (first sm_zps24ai_equip_time seconds of a round): NavBot runs on its own and
//                 collects weapons and ammo (with E).
//   2. Hold out   The team picks one building (the densest cluster of doors and windows) and goes
//                 there. Up to sm_zps24ai_barricaders bots fetch a weapon_barricade and board up the
//                 building's doors and windows, asking the game's own CWeapon_Barricade::
//                 CanAttachBarricade() whether a board fits before hammering.
//   3. Defend     Everyone else holds the spot; NavBot's combat code does the shooting.
//
// Always: a bot holding a gun backs away from zombies closer than sm_zps24ai_safe_distance, opens
// closed doors in front of it with E, and gets released to restock when it runs out of ammo.
//
// Bots are steered through NavBot's scripted plugin command: OnScriptedUpdate() runs every bot
// update and returns where the bot should walk.
#include <sourcemod>
#include <sdktools>
#include <navbot>

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

ConVar g_enable, g_equipTime, g_radius, g_safeDist, g_barricaders, g_boardsPerOpening, g_debug, g_upperHeight, g_furniture;

Handle g_canAttach;               // SDKCall: bool CWeapon_Barricade::CanAttachBarricade()

// The team's hold-out and the openings (doors/windows) around it.
bool  g_haveHoldout;
float g_holdout[3];
int   g_openingCount;
float g_openingPos[MAX_OPENINGS][3];
int   g_openingBoards[MAX_OPENINGS];     // boards successfully placed
int   g_openingClaim[MAX_OPENINGS];      // client working on it (0 = nobody)
bool  g_openingDone[MAX_OPENINGS];
float g_roundStart;

// Defend spots inside the hold-out: upper floors / roofs / balconies first, then corners.
#define MAX_DEFEND 32
int   g_defendCount;
float g_defendPos[MAX_DEFEND][3];

// Per-bot state
enum BotJob { JOB_NONE, JOB_BARRICADE }
BotJob g_job[MAXPLAYERS + 1];
int    g_jobOpening[MAXPLAYERS + 1];
float  g_jobStarted[MAXPLAYERS + 1];
int    g_aimTry[MAXPLAYERS + 1];
int    g_carryProp[MAXPLAYERS + 1];      // furniture being carried (entity reference) or INVALID_ENT_REFERENCE
float  g_carryStarted[MAXPLAYERS + 1];
float  g_nextUse[MAXPLAYERS + 1];
float  g_restockUntil[MAXPLAYERS + 1];
bool   g_scripted[MAXPLAYERS + 1];

static const char g_guns[][] = { "weapon_glock", "weapon_glock18c", "weapon_usp", "weapon_ppk", "weapon_revolver",
	"weapon_870", "weapon_supershorty", "weapon_winchester", "weapon_ak47", "weapon_m4", "weapon_mp5" };

public void OnPluginStart()
{
	g_enable           = CreateConVar("sm_zps24ai_enable", "1", "Enable the ZPS 2.4 survivor AI");
	g_equipTime        = CreateConVar("sm_zps24ai_equip_time", "30", "Seconds at round start bots spend collecting weapons/ammo before holding out");
	g_radius           = CreateConVar("sm_zps24ai_holdout_radius", "550", "Doors/windows within this distance of the hold-out get barricaded");
	g_safeDist         = CreateConVar("sm_zps24ai_safe_distance", "260", "Bots with guns back away from zombies closer than this");
	g_barricaders      = CreateConVar("sm_zps24ai_barricaders", "3", "How many survivor bots barricade at once");
	g_boardsPerOpening = CreateConVar("sm_zps24ai_boards", "3", "Boards to put on each door/window");
	g_debug            = CreateConVar("sm_zps24ai_debug", "0", "Log AI decisions");
	g_upperHeight      = CreateConVar("sm_zps24ai_upper_height", "80", "Nav areas this much above the hold-out floor count as upper floor / roof / balcony");
	g_furniture        = CreateConVar("sm_zps24ai_furniture", "1", "Barricaders without a barricade tool carry furniture to the openings");
	AutoExecConfig(true, "zps24_survivors");

	GameData gd = new GameData("zps24_ai.games");
	if (gd == null)
		SetFailState("Missing gamedata zps24_ai.games.txt");
	StartPrepSDKCall(SDKCall_Entity);
	if (!PrepSDKCall_SetFromConf(gd, SDKConf_Signature, "CanAttachBarricade"))
		SetFailState("CanAttachBarricade not found");
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
	g_canAttach = EndPrepSDKCall();
	delete gd;

	HookEventEx("game_round_restart", Event_RoundRestart, EventHookMode_PostNoCopy);
	RegServerCmd("sm_zps24ai_status", Cmd_Status, "Show the hold-out and barricade progress");
	ResetRound();
}

public void OnMapStart()
{
	ResetRound();
	CreateTimer(1.0, Timer_Think, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void Event_RoundRestart(Event event, const char[] name, bool dontBroadcast)
{
	ResetRound();
}

void ResetRound()
{
	g_haveHoldout = false;
	g_openingCount = 0;
	g_defendCount = 0;
	g_roundStart = GetGameTime();
	for (int i = 0; i <= MaxClients; i++)
	{
		g_job[i] = JOB_NONE;
		g_carryProp[i] = INVALID_ENT_REFERENCE;
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
	PrintToServer("[zps24ai] %s", buf);
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

int CollectOpenings(float pos[][3], int max)
{
	static const char classes[][] = { "func_door_rotating", "func_door", "prop_door_rotating", "func_breakable_surf", "func_breakable" };
	int n = 0;
	for (int c = 0; c < sizeof(classes); c++)
	{
		int ent = -1;
		while ((ent = FindEntityByClassname(ent, classes[c])) != -1 && n < max)
		{
			EntityCenter(ent, pos[n]);
			n++;
		}
	}
	return n;
}

void ChooseHoldout()
{
	float all[MAX_OPENINGS * 4][3];
	int count = CollectOpenings(all, sizeof(all));
	if (count == 0)
		return;

	// The opening with the most other openings nearby marks the most enclosed building.
	float r = g_radius.FloatValue;
	int best = -1, bestScore = -1;
	for (int i = 0; i < count; i++)
	{
		int score = 0;
		for (int j = 0; j < count; j++)
			if (GetVectorDistance(all[i], all[j]) <= r)
				score++;
		if (score > bestScore) { bestScore = score; best = i; }
	}

	// Hold-out = average of that cluster, snapped to the nav mesh.
	float sum[3];
	int members = 0;
	g_openingCount = 0;
	for (int j = 0; j < count; j++)
	{
		if (GetVectorDistance(all[best], all[j]) > r)
			continue;
		AddVectors(sum, all[j], sum);
		members++;
		if (g_openingCount < MAX_OPENINGS)
		{
			g_openingPos[g_openingCount] = all[j];
			g_openingBoards[g_openingCount] = 0;
			g_openingClaim[g_openingCount] = 0;
			g_openingDone[g_openingCount] = false;
			g_openingCount++;
		}
	}
	ScaleVector(sum, 1.0 / float(members));

	Address area = NavBotNavMesh.GetNearestNavArea(sum, 600.0, false, true);
	if (area == Address_Null)
		return;
	NavBotNavArea.GetCenter(area, g_holdout);
	g_haveHoldout = true;
	BuildDefendSpots(area);
	Debug("Hold-out at %.0f %.0f %.0f with %d openings", g_holdout[0], g_holdout[1], g_holdout[2], g_openingCount);
}

// Rank the hold-out building's walkable areas: highest first (upper floors, roofs, balconies),
// then "corners" (areas with few neighbours). Each defending bot gets its own spot.
void BuildDefendSpots(Address start)
{
	NavBotNavAreaCollector c = new NavBotNavAreaCollector();
	c.SetSearchStartArea(start);
	c.TravelLimit = g_radius.FloatValue * 1.6;
	c.SearchLadder = true;
	c.Execute();
	NavBotNavAreaVector v = c.GetCollectedAreas();
	delete c;

	int n = v.Size;
	float scores[512], centers[512][3];
	if (n > 512) n = 512;
	float floorZ = 999999.0;          // the building's ground floor = lowest collected area
	for (int i = 0; i < n; i++)
	{
		NavBotNavArea.GetCenter(v.At(i), centers[i]);
		if (centers[i][2] < floorZ) floorZ = centers[i][2];
	}
	for (int i = 0; i < n; i++)
	{
		Address a = v.At(i);
		float height = centers[i][2] - floorZ;
		int neighbours = 0;
		for (int d = 0; d < 4; d++)
			neighbours += NavBotNavArea.GetAdjacentAreaCount(a, view_as<NavBotNavDirType>(d));
		// Elevation dominates; few neighbours (a corner) breaks ties; stay close to the building.
		scores[i] = (height >= g_upperHeight.FloatValue ? 1000.0 + height : 0.0)
			+ (neighbours <= 2 ? 200.0 : 0.0)
			- GetVectorDistance(centers[i], g_holdout) * 0.2;
	}
	delete v;

	// Pick the best MAX_DEFEND spots, at least 96 units apart so bots don't stack.
	g_defendCount = 0;
	bool used[512];
	while (g_defendCount < MAX_DEFEND)
	{
		int best = -1;
		for (int i = 0; i < n; i++)
		{
			if (used[i] || (best != -1 && scores[i] <= scores[best]))
				continue;
			bool tooClose = false;
			for (int k = 0; k < g_defendCount; k++)
				if (GetVectorDistance(centers[i], g_defendPos[k]) < 96.0) { tooClose = true; break; }
			if (!tooClose)
				best = i;
		}
		if (best == -1)
			break;
		used[best] = true;
		g_defendPos[g_defendCount] = centers[best];
		g_defendCount++;
	}
	Debug("%d defend spots (best %.0f units above the ground floor)", g_defendCount, g_defendCount ? g_defendPos[0][2] - floorZ : 0.0);
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

	if (StrContains(cls, "breakable") != -1 || StrContains(cls, "prop_physics") != -1 || StrContains(cls, "physbox") != -1
		|| StrContains(cls, "barricade") != -1)
		return Plugin_Handled;   // walk around it instead of smashing it

	return Plugin_Continue;
}

// ---------------------------------------------------------------------------------------------
// Barricading

int ClaimOpening(int client)
{
	float me[3];
	GetClientAbsOrigin(client, me);
	int best = -1;
	float bestDist = 999999.0;
	for (int i = 0; i < g_openingCount; i++)
	{
		if (g_openingDone[i] || (g_openingClaim[i] != 0 && g_openingClaim[i] != client))
			continue;
		float d = GetVectorDistance(me, g_openingPos[i]);
		if (d < bestDist) { bestDist = d; best = i; }
	}
	if (best != -1)
		g_openingClaim[best] = client;
	return best;
}

int CountBarricaders()
{
	int n = 0;
	for (int i = 1; i <= MaxClients; i++)
		if (g_job[i] == JOB_BARRICADE && IsClientInGame(i) && IsPlayerAlive(i))
			n++;
	return n;
}

void ReleaseJob(int client, bool done)
{
	int o = g_jobOpening[client];
	if (g_job[client] == JOB_BARRICADE && o >= 0 && o < g_openingCount)
	{
		g_openingClaim[o] = 0;
		if (done)
			g_openingDone[o] = true;
	}
	g_job[client] = JOB_NONE;
	g_carryProp[client] = INVALID_ENT_REFERENCE;
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
	SubtractVectors(g_holdout, g_openingPos[o], dir);
	dir[2] = 0.0;
	NormalizeVector(dir, dir);
	ScaleVector(dir, 56.0);
	float raw[3];
	AddVectors(g_openingPos[o], dir, raw);
	SnapToNav(raw, out);
}

// Light physics props near an opening that a survivor can carry with E.
int FindFurniture(const float near[3], float maxDist)
{
	static const char classes[][] = { "prop_physics_multiplayer", "prop_physics", "prop_physics_override", "prop_physics_respawnable" };
	int best = -1;
	float bestDist = maxDist;
	for (int c = 0; c < sizeof(classes); c++)
	{
		int ent = -1;
		while ((ent = FindEntityByClassname(ent, classes[c])) != -1)
		{
			if (GetEntPropEnt(ent, Prop_Send, "m_hOwnerEntity") != -1)
				continue;
			float mins[3], maxs[3], pos[3];
			GetEntPropVector(ent, Prop_Send, "m_vecMins", mins);
			GetEntPropVector(ent, Prop_Send, "m_vecMaxs", maxs);
			// Skip tiny clutter and huge objects; furniture is roughly crate/chair/table sized.
			float size = (maxs[0] - mins[0]) + (maxs[1] - mins[1]) + (maxs[2] - mins[2]);
			if (size < 40.0 || size > 220.0)
				continue;
			GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", pos);
			if (FloatAbs(pos[2] - near[2]) > 120.0)     // same floor
				continue;
			float d = GetVectorDistance(pos, near);
			if (d < bestDist) { bestDist = d; best = ent; }
		}
	}
	return best;
}

// Carry a piece of furniture to the opening with E and drop it there.
bool DoFurniture(int client, NavBot bot, float moveGoal[3])
{
	int o = g_jobOpening[client];
	Address ctrl = bot.GetPlayerControllerInterface();
	float me[3], stand[3];
	GetClientAbsOrigin(client, me);
	StandPoint(o, stand);

	int prop = EntRefToEntIndex(g_carryProp[client]);
	if (prop == INVALID_ENT_REFERENCE)
	{
		prop = FindFurniture(g_openingPos[o], 700.0);
		if (prop == -1)
		{
			ReleaseJob(client, true);   // nothing to use here
			return false;
		}
		g_carryProp[client] = EntIndexToEntRef(prop);
		g_carryStarted[client] = 0.0;
	}

	float propPos[3];
	GetEntPropVector(prop, Prop_Data, "m_vecAbsOrigin", propPos);
	bool carrying = g_carryStarted[client] > 0.0 && GetVectorDistance(propPos, me) < 110.0;

	if (!carrying)
	{
		// Furniture already at the opening counts as a barricade.
		if (GetVectorDistance(propPos, g_openingPos[o]) < 70.0)
		{
			g_carryProp[client] = INVALID_ENT_REFERENCE;
			g_openingBoards[o]++;
			if (g_openingBoards[o] >= g_boardsPerOpening.IntValue)
				ReleaseJob(client, true);
			return false;
		}
		SnapToNav(propPos, moveGoal);
		if (GetVectorDistance(me, propPos) < 100.0 && GetGameTime() >= g_nextUse[client])
		{
			NavBotPlayerControllerInterface.AimAtEntity(ctrl, prop, LOOK_USE, 0.6, "Picking up furniture");
			NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_USE, 0.2);
			g_nextUse[client] = GetGameTime() + 1.0;
			g_carryStarted[client] = GetGameTime();
		}
		return true;
	}

	// Carrying: walk to the opening, then drop it in the gap.
	moveGoal = stand;
	if (GetVectorDistance(me, stand) > 60.0 && GetGameTime() - g_carryStarted[client] < 25.0)
		return true;
	NavBotPlayerControllerInterface.AimAtPos(ctrl, g_openingPos[o], LOOK_PRIORITY, 0.6, "Placing furniture");
	if (NavBotPlayerControllerInterface.IsAimOnTarget(ctrl) && GetGameTime() >= g_nextUse[client])
	{
		NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_USE, 0.2);   // drop
		g_nextUse[client] = GetGameTime() + 1.0;
		g_carryStarted[client] = 0.0;
		g_openingBoards[o]++;
		Debug("%N placed furniture at opening %d", client, o);
		if (g_openingBoards[o] >= g_boardsPerOpening.IntValue)
			ReleaseJob(client, true);
		g_carryProp[client] = INVALID_ENT_REFERENCE;
	}
	return false;
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

	// 1. Get a barricade tool if we don't have one.
	int tool = FindOwnedWeapon(client, "weapon_barricade");
	if (tool == -1)
	{
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
	if (GetEntProp(tool, Prop_Send, "m_iClip1") <= 0 && GetEntProp(client, Prop_Send, "m_iAmmo", _, AMMO_BARRICADE) <= 0)
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
	if (GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon") != tool)
	{
		bot.DelayedFakeClientCommand("use weapon_barricade");
		return false;
	}

	static const float offsets[][3] = { {0.0, 0.0, 0.0}, {0.0, 0.0, 20.0}, {0.0, 0.0, -20.0}, {0.0, 0.0, 36.0}, {0.0, 0.0, -36.0} };
	float aim[3];
	int t = g_aimTry[client] % sizeof(offsets);
	AddVectors(g_openingPos[o], offsets[t], aim);

	Address ctrl = bot.GetPlayerControllerInterface();
	NavBotPlayerControllerInterface.AimAtPos(ctrl, aim, LOOK_PRIORITY, 0.5, "Barricading");
	if (!NavBotPlayerControllerInterface.IsAimOnTarget(ctrl))
		return false;

	if (SDKCall(g_canAttach, tool))
	{
		NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_ATTACKPRIM, 0.4);
		g_openingBoards[o]++;
		Debug("%N boards opening %d (%d/%d)", client, o, g_openingBoards[o], g_boardsPerOpening.IntValue);
		if (g_openingBoards[o] >= g_boardsPerOpening.IntValue)
			ReleaseJob(client, true);
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
// Main loop

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

	OpenDoorAhead(client, bot);
	float me[3];
	GetClientAbsOrigin(client, me);

	// Keep a safe distance from zombies while holding a gun.
	float zdist;
	int zombie = NearestZombie(client, g_safeDist.FloatValue, zdist);
	if (zombie && IsGun(GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon")))
	{
		float them[3], away[3];
		GetClientAbsOrigin(zombie, them);
		SubtractVectors(me, them, away);
		away[2] = 0.0;
		NormalizeVector(away, away);
		ScaleVector(away, 200.0);
		AddVectors(me, away, moveGoal);
		routeType = NAVBOT_FASTEST_ROUTE;
		return Plugin_Changed;
	}

	if (g_job[client] == JOB_BARRICADE)
	{
		if (DoBarricade(client, bot, moveGoal))
		{
			routeType = NAVBOT_SAFEST_ROUTE;
			return Plugin_Changed;
		}
		return Plugin_Continue;
	}

	// Defend: each bot holds its own spot (upper floor / roof / balcony / corner) and shoots from there.
	float spot[3];
	spot = g_holdout;
	if (g_defendCount > 0)
		spot = g_defendPos[client % g_defendCount];
	if (GetVectorDistance(me, spot) > 64.0)
	{
		moveGoal = spot;
		routeType = NAVBOT_SAFEST_ROUTE;
		return Plugin_Changed;
	}
	return Plugin_Continue;
}

Action Timer_Think(Handle timer)
{
	if (!g_enable.BoolValue || !LibraryExists("navbot") || !NavBotNavMesh.IsLoaded())
		return Plugin_Continue;
	if (GetGameTime() - g_roundStart < g_equipTime.FloatValue)
		return Plugin_Continue;                  // gear-up phase
	if (!g_haveHoldout)
		ChooseHoldout();
	if (!g_haveHoldout)
		return Plugin_Continue;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !IsPlayerAlive(client) || GetClientTeam(client) != TEAM_SURVIVORS || !NavBotManager.IsNavBot(client))
		{
			if (client <= MaxClients) { if (g_job[client] != JOB_NONE) ReleaseJob(client, false); g_scripted[client] = false; }
			continue;
		}
		NavBot bot = NavBotManager.GetNavBotByIndex(client);

		// Out of gun ammo: release the bot for 20 s so NavBot restocks.
		if (g_restockUntil[client] < GetGameTime() && !HasGunAmmo(client))
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
		if (g_job[client] == JOB_NONE && CountBarricaders() < g_barricaders.IntValue)
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
	if (!g_haveHoldout) { PrintToServer("[zps24ai] no hold-out yet"); return Plugin_Handled; }
	int done = 0;
	for (int i = 0; i < g_openingCount; i++) if (g_openingDone[i]) done++;
	PrintToServer("[zps24ai] hold-out %.0f %.0f %.0f, openings %d done %d, barricaders %d", g_holdout[0], g_holdout[1], g_holdout[2], g_openingCount, done, CountBarricaders());
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
		PrintToServer("  %N -> opening %d boards %d | tool=%d nearest free tool %.0f | to stand %.0f | holding %s | aimtries %d",
			i, o, g_openingBoards[o], FindOwnedWeapon(i, "weapon_barricade") != -1, fdist, GetVectorDistance(me, stand), active, g_aimTry[i]);
	}
	return Plugin_Handled;
}
