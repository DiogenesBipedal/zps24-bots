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

ConVar g_enable, g_debug, g_forceTarget, g_buildSteps;
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
int    g_entryEnt[MAXPLAYERS + 1];       // the window/door of the entrance (entity reference), or -1
bool   g_entryWindow[MAXPLAYERS + 1];    // a ground-floor window: smash it, then climb straight through
float  g_entrySmashUntil[MAXPLAYERS + 1];
float  g_entryClearAt[MAXPLAYERS + 1];   // when the window was found broken
float  g_doorsOnlyUntil[MAXPLAYERS + 1]; // a window took too long: break in through a door instead
int    g_br[MAXPLAYERS + 1] = { -1, ... };   // opening this zombie is breaking through, or -1
int    g_brLast[MAXPLAYERS + 1] = { -1, ... };
int    g_brRepeats[MAXPLAYERS + 1];
float  g_brLastAt[MAXPLAYERS + 1];
int    g_brFrom[MAXPLAYERS + 1];         // which side of it we're on (0/1)
int    g_brPhase[MAXPLAYERS + 1];        // 0 walk up to it, 1 break it, 2 go through
float  g_brUntil[MAXPLAYERS + 1];
float  g_brCooldown[MAXPLAYERS + 1];
int    g_unbarDoor[MAXPLAYERS + 1];      // door being unbarred from the inside (entity reference), or -1
float  g_unbarUntil[MAXPLAYERS + 1];
int    g_toughWin[32];                   // windows no zombie got through this round (shared by the horde)
int    g_toughWinCount;
int    g_ignore[MAXPLAYERS + 1][4];      // obstacles that didn't break when hit (entity refs)
float  g_ignoreUntil[MAXPLAYERS + 1][4];
float  g_goal[MAXPLAYERS + 1][3];        // where we're heading to reach g_target
float  g_goalTarget[MAXPLAYERS + 1][3];  // the target's position when g_goal was chosen
float  g_goalTime[MAXPLAYERS + 1];
float  g_blockedSince[MAXPLAYERS + 1];   // at the goal, but the target is behind a wall
Address g_deadEnd[MAXPLAYERS + 1][4];    // goal areas that turned out to be dead ends
float  g_deadEndUntil[MAXPLAYERS + 1][4];

// Openings between rooms that the nav mesh doesn't cross: planks across doorways, doors with a
// bar against them, windows and boarded windows. Survivors must not path through these (they
// don't break barricades), so they are not linked; zombies break through them deliberately.
#define BR_MAX       96
#define BR_WINDOW    0      // glass: smash until broken
#define BR_PLANK     1      // plank / board (func_physbox): knock it off
#define BR_BARDOOR   2      // a door with a bar against it: knock the bar off, open the door
int   g_brCount;
int   g_brEnt[BR_MAX];                 // the opening's blocker (window, plank) or the door (entity references)
int   g_brKind[BR_MAX];
float g_brSide[BR_MAX][2][3];          // a walkable point on each side
int   g_brComp[BR_MAX][2];             // nav region of each side
bool  g_brClimb[BR_MAX];               // the opening's bottom is above the floor: jump through
float g_brStart[BR_MAX][3];            // where the blocker was at map start
bool  g_brTough[BR_MAX];               // nobody got through this round
bool  g_brOpen[BR_MAX];                // cleared and linked into the nav mesh

// Nav regions: areas connected to each other. Zombies use them to tell when a survivor is in a
// part of the map they can't walk to (behind a plank, a barred door, a window).
#define COMP_MAX_ID 8192
int g_comp[COMP_MAX_ID];

public void OnPluginStart()
{
	g_enable = CreateConVar("sm_zps24zombies_enable", "1", "Enable the ZPS 2.4 zombie AI");
	g_debug  = CreateConVar("sm_zps24zombies_debug", "0", "Log zombie AI decisions");
	g_buildSteps = CreateConVar("sm_zps24zombies_build_steps", "0", "Zombie bots push furniture the main player moved as a zombie into place (steps up to roofs)");
	g_forceTarget = CreateConVar("sm_zps24zombies_force_target", "0", "Debug: every zombie hunts this client index (0 = normal)");
	RegServerCmd("sm_zps24_doorbars", Cmd_DoorBars, "List physics props right next to doors (planks barring them)");
	RegServerCmd("sm_zps24_doorlinks", Cmd_DoorLinks, "Connect the nav areas on both sides of every door again and report");
	AutoExecConfig(true, "zps24_zombies");
	HookEventEx("game_round_restart", Event_RoundRestart, EventHookMode_PostNoCopy);
}

