// Nav mesh inspection for tuning bot movement on a map, from the server console / RCON.
//
//   sm_navdump x1 y1 z1 x2 y2 z2     every nav area overlapping the box: extent, connections
//                                    (with height change and gap), off-mesh links (ladders, jumps)
//   sm_navseed x y z                 add a walkable seed for sm_nav_generate_incremental
//   sm_floormap x1 y1 x2 y2 ztop step   floor heights on a grid (downward traces from ztop, player
//                                    hull), to see stairs and steps the mesh should cover
//   sm_navfixdrops [apply]           drop-down connections a player can't actually take (a railing
//                                    or glass on the ledge): list them, or with "apply" remove them
//                                    (then sm_nav_save to keep the fixed mesh)
//   sm_navbuttondoors [apply]        connections running through a closed door that only a button
//                                    opens (the generator ignores doors): list or remove them
//   sm_navwater [apply]              connections into water areas (from anywhere): list them, or
//                                    remove them, so paths never lead into or across a lake; the
//                                    ways out of the water stay
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
	RegServerCmd("sm_navfixdrops", Cmd_NavFixDrops, "sm_navfixdrops [apply]: find (and remove) drop-down connections blocked by railings");
	RegServerCmd("sm_navbuttondoors", Cmd_NavButtonDoors, "sm_navbuttondoors [apply]: find (and remove) connections running through doors only a button opens");
	RegServerCmd("sm_contents", Cmd_Contents, "sm_contents x y z: brush contents at a point");
	RegServerCmd("sm_navwater", Cmd_NavWater, "sm_navwater [apply]: find (and remove) connections from dry ground into water");
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

bool TraceNoPlayers(int entity, int mask)
{
	return entity > MaxClients;
}

// Can a standing player get from area a's ledge over to area b below and drop onto it?
// Walk off the ledge (hull at step height, so a railing or window glass blocks it), then fall.
bool DropBlocked(Address a, Address b)
{
	float ca[3], cb[3], pa[3], pb[3], above[3];
	NavBotNavArea.GetCenter(a, ca);
	NavBotNavArea.GetCenter(b, cb);
	NavBotNavArea.GetClosestPointOnArea(a, cb, pa);
	NavBotNavArea.GetClosestPointOnArea(b, pa, pb);
	float mins[3] = { -16.0, -16.0, 0.0 }, maxs[3] = { 16.0, 16.0, 54.0 };
	// a little past the ledge, toward b
	float dir[3];
	SubtractVectors(pb, pa, dir);
	dir[2] = 0.0;
	NormalizeVector(dir, dir);
	ScaleVector(dir, 34.0);
	float from[3];
	from = pa;
	from[2] += 18.0;
	above = pb;
	AddVectors(above, dir, above);
	above[2] = from[2];
	TR_TraceHullFilter(from, above, mins, maxs, MASK_PLAYERSOLID, TraceNoPlayers);
	if (TR_DidHit())
		return true;
	float down[3];
	down = above;
	down[2] = pb[2] + 4.0;
	TR_TraceHullFilter(above, down, mins, maxs, MASK_PLAYERSOLID, TraceNoPlayers);
	return TR_DidHit() && TR_GetFraction() < 0.9;
}

