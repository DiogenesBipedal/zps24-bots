// Nav mesh inspection for tuning bot movement on a map, from the server console / RCON.
//
//   sm_navdump x1 y1 z1 x2 y2 z2     every nav area overlapping the box: extent, connections
//                                    (with height change and gap), off-mesh links (ladders, jumps)
//   sm_navseed x y z                 add a walkable seed for sm_nav_generate_incremental
//   sm_floormap x1 y1 x2 y2 ztop step   floor heights on a grid (downward traces from ztop, player
//                                    hull), to see stairs and steps the mesh should cover
#include <sourcemod>
#include <sdktools>
#include <navbot>

public Plugin myinfo =
{
	name = "ZPS 2.4 nav debug",
	author = "Dead Apocalypse",
	description = "Dump nav areas and floor heights for tuning bot movement",
	version = "1.0"
};

public void OnPluginStart()
{
	RegServerCmd("sm_navdump", Cmd_NavDump, "sm_navdump x1 y1 z1 x2 y2 z2");
	RegServerCmd("sm_floormap", Cmd_FloorMap, "sm_floormap x1 y1 x2 y2 ztop step");
	RegServerCmd("sm_navtp", Cmd_NavTp, "sm_navtp client x y z [freeze 0/1]: move a player, optionally pin them there");
	RegServerCmd("sm_where", Cmd_Where, "sm_where team: positions of a team's living players");
	RegServerCmd("sm_navreach", Cmd_NavReach, "sm_navreach x y z x1 y1 z1 x2 y2 z2: which areas in the box are reachable from the area at x y z");
	RegServerCmd("sm_navseed", Cmd_NavSeed, "sm_navseed x y z: add a walkable seed for (incremental) nav generation");
}

float ArgF(int i)
{
	char s[32];
	GetCmdArg(i, s, sizeof(s));
	return StringToFloat(s);
}

Action Cmd_NavDump(int args)
{
	if (args < 6) { PrintToServer("usage: sm_navdump x1 y1 z1 x2 y2 z2"); return Plugin_Handled; }
	float mins[3], maxs[3];
	for (int i = 0; i < 3; i++) { mins[i] = ArgF(i + 1); maxs[i] = ArgF(i + 4); }
	NavBotNavAreaVector v = NavBotNavMesh.CollectAreasOverlappingExtent(mins, maxs);
	PrintToServer("[navdump] %d areas", v.Size);
	for (int i = 0; i < v.Size; i++)
	{
		Address a = v.At(i);
		float lo[3], hi[3];
		NavBotNavArea.GetExtent(a, lo, hi);
		char line[1024];
		Format(line, sizeof(line), "#%d (%.0f %.0f %.0f)-(%.0f %.0f %.0f) ->", NavBotNavArea.GetID(a), lo[0], lo[1], lo[2], hi[0], hi[1], hi[2]);
		for (int d = 0; d < 4; d++)
		{
			int n = NavBotNavArea.GetAdjacentAreaCount(a, view_as<NavBotNavDirType>(d));
			for (int k = 0; k < n; k++)
			{
				Address b = NavBotNavArea.GetAdjacentArea(a, view_as<NavBotNavDirType>(d), k);
				Format(line, sizeof(line), "%s %c%d(dz %.0f gap %.0f)", line, "NESW"[d], NavBotNavArea.GetID(b),
					NavBotNavArea.ComputeAdjacentConnectionHeightChange(a, b), NavBotNavArea.ComputeAdjacentConnectionGapDistance(a, b));
			}
		}
		int off = NavBotNavArea.GetOffMeshConnectionCount(a);
		for (int k = 0; k < off; k++)
		{
			Address c = NavBotNavArea.GetOffMeshConnection(a, k);
			Address to = NavBotNavOffMeshConnection.GetConnectedArea(c);
			Format(line, sizeof(line), "%s off:%d->#%d", line, NavBotNavOffMeshConnection.GetType(c), to != Address_Null ? NavBotNavArea.GetID(to) : -1);
		}
		PrintToServer("%s", line);
	}
	delete v;
	return Plugin_Handled;
}

Action Cmd_NavTp(int args)
{
	if (args < 4) { PrintToServer("usage: sm_navtp client x y z [freeze]"); return Plugin_Handled; }
	int client = RoundToFloor(ArgF(1));
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || !IsPlayerAlive(client)) { PrintToServer("[navtp] no such live player"); return Plugin_Handled; }
	float pos[3];
	for (int i = 0; i < 3; i++) pos[i] = ArgF(i + 2);
	TeleportEntity(client, pos, NULL_VECTOR, view_as<float>({0.0, 0.0, 0.0}));
	if (args >= 5)
		SetEntityMoveType(client, ArgF(5) != 0.0 ? MOVETYPE_NONE : MOVETYPE_WALK);
	PrintToServer("[navtp] %N -> %.0f %.0f %.0f", client, pos[0], pos[1], pos[2]);
	return Plugin_Handled;
}

