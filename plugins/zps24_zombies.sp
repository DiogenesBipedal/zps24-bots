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
	AutoExecConfig(true, "zps24_zombies");
}

public void OnMapStart()
{
	for (int i = 0; i <= MaxClients; i++)
	{
		g_scripted[i] = false;
		g_smash[i] = INVALID_ENT_REFERENCE;
		g_goalTime[i] = 0.0;
		g_blockedSince[i] = 0.0;
		for (int k = 0; k < 4; k++)
			g_deadEndUntil[i][k] = 0.0;
		Unstick_Reset(i);
	}
	Stairs_OnMapStart();
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

// Nearest smashable obstacle within reach of a stuck zombie.
int FindObstacle(int client)
{
	float me[3], c[3];
	GetClientAbsOrigin(client, me);
	me[2] += 36.0;
	int best = -1;
	float bestDist = 110.0;
	for (int ent = MaxClients + 1; ent < GetMaxEntities(); ent++)
	{
		if (!IsSmashable(ent) || IsIgnored(client, ent))
			continue;
		CenterOf(ent, c);
		float d = GetVectorDistance(me, c);
		if (d < bestDist) { bestDist = d; best = ent; }
	}
	return best;
}

// Don't let NavBot try to break unbreakable obstacles (e.g. metal closets) for zombies: detour.
public Action OnNavBotObstacleOnPath(NavBot bot, int entity, bool hitWorld, const float goal[3])
{
	int client = bot.Index;
	if (hitWorld || entity <= MaxClients || !IsValidEntity(entity) || !IsClientInGame(client) || GetClientTeam(client) != TEAM_ZOMBIES)
		return Plugin_Continue;
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

Action Timer_Think(Handle timer)
{
	if (!g_enable.BoolValue || !LibraryExists("navbot") || !NavBotNavMesh.IsLoaded())
		return Plugin_Continue;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !IsPlayerAlive(client) || GetClientTeam(client) != TEAM_ZOMBIES || !NavBotManager.IsNavBot(client))
		{
			g_scripted[client] = false;
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
			if (obstacle != -1)
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