void Event_RoundRestart(Event event, const char[] name, bool dontBroadcast)
{
	g_fixedCount = 0;                   // props respawn every round
	g_toughWinCount = 0;
	g_doorsLinked = false;              // props respawn: find the openings and their blockers again
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
		g_entrySmashUntil[i] = 0.0;
		g_doorsOnlyUntil[i] = 0.0;
		g_unbarDoor[i] = INVALID_ENT_REFERENCE;
		g_br[i] = -1;
		g_brCooldown[i] = 0.0;
		g_fixedCount = 0;
		g_toughWinCount = 0;
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

// Can a bot walk into this area at all? Some ledges and sills only have connections leading
// away from them (drops), so a path can never end there and a zombie heading for one grinds
// into the wall below it.
bool IsEnterable(Address a)
{
	for (int d = 0; d < 4; d++)
	{
		int n = NavBotNavArea.GetAdjacentAreaCount(a, view_as<NavBotNavDirType>(d));
		for (int k = 0; k < n; k++)
		{
			Address b = NavBotNavArea.GetAdjacentArea(a, view_as<NavBotNavDirType>(d), k);
			if (b != Address_Null && NavBotNavArea.IsConnectedToAny(b, a))
				return true;
		}
	}
	return NavBotNavArea.GetOffMeshConnectionCount(a) > 0;
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
	if (area != Address_Null && !IsDeadEnd(client, area) && IsEnterable(area))
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
		if (IsDeadEnd(client, a) || !IsEnterable(a))
			continue;
		NavBotNavArea.GetClosestPointOnArea(a, pos, spot);
		// Horizontal distance first: for a survivor up on a ledge or a bed, the floor right
		// below is the place to attack from.
		float dx = spot[0] - pos[0], dy = spot[1] - pos[1];
		float d = SquareRoot(dx * dx + dy * dy) + FloatAbs(spot[2] - pos[2]) * 0.3;
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

bool IsToughWindow(int ent)
{
	int ref = EntIndexToEntRef(ent);
	for (int i = 0; i < g_toughWinCount; i++)
		if (g_toughWin[i] == ref)
			return true;
	return false;
}

// Height of a window's bottom edge.
float WindowSill(int ent)
{
	float origin[3], mins[3];
	GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", origin);
	GetEntPropVector(ent, Prop_Send, "m_vecMins", mins);
	return origin[2] + mins[2];
}

// Is this window still in the way? (Gone, or its glass shattered, means open.)
bool WindowIntact(int ent)
{
	if (ent == INVALID_ENT_REFERENCE || !IsValidEntity(ent))
		return false;
	if (HasEntProp(ent, Prop_Send, "m_bIsBroken") && GetEntProp(ent, Prop_Send, "m_bIsBroken"))
		return false;
	return true;
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
			g_entryEnt[client] = -1;
			g_entryWindow[client] = false;
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
			// Ground-floor windows first: smash the glass and climb straight in, no walking round
			// to a door. "Ground floor": the sill no higher than a crouch-jump from outside.
			bool window = c >= 3;
			if (window && (GetGameTime() < g_doorsOnlyUntil[client] || IsToughWindow(ent)))
				continue;                    // too strong or too slow last time: doors instead
			if (window)
			{
				// Ground floor only: the floor is at the same height outside and in (not a porch
				// roof under an upstairs window), and the sill within a crouch-jump.
				Address inArea = NavBotNavMesh.GetNearestNavArea(inside, 100.0, false, true);
				if (inArea == Address_Null)
					continue;
				float inFloor[3];
				NavBotNavArea.GetClosestPointOnArea(inArea, inside, inFloor);
				float sill = WindowSill(ent);
				if (FloatAbs(inFloor[2] - out[2]) > 24.0 || sill - out[2] > 56.0)
					continue;
				inside = inFloor;
			}
			float cost = d + 500.0 * float(EntryLoad(client, out)) - (window ? 250.0 : 0.0);
			if (cost < bestCost)
			{
				bestCost = cost;
				found = true;
				g_entryOut[client] = out;
				g_entryIn[client] = inside;
				g_entryEnt[client] = EntIndexToEntRef(ent);
				g_entryWindow[client] = window;
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

#define ENTRY_NONE  0
#define ENTRY_PATH  1      // moveGoal set: path there
#define ENTRY_STEER 2      // steering the bot ourselves (no pathing)

// ---------------------------------------------------------------------------------------------
// Breaking through to a survivor in a part of the map we can't walk to (behind a plank, a
// barred door or a window). The openings are found at map start (LinkDoors).

int BreachLoad(int client, int k)
{
	int n = 0;
	for (int i = 1; i <= MaxClients; i++)
		if (i != client && g_br[i] == k && IsClientInGame(i) && IsPlayerAlive(i))
			n++;
	return n;
}

bool BlockerGone(int k)
{
	int ent = EntRefToEntIndex(g_brEnt[k]);
	switch (g_brKind[k])
	{
		case BR_WINDOW: return !WindowIntact(ent);
		case BR_PLANK:
		{
			if (ent == INVALID_ENT_REFERENCE)
				return true;
			float c[3];
			CenterOf(ent, c);
			return GetVectorDistance(c, g_brStart[k]) > 40.0;      // knocked off the opening
		}
		case BR_BARDOOR: return ent == INVALID_ENT_REFERENCE || DoorBar(ent) == -1;
	}
	return true;
}

int UpdateBreach(int client, NavBot bot, const float me[3], int target, float moveGoal[3])
{
	int k = g_br[client];
	if (k == -1)
	{
		if (GetGameTime() < g_brCooldown[client] || g_brCount == 0)
			return ENTRY_NONE;
		int myComp = AreaComp(NavBotNavMesh.GetNearestNavArea(me, 120.0, false, true));
		NavBotBasePlayer tp = NavBotManager.GetBasePlayer(target);
		Address ta = tp.IsNull ? Address_Null : tp.GetLastKnownNavArea();
		int tComp = AreaComp(ta);
		if (myComp == -1 || tComp == -1 || myComp == tComp)
			return ENTRY_NONE;
		// The cheapest opening between our region and theirs.
		float tpos[3];
		GetClientAbsOrigin(target, tpos);
		float best = 999999.0;
		for (int i = 0; i < g_brCount; i++)
		{
			if (g_brTough[i])
				continue;
			for (int side = 0; side < 2; side++)
			{
				if (g_brComp[i][side] != myComp || g_brComp[i][1 - side] != tComp)
					continue;
				float cost = GetVectorDistance(me, g_brSide[i][side]) + GetVectorDistance(g_brSide[i][1 - side], tpos)
					+ 300.0 * float(BreachLoad(client, i)) + (g_brKind[i] == BR_WINDOW ? -100.0 : 0.0);
				if (cost < best) { best = cost; g_br[client] = i; g_brFrom[client] = side; }
			}
		}
		k = g_br[client];
		if (k == -1)
		{
			g_brCooldown[client] = GetGameTime() + 5.0;
			return ENTRY_NONE;
		}
		// The same opening again and again: we're not really getting through it. Give it up.
		if (k == g_brLast[client] && GetGameTime() - g_brLastAt[client] < 60.0)
		{
			if (++g_brRepeats[client] >= 3)
			{
				g_brTough[k] = true;
				g_br[client] = -1;
				g_brRepeats[client] = 0;
				Debug("%N: keeps failing the opening at %.0f %.0f %.0f, giving up on it", client, g_brStart[k][0], g_brStart[k][1], g_brStart[k][2]);
				return ENTRY_NONE;
			}
		}
		else
			g_brRepeats[client] = 0;
		g_brLast[client] = k;
		g_brLastAt[client] = GetGameTime();
		g_brPhase[client] = 0;
		g_brUntil[client] = GetGameTime() + 40.0;
		Debug("%N breaks through a %s at %.0f %.0f %.0f to reach %N", client,
			g_brKind[k] == BR_WINDOW ? "window" : (g_brKind[k] == BR_PLANK ? "plank" : "barred door"),
			g_brStart[k][0], g_brStart[k][1], g_brStart[k][2], target);
	}
	if (GetGameTime() > g_brUntil[client])
	{
		if (g_brPhase[client] == 1)
		{
			g_brTough[k] = true;                // couldn't break it: the horde stops trying this one
			Debug("%N: couldn't break through, giving up on that opening", client);
		}
		g_br[client] = -1;
		g_brCooldown[client] = GetGameTime() + 3.0;
		return ENTRY_NONE;
	}
	int from = g_brFrom[client], to = 1 - from;
	Address ctrl = bot.GetPlayerControllerInterface();
	int ent = EntRefToEntIndex(g_brEnt[k]);

	if (g_brPhase[client] == 0)
	{
		if (GetVectorDistance(me, g_brSide[k][from]) > 40.0)
		{
			moveGoal = g_brSide[k][from];
			return ENTRY_PATH;
		}
		g_brPhase[client] = BlockerGone(k) ? 2 : 1;
		g_brUntil[client] = GetGameTime() + (g_brPhase[client] == 1 ? 12.0 : 5.0);
	}
	if (g_brPhase[client] == 1)
	{
		if (BlockerGone(k))
		{
			if (g_brKind[k] == BR_BARDOOR && ent != INVALID_ENT_REFERENCE)
			{
				AcceptEntityInput(ent, "Unlock", client, client);
				AcceptEntityInput(ent, "Open", client, client);
			}
			Debug("%N broke through", client);
			g_brPhase[client] = 2;
			g_brUntil[client] = GetGameTime() + 5.0;
			return ENTRY_STEER;
		}
		int blocker = g_brKind[k] == BR_BARDOOR ? (ent != INVALID_ENT_REFERENCE ? DoorBar(ent) : -1) : ent;
		float c[3];
		if (blocker != -1 && IsValidEntity(blocker))
			CenterOf(blocker, c);
		else
			c = g_brStart[k];
		NavBotPlayerControllerInterface.AimAtPos(ctrl, c, LOOK_PRIORITY, 0.4, "Breaking through");
		float eye[3];
		GetClientEyePosition(client, eye);
		if (GetVectorDistance(eye, c) > 75.0)
			NavBotMovementInterface.MoveTowards(bot.GetMovementInterface(), c, 100);
		if (GetGameTime() >= g_nextShove[client] && NavBotPlayerControllerInterface.IsAimOnTarget(ctrl))
		{
			// Windows: swing. Planks and bars: swing and shove in turn, with the push assist,
			// away from us (into the room / off the door).
			bool shove = g_brKind[k] != BR_WINDOW && !IsWooden(blocker) && RoundToFloor(GetGameTime()) % 2 == 0;
			NavBotPlayerControllerInterface.PressButtonByID(ctrl, shove ? NAVBOT_BUTTON_ATTACKSEC : NAVBOT_BUTTON_ATTACKPRIM, 0.2);
			g_nextShove[client] = GetGameTime() + 0.7;
			if ((shove || IsWooden(blocker)) && blocker != -1)   // a hit knocks wood off too
			{
				float dir[3];
				SubtractVectors(g_brSide[k][to], g_brSide[k][from], dir);
				dir[2] = 0.0;
				NormalizeVector(dir, dir);
				DataPack pack;
				CreateDataTimer(0.25, Timer_ShoveImpulse, pack, TIMER_FLAG_NO_MAPCHANGE);
				pack.WriteCell(EntIndexToEntRef(blocker));
				pack.WriteFloat(dir[0]);
				pack.WriteFloat(dir[1]);
			}
		}
		return ENTRY_STEER;
	}
	// Phase 2: through the opening, climbing if it's a window or a boarded window. Past most of
	// the way across counts: then go and hunt.
	// Through = 16+ units past the opening itself (its center), toward the far side.
	float dir[3], rel[3];
	SubtractVectors(g_brSide[k][to], g_brSide[k][from], dir);
	dir[2] = 0.0;
	NormalizeVector(dir, dir);
	SubtractVectors(me, g_brStart[k], rel);
	rel[2] = 0.0;
	if (GetVectorDistance(me, g_brSide[k][to]) < 40.0 || GetVectorDotProduct(rel, dir) > 16.0)
	{
		g_br[client] = -1;
		g_brCooldown[client] = GetGameTime() + 2.0;
		return ENTRY_NONE;
	}
	float look[3];
	look = g_brSide[k][to];
	look[2] += 40.0;
	NavBotPlayerControllerInterface.AimAtPos(ctrl, look, LOOK_MOVEMENT, 0.3, "Going through");
	NavBotMovementInterface.MoveTowards(bot.GetMovementInterface(), g_brSide[k][to], 100);
	if (g_brClimb[k] && (GetEntityFlags(client) & FL_ONGROUND))
	{
		NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_JUMP, 0.1);
		NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_CROUCH, 0.6);
	}
	return ENTRY_STEER;
}

// ---------------------------------------------------------------------------------------------
// Unbarring a door from the inside: in through a window, then knock away the plank (or padlock,
// or furniture) holding a door shut and open it for the horde.

// A physics object right on a door, holding it shut: a plank (func_physbox), a padlock, furniture.
int DoorBar(int door)
{
	static const char props[][] = { "func_physbox", "func_physbox_multiplayer", "prop_physics_multiplayer", "prop_physics", "prop_physics_override" };
	float dc[3];
	CenterOf(door, dc);
	int best = -1;
	float bestDist = 75.0;
	for (int k = 0; k < sizeof(props); k++)
	{
		int p = -1;
		while ((p = FindEntityByClassname(p, props[k])) != -1)
		{
			float pc[3];
			CenterOf(p, pc);
			float d = GetVectorDistance(pc, dc);
			if (d < bestDist) { bestDist = d; best = p; }
		}
	}
	return best;
}

// After climbing in: the nearest barred door of this house, on our floor.
void StartUnbar(int client, const float me[3])
{
	static const char doors[][] = { "func_door_rotating", "prop_door_rotating", "func_door" };
	int best = -1;
	float bestDist = 700.0;
	for (int c = 0; c < sizeof(doors); c++)
	{
		int door = -1;
		while ((door = FindEntityByClassname(door, doors[c])) != -1)
		{
			float dc[3];
			CenterOf(door, dc);
			if (FloatAbs(dc[2] - me[2]) > 100.0 || DoorBar(door) == -1)
				continue;
			float d = GetVectorDistance(dc, me);
			if (d < bestDist) { bestDist = d; best = door; }
		}
	}
	if (best == -1)
		return;
	g_unbarDoor[client] = EntIndexToEntRef(best);
	g_unbarUntil[client] = GetGameTime() + 20.0;
	Debug("%N is inside: unbarring door %d", client, best);
}

// Knock the bar off the door (shove + swing, with the push assist, away from the door), then
// open it. Returns ENTRY_* like UpdateEntry.
int UpdateUnbar(int client, NavBot bot, const float me[3], float moveGoal[3])
{
	int door = EntRefToEntIndex(g_unbarDoor[client]);
	if (door == INVALID_ENT_REFERENCE || GetGameTime() > g_unbarUntil[client])
	{
		g_unbarDoor[client] = INVALID_ENT_REFERENCE;
		return ENTRY_NONE;
	}
	float dc[3];
	CenterOf(door, dc);
	int bar = DoorBar(door);
	if (bar == -1)
	{
		// Clear: open it for the others.
		AcceptEntityInput(door, "Unlock", client, client);
		AcceptEntityInput(door, "Open", client, client);
		Debug("%N unbarred and opened door %d", client, door);
		g_unbarDoor[client] = INVALID_ENT_REFERENCE;
		return ENTRY_NONE;
	}
	float bc[3], eye[3];
	CenterOf(bar, bc);
	GetClientEyePosition(client, eye);
	if (GetVectorDistance(eye, bc) > 80.0)
	{
		// Walk up to it on our (inside) side.
		float side[3];
		SubtractVectors(me, dc, side);
		side[2] = 0.0;
		NormalizeVector(side, side);
		ScaleVector(side, 50.0);
		AddVectors(bc, side, moveGoal);
		moveGoal[2] = me[2];
		Address area = NavBotNavMesh.GetNearestNavArea(moveGoal, 150.0, false, true);
		if (area != Address_Null)
			NavBotNavArea.GetClosestPointOnArea(area, moveGoal, moveGoal);
		if (GetVectorDistance(me, moveGoal) > 30.0)
			return ENTRY_PATH;
		NavBotMovementInterface.MoveTowards(bot.GetMovementInterface(), bc, 100);
		return ENTRY_STEER;
	}
	Address ctrl = bot.GetPlayerControllerInterface();
	NavBotPlayerControllerInterface.AimAtPos(ctrl, bc, LOOK_PRIORITY, 0.4, "Knocking the bar off a door");
	if (GetGameTime() >= g_nextShove[client] && NavBotPlayerControllerInterface.IsAimOnTarget(ctrl))
	{
		// Alternate swing (breaks wooden planks) and shove (moves padlocks and furniture).
		bool shove = !IsWooden(bar) && RoundToFloor(GetGameTime()) % 2 == 0;
		NavBotPlayerControllerInterface.PressButtonByID(ctrl, shove ? NAVBOT_BUTTON_ATTACKSEC : NAVBOT_BUTTON_ATTACKPRIM, 0.2);
		g_nextShove[client] = GetGameTime() + 0.7;
		float dir[3];
		SubtractVectors(bc, dc, dir);        // off the door, into the room or along the wall
		dir[2] = 0.0;
		if (GetVectorLength(dir) < 1.0)
			SubtractVectors(me, dc, dir);
		dir[2] = 0.0;
		NormalizeVector(dir, dir);
		DataPack pack;
		CreateDataTimer(0.25, Timer_ShoveImpulse, pack, TIMER_FLAG_NO_MAPCHANGE);
		pack.WriteCell(EntIndexToEntRef(bar));
		pack.WriteFloat(dir[0]);
		pack.WriteFloat(dir[1]);
	}
	return ENTRY_STEER;
}


// Breaking in: walk to the chosen entrance, then through it. Doors: path to the inside point
// (whatever is in the way gets smashed or shoved by the obstacle code). Ground-floor windows:
// smash the glass, keep hitting until it's clear, then climb straight in (jump + crouch),
// without the pathfinder sending us round to a door.
int UpdateEntry(int client, NavBot bot, const float me[3], const float target[3], float moveGoal[3])
{
	Address ctrl = bot.GetPlayerControllerInterface();
	if (GetGameTime() < g_entryInUntil[client])
	{
		// Through? Past most of the way from the outside point to the inside point (on the sill
		// or just inside counts): stop climbing and go hunting.
		float dir[3], rel[3], plane[3];
		SubtractVectors(g_entryIn[client], g_entryOut[client], dir);
		dir[2] = 0.0;
		float len = GetVectorLength(dir);
		NormalizeVector(dir, dir);
		int went = EntRefToEntIndex(g_entryEnt[client]);
		if (went != INVALID_ENT_REFERENCE && IsValidEntity(went))
			CenterOf(went, plane);           // 16+ units past the window or door itself
		else
		{
			for (int i = 0; i < 3; i++) plane[i] = g_entryOut[client][i] + (g_entryIn[client][i] - g_entryOut[client][i]) * 0.6;
		}
		SubtractVectors(me, plane, rel);
		rel[2] = 0.0;
		bool through = len > 0.0 && GetVectorDotProduct(rel, dir) > 16.0;
		if (through || GetVectorDistance(me, g_entryIn[client]) < 40.0)
		{
			g_entryInUntil[client] = 0.0;   // inside
			g_entryCooldown[client] = GetGameTime() + 45.0;   // hunt in here; no going back out to an entrance
			if (g_entryWindow[client])
				StartUnbar(client, me);      // came in through a window: open a barred door for the horde
			return ENTRY_NONE;
		}
		if (!g_entryWindow[client])
		{
			moveGoal = g_entryIn[client];
			return ENTRY_PATH;
		}
		float look[3];
		look = g_entryIn[client];
		look[2] += 40.0;
		NavBotPlayerControllerInterface.AimAtPos(ctrl, look, LOOK_MOVEMENT, 0.3, "Climbing in");
		NavBotMovementInterface.MoveTowards(bot.GetMovementInterface(), g_entryIn[client], 100);
		if (GetEntityFlags(client) & FL_ONGROUND)
		{
			NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_JUMP, 0.1);
			NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_CROUCH, 0.6);
		}
		return ENTRY_STEER;
	}

	// Smashing the window of our entrance.
	if (GetGameTime() < g_entrySmashUntil[client])
	{
		int win = EntRefToEntIndex(g_entryEnt[client]);
		if (!WindowIntact(win) && g_entryClearAt[client] == 0.0)
			g_entryClearAt[client] = GetGameTime();
		// Broken: a second more of swings clears the shards, then climb in.
		if (g_entryClearAt[client] > 0.0 && GetGameTime() - g_entryClearAt[client] > 1.0)
		{
			g_entrySmashUntil[client] = 0.0;
			g_entryInUntil[client] = GetGameTime() + 4.0;
			g_entryCooldown[client] = GetGameTime() + 20.0;
			Debug("%N climbs in through the window", client);
			return ENTRY_STEER;
		}
		float c[3];
		if (win != INVALID_ENT_REFERENCE && IsValidEntity(win))
			CenterOf(win, c);
		else
			c = g_entryIn[client];
		NavBotPlayerControllerInterface.AimAtPos(ctrl, c, LOOK_PRIORITY, 0.4, "Smashing a window");
		NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_ATTACKPRIM, 0.3);
		return ENTRY_STEER;
	}
	if (g_entrySmashUntil[client] != 0.0)
	{
		// 8 s and the window still holds (boarded up, reinforced): too strong or too slow. Tell
		// the horde, and break in through a door instead.
		g_entrySmashUntil[client] = 0.0;
		int win = EntRefToEntIndex(g_entryEnt[client]);
		if (win != INVALID_ENT_REFERENCE && g_toughWinCount < sizeof(g_toughWin))
			g_toughWin[g_toughWinCount++] = g_entryEnt[client];
		g_doorsOnlyUntil[client] = GetGameTime() + 30.0;
		g_hasEntry[client] = false;
		g_entryCooldown[client] = 0.0;
		Debug("%N: window too strong, going for a door", client);
		return ENTRY_NONE;
	}

	// Whenever we're outside and the survivor is in a house: go in through a window (or a door),
	// even if we can see them through the glass. Rushing straight at them sends the pathfinder
	// round to whatever door it knows.
	if (Learned_Indoors(me) || !Learned_Indoors(target) || GetGameTime() < g_entryCooldown[client])
	{
		g_hasEntry[client] = false;
		return ENTRY_NONE;
	}
	if (!g_hasEntry[client] || GetGameTime() - g_entryChosen[client] > 30.0)
	{
		if (!ChooseEntry(client, target))
		{
			g_entryCooldown[client] = GetGameTime() + 5.0;
			return ENTRY_NONE;
		}
	}
	if (GetVectorDistance(me, g_entryOut[client]) > 60.0)
	{
		moveGoal = g_entryOut[client];
		return ENTRY_PATH;
	}
	// At the entrance.
	g_hasEntry[client] = false;
	if (g_entryWindow[client])
	{
		g_entrySmashUntil[client] = GetGameTime() + 8.0;
		g_entryClearAt[client] = WindowIntact(EntRefToEntIndex(g_entryEnt[client])) ? 0.0 : GetGameTime() - 1.0;
		Debug("%N smashes the window", client);
		return ENTRY_STEER;
	}
	g_entryInUntil[client] = GetGameTime() + 8.0;
	g_entryCooldown[client] = GetGameTime() + 20.0;
	moveGoal = g_entryIn[client];
	return ENTRY_PATH;
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

