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

#include "include/zps24_learned.inc"

#define STAIRS_MAX_ROUTES  32                   // hand-made + ladders + learned from humans
#define STAIRS_MAX_POINTS  24

int   g_st_routeCount;
int   g_st_pointCount[STAIRS_MAX_ROUTES];
float g_st_points[STAIRS_MAX_ROUTES][STAIRS_MAX_POINTS][3];
int   g_st_lower[STAIRS_MAX_ROUTES];          // floor the route starts on (points[0]); -1 = learned
float g_st_bestZ[MAXPLAYERS + 1];            // highest a bot got on a jump step (tuning)
float g_st_jumpFrom[MAXPLAYERS + 1][3];
bool  g_st_peakDucked[MAXPLAYERS + 1];
float g_st_crouchJumpUntil[MAXPLAYERS + 1];   // crouch-jumping onto a ledge: buttons set in Stairs_RunCmd
int   g_st_handMade;                          // routes before this index are hand-made
int   g_st_ladderEnd;                         // [g_st_handMade, g_st_ladderEnd): ladders; after: learned
bool  g_st_ladder[STAIRS_MAX_ROUTES];
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
int   g_st_banned[MAXPLAYERS + 1] = { -1, ... };   // a learned route that failed this bot
float g_st_bannedUntil[MAXPLAYERS + 1];

void Stairs_Log(const char[] fmt, any ...)
{
	ConVar cv = FindConVar("sm_zps24zombies_debug");
	if (cv == null || !cv.BoolValue)
		return;
	char buf[192];
	VFormat(buf, sizeof(buf), fmt, 2);
	PrintToServer("[stairs] %s", buf);
}

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
	{
		g_st_pointCount[r] = 0;
		g_st_ladder[r] = false;
	}
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
	g_st_handMade = g_st_routeCount;
	Stairs_AddLadders();
	// (zps_cinema's projection room: a crouch-jump through the projection window was tried and
	// dropped. Zombies' crouch-jumps peak about 24 units up, the ledge is 44. The real way in is the
	// z 112 corridor, which was missing from the nav mesh: seeded and generated, see the manual.)
	g_st_ladderEnd = g_st_routeCount;
	Learned_Load();
	Stairs_AddLearned();
}

// A nav area on one side of a ladder near height z: returns the closest point on it, or false.
bool Stairs_LadderSide(const float c[3], const float n[3], float sign, float z, float out[3])
{
	for (float dist = 24.0; dist <= 72.0; dist += 16.0)
	{
		float p[3];
		p[0] = c[0] + n[0] * dist * sign;
		p[1] = c[1] + n[1] * dist * sign;
		p[2] = z + 16.0;
		Address a = NavBotNavMesh.GetNearestNavArea(p, 48.0, false, true);
		if (a == Address_Null)
			continue;
		NavBotNavArea.GetClosestPointOnArea(a, p, out);
		if (FloatAbs(out[2] - z) < 40.0)
			return true;
	}
	return false;
}

// Every walk-in ladder (info_ladder) becomes a route: floor in front of it, its foot, its top,
// and a step off onto the floor above. Bots climb by facing the ladder and walking into it.
void Stairs_AddLadders()
{
	int ent = -1;
	while ((ent = FindEntityByClassname(ent, "info_ladder")) != -1 && g_st_routeCount < STAIRS_MAX_ROUTES)
	{
		if (!HasEntProp(ent, Prop_Data, "mins"))
		{
			LogMessage("info_ladder %d: no mins/maxs", ent);
			continue;
		}
		float mins[3], maxs[3], c[3], n[3];
		GetEntPropVector(ent, Prop_Data, "mins", mins);
		GetEntPropVector(ent, Prop_Data, "maxs", maxs);
		for (int i = 0; i < 3; i++) c[i] = (mins[i] + maxs[i]) * 0.5;
		// The ladder is a thin plate; its normal is the thin axis.
		bool thinX = maxs[0] - mins[0] < maxs[1] - mins[1];
		n[0] = thinX ? 1.0 : 0.0;
		n[1] = thinX ? 0.0 : 1.0;
		float bottom[3], top[3];
		float sb = 0.0, st = 0.0;
		for (float sg = -1.0; sg <= 1.0 && sb == 0.0; sg += 2.0)
			if (Stairs_LadderSide(c, n, sg, mins[2], bottom)) sb = sg;
		if (sb == 0.0)
		{
			LogMessage("Ladder at %.0f %.0f (%.0f..%.0f): no floor at its foot", c[0], c[1], mins[2], maxs[2]);
			continue;
		}
		// Off the top: usually over it (the far side), sometimes back onto the near side.
		if (Stairs_LadderSide(c, n, -sb, maxs[2], top)) st = -sb;
		else if (Stairs_LadderSide(c, n, sb, maxs[2], top)) st = sb;
		if (st == 0.0)
		{
			LogMessage("Ladder at %.0f %.0f (%.0f..%.0f): no floor at its top", c[0], c[1], mins[2], maxs[2]);
			continue;
		}
		int r = g_st_routeCount++;
		g_st_pointCount[r] = 0;
		g_st_lower[r] = -1;
		g_st_ladder[r] = true;
		Stairs_AddPoint(r, bottom[0], bottom[1], bottom[2]);
		Stairs_AddPoint(r, c[0] + n[0] * sb * 14.0, c[1] + n[1] * sb * 14.0, bottom[2]);    // foot
		Stairs_AddPoint(r, c[0] + n[0] * sb * 14.0, c[1] + n[1] * sb * 14.0, maxs[2] - 8.0); // top
		Stairs_AddPoint(r, top[0], top[1], top[2]);
		LogMessage("Ladder at %.0f %.0f: %.0f -> %.0f", c[0], c[1], bottom[2], top[2]);
	}
}

