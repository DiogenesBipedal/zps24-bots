// Shared escalating "unstick" logic for zps24_survivors and zps24_zombies.
//
// Call Unstick_Track(client) once a second, and Unstick_Goal(client, bot, goal) from the scripted
// update before using your own move goal. A bot counts as stuck when it wanted to move somewhere
// (Unstick_WantMove) but hasn't covered 30 units:
//    3 s  jump + sidestep
//    6 s  detour to a random walkable spot 250-600 units away for 4 s
//   15 s  teleport to the centre of the nearest nav area (last resort)
#if defined _zps24_unstick_included
 #endinput
#endif
#define _zps24_unstick_included

float g_us_lastPos[MAXPLAYERS + 1][3];
float g_us_movedAt[MAXPLAYERS + 1];
bool  g_us_wantMove[MAXPLAYERS + 1];
float g_us_detour[MAXPLAYERS + 1][3];
float g_us_detourUntil[MAXPLAYERS + 1];
float g_us_nextAction[MAXPLAYERS + 1];

void Unstick_Reset(int client)
{
	g_us_movedAt[client] = GetGameTime();
	g_us_wantMove[client] = false;
	g_us_detourUntil[client] = 0.0;
	g_us_nextAction[client] = 0.0;
}

// The bot is trying to get somewhere farther than 100 units away.
void Unstick_WantMove(int client, const float me[3], const float goal[3])
{
	g_us_wantMove[client] = GetVectorDistance(me, goal) > 100.0;
}

float Unstick_StuckFor(int client)
{
	return g_us_wantMove[client] ? GetGameTime() - g_us_movedAt[client] : 0.0;
}

bool Unstick_RandomSpot(int client, float out[3])
{
	float pos[3];
	GetClientAbsOrigin(client, pos);
	Address start = NavBotNavMesh.GetNearestNavArea(pos, 300.0, false, true);
	if (start == Address_Null)
		return false;
	NavBotNavAreaCollector c = new NavBotNavAreaCollector();
	c.SetSearchStartArea(start);
	c.TravelLimit = 600.0;
	c.Execute();
	bool ok = false;
	for (int tries = 0; tries < 8 && !ok; tries++)
	{
		Address a = c.GetRandomCollectedArea();
		if (a == Address_Null)
			break;
		NavBotNavArea.GetCenter(a, out);
		ok = GetVectorDistance(out, pos) > 250.0;
	}
	delete c;
	return ok;
}

// Once a second.
void Unstick_Track(int client, NavBot bot)
{
	float pos[3];
	GetClientAbsOrigin(client, pos);
	if (GetVectorDistance(pos, g_us_lastPos[client]) > 30.0)
	{
		g_us_lastPos[client] = pos;
		g_us_movedAt[client] = GetGameTime();
		return;
	}

	float stuck = Unstick_StuckFor(client);
	if (stuck < 3.0 || GetGameTime() < g_us_nextAction[client])
		return;

	Address ctrl = bot.GetPlayerControllerInterface();
	if (stuck >= 15.0)
	{
		Address area = NavBotNavMesh.GetNearestNavArea(pos, 300.0, false, true);
		if (area != Address_Null)
		{
			float c[3];
			NavBotNavArea.GetCenter(area, c);
			c[2] += 8.0;
			TeleportEntity(client, c, NULL_VECTOR, view_as<float>({0.0, 0.0, 0.0}));
		}
		g_us_movedAt[client] = GetGameTime();       // start over
		g_us_nextAction[client] = GetGameTime() + 2.0;
	}
	else if (stuck >= 6.0)
	{
		if (g_us_detourUntil[client] < GetGameTime() && Unstick_RandomSpot(client, g_us_detour[client]))
			g_us_detourUntil[client] = GetGameTime() + 4.0;
		g_us_nextAction[client] = GetGameTime() + 4.0;
	}
	else
	{
		NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_JUMP, 0.2);
		NavBotPlayerControllerInterface.PressButtonByID(ctrl, GetRandomInt(0, 1) ? NAVBOT_BUTTON_MOVELEFT : NAVBOT_BUTTON_MOVERIGHT, 0.6);
		g_us_nextAction[client] = GetGameTime() + 1.0;
	}
}

// Overrides the move goal while a detour is active. Returns true if it did.
bool Unstick_Goal(int client, float moveGoal[3])
{
	if (g_us_detourUntil[client] <= GetGameTime())
		return false;
	moveGoal = g_us_detour[client];
	return true;
}