Action Cmd_NavFixDrops(int args)
{
	char arg[16];
	GetCmdArg(1, arg, sizeof(arg));
	bool apply = StrEqual(arg, "apply");
	float mins[3] = { -32768.0, -32768.0, -32768.0 }, maxs[3] = { 32768.0, 32768.0, 32768.0 };
	NavBotNavAreaVector v = NavBotNavMesh.CollectAreasOverlappingExtent(mins, maxs);
	int found = 0;
	static Address fromA[2048], toB[2048];
	for (int i = 0; i < v.Size; i++)
	{
		Address a = v.At(i);
		for (int d = 0; d < 4; d++)
		{
			int n = NavBotNavArea.GetAdjacentAreaCount(a, view_as<NavBotNavDirType>(d));
			for (int k = 0; k < n; k++)
			{
				Address b = NavBotNavArea.GetAdjacentArea(a, view_as<NavBotNavDirType>(d), k);
				float dz = NavBotNavArea.ComputeAdjacentConnectionHeightChange(a, b);
				if (dz > -60.0 || !DropBlocked(a, b) || found >= sizeof(fromA))
					continue;
				float ca[3], cb[3];
				NavBotNavArea.GetCenter(a, ca);
				NavBotNavArea.GetCenter(b, cb);
				PrintToServer("[navfixdrops] #%d (%.0f %.0f %.0f) -> #%d (%.0f %.0f %.0f) drop %.0f: blocked", NavBotNavArea.GetID(a), ca[0], ca[1], ca[2],
					NavBotNavArea.GetID(b), cb[0], cb[1], cb[2], -dz);
				fromA[found] = a;
				toB[found] = b;
				found++;
			}
		}
	}
	delete v;
	if (apply)
		for (int i = 0; i < found; i++)
			NavBotNavArea.DisconnectFromAdjacent(fromA[i], toB[i]);
	PrintToServer("[navfixdrops] %d blocked drop-down connections%s", found, apply ? " removed (sm_nav_save to keep)" : " (sm_navfixdrops apply to remove)");
	return Plugin_Handled;
}

bool AreaInWater(Address a)
{
	float c[3];
	NavBotNavArea.GetCenter(a, c);
	c[2] += 16.0;
	return (TR_GetPointContents(c) & MASK_WATER) != 0;
}

Action Cmd_NavWater(int args)
{
	char arg[16];
	GetCmdArg(1, arg, sizeof(arg));
	bool apply = StrEqual(arg, "apply");
	float mins[3] = { -32768.0, -32768.0, -32768.0 }, maxs[3] = { 32768.0, 32768.0, 32768.0 };
	NavBotNavAreaVector v = NavBotNavMesh.CollectAreasOverlappingExtent(mins, maxs);
	static Address fromA[4096], toB[4096];
	int found = 0, wet = 0;
	for (int i = 0; i < v.Size; i++)
	{
		Address a = v.At(i);
		if (AreaInWater(a)) wet++;
		for (int d = 0; d < 4; d++)
		{
			int n = NavBotNavArea.GetAdjacentAreaCount(a, view_as<NavBotNavDirType>(d));
			for (int k = 0; k < n && found < sizeof(fromA); k++)
			{
				Address b = NavBotNavArea.GetAdjacentArea(a, view_as<NavBotNavDirType>(d), k);
				if (!AreaInWater(b))
					continue;
				fromA[found] = a;
				toB[found] = b;
				found++;
			}
		}
	}
	PrintToServer("[navwater] %d of %d areas are in water; %d connections lead into it", wet, v.Size, found);
	delete v;
	if (apply)
	{
		for (int i = 0; i < found; i++)
			NavBotNavArea.DisconnectFromAdjacent(fromA[i], toB[i]);
		PrintToServer("[navwater] removed them: water areas only lead out now; sm_nav_save to keep");
	}
	return Plugin_Handled;
}

Action Cmd_Contents(int args)
{
	float p[3];
	for (int i = 0; i < 3; i++) p[i] = ArgF(i + 1);
	int c = TR_GetPointContents(p);
	PrintToServer("[contents] %.0f %.0f %.0f: 0x%x%s", p[0], p[1], p[2], c, (c & MASK_WATER) ? " WATER" : "");
	return Plugin_Handled;
}

// A door with neither "Use opens" (256) nor "Touch opens" (1024): only a button or a trigger works it.
bool ButtonOnly(int ent)
{
	return (GetEntProp(ent, Prop_Data, "m_spawnflags") & (256 | 1024)) == 0;
}