// Pick up what the bots learned since the map started (call at round start).
void Stairs_Relearn()
{
	Learned_Load();
	Stairs_AddLearned();
}

// Add the routes learned from human players (zps24_learn) for this map. Call after
// Learned_Load(); safe to call again (it replaces the learned ones).
void Stairs_AddLearned()
{
	g_st_routeCount = g_st_ladderEnd;
	for (int i = g_st_ladderEnd; i < STAIRS_MAX_ROUTES; i++)
	{
		g_st_pointCount[i] = 0;
		g_st_ladder[i] = false;
	}
	for (int l = 0; l < g_ln_routeCount && g_st_routeCount < STAIRS_MAX_ROUTES; l++)
	{
		int r = g_st_routeCount++;
		g_st_lower[r] = -1;
		for (int i = 0; i < g_ln_routeLen[l] && i < STAIRS_MAX_POINTS; i++)
			Stairs_AddPoint(r, g_ln_routes[l][i][0], g_ln_routes[l][i][1], g_ln_routes[l][i][2]);
	}
}

// A learned route that takes the bot toward the target's floor: it must start on the bot's floor,
// not too far away, and end closer in height to the target. Returns the route or -1.
int Stairs_LearnedFor(const float me[3], const float target[3], int &step)
{
	return Stairs_GenericFor(me, target, step, g_st_ladderEnd, g_st_routeCount);
}

int Stairs_GenericFor(const float me[3], const float target[3], int &step, int lo, int hi)
{
	float dzNow = FloatAbs(me[2] - target[2]);
	if (dzNow < 60.0)
		return -1;
	int best = -1;
	float bestCost = 999999.0;
	for (int r = lo; r < hi; r++)
	{
		int last = g_st_pointCount[r] - 1;
		for (int dir = 0; dir < 2; dir++)
		{
			float start[3], end[3];
			start = g_st_points[r][dir == 0 ? 0 : last];
			end = g_st_points[r][dir == 0 ? last : 0];
			if (FloatAbs(me[2] - start[2]) > 40.0 || FloatAbs(end[2] - target[2]) > dzNow - 40.0)
				continue;
			float toStart = Stairs_Dist2D(me, start), toTarget = Stairs_Dist2D(end, target);
			if (toStart > 1200.0 || toTarget > 1500.0)
				continue;
			float cost = toStart + toTarget * 0.5 + FloatAbs(end[2] - target[2]);
			if (cost < bestCost)
			{
				bestCost = cost;
				best = r;
				step = dir == 0 ? 1 : -1;
			}
		}
	}
	return best;
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
		if (g_st_lower[r] < 0) continue;
		if (to > from && g_st_lower[r] == from) { step = 1; return r; }
		if (to < from && g_st_lower[r] == from - 1) { step = -1; return r; }
	}
	return -1;
}

