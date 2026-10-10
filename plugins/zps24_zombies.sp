// ZPS 2.4 zombie brain for NavBot bots.
//
// NavBot's ZPS zombies roam the map, including empty buildings. This plugin:
//   - sends zombie bots towards living survivors (each zombie picks one of the closest few, so
//     they spread over the survivors' positions instead of all chasing one), ignoring empty areas;
//   - when a zombie hasn't moved for a while next to a barricade board, window, breakable or piece
//     of furniture, makes it attack that obstacle until it breaks.
// NavBot's combat code still does the fighting once a survivor is in reach.
#include <sourcemod>
#include <sdktools>
#include <navbot>
#include "include/zps24_unstick.inc"
#include "include/zps24_stairs.inc"

public Plugin myinfo =
{
	name = "ZPS 2.4 zombie AI",
	author = "Dead Apocalypse",
	description = "Zombies hunt survivors and break barricades",
	version = "1.0"
};

#define TEAM_SURVIVORS 2
#define TEAM_ZOMBIES   3

ConVar g_enable, g_debug, g_forceTarget;
bool   g_scripted[MAXPLAYERS + 1];
int    g_target[MAXPLAYERS + 1];
float  g_retarget[MAXPLAYERS + 1];
float  g_lastPos[MAXPLAYERS + 1][3];
float  g_stuckSince[MAXPLAYERS + 1];
int    g_smash[MAXPLAYERS + 1];          // entity reference of the obstacle being attacked
float  g_smashUntil[MAXPLAYERS + 1];
int    g_smashHealth[MAXPLAYERS + 1];    // obstacle health when we started hitting it
int    g_shove[MAXPLAYERS + 1];          // furniture being shoved out of the way (entity reference)
float  g_shoveUntil[MAXPLAYERS + 1];
float  g_shoveFrom[MAXPLAYERS + 1][3];   // where it was when we started
float  g_nextShove[MAXPLAYERS + 1];
int    g_place[MAXPLAYERS + 1] = { -1, ... };   // learned zombie furniture placement this bot is setting up
float  g_placeStarted[MAXPLAYERS + 1];
int    g_placeBy[LEARN_MAX_PLACES];      // zombie setting it up this round (0 = nobody)
bool   g_placeDone[LEARN_MAX_PLACES];
bool   g_doorsLinked;                    // nav areas on both sides of every door connected (once per map)
int    g_fixed[32];                      // furniture no zombie could move (shared by the horde)
int    g_fixedCount;
// Breaking into a building through a chosen entrance (door, window, or one learned from the
// main player), spread over the horde so they don't all queue at the same door.
bool   g_hasEntry[MAXPLAYERS + 1];
float  g_entryOut[MAXPLAYERS + 1][3];    // where to stand outside
float  g_entryIn[MAXPLAYERS + 1][3];     // a point just inside
float  g_entryInUntil[MAXPLAYERS + 1];   // pushing through to the inside point until then
float  g_entryCooldown[MAXPLAYERS + 1];
float  g_entryChosen[MAXPLAYERS + 1];
int    g_ignore[MAXPLAYERS + 1][4];      // obstacles that didn't break when hit (entity refs)
float  g_ignoreUntil[MAXPLAYERS + 1][4];
float  g_goal[MAXPLAYERS + 1][3];        // where we're heading to reach g_target
float  g_goalTarget[MAXPLAYERS + 1][3];  // the target's position when g_goal was chosen
float  g_goalTime[MAXPLAYERS + 1];
float  g_blockedSince[MAXPLAYERS + 1];   // at the goal, but the target is behind a wall
Address g_deadEnd[MAXPLAYERS + 1][4];    // goal areas that turned out to be dead ends
float  g_deadEndUntil[MAXPLAYERS + 1][4];

public void OnPluginStart()
{
	g_enable = CreateConVar("sm_zps24zombies_enable", "1", "Enable the ZPS 2.4 zombie AI");
	g_debug  = CreateConVar("sm_zps24zombies_debug", "0", "Log zombie AI decisions");
	g_forceTarget = CreateConVar("sm_zps24zombies_force_target", "0", "Debug: every zombie hunts this client index (0 = normal)");
	RegServerCmd("sm_zps24_doorlinks", Cmd_DoorLinks, "Connect the nav areas on both sides of every door again and report");
	AutoExecConfig(true, "zps24_zombies");
	HookEventEx("game_round_restart", Event_RoundRestart, EventHookMode_PostNoCopy);
}

void Event_RoundRestart(Event event, const char[] name, bool dontBroadcast)
{
	g_fixedCount = 0;                   // props respawn every round
	Stairs_Relearn();
	ResetPlacements();
}

