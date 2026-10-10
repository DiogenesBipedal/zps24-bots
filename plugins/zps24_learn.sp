// Learn from the main player: follow the teacher (server admins, i.e. the host, or the player
// named by sm_zps24learn_teacher) and record, per map,
//
//   hold spots  places they stay put for sm_zps24learn_hold_time seconds while alive
//   routes      paths between floors over ground the nav mesh doesn't cover (steep stairs,
//               jumps, climbs): from the last point on the mesh to the first point back on it
//   style       how far the nearest zombie is when they open fire, and when they back away
//   furniture   which pieces they move (shove or carry) and where they leave them: the
//               survivor bots' barricaders put the same pieces in the same places
//   entries     (as a zombie) where they get into buildings: the last point outside and the
//               first point inside; zombie bots attack houses through these first
//
// The survivor and zombie AI plugins read the file (include/zps24_learned.inc): survivors defend
// from learned hold spots first, both teams walk learned routes, survivors copy the distances.
//
//   sm_zps24learn_status         what has been learned on this map
//   sm_zps24learn_forget         wipe this map's file
#include <sourcemod>
#include <sdktools>
#include <navbot>
#include "include/zps24_learned.inc"

public Plugin myinfo =
{
	name = "ZPS 2.4 learn from humans",
	author = "Dead Apocalypse",
	description = "Record human survivors' hold spots, routes and fighting distances for the bots",
	version = "1.0"
};

#define TEAM_SURVIVORS 2
#define TEAM_ZOMBIES   3
#define TICK           0.25

ConVar g_enable, g_holdTime, g_debug, g_teacher;

// Per human
float g_anchor[MAXPLAYERS + 1][3];          // where they've been standing
float g_anchorSince[MAXPLAYERS + 1];
bool  g_wasOnMesh[MAXPLAYERS + 1];          // has been on the mesh (so a trail has a start)
bool  g_inTrail[MAXPLAYERS + 1];
float g_lastOnMesh[MAXPLAYERS + 1][3];
int   g_trailLen[MAXPLAYERS + 1];
float g_trail[MAXPLAYERS + 1][64][3];        // off-mesh path being recorded
float g_trailSince[MAXPLAYERS + 1];
bool  g_trailBad[MAXPLAYERS + 1];            // ladder, noclip, hook or teleport on the way: not walkable by bots
float g_prevPos[MAXPLAYERS + 1][3];          // position last tick (spots teleports and the grappling hook)
bool  g_wasShooting[MAXPLAYERS + 1];
float g_lastOutside[MAXPLAYERS + 1][3];      // as a zombie: last spot outdoors, on the ground
float g_lastOutsideAt[MAXPLAYERS + 1];

// Furniture near the teacher, watched for being moved
#define MAX_TRACK 32
int   g_trk[MAX_TRACK];                      // entity references
float g_trkStart[MAX_TRACK][3];              // where it was before this move
float g_trkLast[MAX_TRACK][3];               // last tick
bool  g_trkMoved[MAX_TRACK];                 // moved by the teacher
float g_handsOn[MAXPLAYERS + 1];             // last time the teacher pressed use / shove / attack
bool  g_wasRetreating[MAXPLAYERS + 1];

public void OnPluginStart()
{
	g_enable   = CreateConVar("sm_zps24learn_enable", "1", "Learn hold spots, routes and fighting distances from human survivors");
	g_holdTime = CreateConVar("sm_zps24learn_hold_time", "10", "Seconds a human must stay put for the spot to count as a hold spot");
	g_debug    = CreateConVar("sm_zps24learn_debug", "1", "Announce what was learned in the server log");
	g_teacher  = CreateConVar("sm_zps24learn_teacher", "", "Learn only from the player whose name contains this (empty = from server admins only)");
	RegServerCmd("sm_zps24learn_status", Cmd_Status, "What the bots have learned on this map");
	RegServerCmd("sm_zps24learn_forget", Cmd_Forget, "Forget everything learned on this map");
	RegServerCmd("sm_zps24learn_drop", Cmd_Drop, "sm_zps24learn_drop <spot|route|furniture|entry> <index>: forget one lesson");
	HookEventEx("player_death", Event_PlayerDeath, EventHookMode_Post);
}

