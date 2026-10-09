// Hand-made stair routes for staircases the nav mesh generator leaves out.
//
// The church tower's staircases (zpo_church_siege_final_h) are steep and narrow: 9.5-unit steps,
// 10 units deep. NavBot's generator never puts nav areas on them, so the tower's floors are
// separate islands and bots can't path between them. Here each staircase is a list of points,
// from an approach point on the lower floor's nav mesh to an exit point on the upper floor's.
// A bot paths normally to the near end, then gets steered point by point (MoveTowards, no
// pathfinding) to the far end.
//
// Usage from a scripted-update callback:
//   if (Stairs_Update(client, bot, myPos, targetPos, moveGoal, routeType, result)) return result;
// Call Stairs_OnMapStart() from OnMapStart().

#if defined _zps24_stairs_included
 #endinput
#endif
#define _zps24_stairs_included

#define STAIRS_MAX_ROUTES  4
#define STAIRS_MAX_POINTS  6

int   g_st_routeCount;
int   g_st_pointCount[STAIRS_MAX_ROUTES];
float g_st_points[STAIRS_MAX_ROUTES][STAIRS_MAX_POINTS][3];
int   g_st_lower[STAIRS_MAX_ROUTES];          // floor the route starts on (points[0])
float g_st_floorZ[8];                         // floor heights of the building, lowest first
int   g_st_floorCount;
float g_st_boxMin[3], g_st_boxMax[3];         // the building

// Per-bot climb state
int   g_st_route[MAXPLAYERS + 1] = { -1, ... };
int   g_st_point[MAXPLAYERS + 1];
int   g_st_step[MAXPLAYERS + 1];              // +1 going up, -1 going down
float g_st_progressAt[MAXPLAYERS + 1];
float g_st_bestDist[MAXPLAYERS + 1];
float g_st_cooldown[MAXPLAYERS + 1];

void Stairs_AddPoint(int r, float x, float y, float z)
{
	int n = g_st_pointCount[r]++;
	g_st_points[r][n][0] = x;
	g_st_points[r][n][1] = y;
	g_st_points[r][n][2] = z;
}

void Stairs_OnMapStart()
{
	g_st_routeCount = 0;
	g_st_floorCount = 0;
	for (int r = 0; r < STAIRS_MAX_ROUTES; r++)
		g_st_pointCount[r] = 0;
	for (int i = 0; i <= MaxClients; i++)
	{
		g_st_route[i] = -1;
		g_st_cooldown[i] = 0.0;
	}
	char map[64];
	GetCurrentMap(map, sizeof(map));
	if (StrEqual(map, "zpo_church_siege_final_h"))
	{
		// Church tower: ground floor (z -47), second floor (104), third floor (256).
		g_st_boxMin = view_as<float>({-1172.0, 188.0, -80.0});
		g_st_boxMax = view_as<float>({-900.0, 468.0, 330.0});
		g_st_floorZ[0] = -47.0; g_st_floorZ[1] = 104.0; g_st_floorZ[2] = 256.0;
		g_st_floorCount = 3;
		// South wall: ground floor -> second floor, climbing west, then north onto the landing.
		g_st_lower[0] = 0;
		Stairs_AddPoint(0, -985.0, 224.0, -47.0);
		Stairs_AddPoint(0, -1020.0, 224.0, -28.0);
		Stairs_AddPoint(0, -1146.0, 224.0, 94.0);
		Stairs_AddPoint(0, -1146.0, 262.0, 104.0);
		Stairs_AddPoint(0, -1138.0, 292.0, 104.0);
		// North wall: second floor -> third floor, climbing west, then south off the top step.
		g_st_lower[1] = 1;
		Stairs_AddPoint(1, -990.0, 436.0, 104.0);
		Stairs_AddPoint(1, -1018.0, 436.0, 113.0);
		Stairs_AddPoint(1, -1154.0, 436.0, 246.0);
		Stairs_AddPoint(1, -1152.0, 404.0, 256.0);
		Stairs_AddPoint(1, -1140.0, 385.0, 256.0);
		g_st_routeCount = 2;
	}
}