public void OnMapStart()
{
	for (int i = 0; i <= MaxClients; i++)
	{
		g_scripted[i] = false;
		g_smash[i] = INVALID_ENT_REFERENCE;
		g_shove[i] = INVALID_ENT_REFERENCE;
		g_hasEntry[i] = false;
		g_fixedCount = 0;
		g_entryInUntil[i] = 0.0;
		g_entryCooldown[i] = 0.0;
		g_goalTime[i] = 0.0;
		g_blockedSince[i] = 0.0;
		for (int k = 0; k < 4; k++)
			g_deadEndUntil[i][k] = 0.0;
		Unstick_Reset(i);
	}
	Stairs_OnMapStart();
	ResetPlacements();
	g_doorsLinked = false;
	CreateTimer(0.5, Timer_Think, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void Debug(const char[] fmt, any ...)
{
	if (!g_debug.BoolValue)
		return;
	char buf[256];
	VFormat(buf, sizeof(buf), fmt, 2);
	PrintToServer("[zps24zombies] %s", buf);
}

bool IsLiveSurvivor(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client) && IsPlayerAlive(client) && GetClientTeam(client) == TEAM_SURVIVORS;
}

// One of the three closest survivors, so the horde spreads over where survivors actually are.
int PickTarget(int zombie)
{
	float me[3], pos[3];
	GetClientAbsOrigin(zombie, me);
	int ids[MAXPLAYERS];
	float dist[MAXPLAYERS];
	int n = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsLiveSurvivor(i))
			continue;
		GetClientAbsOrigin(i, pos);
		ids[n] = i;
		dist[n] = GetVectorDistance(me, pos);
		n++;
	}
	if (n == 0)
		return 0;
	// partial selection sort for the 3 nearest
	int k = n < 3 ? n : 3;
	for (int a = 0; a < k; a++)
		for (int b = a + 1; b < n; b++)
			if (dist[b] < dist[a])
			{
				float td = dist[a]; dist[a] = dist[b]; dist[b] = td;
				int ti = ids[a]; ids[a] = ids[b]; ids[b] = ti;
			}
	return ids[GetRandomInt(0, k - 1)];
}

// Walls only: players and props don't block the view for this purpose.
bool CanSee(int a, int b)
{
	float from[3], to[3];
	GetClientEyePosition(a, from);
	GetClientEyePosition(b, to);
	TR_TraceRay(from, to, MASK_SOLID_BRUSHONLY, RayType_EndPoint);
	return !TR_DidHit();
}

bool IsDeadEnd(int client, Address area)
{
	for (int k = 0; k < 4; k++)
		if (g_deadEnd[client][k] == area && GetGameTime() < g_deadEndUntil[client][k])
			return true;
	return false;
}

void MarkDeadEnd(int client, Address area)
{
	int slot = 0;
	for (int k = 1; k < 4; k++)
		if (g_deadEndUntil[client][k] < g_deadEndUntil[client][slot])
			slot = k;
	g_deadEnd[client][slot] = area;
	g_deadEndUntil[client][slot] = GetGameTime() + 20.0;
}

// Where to walk to reach a survivor. Aim at the survivor's own floor: the raw position snaps to
// whatever nav area is nearest, which for someone upstairs is often the floor below, and for
// someone hiding where the mesh doesn't reach (a closet, on furniture, a nook) is often the room
// on the other side of a wall. Only spots the survivor can be seen from count; failing that,
// the last area the survivor stood on, which is the way they came in.
void ComputeGoal(int client, int target, float goal[3])
{
	float pos[3], eye[3], probe[3], spot[3];
	GetClientAbsOrigin(target, pos);
	GetClientEyePosition(target, eye);
	probe = pos;
	probe[2] += 16.0;

	Address area = NavBotNavMesh.GetNearestNavArea(probe, 150.0, true, true);
	if (area != Address_Null && !IsDeadEnd(client, area))
	{
		NavBotNavArea.GetClosestPointOnArea(area, pos, goal);
		return;
	}

	float mins[3], maxs[3];
	mins[0] = pos[0] - 320.0; mins[1] = pos[1] - 320.0; mins[2] = pos[2] - 100.0;
	maxs[0] = pos[0] + 320.0; maxs[1] = pos[1] + 320.0; maxs[2] = pos[2] + 100.0;
	NavBotNavAreaVector areas = NavBotNavMesh.CollectAreasOverlappingExtent(mins, maxs);
	Address best = Address_Null;
	float bestDist = 1.0e9;
	for (int i = 0; i < areas.Size; i++)
	{
		Address a = areas.At(i);
		if (IsDeadEnd(client, a))
			continue;
		NavBotNavArea.GetClosestPointOnArea(a, pos, spot);
		float d = GetVectorDistance(spot, pos);
		if (d >= bestDist || !NavBotNavArea.IsVisible(a, eye))
			continue;
		best = a;
		bestDist = d;
		goal = spot;
	}
	delete areas;
	if (best != Address_Null)
		return;

	NavBotBasePlayer player = NavBotManager.GetBasePlayer(target);
	if (!player.IsNull)
	{
		Address last = player.GetLastKnownNavArea();
		if (last != Address_Null && !IsDeadEnd(client, last))
		{
			NavBotNavArea.GetClosestPointOnArea(last, pos, goal);
			return;
		}
	}
	goal = pos;
}

// How many other zombies already use this entrance.
int EntryLoad(int client, const float out[3])
{
	int n = 0;
	for (int i = 1; i <= MaxClients; i++)
		if (i != client && g_hasEntry[i] && GetVectorDistance(g_entryOut[i], out) < 80.0 && IsClientInGame(i) && IsPlayerAlive(i))
			n++;
	return n;
}