public void OnMapStart()
{
	Learned_Load();
	for (int i = 0; i <= MaxClients; i++)
		ResetClient(i);
	for (int t = 0; t < MAX_TRACK; t++)
		g_trk[t] = INVALID_ENT_REFERENCE;
	CreateTimer(TICK, Timer_Watch, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void ResetClient(int client)
{
	g_anchorSince[client] = 0.0;
	g_wasOnMesh[client] = false;
	g_inTrail[client] = false;
	g_trailLen[client] = 0;
	g_wasShooting[client] = false;
	g_wasRetreating[client] = false;
}

void Note(const char[] fmt, any ...)
{
	if (!g_debug.BoolValue)
		return;
	char buf[256];
	VFormat(buf, sizeof(buf), fmt, 2);
	LogMessage("%s", buf);
}

// A human's hold spot ends when they move off it or die: keep it if they held it long enough.
void EndHold(int client, bool died)
{
	if (g_anchorSince[client] == 0.0)
		return;
	float secs = GetGameTime() - g_anchorSince[client];
	g_anchorSince[client] = 0.0;
	if (secs < g_holdTime.FloatValue)
		return;
	if (died)
		secs *= 0.25;                    // they held it, but it got them killed
	int best = -1;
	for (int i = 0; i < g_ln_spotCount; i++)
		if (GetVectorDistance(g_ln_spots[i], g_anchor[client]) < 64.0) { best = i; break; }
	if (best == -1)
	{
		if (g_ln_spotCount < LEARN_MAX_SPOTS)
			best = g_ln_spotCount++;
		else
		{
			best = 0;                        // replace the least-held spot
			for (int i = 1; i < g_ln_spotCount; i++)
				if (g_ln_spotSecs[i] < g_ln_spotSecs[best]) best = i;
		}
		g_ln_spots[best] = g_anchor[client];
		g_ln_spotSecs[best] = 0.0;
	}
	g_ln_spotSecs[best] += secs;
	Learned_Save();
	Note("Learned hold spot %d at %.0f %.0f %.0f from %N (%.0f s, %.0f s in total)", best,
		g_anchor[client][0], g_anchor[client][1], g_anchor[client][2], client, secs, g_ln_spotSecs[best]);
}

void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client > 0 && client <= MaxClients)
	{
		EndHold(client, true);
		ResetClient(client);
	}
}

// Standing on the nav mesh: right over an area, at its height.
bool OnMesh(const float pos[3])
{
	Address area = NavBotNavMesh.GetNearestNavArea(pos, 64.0, false, false);
	if (area == Address_Null)
		return false;
	float p[3];
	NavBotNavArea.GetClosestPointOnArea(area, pos, p);
	float dx = p[0] - pos[0], dy = p[1] - pos[1];
	return dx * dx + dy * dy < 12.0 * 12.0 && FloatAbs(p[2] - pos[2]) < 20.0;
}

// Back on the mesh after a stretch off it: keep the path if it changed floors.
void EndTrail(int client, const float pos[3])
{
	int n = g_trailLen[client];
	g_trailLen[client] = 0;
	float secs = GetGameTime() - g_trailSince[client];
	float start[3];
	start = g_lastOnMesh[client];
	if (g_trailBad[client] || secs > 45.0 || FloatAbs(pos[2] - start[2]) < 48.0)
		return;

	// Points: last spot on the mesh, the path (thinned to fit), first spot back on the mesh.
	float pts[LEARN_MAX_POINTS][3];
	int count = 0;
	pts[count++] = start;
	int room = LEARN_MAX_POINTS - 2;
	for (int i = 0; i < room && i < n; i++)
	{
		int k = n <= room ? i : RoundToFloor(float(i) * float(n) / float(room));
		pts[count++] = g_trail[client][k];
	}
	pts[count++] = pos;
	if (!Learned_RouteWalkable(pts, count))
		return;                              // a gap no player can walk or jump

	// Same route as one we know (both ends close): count the use, keep the old one.
	for (int r = 0; r < g_ln_routeCount; r++)
	{
		int last = g_ln_routeLen[r] - 1;
		if ((GetVectorDistance(g_ln_routes[r][0], start) < 64.0 && GetVectorDistance(g_ln_routes[r][last], pos) < 64.0)
			|| (GetVectorDistance(g_ln_routes[r][0], pos) < 64.0 && GetVectorDistance(g_ln_routes[r][last], start) < 64.0))
		{
			g_ln_routeUses[r]++;
			Learned_Save();
			return;
		}
	}
	if (g_ln_routeCount >= LEARN_MAX_ROUTES)
		return;
	int r = g_ln_routeCount++;
	g_ln_routeLen[r] = count;
	g_ln_routeUses[r] = 1;
	for (int i = 0; i < count; i++)
		g_ln_routes[r][i] = pts[i];
	Learned_Save();
	Note("Learned route %d from %N: %.0f %.0f %.0f -> %.0f %.0f %.0f, %d points", r, client,
		start[0], start[1], start[2], pos[0], pos[1], pos[2], count);
}