// Steers the bot while it should use a staircase. Returns true when it has set moveGoal or is
// steering the bot itself; `result` is then what the scripted-update callback should return.
// allowLearned: also consider routes learned from the main player. Pass true only when the bot
// is stuck on its normal path; where the nav mesh covers the way (most stairs), pathing is better.
bool Stairs_Update(int client, NavBot bot, const float me[3], const float target[3], float moveGoal[3], NavBotRouteType &routeType, Action &result, bool allowLearned = false)
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
		float d3 = GetVectorDistance(me, wp);        // climbing a ladder only changes height
		if (d3 < g_st_bestDist[client] - 4.0)
		{
			g_st_bestDist[client] = d3;
			g_st_progressAt[client] = GetGameTime();
		}
		else if (GetGameTime() - g_st_progressAt[client] > 3.0)
		{
			if (r >= g_st_ladderEnd)
			{
				g_st_banned[client] = r;             // a learned route that doesn't work from here: not again for a while
				g_st_bannedUntil[client] = GetGameTime() + 30.0;
			}
			Stairs_Log("%N: no progress on route %d at point %d (%.0f %.0f %.0f), me %.0f %.0f %.0f", client, r, g_st_point[client], wp[0], wp[1], wp[2], me[0], me[1], me[2]);
			g_st_route[client] = -1;                 // stuck (someone in the way?): try again shortly
			g_st_cooldown[client] = GetGameTime() + 3.0;
			return false;
		}
		// Reached: close, at its height; a point higher up only once we're really up on it (a step
		// at the foot of cinema's projection window sat within 40 of the sill and skipped it).
		if (d < 16.0 && FloatAbs(me[2] - wp[2]) < 40.0 && me[2] > wp[2] - 12.0)
		{
			int next = g_st_point[client] + g_st_step[client];
			if (next < 0 || next >= g_st_pointCount[r])
			{
				Stairs_Log("%N: finished route %d at %.0f %.0f %.0f", client, r, me[0], me[1], me[2]);
				g_st_route[client] = -1;             // arrived on the other floor
				return false;
			}
			g_st_point[client] = next;
			g_st_bestDist[client] = 999999.0;
			g_st_progressAt[client] = GetGameTime();
			wp = g_st_points[r][next];
		}
		Address ctrl = bot.GetPlayerControllerInterface();
		if (g_st_ladder[r] && d < 24.0 && FloatAbs(wp[2] - me[2]) > 30.0)
		{
			// On the ladder: face it, look the way we're going (up or down) and walk into it.
			float look[3];
			look = wp;
			look[2] += wp[2] > me[2] ? 40.0 : -40.0;
			NavBotPlayerControllerInterface.AimAtPos(ctrl, look, LOOK_MOVEMENT, 0.3, "Climbing a ladder");
			NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_FORWARDS, 0.2);
			NavBotMovementInterface.MoveTowards(bot.GetMovementInterface(), wp, 100);
			result = Plugin_Continue;
			return true;
		}
		float look[3];
		look = wp;
		look[2] += 60.0;
		NavBotPlayerControllerInterface.AimAtPos(ctrl, look, LOOK_MOVEMENT, 0.3, "Taking the stairs");
		// Next point higher than a step (onto a car, a crate, a roof edge): jump for it, crouched,
		// the way players climb.
		// A real crouch-jump: jump on the ground, pull the legs up (crouch) once in the air, keep
		// pushing forward all the way.
		if (!g_st_ladder[r] && d < 90.0 && (wp[2] - me[2] > 18.0 || Stairs_LowOpening(me, wp)))
		{
			NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_FORWARDS, 0.2);
			g_st_crouchJumpUntil[client] = GetGameTime() + 0.3;   // Stairs_RunCmd does the buttons
			if (GetEntityFlags(client) & FL_ONGROUND)
			{
				if (g_st_bestZ[client] > me[2] + 4.0)
					Stairs_Log("%N jump step: took off at %.0f %.0f %.0f, peaked at z %.0f %s(aiming for %.0f %.0f %.0f)", client,
						g_st_jumpFrom[client][0], g_st_jumpFrom[client][1], g_st_jumpFrom[client][2], g_st_bestZ[client],
						g_st_peakDucked[client] ? "crouched " : "standing ", wp[0], wp[1], wp[2]);
				g_st_bestZ[client] = me[2];
				g_st_jumpFrom[client] = me;
			}
			else if (me[2] > g_st_bestZ[client])
			{
				g_st_bestZ[client] = me[2];
				g_st_peakDucked[client] = (GetEntityFlags(client) & FL_DUCKING) != 0;
			}
		}
		NavBotMovementInterface.MoveTowards(bot.GetMovementInterface(), wp, 100);
		result = Plugin_Continue;                    // keep the behavior, no pathfinding
		return true;
	}

	if (GetGameTime() < g_st_cooldown[client])
		return false;

	// Need a different floor of the building (hand-made routes), or another floor anywhere a
	// human showed the way (learned routes)?
	int step;
	r = -1;
	int tl = Stairs_Level(target);
	int ml = Stairs_Level(me);
	if (tl != -1 || ml != -1)
	{
		int from = ml == -1 ? 0 : ml;                // outside: enter on the ground floor
		int to = tl == -1 ? 0 : tl;                  // target outside: leave by the ground floor
		if (from != to)
			r = Stairs_RouteFor(from, to, step);
	}
	if (r == -1)
		r = Stairs_GenericFor(me, target, step, g_st_handMade, g_st_ladderEnd);   // ladders: always
	if (r == -1 && allowLearned)
	{
		r = Stairs_LearnedFor(me, target, step);
		if (r != -1 && r == g_st_banned[client] && GetGameTime() < g_st_bannedUntil[client])
			r = -1;
	}
	if (r == -1)
		return false;

	// Walk (normal pathfinding) to this end of the staircase, then start steering.
	int first = step == 1 ? 0 : g_st_pointCount[r] - 1;
	float start[3];
	start = g_st_points[r][first];
	if (Stairs_Dist2D(me, start) < 24.0 && FloatAbs(me[2] - start[2]) < 40.0)
	{
		Stairs_Log("%N: starting route %d%s", client, r, g_st_ladder[r] ? " (ladder)" : "");
		g_st_route[client] = r;
		g_st_step[client] = step;
		g_st_point[client] = first + step;
		g_st_bestDist[client] = 999999.0;
		g_st_progressAt[client] = GetGameTime();
		result = Plugin_Continue;
		return true;
	}
	static float lastLog[MAXPLAYERS + 1];
	if (GetGameTime() - lastLog[client] > 5.0)
	{
		lastLog[client] = GetGameTime();
		Stairs_Log("%N: heading for route %d%s, foot %.0f %.0f %.0f (%.0f away)", client, r, g_st_ladder[r] ? " (ladder)" : "",
			start[0], start[1], start[2], GetVectorDistance(me, start));
	}
	moveGoal = start;
	routeType = NAVBOT_FASTEST_ROUTE;
	result = Plugin_Changed;
	return true;
}