// Pick a way into the building the target is in: the main player's entrances (as a zombie) and
// the doors and windows near the target. The cost is the distance from the entrance to the
// target, minus a bonus for learned entrances (more for ones used often), plus a penalty for
// each zombie already going through it.
bool ChooseEntry(int client, const float target[3])
{
	float me[3];
	GetClientAbsOrigin(client, me);
	float bestCost = 999999.0;
	bool found = false;

	for (int e = 0; e < g_ln_entryCount; e++)
	{
		float d = GetVectorDistance(g_ln_entryIn[e], target);
		if (d > 700.0)
			continue;
		int uses = g_ln_entryUses[e] > 5 ? 5 : g_ln_entryUses[e];
		float cost = d - 200.0 - 60.0 * float(uses) + 300.0 * float(EntryLoad(client, g_ln_entryOut[e]));
		if (cost < bestCost)
		{
			bestCost = cost;
			found = true;
			g_entryOut[client] = g_ln_entryOut[e];
			g_entryIn[client] = g_ln_entryIn[e];
		}
	}

	static const char classes[][] = { "func_door_rotating", "prop_door_rotating", "func_door", "func_breakable", "func_breakable_surf" };
	for (int c = 0; c < sizeof(classes); c++)
	{
		int ent = -1;
		while ((ent = FindEntityByClassname(ent, classes[c])) != -1)
		{
			float center[3];
			CenterOf(ent, center);
			float d = GetVectorDistance(center, target);
			if (d > 600.0 || FloatAbs(center[2] - target[2]) > 160.0)
				continue;
			// The outside point is on our side of it, the inside point on the far side.
			float dir[3], out[3], inside[3];
			SubtractVectors(me, center, dir);
			dir[2] = 0.0;
			NormalizeVector(dir, dir);
			for (int i = 0; i < 3; i++) { out[i] = center[i] + dir[i] * 64.0; inside[i] = center[i] - dir[i] * 64.0; }
			out[2] = center[2] - 30.0;
			inside[2] = center[2] - 30.0;
			if (Learned_Indoors(out) || !Learned_Indoors(inside))
				continue;                   // not a way from outside to inside
			Address area = NavBotNavMesh.GetNearestNavArea(out, 100.0, false, true);
			if (area == Address_Null)
				continue;
			NavBotNavArea.GetClosestPointOnArea(area, out, out);
			float cost = d + 300.0 * float(EntryLoad(client, out));
			if (cost < bestCost)
			{
				bestCost = cost;
				found = true;
				g_entryOut[client] = out;
				g_entryIn[client] = inside;
			}
		}
	}
	g_hasEntry[client] = found;
	g_entryChosen[client] = GetGameTime();
	if (found)
		Debug("%N attacks through the entrance at %.0f %.0f %.0f (%d others there)", client,
			g_entryOut[client][0], g_entryOut[client][1], g_entryOut[client][2], EntryLoad(client, g_entryOut[client]));
	return found;
}

// Breaking in: walk to the chosen entrance, then push through it (whatever is in the way gets
// smashed or shoved by the obstacle code). Returns true when it set moveGoal.
bool UpdateEntry(int client, const float me[3], const float target[3], bool sees, float moveGoal[3])
{
	if (GetGameTime() < g_entryInUntil[client])
	{
		moveGoal = g_entryIn[client];
		if (GetVectorDistance(me, g_entryIn[client]) > 40.0)
			return true;
		g_entryInUntil[client] = 0.0;       // inside: hunt normally
		return false;
	}
	// Only from outside, for a target indoors and out of sight.
	if (sees || Learned_Indoors(me) || !Learned_Indoors(target) || GetVectorDistance(me, target) < 250.0
		|| GetGameTime() < g_entryCooldown[client])
	{
		g_hasEntry[client] = false;
		return false;
	}
	if (!g_hasEntry[client] || GetGameTime() - g_entryChosen[client] > 30.0)
	{
		if (!ChooseEntry(client, target))
		{
			g_entryCooldown[client] = GetGameTime() + 5.0;
			return false;
		}
	}
	if (GetVectorDistance(me, g_entryOut[client]) > 60.0)
	{
		moveGoal = g_entryOut[client];
		return true;
	}
	// At the entrance: through it.
	g_hasEntry[client] = false;
	g_entryInUntil[client] = GetGameTime() + 8.0;
	g_entryCooldown[client] = GetGameTime() + 20.0;
	moveGoal = g_entryIn[client];
	return true;
}

// Can this entity actually be broken? Big metal furniture is often a prop_physics with no
// breakable data (no health, takes no damage); hitting it forever is what got zombies stuck.
bool CanBreak(int ent)
{
	if (HasEntProp(ent, Prop_Data, "m_takedamage") && GetEntProp(ent, Prop_Data, "m_takedamage") == 0)
		return false;
	char cls[64];
	GetEntityClassname(ent, cls, sizeof(cls));
	if (StrContains(cls, "breakable") != -1)
		return true;
	return HasEntProp(ent, Prop_Data, "m_iHealth") && GetEntProp(ent, Prop_Data, "m_iHealth") > 0;
}