int NearestZombie(const float pos[3], float &dist)
{
	int best = 0;
	dist = 999999.0;
	float them[3];
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) != TEAM_ZOMBIES)
			continue;
		GetClientAbsOrigin(i, them);
		float d = GetVectorDistance(pos, them);
		if (d < dist) { dist = d; best = i; }
	}
	return best;
}

bool IsGunName(const char[] cls)
{
	static const char guns[][] = { "weapon_glock", "weapon_glock18c", "weapon_usp", "weapon_ppk", "weapon_revolver",
		"weapon_870", "weapon_supershorty", "weapon_winchester", "weapon_ak47", "weapon_m4", "weapon_mp5" };
	for (int i = 0; i < sizeof(guns); i++)
		if (StrEqual(cls, guns[i]))
			return true;
	return false;
}

// Is this the player the bots learn from?
bool IsTeacher(int client)
{
	if (!IsClientInGame(client) || IsFakeClient(client))
		return false;
	char want[64];
	g_teacher.GetString(want, sizeof(want));
	if (want[0] != '\0')
	{
		char name[64];
		GetClientName(client, name, sizeof(name));
		return StrContains(name, want, false) != -1;
	}
	return (GetUserFlagBits(client) & (ADMFLAG_ROOT | ADMFLAG_GENERIC)) != 0;
}

void RecordEntry(int client, const float out[3], const float inside[3])
{
	if (GetVectorDistance(out, inside) < 12.0)
		return;                              // standing at the edge of a roof: no way through to learn
	for (int e = 0; e < g_ln_entryCount; e++)
		if (GetVectorDistance(g_ln_entryIn[e], inside) < 80.0)
		{
			g_ln_entryUses[e]++;
			Learned_Save();
			return;
		}
	if (g_ln_entryCount >= LEARN_MAX_ENTRIES)
		return;
	int e = g_ln_entryCount++;
	g_ln_entryOut[e] = out;
	g_ln_entryIn[e] = inside;
	g_ln_entryUses[e] = 1;
	Learned_Save();
	Note("Learned entry %d from %N: %.0f %.0f %.0f -> %.0f %.0f %.0f", e, client, out[0], out[1], out[2], inside[0], inside[1], inside[2]);
}

// ---------------------------------------------------------------------------------------------
// Furniture the teacher moves

int HammerID(int ent)
{
	return HasEntProp(ent, Prop_Data, "m_iHammerID") ? GetEntProp(ent, Prop_Data, "m_iHammerID") : 0;
}

void TrackFurnitureNear(const float pos[3])
{
	static const char classes[][] = { "prop_physics_multiplayer", "prop_physics", "prop_physics_override", "prop_physics_respawnable" };
	for (int c = 0; c < sizeof(classes); c++)
	{
		int ent = -1;
		while ((ent = FindEntityByClassname(ent, classes[c])) != -1)
		{
			float p[3];
			GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", p);
			if (GetVectorDistance(p, pos) > 110.0)
				continue;
			int ref = EntIndexToEntRef(ent), free = -1;
			bool known = false;
			for (int t = 0; t < MAX_TRACK; t++)
			{
				if (g_trk[t] == ref) { known = true; break; }
				if (free == -1 && EntRefToEntIndex(g_trk[t]) == INVALID_ENT_REFERENCE) free = t;
			}
			if (known || free == -1)
				continue;
			g_trk[free] = ref;
			g_trkStart[free] = p;
			g_trkLast[free] = p;
			g_trkMoved[free] = false;
		}
	}
}

