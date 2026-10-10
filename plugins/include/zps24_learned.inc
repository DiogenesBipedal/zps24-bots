// What the bots learned from watching human players, per map (see zps24_learn.sp).
//
// Stored in addons/sourcemod/data/zps24_learn/<map>.cfg:
//   spots   places a human held for a while and survived (the longer, the better)
//   routes  paths a human took between floors where the nav mesh has no areas (steep stairs,
//           jumps); bots walk them point by point
//   style   distances a human started shooting at, and backed away at
//   placements  furniture a human moved: which prop (map hammer ID) and where they left it
//
// Learned_Load() reads the current map's file; call it on map and round start.

#if defined _zps24_learned_included
 #endinput
#endif
#define _zps24_learned_included

#define LEARN_MAX_SPOTS   64
#define LEARN_MAX_ROUTES  16
#define LEARN_MAX_POINTS  12
#define LEARN_MAX_PLACES  32

int   g_ln_spotCount;
float g_ln_spots[LEARN_MAX_SPOTS][3];
float g_ln_spotSecs[LEARN_MAX_SPOTS];        // total seconds humans held it

int   g_ln_routeCount;
int   g_ln_routeLen[LEARN_MAX_ROUTES];
float g_ln_routes[LEARN_MAX_ROUTES][LEARN_MAX_POINTS][3];
int   g_ln_routeUses[LEARN_MAX_ROUTES];      // times a human took it

int   g_ln_placeCount;
int   g_ln_placeHammer[LEARN_MAX_PLACES];    // m_iHammerID: the same prop every round
float g_ln_placeFrom[LEARN_MAX_PLACES][3];   // where the prop starts the round
float g_ln_placeTo[LEARN_MAX_PLACES][3];     // where the human left it

float g_ln_shootSum, g_ln_retreatSum;        // sums of distances to the nearest zombie
int   g_ln_shootN, g_ln_retreatN;

void Learned_Path(char[] path, int maxlen)
{
	char map[64];
	GetCurrentMap(map, sizeof(map));
	BuildPath(Path_SM, path, maxlen, "data/zps24_learn");
	if (!DirExists(path))
		CreateDirectory(path, 511);
	BuildPath(Path_SM, path, maxlen, "data/zps24_learn/%s.cfg", map);
}

void Learned_Load()
{
	g_ln_spotCount = 0;
	g_ln_routeCount = 0;
	g_ln_placeCount = 0;
	g_ln_shootSum = 0.0; g_ln_retreatSum = 0.0;
	g_ln_shootN = 0; g_ln_retreatN = 0;
	char path[PLATFORM_MAX_PATH];
	Learned_Path(path, sizeof(path));
	if (!FileExists(path))
		return;
	KeyValues kv = new KeyValues("learned");
	if (!kv.ImportFromFile(path))
	{
		delete kv;
		return;
	}
	if (kv.JumpToKey("spots") && kv.GotoFirstSubKey())
	{
		do
		{
			if (g_ln_spotCount >= LEARN_MAX_SPOTS) break;
			kv.GetVector("pos", g_ln_spots[g_ln_spotCount]);
			g_ln_spotSecs[g_ln_spotCount] = kv.GetFloat("secs");
			g_ln_spotCount++;
		} while (kv.GotoNextKey());
	}
	kv.Rewind();
	if (kv.JumpToKey("routes") && kv.GotoFirstSubKey())
	{
		do
		{
			if (g_ln_routeCount >= LEARN_MAX_ROUTES) break;
			int r = g_ln_routeCount;
			g_ln_routeUses[r] = kv.GetNum("uses", 1);
			g_ln_routeLen[r] = 0;
			char key[8];
			for (int i = 0; i < LEARN_MAX_POINTS; i++)
			{
				Format(key, sizeof(key), "p%d", i);
				float v[3] = { 999999.0, 0.0, 0.0 };
				kv.GetVector(key, v, v);
				if (v[0] == 999999.0) break;
				g_ln_routes[r][i] = v;
				g_ln_routeLen[r]++;
			}
			if (g_ln_routeLen[r] >= 2)
				g_ln_routeCount++;
		} while (kv.GotoNextKey());
	}
	kv.Rewind();
	if (kv.JumpToKey("placements") && kv.GotoFirstSubKey())
	{
		do
		{
			if (g_ln_placeCount >= LEARN_MAX_PLACES) break;
			int k = g_ln_placeCount++;
			g_ln_placeHammer[k] = kv.GetNum("hammer");
			kv.GetVector("from", g_ln_placeFrom[k]);
			kv.GetVector("to", g_ln_placeTo[k]);
		} while (kv.GotoNextKey());
	}
	kv.Rewind();
	if (kv.JumpToKey("style"))
	{
		g_ln_shootSum = kv.GetFloat("shoot_sum");
		g_ln_shootN = kv.GetNum("shoot_n");
		g_ln_retreatSum = kv.GetFloat("retreat_sum");
		g_ln_retreatN = kv.GetNum("retreat_n");
	}
	delete kv;
}