int EntHealth(int ent)
{
	return HasEntProp(ent, Prop_Data, "m_iHealth") ? GetEntProp(ent, Prop_Data, "m_iHealth") : 0;
}

bool IsIgnored(int client, int ent)
{
	int ref = EntIndexToEntRef(ent);
	for (int i = 0; i < 4; i++)
		if (g_ignore[client][i] == ref && GetGameTime() < g_ignoreUntil[client][i])
			return true;
	return false;
}

void Ignore(int client, int ent)
{
	int slot = 0;
	for (int i = 1; i < 4; i++)
		if (g_ignoreUntil[client][i] < g_ignoreUntil[client][slot]) slot = i;
	g_ignore[client][slot] = EntIndexToEntRef(ent);
	g_ignoreUntil[client][slot] = GetGameTime() + 60.0;
}

bool IsSmashable(int ent)
{
	if (ent <= MaxClients || !IsValidEntity(ent) || !CanBreak(ent))
		return false;
	char cls[64], model[128];
	GetEntityClassname(ent, cls, sizeof(cls));
	if (StrContains(cls, "weapon_") == 0 || StrContains(cls, "item_") == 0)
		return false;   // loose pickups, e.g. a barricade tool lying on the floor
	if (StrContains(cls, "breakable") != -1 || StrContains(cls, "physbox") != -1 || StrContains(cls, "prop_physics") != -1
		|| StrContains(cls, "barricade") != -1 || StrContains(cls, "door") != -1)
		return true;
	if (HasEntProp(ent, Prop_Data, "m_ModelName"))
	{
		GetEntPropString(ent, Prop_Data, "m_ModelName", model, sizeof(model));
		if (StrContains(model, "barricade", false) != -1)   // boards nailed up by survivors
			return true;
	}
	return false;
}

float CenterOf(int ent, float out[3])
{
	float origin[3], mins[3], maxs[3];
	GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", origin);
	if (!HasEntProp(ent, Prop_Send, "m_vecMins"))
	{
		out = origin;          // no collision bounds networked: use the origin
		return 0.0;
	}
	GetEntPropVector(ent, Prop_Send, "m_vecMins", mins);
	GetEntPropVector(ent, Prop_Send, "m_vecMaxs", maxs);
	for (int i = 0; i < 3; i++)
		out[i] = origin[i] + (mins[i] + maxs[i]) * 0.5;
	return 0.0;
}

// Nearest smashable obstacle or piece of furniture within reach of a stuck zombie.
int FindObstacle(int client)
{
	float me[3], c[3];
	GetClientAbsOrigin(client, me);
	me[2] += 36.0;
	int best = -1;
	float bestDist = 110.0;
	for (int ent = MaxClients + 1; ent < GetMaxEntities(); ent++)
	{
		if (IsIgnored(client, ent) || !(IsSmashable(ent) || (IsValidEntity(ent) && IsFurniture(ent))))
			continue;
		CenterOf(ent, c);
		float d = GetVectorDistance(me, c);
		if (d < bestDist) { bestDist = d; best = ent; }
	}
	return best;
}

bool IsFurniture(int ent)
{
	char cls[64];
	GetEntityClassname(ent, cls, sizeof(cls));
	if (StrContains(cls, "prop_physics") == -1)
		return false;
	int ref = EntIndexToEntRef(ent);
	for (int i = 0; i < g_fixedCount; i++)
		if (g_fixed[i] == ref)
			return false;                // fixed in place: treat like a wall
	return !IsZombieStep(ent);
}

// Furniture sitting where the main player put it as a zombie (a car to climb a roof from):
// leave it there.
bool IsZombieStep(int ent)
{
	float pos[3];
	GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", pos);
	for (int k = 0; k < g_ln_placeCount; k++)
		if (g_ln_placeTeam[k] == TEAM_ZOMBIES && GetVectorDistance(pos, g_ln_placeTo[k]) < 48.0)
			return true;
	return false;
}

void ResetPlacements()
{
	for (int k = 0; k < LEARN_MAX_PLACES; k++)
	{
		g_placeBy[k] = 0;
		g_placeDone[k] = false;
	}
	for (int i = 0; i <= MaxClients; i++)
		g_place[i] = -1;
}

// Hand each learned zombie placement that isn't in place yet to the nearest free zombie.
void AssignPlacements()
{
	for (int k = 0; k < g_ln_placeCount; k++)
	{
		if (g_ln_placeTeam[k] != TEAM_ZOMBIES || g_placeDone[k])
			continue;
		if (g_placeBy[k] != 0 && IsClientInGame(g_placeBy[k]) && IsPlayerAlive(g_placeBy[k]) && g_place[g_placeBy[k]] == k)
			continue;
		int prop = Learned_FindPlaceProp(k);
		if (prop == -1)
		{
			g_placeDone[k] = true;           // gone this round
			continue;
		}
		float pos[3];
		GetEntPropVector(prop, Prop_Data, "m_vecAbsOrigin", pos);
		if (GetVectorDistance(pos, g_ln_placeTo[k]) < 48.0)
			continue;                        // already there
		int best = 0;
		float bestDist = 2500.0;
		for (int i = 1; i <= MaxClients; i++)
		{
			if (!IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) != TEAM_ZOMBIES || !NavBotManager.IsNavBot(i) || g_place[i] != -1)
				continue;
			float z[3];
			GetClientAbsOrigin(i, z);
			float d = GetVectorDistance(z, pos);
			if (d < bestDist) { bestDist = d; best = i; }
		}
		if (best)
		{
			g_place[best] = k;
			g_placeBy[k] = best;
			g_placeStarted[best] = GetGameTime();
			Debug("%N sets up the main player's furniture %d (a step for the horde)", best, k);
		}
	}
}