bool Stairs_NotPlayers(int ent, int mask)
{
	return ent > MaxClients;
}

// The way to the next point goes through a window (cabin's main house: off the roof through the
// upstairs window, the teacher's route as a zombie): standing we'd walk into the wall under it or
// the frame above, crouched and jumping we get through. Then crouch-jump, the way the teacher does.
bool Stairs_LowOpening(const float me[3], const float wp[3])
{
	float dir[3], to[3];
	SubtractVectors(wp, me, dir);
	dir[2] = 0.0;
	if (GetVectorLength(dir) < 8.0)
		return false;
	NormalizeVector(dir, dir);
	ScaleVector(dir, 48.0);
	float from[3];
	from = me;
	from[2] += 2.0;
	AddVectors(from, dir, to);
	TR_TraceHullFilter(from, to, view_as<float>({-16.0, -16.0, 0.0}), view_as<float>({16.0, 16.0, 72.0}), MASK_PLAYERSOLID, Stairs_NotPlayers);
	if (!TR_DidHit())
		return false;                        // walk on through
	from[2] = me[2] + 26.0;                  // a crouched body at the top of a jump
	to[2] = from[2];
	TR_TraceHullFilter(from, to, view_as<float>({-16.0, -16.0, 0.0}), view_as<float>({16.0, 16.0, 36.0}), MASK_PLAYERSOLID, Stairs_NotPlayers);
	return !TR_DidHit();
}

// Call from OnPlayerRunCmd. A crouch-jump needs jump on the ground, then duck held in the air (legs
// up: about 18 units more). Pressed through NavBot the duck didn't happen mid-air and bots peaked
// 18-23 units up, short of a 44-unit ledge; set straight in the usercmd, it does.
stock bool Stairs_RunCmd(int client, int &buttons)
{
	if (client < 1 || client > MaxClients || GetGameTime() >= g_st_crouchJumpUntil[client])
		return false;
	if (GetEntityFlags(client) & FL_ONGROUND)
	{
		buttons |= IN_JUMP;
		buttons &= ~IN_DUCK;
	}
	else
		buttons |= IN_DUCK;
	buttons |= IN_FORWARD;
	return true;
}