// Wooden barricades: planks (func_physbox), boards survivors nailed up (barricade models),
// wooden breakables. Broken with normal hits (left click), never shoved.
bool IsWooden(int ent)
{
	if (ent <= MaxClients || !IsValidEntity(ent))
		return false;
	char cls[64];
	GetEntityClassname(ent, cls, sizeof(cls));
	if (StrContains(cls, "func_physbox") != -1)
		return true;
	if (StrEqual(cls, "func_breakable") && GetEntProp(ent, Prop_Data, "m_Material") == 1)
		return true;
	if (HasEntProp(ent, Prop_Data, "m_ModelName"))
	{
		char model[128];
		GetEntPropString(ent, Prop_Data, "m_ModelName", model, sizeof(model));
		if (StrContains(model, "barricade", false) != -1 || StrContains(model, "wood", false) != -1 || StrContains(model, "plank", false) != -1)
			return true;
	}
	return false;
}

bool IsFurniture(int ent)
{
	char cls[64];
	GetEntityClassname(ent, cls, sizeof(cls));
	if (StrContains(cls, "prop_physics") == -1 || IsWooden(ent))
		return false;                    // only movable furniture gets shoved; wood gets smashed
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
	if (!g_buildSteps.BoolValue)
		return;
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
	if (Stairs_Update(client, bot, me, target, moveGoal, routeType, stairs, Unstick_StuckFor(client) > 2.5))
	{
		g_blockedSince[client] = 0.0;
		if (stairs == Plugin_Continue)
			g_us_wantMove[client] = false;     // steering ourselves; don't let unstick detour us
		else
			Unstick_WantMove(client, me, moveGoal);
		return stairs;
	}

	// Target holed up in a building: attack through an entrance of our own.
	int entry = UpdateUnbar(client, bot, me, moveGoal);
	if (entry == ENTRY_NONE)
		entry = UpdateBreach(client, bot, me, g_target[client], moveGoal);   // survivor in a sealed-off part
	if (entry == ENTRY_NONE)
		entry = UpdateEntry(client, bot, me, target, moveGoal);
	if (entry == ENTRY_STEER)
	{
		g_blockedSince[client] = 0.0;
		g_us_wantMove[client] = false;
		return Plugin_Continue;
	}
	if (entry == ENTRY_PATH)
	{
		g_blockedSince[client] = 0.0;
		routeType = NAVBOT_FASTEST_ROUTE;
		Unstick_WantMove(client, me, moveGoal);
		return Plugin_Changed;
	}

	// Close and in plain view: go straight for them.
	if (sees && GetVectorDistance(me, target) < 200.0)
	{
		// Up on a ledge, a bed, a shelf: jump at them (crouched), swinging.
		float dx = target[0] - me[0], dy = target[1] - me[1];
		if (target[2] - me[2] > 30.0 && dx * dx + dy * dy < 90.0 * 90.0 && (GetEntityFlags(client) & FL_ONGROUND))
		{
			Address ctrl = bot.GetPlayerControllerInterface();
			NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_JUMP, 0.1);
			NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_CROUCH, 0.6);
			NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_ATTACKPRIM, 0.3);
		}
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
int AreaComp(Address a)
{
	if (a == Address_Null)
		return -1;
	int id = NavBotNavArea.GetID(a);
	return id >= 0 && id < COMP_MAX_ID ? g_comp[id] : -1;
}