// Shove a learned zombie placement into place: stand on the far side of it from where it goes,
// right click (arms' punt plus the push assist), repeat. Returns true when it set moveGoal or is
// working (the caller returns Plugin_Changed / Plugin_Continue accordingly through `walking`).
bool UpdatePlace(int client, NavBot bot, float moveGoal[3], bool &walking)
{
	int k = g_place[client];
	if (k < 0)
		return false;
	int prop = Learned_FindPlaceProp(k);
	if (prop == -1 || GetGameTime() - g_placeStarted[client] > 45.0)
	{
		g_placeDone[k] = true;
		g_place[client] = -1;
		return false;
	}
	float pos[3], c[3], me[3], eye[3];
	GetEntPropVector(prop, Prop_Data, "m_vecAbsOrigin", pos);
	CenterOf(prop, c);
	GetClientAbsOrigin(client, me);
	GetClientEyePosition(client, eye);
	float to[3];
	to = g_ln_placeTo[k];
	to[2] = pos[2];
	if (GetVectorDistance(pos, to) < 40.0)
	{
		Debug("%N set up the main player's furniture %d", client, k);
		g_placeDone[k] = true;
		g_place[client] = -1;
		return false;
	}
	// Behind it, on the line from its destination through it.
	float back[3], spot[3];
	SubtractVectors(pos, to, back);
	back[2] = 0.0;
	NormalizeVector(back, back);
	float size = 40.0;
	if (HasEntProp(prop, Prop_Send, "m_vecMaxs"))
	{
		float mins[3], maxs[3];
		GetEntPropVector(prop, Prop_Send, "m_vecMins", mins);
		GetEntPropVector(prop, Prop_Send, "m_vecMaxs", maxs);
		size = (maxs[0] - mins[0] > maxs[1] - mins[1] ? maxs[0] - mins[0] : maxs[1] - mins[1]) * 0.5 + 30.0;
	}
	ScaleVector(back, size);
	AddVectors(c, back, spot);
	spot[2] = me[2];
	Address area = NavBotNavMesh.GetNearestNavArea(spot, 200.0, false, true);
	if (area != Address_Null)
		NavBotNavArea.GetClosestPointOnArea(area, spot, spot);
	if (GetVectorDistance(me, spot) > 40.0 && GetVectorDistance(eye, c) > size + 30.0)
	{
		moveGoal = spot;
		walking = true;
		return true;
	}
	Address ctrl = bot.GetPlayerControllerInterface();
	c[2] -= 4.0;
	NavBotPlayerControllerInterface.AimAtPos(ctrl, c, LOOK_PRIORITY, 0.4, "Setting up a step");
	if (GetVectorDistance(eye, c) > size + 20.0)
		NavBotMovementInterface.MoveTowards(bot.GetMovementInterface(), c, 100);
	else if (GetGameTime() >= g_nextShove[client] && NavBotPlayerControllerInterface.IsAimOnTarget(ctrl))
	{
		NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_ATTACKSEC, 0.15);
		g_nextShove[client] = GetGameTime() + 0.8;
		float dir[3];
		SubtractVectors(to, pos, dir);
		dir[2] = 0.0;
		NormalizeVector(dir, dir);
		DataPack pack;
		CreateDataTimer(0.25, Timer_ShoveImpulse, pack, TIMER_FLAG_NO_MAPCHANGE);
		pack.WriteCell(EntIndexToEntRef(prop));
		pack.WriteFloat(dir[0]);
		pack.WriteFloat(dir[1]);
	}
	walking = false;
	return true;
}

// Start shoving a piece of furniture out of the way (right click with the zombie's arms).
void StartShove(int client, int prop)
{
	if (EntRefToEntIndex(g_shove[client]) != INVALID_ENT_REFERENCE || IsIgnored(client, prop))
		return;
	g_shove[client] = EntIndexToEntRef(prop);
	g_shoveUntil[client] = GetGameTime() + 3.0;
	GetEntPropVector(prop, Prop_Data, "m_vecAbsOrigin", g_shoveFrom[client]);
	Debug("%N shoves furniture %d", client, prop);
}

Action Timer_ShoveImpulse(Handle timer, DataPack pack)
{
	pack.Reset();
	int prop = EntRefToEntIndex(pack.ReadCell());
	if (prop == INVALID_ENT_REFERENCE)
		return Plugin_Stop;
	float vel[3];
	vel[0] = pack.ReadFloat() * 260.0;
	vel[1] = pack.ReadFloat() * 260.0;
	vel[2] = 40.0;
	TeleportEntity(prop, NULL_VECTOR, NULL_VECTOR, vel);
	return Plugin_Stop;
}