Action Cmd_NavButtonDoors(int args)
{
	char arg[16];
	GetCmdArg(1, arg, sizeof(arg));
	bool apply = StrEqual(arg, "apply");
	static const char classes[][] = { "func_door", "func_door_rotating" };
	static Address fromA[1024], toB[1024];
	int found = 0;
	for (int c = 0; c < sizeof(classes); c++)
	{
		int door = -1;
		while ((door = FindEntityByClassname(door, classes[c])) != -1)
		{
			if (!ButtonOnly(door) || GetEntProp(door, Prop_Data, "m_toggle_state") != 1)
				continue;   // opens with E or by touch, or isn't closed
			float o[3], mins[3], maxs[3], lo[3], hi[3];
			GetEntPropVector(door, Prop_Data, "m_vecAbsOrigin", o);
			GetEntPropVector(door, Prop_Send, "m_vecMins", mins);
			GetEntPropVector(door, Prop_Send, "m_vecMaxs", maxs);
			for (int i = 0; i < 3; i++) { lo[i] = o[i] + mins[i]; hi[i] = o[i] + maxs[i]; }
			// The door's plane: its thin axis.
			int axis = (hi[0] - lo[0]) < (hi[1] - lo[1]) ? 0 : 1;
			float plane = (lo[axis] + hi[axis]) * 0.5;
			float span[3], spanHi[3];
			span = lo; spanHi = hi;
			span[axis] -= 80.0; spanHi[axis] += 80.0;
			span[2] -= 40.0;
			NavBotNavAreaVector v = NavBotNavMesh.CollectAreasOverlappingExtent(span, spanHi);
			for (int i = 0; i < v.Size; i++)
			{
				Address a = v.At(i);
				float ca[3];
				NavBotNavArea.GetCenter(a, ca);
				for (int d = 0; d < 4; d++)
				{
					int n = NavBotNavArea.GetAdjacentAreaCount(a, view_as<NavBotNavDirType>(d));
					for (int k = 0; k < n && found < sizeof(fromA); k++)
					{
						Address b = NavBotNavArea.GetAdjacentArea(a, view_as<NavBotNavDirType>(d), k);
						float cb[3], pa[3], pb[3];
						NavBotNavArea.GetCenter(b, cb);
						NavBotNavArea.GetClosestPointOnArea(a, cb, pa);
						NavBotNavArea.GetClosestPointOnArea(b, ca, pb);
						// Crossing the door: the two areas' facing edges are on opposite sides of
						// its plane, and where they meet is within the door's width and height.
						float mid[3];
						for (int j = 0; j < 3; j++) mid[j] = (pa[j] + pb[j]) * 0.5;
						int other = 1 - axis;
						bool crosses = (ca[axis] - plane) * (cb[axis] - plane) < 0.0;
						if (!crosses || mid[other] < lo[other] - 8.0 || mid[other] > hi[other] + 8.0 || mid[2] > hi[2] || mid[2] < lo[2] - 40.0)
							continue;
						if (!apply)
							PrintToServer("[navbuttondoors]   #%d -> #%d", NavBotNavArea.GetID(a), NavBotNavArea.GetID(b));
						fromA[found] = a;
						toB[found] = b;
						found++;
					}
				}
			}
			delete v;
			char name[64];
			GetEntPropString(door, Prop_Data, "m_iName", name, sizeof(name));
			PrintToServer("[navbuttondoors] door %d '%s' at %.0f %.0f %.0f: %d connections through it so far", door, name,
				(lo[0] + hi[0]) * 0.5, (lo[1] + hi[1]) * 0.5, (lo[2] + hi[2]) * 0.5, found);
		}
	}
	if (apply)
		for (int i = 0; i < found; i++)
			NavBotNavArea.DisconnectFromAdjacent(fromA[i], toB[i]);
	PrintToServer("[navbuttondoors] %d connections%s", found, apply ? " removed (sm_nav_save to keep)" : " (sm_navbuttondoors apply to remove)");
	return Plugin_Handled;
}