Action Cmd_Where(int args)
{
	int team = RoundToFloor(ArgF(1));
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) != team)
			continue;
		float pos[3];
		GetClientAbsOrigin(i, pos);
		PrintToServer("[where] %d %N %.0f %.0f %.0f", i, i, pos[0], pos[1], pos[2]);
	}
	return Plugin_Handled;
}

// Breadth-first search over adjacency, then list the box's areas: reached or not.
Action Cmd_NavReach(int args)
{
	if (args < 9) { PrintToServer("usage: sm_navreach x y z x1 y1 z1 x2 y2 z2"); return Plugin_Handled; }
	float from[3], mins[3], maxs[3];
	for (int i = 0; i < 3; i++) { from[i] = ArgF(i + 1); mins[i] = ArgF(i + 4); maxs[i] = ArgF(i + 7); }
	Address start = NavBotNavMesh.GetNearestNavArea(from, 200.0, false, true);
	if (start == Address_Null) { PrintToServer("[navreach] no area near the start"); return Plugin_Handled; }
	StringMap seen = new StringMap();
	ArrayList queue = new ArrayList();
	queue.Push(start);
	char key[16];
	IntToString(NavBotNavArea.GetID(start), key, sizeof(key));
	seen.SetValue(key, 1);
	NavBotNavAreaVector adj = new NavBotNavAreaVector();
	while (queue.Length > 0)
	{
		Address a = queue.Get(0);
		queue.Erase(0);
		adj.Clear();
		for (int d = 0; d < 4; d++)
		{
			int n = NavBotNavArea.GetAdjacentAreaCount(a, view_as<NavBotNavDirType>(d));
			for (int k = 0; k < n; k++)
				adj.Push(NavBotNavArea.GetAdjacentArea(a, view_as<NavBotNavDirType>(d), k));
		}
		int off = NavBotNavArea.GetOffMeshConnectionCount(a);
		for (int k = 0; k < off; k++)
		{
			Address to = NavBotNavOffMeshConnection.GetConnectedArea(NavBotNavArea.GetOffMeshConnection(a, k));
			if (to != Address_Null)
				adj.Push(to);
		}
		for (int i = 0; i < adj.Size; i++)
		{
			Address b = adj.At(i);
			IntToString(NavBotNavArea.GetID(b), key, sizeof(key));
			int dummy;
			if (seen.GetValue(key, dummy))
				continue;
			seen.SetValue(key, 1);
			queue.Push(b);
		}
	}
	delete adj;
	NavBotNavAreaVector box = NavBotNavMesh.CollectAreasOverlappingExtent(mins, maxs);
	int reached = 0;
	for (int i = 0; i < box.Size; i++)
	{
		Address a = box.At(i);
		IntToString(NavBotNavArea.GetID(a), key, sizeof(key));
		int dummy;
		bool ok = seen.GetValue(key, dummy);
		if (ok) reached++;
		float c[3];
		NavBotNavArea.GetCenter(a, c);
		PrintToServer("  #%d (%.0f %.0f %.0f) %s", NavBotNavArea.GetID(a), c[0], c[1], c[2], ok ? "reached" : "-");
	}
	PrintToServer("[navreach] start #%d: %d areas reachable in total; %d of %d in the box", NavBotNavArea.GetID(start), seen.Size, reached, box.Size);
	delete box;
	delete seen;
	delete queue;
	return Plugin_Handled;
}

Action Cmd_NavSeed(int args)
{
	if (args < 3) { PrintToServer("usage: sm_navseed x y z"); return Plugin_Handled; }
	float pos[3];
	for (int i = 0; i < 3; i++) pos[i] = ArgF(i + 1);
	PrintToServer("[navseed] %.0f %.0f %.0f: %s", pos[0], pos[1], pos[2], NavBotNavMesh.AddWalkableSeed(pos) ? "added" : "rejected");
	return Plugin_Handled;
}

Action Cmd_FloorMap(int args)
{
	if (args < 6) { PrintToServer("usage: sm_floormap x1 y1 x2 y2 ztop step"); return Plugin_Handled; }
	float x1 = ArgF(1), y1 = ArgF(2), x2 = ArgF(3), y2 = ArgF(4), ztop = ArgF(5), step = ArgF(6);
	PrintToServer("[floormap] rows = y from %.0f to %.0f, columns = x from %.0f to %.0f, step %.0f; '----' = no floor", y2, y1, x1, x2, step);
	for (float y = y2; y >= y1; y -= step)
	{
		char line[1024];
		Format(line, sizeof(line), "y%6.0f:", y);
		for (float x = x1; x <= x2; x += step)
		{
			float from[3], to[3], end[3];
			from[0] = x; from[1] = y; from[2] = ztop;
			to = from; to[2] = ztop - 600.0;
			TR_TraceHull(from, to, view_as<float>({-4.0, -4.0, 0.0}), view_as<float>({4.0, 4.0, 4.0}), MASK_PLAYERSOLID_BRUSHONLY);
			if (TR_StartSolid() || !TR_DidHit())
				Format(line, sizeof(line), "%s ----", line);
			else
			{
				TR_GetEndPosition(end);
				Format(line, sizeof(line), "%s %4.0f", line, end[2]);
			}
		}
		PrintToServer("%s", line);
	}
	return Plugin_Handled;
}