// Furniture in the way: zombies shove it aside with a right click. The arms' punt alone barely
// moves heavy furniture, so a shove that lands also gives the prop a push of its own.
bool UpdateShove(int client, NavBot bot)
{
	int prop = EntRefToEntIndex(g_shove[client]);
	if (prop == INVALID_ENT_REFERENCE)
		return false;
	float c[3], eye[3], pos[3];
	CenterOf(prop, c);
	GetClientEyePosition(client, eye);
	GetEntPropVector(prop, Prop_Data, "m_vecAbsOrigin", pos);
	if (GetGameTime() >= g_shoveUntil[client] || GetVectorDistance(eye, c) > 130.0)
	{
		g_shove[client] = INVALID_ENT_REFERENCE;
		Debug("%N: shoved furniture %d %.0f units", client, prop, GetVectorDistance(pos, g_shoveFrom[client]));
		if (GetVectorDistance(pos, g_shoveFrom[client]) < 10.0)
		{
			// Didn't budge: smash it if it breaks, else go around.
			if (CanBreak(prop))
			{
				g_smash[client] = EntIndexToEntRef(prop);
				g_smashUntil[client] = GetGameTime() + 4.0;
				g_smashHealth[client] = EntHealth(prop);
			}
			else
			{
				if (g_fixedCount < sizeof(g_fixed))
					g_fixed[g_fixedCount++] = EntIndexToEntRef(prop);   // tell the horde
				Ignore(client, prop);
				if (Unstick_RandomSpot(client, g_us_detour[client]))
					g_us_detourUntil[client] = GetGameTime() + 3.0;
			}
			Debug("%N: furniture %d won't move", client, prop);
		}
		return false;
	}
	Address ctrl = bot.GetPlayerControllerInterface();
	c[2] -= 4.0;
	NavBotPlayerControllerInterface.AimAtPos(ctrl, c, LOOK_PRIORITY, 0.4, "Shoving furniture");
	if (GetVectorDistance(eye, c) > 75.0)
	{
		NavBotMovementInterface.MoveTowards(bot.GetMovementInterface(), c, 100);   // step into reach
		return true;
	}
	if (GetGameTime() >= g_nextShove[client] && NavBotPlayerControllerInterface.IsAimOnTarget(ctrl))
	{
		NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_ATTACKSEC, 0.15);
		g_nextShove[client] = GetGameTime() + 0.8;
		float dir[3];
		SubtractVectors(c, eye, dir);
		dir[2] = 0.0;
		NormalizeVector(dir, dir);
		DataPack pack;
		CreateDataTimer(0.25, Timer_ShoveImpulse, pack, TIMER_FLAG_NO_MAPCHANGE);
		pack.WriteCell(EntIndexToEntRef(prop));
		pack.WriteFloat(dir[0]);
		pack.WriteFloat(dir[1]);
	}
	return true;
}

// Don't let NavBot try to break unbreakable obstacles (e.g. metal closets) for zombies: detour.
public Action OnNavBotObstacleOnPath(NavBot bot, int entity, bool hitWorld, const float goal[3])
{
	int client = bot.Index;
	if (hitWorld || entity <= MaxClients || !IsValidEntity(entity) || !IsClientInGame(client) || GetClientTeam(client) != TEAM_ZOMBIES)
		return Plugin_Continue;
	if (IsFurniture(entity) && !IsIgnored(client, entity))
	{
		StartShove(client, entity);
		return Plugin_Handled;      // shove it, don't smash it
	}
	if (CanBreak(entity) && !IsIgnored(client, entity))
		return Plugin_Continue;     // NavBot breaks it
	if (g_us_detourUntil[client] < GetGameTime() && Unstick_RandomSpot(client, g_us_detour[client]))
		g_us_detourUntil[client] = GetGameTime() + 3.0;
	return Plugin_Handled;
}