// Floor index of a position inside the building, or -1 outside it.
int Stairs_Level(const float pos[3])
{
	if (g_st_floorCount == 0)
		return -1;
	for (int i = 0; i < 3; i++)
		if (pos[i] < g_st_boxMin[i] || pos[i] > g_st_boxMax[i])
			return -1;
	int best = 0;
	for (int f = 1; f < g_st_floorCount; f++)
		if (pos[2] >= g_st_floorZ[f] - 30.0)
			best = f;
	return best;
}

float Stairs_Dist2D(const float a[3], const float b[3])
{
	float dx = a[0] - b[0], dy = a[1] - b[1];
	return SquareRoot(dx * dx + dy * dy);
}

// Route that leads from floor `from` one floor towards `to`, and its direction.
int Stairs_RouteFor(int from, int to, int &step)
{
	for (int r = 0; r < g_st_routeCount; r++)
	{
		if (to > from && g_st_lower[r] == from) { step = 1; return r; }
		if (to < from && g_st_lower[r] == from - 1) { step = -1; return r; }
	}
	return -1;
}

// Steers the bot while it should use a staircase. Returns true when it has set moveGoal or is
// steering the bot itself; `result` is then what the scripted-update callback should return.
bool Stairs_Update(int client, NavBot bot, const float me[3], const float target[3], float moveGoal[3], NavBotRouteType &routeType, Action &result)
{
	if (g_st_routeCount == 0)
		return false;

	// Already on a staircase: next point, until the far end.
	int r = g_st_route[client];
	if (r != -1)
	{
		float wp[3];
		wp = g_st_points[r][g_st_point[client]];
		float d = Stairs_Dist2D(me, wp);
		if (d < g_st_bestDist[client] - 4.0)
		{
			g_st_bestDist[client] = d;
			g_st_progressAt[client] = GetGameTime();
		}
		else if (GetGameTime() - g_st_progressAt[client] > 3.0)
		{
			g_st_route[client] = -1;                 // stuck (someone in the way?): try again shortly
			g_st_cooldown[client] = GetGameTime() + 3.0;
			return false;
		}
		if (d < 16.0)
		{
			int next = g_st_point[client] + g_st_step[client];
			if (next < 0 || next >= g_st_pointCount[r])
			{
				g_st_route[client] = -1;             // arrived on the other floor
				return false;
			}
			g_st_point[client] = next;
			g_st_bestDist[client] = 999999.0;
			g_st_progressAt[client] = GetGameTime();
			wp = g_st_points[r][next];
		}
		float look[3];
		look = wp;
		look[2] += 60.0;
		NavBotPlayerControllerInterface.AimAtPos(bot.GetPlayerControllerInterface(), look, LOOK_MOVEMENT, 0.3, "Taking the stairs");
		NavBotMovementInterface.MoveTowards(bot.GetMovementInterface(), wp, 100);
		result = Plugin_Continue;                    // keep the behavior, no pathfinding
		return true;
	}

	if (GetGameTime() < g_st_cooldown[client])
		return false;

	// Need a different floor of the building?
	int tl = Stairs_Level(target);
	int ml = Stairs_Level(me);
	if (tl == -1 && ml == -1)
		return false;
	int from = ml == -1 ? 0 : ml;                    // outside: enter on the ground floor
	int to = tl == -1 ? 0 : tl;                      // target outside: leave by the ground floor
	if (from == to)
		return false;
	int step;
	r = Stairs_RouteFor(from, to, step);
	if (r == -1)
		return false;

	// Walk (normal pathfinding) to this end of the staircase, then start steering.
	int first = step == 1 ? 0 : g_st_pointCount[r] - 1;
	float start[3];
	start = g_st_points[r][first];
	if (Stairs_Dist2D(me, start) < 24.0 && FloatAbs(me[2] - start[2]) < 40.0)
	{
		g_st_route[client] = r;
		g_st_step[client] = step;
		g_st_point[client] = first + step;
		g_st_bestDist[client] = 999999.0;
		g_st_progressAt[client] = GetGameTime();
		result = Plugin_Continue;
		return true;
	}
	moveGoal = start;
	routeType = NAVBOT_FASTEST_ROUTE;
	result = Plugin_Changed;
	return true;
}