// A tracked prop that moved with the teacher next to it and has come to rest: a placement.
void UpdateTracked(int teacher)
{
	float me[3];
	GetClientAbsOrigin(teacher, me);
	for (int t = 0; t < MAX_TRACK; t++)
	{
		int ent = EntRefToEntIndex(g_trk[t]);
		if (ent == INVALID_ENT_REFERENCE)
			continue;
		float p[3];
		GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", p);
		float step = GetVectorDistance(p, g_trkLast[t]);
		g_trkLast[t] = p;
		if (step > 2.0)
		{
			// The teacher is moving it: right next to it and using their hands (use to carry,
			// right click to shove, attack). Bots pushing furniture nearby don't count.
			if (GetVectorDistance(p, me) < 100.0 && GetGameTime() - g_handsOn[teacher] < 1.5)
				g_trkMoved[t] = true;
			else if (!g_trkMoved[t])
				g_trkStart[t] = p;             // something else moved it (a zombie, physics)
			continue;
		}
		if (g_trkMoved[t] && GetVectorDistance(p, g_trkStart[t]) >= 48.0)
			RecordPlacement(ent, g_trkStart[t], p, GetClientTeam(teacher));
		g_trkMoved[t] = false;
		g_trkStart[t] = p;
		if (GetVectorDistance(p, me) > 500.0)
			g_trk[t] = INVALID_ENT_REFERENCE;   // out of the teacher's way: stop watching
	}
}

void RecordPlacement(int ent, const float from[3], const float to[3], int team)
{
	int hammer = HammerID(ent);
	int k = -1;
	for (int i = 0; i < g_ln_placeCount; i++)
		if ((hammer > 0 && g_ln_placeHammer[i] == hammer) || (hammer == 0 && GetVectorDistance(g_ln_placeTo[i], from) < 16.0))
		{
			k = i;
			break;
		}
	if (k == -1)
	{
		if (g_ln_placeCount >= LEARN_MAX_PLACES)
			return;
		k = g_ln_placeCount++;
		g_ln_placeHammer[k] = hammer;
		g_ln_placeFrom[k] = from;               // where it starts the round
	}
	g_ln_placeTeam[k] = team;
	if (GetVectorDistance(to, g_ln_placeFrom[k]) < 48.0)
	{
		// Put back where it started: forget it.
		g_ln_placeCount--;
		for (int i = k; i < g_ln_placeCount; i++)
		{
			g_ln_placeHammer[i] = g_ln_placeHammer[i + 1];
			g_ln_placeFrom[i] = g_ln_placeFrom[i + 1];
			g_ln_placeTo[i] = g_ln_placeTo[i + 1];
			g_ln_placeTeam[i] = g_ln_placeTeam[i + 1];
		}
		Learned_Save();
		return;
	}
	g_ln_placeTo[k] = to;
	Learned_Save();
	Note("Learned %s furniture placement %d (prop hammer ID %d): %.0f %.0f %.0f -> %.0f %.0f %.0f", team == TEAM_ZOMBIES ? "zombie" : "survivor", k, hammer,
		g_ln_placeFrom[k][0], g_ln_placeFrom[k][1], g_ln_placeFrom[k][2], to[0], to[1], to[2]);
}