Action OnScriptedUpdate(NavBot bot, float moveGoal[3], NavBotRouteType& routeType)
{
	int client = bot.Index;
	if (!g_enable.BoolValue || !IsClientInGame(client) || !IsPlayerAlive(client) || GetClientTeam(client) != TEAM_ZOMBIES)
	{
		g_scripted[client] = false;
		return Plugin_Stop;
	}

	if (UpdateShove(client, bot))
		return Plugin_Continue;

	// Smashing an obstacle: stand still, aim at it and swing.
	int obstacle = EntRefToEntIndex(g_smash[client]);
	if (obstacle != INVALID_ENT_REFERENCE && GetGameTime() >= g_smashUntil[client])
	{
		// Time's up: if it took no damage, it can't be broken this way. Forget it and go around.
		if (EntHealth(obstacle) >= g_smashHealth[client])
		{
			Ignore(client, obstacle);
			if (Unstick_RandomSpot(client, g_us_detour[client]))
				g_us_detourUntil[client] = GetGameTime() + 4.0;
			Debug("%N: obstacle %d won't break, detouring", client, obstacle);
		}
		g_smash[client] = INVALID_ENT_REFERENCE;
		obstacle = INVALID_ENT_REFERENCE;
	}
	if (obstacle != INVALID_ENT_REFERENCE && GetGameTime() < g_smashUntil[client])
	{
		Address ctrl = bot.GetPlayerControllerInterface();
		float c[3];
		CenterOf(obstacle, c);
		NavBotPlayerControllerInterface.AimAtPos(ctrl, c, LOOK_PRIORITY, 0.5, "Smashing barricade");
		NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_ATTACKPRIM, 0.3);
		return Plugin_Continue;
	}
	g_smash[client] = INVALID_ENT_REFERENCE;

	// Setting up a step the main player built (a car under the roof edge)?
	bool walking;
	if (UpdatePlace(client, bot, moveGoal, walking))
	{
		float me2[3];
		GetClientAbsOrigin(client, me2);
		if (!walking)
		{
			g_us_wantMove[client] = false;
			return Plugin_Continue;
		}
		routeType = NAVBOT_FASTEST_ROUTE;
		Unstick_WantMove(client, me2, moveGoal);
		return Plugin_Changed;
	}

	if (Unstick_Goal(client, moveGoal))
		return Plugin_Changed;              // detour around whatever we're stuck on

	if (g_forceTarget.IntValue > 0 && IsLiveSurvivor(g_forceTarget.IntValue))
		g_target[client] = g_forceTarget.IntValue;
	else if (!IsLiveSurvivor(g_target[client]) || GetGameTime() > g_retarget[client])
	{
		g_target[client] = PickTarget(client);
		g_retarget[client] = GetGameTime() + GetRandomFloat(8.0, 14.0);
	}
	if (!g_target[client])
	{
		g_us_wantMove[client] = false;
		return Plugin_Continue;     // no survivors left to hunt
	}

	float me[3], target[3];
	GetClientAbsOrigin(client, me);
	GetClientAbsOrigin(g_target[client], target);
	bool sees = CanSee(client, g_target[client]);

	// Staircases the nav mesh doesn't cover (church tower): walk the hand-made route.
	Action stairs;
	if (Stairs_Update(client, bot, me, target, moveGoal, routeType, stairs))
	{
		g_blockedSince[client] = 0.0;
		if (stairs == Plugin_Continue)
			g_us_wantMove[client] = false;     // steering ourselves; don't let unstick detour us
		else
			Unstick_WantMove(client, me, moveGoal);
		return stairs;
	}

	// Target holed up in a building: attack through an entrance of our own.
	if (UpdateEntry(client, me, target, sees, moveGoal))
	{
		g_blockedSince[client] = 0.0;
		routeType = NAVBOT_FASTEST_ROUTE;
		Unstick_WantMove(client, me, moveGoal);
		return Plugin_Changed;
	}

	// Close and in plain view: go straight for them.
	if (sees && GetVectorDistance(me, target) < 200.0)
	{
		moveGoal = target;
		g_blockedSince[client] = 0.0;
		routeType = NAVBOT_FASTEST_ROUTE;
		Unstick_WantMove(client, me, moveGoal);
		return Plugin_Changed;
	}

	if (GetGameTime() > g_goalTime[client] + 1.0 || GetVectorDistance(target, g_goalTarget[client]) > 64.0)
	{
		ComputeGoal(client, g_target[client], g_goal[client]);
		g_goalTarget[client] = target;
		g_goalTime[client] = GetGameTime();
	}

	// Arrived, yet the survivor is still behind a wall: that spot is a dead end. Remember it and
	// pick another, instead of standing in the corner for the rest of the round.
	if (!sees && GetVectorDistance(me, g_goal[client]) < 70.0 && GetVectorDistance(me, target) > 80.0)
	{
		if (g_blockedSince[client] == 0.0)
			g_blockedSince[client] = GetGameTime();
		else if (GetGameTime() - g_blockedSince[client] > 2.0)
		{
			Address dead = NavBotNavMesh.GetNearestNavArea(g_goal[client], 64.0, false, true);
			if (dead != Address_Null)
				MarkDeadEnd(client, dead);
			Debug("%N: dead end near %N, picking another spot", client, g_target[client]);
			ComputeGoal(client, g_target[client], g_goal[client]);
			g_goalTarget[client] = target;
			g_goalTime[client] = GetGameTime();
			g_blockedSince[client] = 0.0;
		}
	}
	else
		g_blockedSince[client] = 0.0;

	moveGoal = g_goal[client];
	routeType = NAVBOT_FASTEST_ROUTE;
	Unstick_WantMove(client, me, moveGoal);
	return Plugin_Changed;
}

// ---------------------------------------------------------------------------------------------
// Doors in the nav mesh

bool TraceWorldOnly(int entity, int mask)
{
	return entity == 0;
}

