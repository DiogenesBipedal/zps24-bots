// Learn from the main player: follow the teacher (server admins, i.e. the host, or the player
// named by sm_zps24learn_teacher) and record, per map,
//
//   hold spots  places they stay put for sm_zps24learn_hold_time seconds while alive
//   routes      paths between floors over ground the nav mesh doesn't cover (steep stairs,
//               jumps, climbs): from the last point on the mesh to the first point back on it
//   style       how far the nearest zombie is when they open fire, and when they back away
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
float g_trail[MAXPLAYERS + 1][32][3];        // off-mesh path being recorded
float g_trailSince[MAXPLAYERS + 1];
bool  g_trailBad[MAXPLAYERS + 1];            // ladder or noclip on the way: not walkable by bots
bool  g_wasShooting[MAXPLAYERS + 1];
bool  g_wasRetreating[MAXPLAYERS + 1];

public void OnPluginStart()
{
	g_enable   = CreateConVar("sm_zps24learn_enable", "1", "Learn hold spots, routes and fighting distances from human survivors");
	g_holdTime = CreateConVar("sm_zps24learn_hold_time", "10", "Seconds a human must stay put for the spot to count as a hold spot");
	g_debug    = CreateConVar("sm_zps24learn_debug", "1", "Announce what was learned in the server log");
	g_teacher  = CreateConVar("sm_zps24learn_teacher", "", "Learn only from the player whose name contains this (empty = from server admins only)");
	RegServerCmd("sm_zps24learn_status", Cmd_Status, "What the bots have learned on this map");
	RegServerCmd("sm_zps24learn_forget", Cmd_Forget, "Forget everything learned on this map");
	HookEventEx("player_death", Event_PlayerDeath, EventHookMode_Post);
}

public void OnMapStart()
{
	Learned_Load();
	for (int i = 0; i <= MaxClients; i++)
		ResetClient(i);
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
	if (g_trailBad[client] || secs > 15.0 || FloatAbs(pos[2] - start[2]) < 48.0)
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
			if (GetGameTime() - g_trailSince[client] > 15.0)
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
	PrintToServer("[learn] %d hold spots, %d routes; opened fire at %.0f on average (%d times), backed away at %.0f (%d times)",
		g_ln_spotCount, g_ln_routeCount, g_ln_shootN ? g_ln_shootSum / float(g_ln_shootN) : 0.0, g_ln_shootN,
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
	return Plugin_Handled;
}

Action Cmd_Forget(int args)
{
	g_ln_spotCount = 0;
	g_ln_routeCount = 0;
	g_ln_shootSum = 0.0; g_ln_retreatSum = 0.0;
	g_ln_shootN = 0; g_ln_retreatN = 0;
	Learned_Save();
	PrintToServer("[learn] forgot everything on this map");
	return Plugin_Handled;
}