Action Timer_Watch(Handle timer)
{
	if (!g_enable.BoolValue || !LibraryExists("navbot") || !NavBotNavMesh.IsLoaded())
		return Plugin_Continue;
	bool dirty = false;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsTeacher(client) || !IsPlayerAlive(client) || GetClientTeam(client) < TEAM_SURVIVORS)
		{
			if (g_anchorSince[client] != 0.0 || g_inTrail[client]) ResetClient(client);
			continue;
		}
		bool survivor = GetClientTeam(client) == TEAM_SURVIVORS;
		MoveType mt = GetEntityMoveType(client);
		float pos[3];
		GetClientAbsOrigin(client, pos);
		// Faster than any run or jump (grappling hook, teleport, respawn): not a route to learn.
		bool flew = GetVectorDistance(pos, g_prevPos[client]) > 300.0;
		g_prevPos[client] = pos;
		if (flew && g_inTrail[client])
			g_trailBad[client] = true;

		// Ways into buildings (as a zombie)
		if (!survivor && (GetEntityFlags(client) & FL_ONGROUND))
		{
			if (!Learned_Indoors(pos))
			{
				g_lastOutside[client] = pos;
				g_lastOutsideAt[client] = GetGameTime();
			}
			else if (g_lastOutsideAt[client] > 0.0 && GetGameTime() - g_lastOutsideAt[client] < 1.0
				&& GetVectorDistance(pos, g_lastOutside[client]) < 200.0)
			{
				RecordEntry(client, g_lastOutside[client], pos);
				g_lastOutsideAt[client] = 0.0;
			}
		}

		if (GetClientButtons(client) & (IN_USE | IN_ATTACK2 | IN_ATTACK))
			g_handsOn[client] = GetGameTime();

		// Furniture (as a survivor: barricades)
		if (survivor)
		{
			TrackFurnitureNear(pos);
			UpdateTracked(client);
		}

		// Hold spots (as a survivor)
		if (survivor && (g_anchorSince[client] == 0.0 || GetVectorDistance(pos, g_anchor[client]) > 80.0))
		{
			EndHold(client, false);
			g_anchor[client] = pos;
			g_anchorSince[client] = GetGameTime();
		}

		// Routes off the nav mesh: from the last point on it to the first point back on it.
		bool onGround = (GetEntityFlags(client) & FL_ONGROUND) != 0;
		if (onGround && OnMesh(pos))
		{
			if (g_inTrail[client])
				EndTrail(client, pos);
			g_inTrail[client] = false;
			g_lastOnMesh[client] = pos;
			g_wasOnMesh[client] = true;
		}
		else if (g_wasOnMesh[client])
		{
			if (!g_inTrail[client])
			{
				g_inTrail[client] = true;
				g_trailSince[client] = GetGameTime();
				g_trailLen[client] = 0;
				g_trailBad[client] = false;
			}
			if (mt == MOVETYPE_NOCLIP || mt == MOVETYPE_LADDER || mt == MOVETYPE_FLY)
				g_trailBad[client] = true;    // bots can't follow that
			int n = g_trailLen[client];
			if (onGround && n < sizeof(g_trail[]) && (n == 0 || GetVectorDistance(pos, g_trail[client][n - 1]) > 24.0))
				g_trail[client][g_trailLen[client]++] = pos;
			if (GetGameTime() - g_trailSince[client] > 45.0)
			{
				g_inTrail[client] = false;    // wandering off the mesh, not a route
				g_wasOnMesh[client] = false;
			}
		}

		// Fighting style (as a survivor)
		if (!survivor)
			continue;
		float zd;
		int z = NearestZombie(pos, zd);
		int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
		char cls[64];
		if (weapon > 0)
			GetEntityClassname(weapon, cls, sizeof(cls));
		bool shooting = z != 0 && zd < 1500.0 && weapon > 0 && IsGunName(cls) && (GetClientButtons(client) & IN_ATTACK);
		if (shooting && !g_wasShooting[client])
		{
			g_ln_shootSum += zd;
			g_ln_shootN++;
			dirty = true;
		}
		g_wasShooting[client] = shooting;

		bool retreating = false;
		if (z != 0 && zd < 600.0)
		{
			float vel[3], them[3], away[3];
			GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", vel);
			vel[2] = 0.0;
			GetClientAbsOrigin(z, them);
			SubtractVectors(pos, them, away);
			away[2] = 0.0;
			NormalizeVector(away, away);
			float speed = GetVectorLength(vel);
			retreating = speed > 100.0 && GetVectorDotProduct(vel, away) / speed > 0.7;
		}
		if (retreating && !g_wasRetreating[client])
		{
			g_ln_retreatSum += zd;
			g_ln_retreatN++;
			dirty = true;
		}
		g_wasRetreating[client] = retreating;
	}
	static float lastStyleSave;
	if (dirty && GetGameTime() - lastStyleSave > 10.0)
	{
		lastStyleSave = GetGameTime();
		Learned_Save();
	}
	return Plugin_Continue;
}