void LabelRegions()
{
	for (int i = 0; i < COMP_MAX_ID; i++)
		g_comp[i] = -1;
	float lo[3] = { -32768.0, -32768.0, -32768.0 }, hi[3] = { 32768.0, 32768.0, 32768.0 };
	NavBotNavAreaVector all = NavBotNavMesh.CollectAreasOverlappingExtent(lo, hi);
	ArrayList queue = new ArrayList();
	int comps = 0;
	for (int i = 0; i < all.Size; i++)
	{
		Address start = all.At(i);
		int sid = NavBotNavArea.GetID(start);
		if (sid < 0 || sid >= COMP_MAX_ID || g_comp[sid] != -1)
			continue;
		g_comp[sid] = comps;
		queue.Clear();
		queue.Push(start);
		while (queue.Length > 0)
		{
			Address a = queue.Get(queue.Length - 1);
			queue.Erase(queue.Length - 1);
			// Undirected: a region is everything joined by a connection either way (drops count).
			for (int d = 0; d < 4; d++)
			{
				int n = NavBotNavArea.GetAdjacentAreaCount(a, view_as<NavBotNavDirType>(d));
				for (int k = 0; k < n; k++)
				{
					Address b = NavBotNavArea.GetAdjacentArea(a, view_as<NavBotNavDirType>(d), k);
					int bid = b != Address_Null ? NavBotNavArea.GetID(b) : -1;
					if (bid < 0 || bid >= COMP_MAX_ID || g_comp[bid] != -1)
						continue;
					g_comp[bid] = comps;
					queue.Push(b);
				}
			}
			int off = NavBotNavArea.GetOffMeshConnectionCount(a);
			for (int k = 0; k < off; k++)
			{
				Address b = NavBotNavOffMeshConnection.GetConnectedArea(NavBotNavArea.GetOffMeshConnection(a, k));
				int bid = b != Address_Null ? NavBotNavArea.GetID(b) : -1;
				if (bid < 0 || bid >= COMP_MAX_ID || g_comp[bid] != -1)
					continue;
				g_comp[bid] = comps;
				queue.Push(b);
			}
		}
		comps++;
	}
	delete queue;
	delete all;
	LogMessage("Nav regions: %d", comps);
}