// Rooms whose door was closed while the nav mesh was generated come out as islands: their
// areas aren't connected to the rest, so a zombie hunting someone inside can't find a path and
// walks straight at the wall in between. Connect the areas on both sides of every door.
int LinkDoors(bool verbose)
{
	static const char classes[][] = { "func_door_rotating", "prop_door_rotating", "func_door" };
	int linked = 0;
	for (int c = 0; c < sizeof(classes); c++)
	{
		int ent = -1;
		while ((ent = FindEntityByClassname(ent, classes[c])) != -1)
		{
			if (!HasEntProp(ent, Prop_Send, "m_vecMins"))
				continue;
			float center[3], mins[3], maxs[3];
			CenterOf(ent, center);
			GetEntPropVector(ent, Prop_Send, "m_vecMins", mins);
			GetEntPropVector(ent, Prop_Send, "m_vecMaxs", maxs);
			float sx = maxs[0] - mins[0], sy = maxs[1] - mins[1], sz = maxs[2] - mins[2];
			float thin = sx < sy ? sx : sy, wide = sx < sy ? sy : sx;
			if (thin > 16.0 || wide < 24.0 || sz < 70.0 || sz > 160.0)
				continue;                    // not a closed, door-shaped door
			float n[3], a[3], b[3];
			n[0] = sx < sy ? 1.0 : 0.0;
			n[1] = sx < sy ? 0.0 : 1.0;
			float floorZ = center[2] - sz * 0.5 + 16.0;
			for (int i = 0; i < 2; i++) { a[i] = center[i] + n[i] * 40.0; b[i] = center[i] - n[i] * 40.0; }
			a[2] = floorZ; b[2] = floorZ;
			// Only through the doorway: no wall (world) between the two sides.
			TR_TraceRayFilter(a, b, MASK_SOLID_BRUSHONLY, RayType_EndPoint, TraceWorldOnly);
			if (TR_DidHit())
				continue;
			Address areaA = NavBotNavMesh.GetNearestNavArea(a, 64.0, false, true);
			Address areaB = NavBotNavMesh.GetNearestNavArea(b, 64.0, false, true);
			if (areaA == Address_Null || areaB == Address_Null || areaA == areaB)
				continue;
			float ca[3], cb[3];
			NavBotNavArea.GetClosestPointOnArea(areaA, a, ca);
			NavBotNavArea.GetClosestPointOnArea(areaB, b, cb);
			if (FloatAbs(ca[2] - cb[2]) > 18.0)
				continue;
			bool ab = NavBotNavArea.IsConnectedToAny(areaA, areaB), ba = NavBotNavArea.IsConnectedToAny(areaB, areaA);
			if (ab && ba)
				continue;
			bool made = false;
			if (!ab) made = NavBotNavArea.ConnectToAdjacent(areaA, areaB) || made;
			if (!ba) made = NavBotNavArea.ConnectToAdjacent(areaB, areaA) || made;
			if (made)
				linked++;
			if (verbose)
				PrintToServer("[doorlinks] door %d (%s) at %.0f %.0f %.0f: areas #%d <-> #%d %s", ent, classes[c], center[0], center[1], center[2],
					NavBotNavArea.GetID(areaA), NavBotNavArea.GetID(areaB), made ? "linked" : "could not link");
		}
	}
	return linked;
}

Action Cmd_DoorLinks(int args)
{
	if (!NavBotNavMesh.IsLoaded()) { PrintToServer("[doorlinks] no nav mesh"); return Plugin_Handled; }
	PrintToServer("[doorlinks] %d doors linked", LinkDoors(true));
	g_doorsLinked = true;
	return Plugin_Handled;
}

Action Timer_Think(Handle timer)
{
	if (!g_enable.BoolValue || !LibraryExists("navbot") || !NavBotNavMesh.IsLoaded())
		return Plugin_Continue;
	if (!g_doorsLinked)
	{
		g_doorsLinked = true;
		int n = LinkDoors(false);
		if (n > 0)
			LogMessage("Linked the nav mesh through %d doors", n);
	}

	AssignPlacements();
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !IsPlayerAlive(client) || GetClientTeam(client) != TEAM_ZOMBIES || !NavBotManager.IsNavBot(client))
		{
			g_scripted[client] = false;
			if (g_place[client] != -1) { g_placeBy[g_place[client]] = 0; g_place[client] = -1; }
			continue;
		}
		NavBot bot = NavBotManager.GetNavBotByIndex(client);
		Unstick_Track(client, bot);

		// Stuck detection: barely moved for 1.5 s while not already smashing something.
		float pos[3];
		GetClientAbsOrigin(client, pos);
		if (GetVectorDistance(pos, g_lastPos[client]) > 24.0)
			g_stuckSince[client] = GetGameTime();
		g_lastPos[client] = pos;
		if (GetGameTime() - g_stuckSince[client] > 1.5 && EntRefToEntIndex(g_smash[client]) == INVALID_ENT_REFERENCE)
		{
			int obstacle = FindObstacle(client);
			if (obstacle != -1 && IsFurniture(obstacle))
				StartShove(client, obstacle);
			else if (obstacle != -1)
			{
				g_smash[client] = EntIndexToEntRef(obstacle);
				g_smashUntil[client] = GetGameTime() + 4.0;
				g_smashHealth[client] = EntHealth(obstacle);
				char cls[64];
				GetEntityClassname(obstacle, cls, sizeof(cls));
				Debug("%N is stuck, smashing %s", client, cls);
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
		}
	}
	return Plugin_Continue;
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