Action Cmd_Status(int args)
{
	PrintToServer("[learn] %d hold spots, %d routes, %d furniture placements, %d entries; opened fire at %.0f on average (%d times), backed away at %.0f (%d times)",
		g_ln_spotCount, g_ln_routeCount, g_ln_placeCount, g_ln_entryCount, g_ln_shootN ? g_ln_shootSum / float(g_ln_shootN) : 0.0, g_ln_shootN,
		g_ln_retreatN ? g_ln_retreatSum / float(g_ln_retreatN) : 0.0, g_ln_retreatN);
	for (int i = 0; i < g_ln_spotCount; i++)
		PrintToServer("  spot %d at %.0f %.0f %.0f held %.0f s", i, g_ln_spots[i][0], g_ln_spots[i][1], g_ln_spots[i][2], g_ln_spotSecs[i]);
	for (int r = 0; r < g_ln_routeCount; r++)
	{
		int last = g_ln_routeLen[r] - 1;
		PrintToServer("  route %d: %.0f %.0f %.0f -> %.0f %.0f %.0f, %d points, used %d times", r,
			g_ln_routes[r][0][0], g_ln_routes[r][0][1], g_ln_routes[r][0][2],
			g_ln_routes[r][last][0], g_ln_routes[r][last][1], g_ln_routes[r][last][2], g_ln_routeLen[r], g_ln_routeUses[r]);
	}
	for (int k = 0; k < g_ln_placeCount; k++)
		PrintToServer("  %s furniture %d (hammer ID %d): %.0f %.0f %.0f -> %.0f %.0f %.0f", g_ln_placeTeam[k] == TEAM_ZOMBIES ? "zombie" : "survivor", k, g_ln_placeHammer[k],
			g_ln_placeFrom[k][0], g_ln_placeFrom[k][1], g_ln_placeFrom[k][2], g_ln_placeTo[k][0], g_ln_placeTo[k][1], g_ln_placeTo[k][2]);
	for (int e = 0; e < g_ln_entryCount; e++)
		PrintToServer("  entry %d: %.0f %.0f %.0f -> %.0f %.0f %.0f, used %d times", e, g_ln_entryOut[e][0], g_ln_entryOut[e][1],
			g_ln_entryOut[e][2], g_ln_entryIn[e][0], g_ln_entryIn[e][1], g_ln_entryIn[e][2], g_ln_entryUses[e]);
	return Plugin_Handled;
}

Action Cmd_Forget(int args)
{
	g_ln_spotCount = 0;
	g_ln_routeCount = 0;
	g_ln_placeCount = 0;
	g_ln_entryCount = 0;
	g_ln_shootSum = 0.0; g_ln_retreatSum = 0.0;
	g_ln_shootN = 0; g_ln_retreatN = 0;
	Learned_Save();
	PrintToServer("[learn] forgot everything on this map");
	return Plugin_Handled;
}

// Remove element i from parallel arrays by shifting the rest down.
Action Cmd_Drop(int args)
{
	char what[16], num[8];
	GetCmdArg(1, what, sizeof(what));
	GetCmdArg(2, num, sizeof(num));
	int i = StringToInt(num);
	if (StrEqual(what, "spot") && i >= 0 && i < g_ln_spotCount)
	{
		for (int k = i; k < g_ln_spotCount - 1; k++) { g_ln_spots[k] = g_ln_spots[k + 1]; g_ln_spotSecs[k] = g_ln_spotSecs[k + 1]; }
		g_ln_spotCount--;
	}
	else if (StrEqual(what, "route") && i >= 0 && i < g_ln_routeCount)
	{
		for (int k = i; k < g_ln_routeCount - 1; k++)
		{
			g_ln_routeLen[k] = g_ln_routeLen[k + 1];
			g_ln_routeUses[k] = g_ln_routeUses[k + 1];
			for (int p = 0; p < LEARN_MAX_POINTS; p++) g_ln_routes[k][p] = g_ln_routes[k + 1][p];
		}
		g_ln_routeCount--;
	}
	else if (StrEqual(what, "furniture") && i >= 0 && i < g_ln_placeCount)
	{
		for (int k = i; k < g_ln_placeCount - 1; k++)
		{
			g_ln_placeHammer[k] = g_ln_placeHammer[k + 1];
			g_ln_placeFrom[k] = g_ln_placeFrom[k + 1];
			g_ln_placeTo[k] = g_ln_placeTo[k + 1];
			g_ln_placeTeam[k] = g_ln_placeTeam[k + 1];
		}
		g_ln_placeCount--;
	}
	else if (StrEqual(what, "entry") && i >= 0 && i < g_ln_entryCount)
	{
		for (int k = i; k < g_ln_entryCount - 1; k++)
		{
			g_ln_entryOut[k] = g_ln_entryOut[k + 1];
			g_ln_entryIn[k] = g_ln_entryIn[k + 1];
			g_ln_entryUses[k] = g_ln_entryUses[k + 1];
		}
		g_ln_entryCount--;
	}
	else
	{
		PrintToServer("usage: sm_zps24learn_drop <spot|route|furniture|entry> <index> (see sm_zps24learn_status)");
		return Plugin_Handled;
	}
	Learned_Save();
	PrintToServer("[learn] dropped %s %d", what, i);
	return Plugin_Handled;
}