// The walkable floor on one side of an opening: step out along the normal, trace down to the
// floor, take the nav area there. Returns the area and a point on it.
Address SideArea(const float center[3], const float n[3], float sign, float point[3])
{
	for (float dist = 32.0; dist <= 128.0; dist += 16.0)
	{
		float p[3], down[3];
		p[0] = center[0] + n[0] * dist * sign;
		p[1] = center[1] + n[1] * dist * sign;
		p[2] = center[2];
		down = p;
		down[2] -= 300.0;
		TR_TraceRayFilter(p, down, MASK_PLAYERSOLID_BRUSHONLY, RayType_EndPoint, TraceWorldOnly);
		if (TR_StartSolid() || !TR_DidHit())
			continue;
		float floorPos[3];
		TR_GetEndPosition(floorPos);
		floorPos[2] += 16.0;
		Address area = NavBotNavMesh.GetNearestNavArea(floorPos, 40.0, false, true);
		if (area == Address_Null)
			continue;
		NavBotNavArea.GetClosestPointOnArea(area, floorPos, point);
		float rel = (point[0] - center[0]) * n[0] * sign + (point[1] - center[1]) * n[1] * sign;
		if (rel > 8.0)
			return area;
	}
	return Address_Null;
}

// Openings that got cleared (a plank knocked off, a bar removed and the door opened): link the
// nav areas through them so every zombie paths through, not just the one that broke it.
// Windows still need a climb, which path following can't do: those stay with the break-in code.
void LinkClearedOpenings()
{
	bool changed = false;
	for (int k = 0; k < g_brCount; k++)
	{
		if (g_brOpen[k] || g_brClimb[k] || g_brKind[k] == BR_WINDOW || !BlockerGone(k))
			continue;
		g_brOpen[k] = true;
		Address a = NavBotNavMesh.GetNearestNavArea(g_brSide[k][0], 40.0, false, true);
		Address b = NavBotNavMesh.GetNearestNavArea(g_brSide[k][1], 40.0, false, true);
		if (a == Address_Null || b == Address_Null || a == b)
			continue;
		if (!NavBotNavArea.IsConnectedToAny(a, b)) NavBotNavArea.ConnectToAdjacent(a, b);
		if (!NavBotNavArea.IsConnectedToAny(b, a)) NavBotNavArea.ConnectToAdjacent(b, a);
		changed = true;
		Debug("Opening at %.0f %.0f %.0f is clear: linked for the horde", g_brStart[k][0], g_brStart[k][1], g_brStart[k][2]);
	}
	if (changed)
	{
		LabelRegions();
		for (int k = 0; k < g_brCount; k++)
		{
			g_brComp[k][0] = AreaComp(NavBotNavMesh.GetNearestNavArea(g_brSide[k][0], 40.0, false, true));
			g_brComp[k][1] = AreaComp(NavBotNavMesh.GetNearestNavArea(g_brSide[k][1], 40.0, false, true));
		}
	}
}