stock void Learned_Save()
{
	char path[PLATFORM_MAX_PATH], key[16];
	Learned_Path(path, sizeof(path));
	KeyValues kv = new KeyValues("learned");
	kv.JumpToKey("spots", true);
	for (int i = 0; i < g_ln_spotCount; i++)
	{
		IntToString(i, key, sizeof(key));
		kv.JumpToKey(key, true);
		kv.SetVector("pos", g_ln_spots[i]);
		kv.SetFloat("secs", g_ln_spotSecs[i]);
		kv.GoBack();
	}
	kv.Rewind();
	kv.JumpToKey("routes", true);
	for (int r = 0; r < g_ln_routeCount; r++)
	{
		IntToString(r, key, sizeof(key));
		kv.JumpToKey(key, true);
		kv.SetNum("uses", g_ln_routeUses[r]);
		for (int i = 0; i < g_ln_routeLen[r]; i++)
		{
			char pk[8];
			Format(pk, sizeof(pk), "p%d", i);
			kv.SetVector(pk, g_ln_routes[r][i]);
		}
		kv.GoBack();
	}
	kv.Rewind();
	kv.JumpToKey("placements", true);
	for (int k = 0; k < g_ln_placeCount; k++)
	{
		IntToString(k, key, sizeof(key));
		kv.JumpToKey(key, true);
		kv.SetNum("hammer", g_ln_placeHammer[k]);
		kv.SetVector("from", g_ln_placeFrom[k]);
		kv.SetVector("to", g_ln_placeTo[k]);
		kv.GoBack();
	}
	kv.Rewind();
	kv.JumpToKey("style", true);
	kv.SetFloat("shoot_sum", g_ln_shootSum);
	kv.SetNum("shoot_n", g_ln_shootN);
	kv.SetFloat("retreat_sum", g_ln_retreatSum);
	kv.SetNum("retreat_n", g_ln_retreatN);
	kv.Rewind();
	kv.ExportToFile(path);
	delete kv;
}

// Average distance a human opened fire at, or `fallback` until there are enough samples.
stock float Learned_ShootDist(float fallback)
{
	return g_ln_shootN >= 20 ? g_ln_shootSum / float(g_ln_shootN) : fallback;
}

// Average distance a human started backing away from a zombie at, or `fallback`.
stock float Learned_RetreatDist(float fallback)
{
	return g_ln_retreatN >= 10 ? g_ln_retreatSum / float(g_ln_retreatN) : fallback;
}

// The prop a placement is about, this round: by hammer ID, else the prop nearest to where it
// starts. -1 if it's gone (broken).
stock int Learned_FindPlaceProp(int k)
{
	static const char classes[][] = { "prop_physics_multiplayer", "prop_physics", "prop_physics_override", "prop_physics_respawnable" };
	int best = -1;
	float bestDist = 32.0;
	for (int c = 0; c < sizeof(classes); c++)
	{
		int ent = -1;
		while ((ent = FindEntityByClassname(ent, classes[c])) != -1)
		{
			if (g_ln_placeHammer[k] > 0 && HasEntProp(ent, Prop_Data, "m_iHammerID") && GetEntProp(ent, Prop_Data, "m_iHammerID") == g_ln_placeHammer[k])
				return ent;
			float pos[3];
			GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", pos);
			float d = GetVectorDistance(pos, g_ln_placeFrom[k]);
			if (d < bestDist) { bestDist = d; best = ent; }
		}
	}
	return best;
}