// Scan every door, plank and window: link plain doors, record the rest as openings to break.
int LinkDoors(bool verbose)
{
	g_brCount = 0;
	static const char classes[][] = { "func_door_rotating", "prop_door_rotating", "func_door", "func_physbox", "func_physbox_multiplayer", "func_breakable_surf", "func_breakable" };
	int linked = 0;
	for (int c = 0; c < sizeof(classes); c++)
	{
		int ent = -1;
		while ((ent = FindEntityByClassname(ent, classes[c])) != -1)
		{
			if (!HasEntProp(ent, Prop_Send, "m_vecMins"))
				continue;
			bool isDoor = c <= 2, isPlank = c == 3 || c == 4;
			float center[3], mins[3], maxs[3], origin[3];
			CenterOf(ent, center);
			GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", origin);
			GetEntPropVector(ent, Prop_Send, "m_vecMins", mins);
			GetEntPropVector(ent, Prop_Send, "m_vecMaxs", maxs);
			float sx = maxs[0] - mins[0], sy = maxs[1] - mins[1], sz = maxs[2] - mins[2];
			float thin = sx < sy ? sx : sy, wide = sx < sy ? sy : sx;
			if (thin > 16.0 || wide < 24.0 || wide > 140.0)
				continue;                    // not an opening-shaped thing
			if (isDoor && (sz < 70.0 || sz > 160.0))
				continue;
			if (!isDoor && !isPlank && (sz < 20.0 || sz > 140.0))
				continue;
			float n[3];
			n[0] = sx < sy ? 1.0 : 0.0;
			n[1] = sx < sy ? 0.0 : 1.0;
			float pa[3], pb[3];
			Address areaA = SideArea(center, n, 1.0, pa);
			Address areaB = SideArea(center, n, -1.0, pb);
			if (areaA == Address_Null || areaB == Address_Null || areaA == areaB || FloatAbs(pa[2] - pb[2]) > 24.0)
				continue;
			// Only through the opening: nothing of the world in the way at its middle height.
			float ma[3], mb[3];
			ma = pa; mb = pb;
			float midZ = isDoor ? (pa[2] + 40.0) : center[2];
			ma[2] = midZ; mb[2] = midZ;
			TR_TraceRayFilter(ma, mb, MASK_SOLID_BRUSHONLY, RayType_EndPoint, TraceWorldOnly);
			if (TR_DidHit())
				continue;
			float bottom = origin[2] + mins[2];
			float floorZ = pa[2] > pb[2] ? pa[2] : pb[2];
			if (!isDoor && bottom - floorZ > 56.0)
				continue;                    // too high to climb through

			int bar = isDoor ? DoorBar(ent) : -1;
			if (isDoor && bar == -1)
			{
				// A plain door: everyone can walk through. Link it.
				bool ab = NavBotNavArea.IsConnectedToAny(areaA, areaB), ba = NavBotNavArea.IsConnectedToAny(areaB, areaA);
				if (ab && ba)
					continue;
				bool made = false;
				if (!ab) made = NavBotNavArea.ConnectToAdjacent(areaA, areaB) || made;
				if (!ba) made = NavBotNavArea.ConnectToAdjacent(areaB, areaA) || made;
				if (made)
					linked++;
				if (verbose)
					PrintToServer("[doorlinks] door %d at %.0f %.0f %.0f: areas #%d <-> #%d %s", ent, center[0], center[1], center[2],
						NavBotNavArea.GetID(areaA), NavBotNavArea.GetID(areaB), made ? "linked" : "could not link");
				continue;
			}
			if (!isDoor && !isPlank)
			{
				// Windows: glass (func_breakable_surf, glass func_breakable) only.
				if (c == 6 && GetEntProp(ent, Prop_Data, "m_Material") != 0)
					continue;
			}
			if (g_brCount >= BR_MAX)
				continue;
			int k = g_brCount++;
			g_brEnt[k] = EntIndexToEntRef(ent);
			g_brKind[k] = isDoor ? BR_BARDOOR : (isPlank ? BR_PLANK : BR_WINDOW);
			g_brSide[k][0] = pa;
			g_brSide[k][1] = pb;
			g_brClimb[k] = !isDoor && bottom - floorZ > 14.0;
			g_brStart[k] = center;
			g_brTough[k] = false;
			g_brOpen[k] = false;
			if (verbose)
				PrintToServer("[doorlinks] %s %d at %.0f %.0f %.0f: areas #%d | #%d, to break through%s",
					isDoor ? "barred door" : (isPlank ? "plank" : "window"), ent, center[0], center[1], center[2],
					NavBotNavArea.GetID(areaA), NavBotNavArea.GetID(areaB), g_brClimb[k] ? " (climb)" : "");
		}
	}
	LabelRegions();
	for (int k = 0; k < g_brCount; k++)
	{
		g_brComp[k][0] = AreaComp(NavBotNavMesh.GetNearestNavArea(g_brSide[k][0], 40.0, false, true));
		g_brComp[k][1] = AreaComp(NavBotNavMesh.GetNearestNavArea(g_brSide[k][1], 40.0, false, true));
	}
	return linked;
}

Action Cmd_DoorBars(int args)
{
	static const char doors[][] = { "func_door_rotating", "prop_door_rotating", "func_door" };
	static const char props[][] = { "prop_physics_multiplayer", "prop_physics", "prop_physics_override", "prop_physics_respawnable", "func_physbox", "func_physbox_multiplayer" };
	for (int c = 0; c < sizeof(doors); c++)
	{
		int door = -1;
		while ((door = FindEntityByClassname(door, doors[c])) != -1)
		{
			float dc[3];
			CenterOf(door, dc);
			for (int k = 0; k < sizeof(props); k++)
			{
				int p = -1;
				while ((p = FindEntityByClassname(p, props[k])) != -1)
				{
					float pc[3];
					CenterOf(p, pc);
					if (GetVectorDistance(pc, dc) > 90.0)
						continue;
					char model[128] = "-";
					if (HasEntProp(p, Prop_Data, "m_ModelName"))
						GetEntPropString(p, Prop_Data, "m_ModelName", model, sizeof(model));
					PrintToServer("door %d %s at %.0f %.0f %.0f state %d: %s %d %s at %.0f %.0f %.0f", door, doors[c], dc[0], dc[1], dc[2],
						HasEntProp(door, Prop_Data, "m_toggle_state") ? GetEntProp(door, Prop_Data, "m_toggle_state") : -1,
						props[k], p, model, pc[0], pc[1], pc[2]);
				}
			}
		}
	}
	return Plugin_Handled;
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
	static float nextOpenCheck;
	if (g_doorsLinked && GetGameTime() >= nextOpenCheck)
	{
		nextOpenCheck = GetGameTime() + 2.0;
		LinkClearedOpenings();
	}
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
