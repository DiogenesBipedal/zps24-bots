// Hinged doors (func_door, func_door_rotating, prop_door_rotating) aren't physics objects:
// bumping them does nothing, a player opens them with E. Shared by the survivor and zombie AI.
#if defined _zps24_doors_included
	#endinput
#endif
#define _zps24_doors_included

int   g_dr_door[MAXPLAYERS + 1] = { INVALID_ENT_REFERENCE, ... };   // door we're pressing E on
int   g_dr_tries[MAXPLAYERS + 1];
float g_dr_next[MAXPLAYERS + 1];
float g_dr_skipUntil[MAXPLAYERS + 1];   // that door won't open with E (locked/barred): leave it

stock bool Doors_IsHinged(int ent)
{
	char cls[64];
	GetEntityClassname(ent, cls, sizeof(cls));
	return StrEqual(cls, "prop_door_rotating") || StrEqual(cls, "func_door_rotating") || StrEqual(cls, "func_door");
}

// Closed (and not on its way open).
stock bool Doors_IsClosed(int door)
{
	if (HasEntProp(door, Prop_Data, "m_eDoorState"))
		return GetEntProp(door, Prop_Data, "m_eDoorState") == 0;        // DOOR_STATE_CLOSED
	if (HasEntProp(door, Prop_Data, "m_toggle_state"))
		return GetEntProp(door, Prop_Data, "m_toggle_state") == 1;      // TS_AT_BOTTOM
	return false;
}

stock bool Doors_IsLocked(int door)
{
	return HasEntProp(door, Prop_Data, "m_bLocked") && GetEntProp(door, Prop_Data, "m_bLocked") != 0;
}

stock void Doors_Center(int ent, float c[3])
{
	float mins[3], maxs[3], o[3];
	GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", o);
	GetEntPropVector(ent, Prop_Send, "m_vecMins", mins);
	GetEntPropVector(ent, Prop_Send, "m_vecMaxs", maxs);
	for (int i = 0; i < 3; i++)
		c[i] = o[i] + (mins[i] + maxs[i]) * 0.5;
}

// A closed, unlocked hinged door within reach in front of the bot (where it faces or moves).
stock int Doors_ClosedAhead(int client, float reach = 80.0)
{
	float me[3], ang[3], fwd[3], vel[3];
	GetClientAbsOrigin(client, me);
	GetClientEyeAngles(client, ang);
	ang[0] = 0.0;
	GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
	GetEntPropVector(client, Prop_Data, "m_vecVelocity", vel);
	vel[2] = 0.0;
	bool moving = GetVectorLength(vel) > 40.0;
	if (moving)
		NormalizeVector(vel, vel);

	static const char classes[][] = { "prop_door_rotating", "func_door_rotating", "func_door" };
	int best = -1;
	float bestDist = reach;
	for (int k = 0; k < sizeof(classes); k++)
	{
		int door = -1;
		while ((door = FindEntityByClassname(door, classes[k])) != -1)
		{
			float c[3], to[3];
			Doors_Center(door, c);
			if (FloatAbs(c[2] - (me[2] + 40.0)) > 70.0)
				continue;
			SubtractVectors(c, me, to);
			to[2] = 0.0;
			float d = GetVectorLength(to);
			if (d >= bestDist || !Doors_IsClosed(door) || Doors_IsLocked(door))
				continue;
			NormalizeVector(to, to);
			if (GetVectorDotProduct(to, fwd) < 0.3 && !(moving && GetVectorDotProduct(to, vel) > 0.3))
				continue;
			best = door;
			bestDist = d;
		}
	}
	return best;
}

// Press E on `door` (aim at it first). Two tries; if it stays shut, leave it to the caller for
// 10 s (locked, barred, or this team can't use it) and return false.
stock bool Doors_Use(int client, NavBot bot, int door)
{
	float now = GetGameTime();
	int ref = EntIndexToEntRef(door);
	if (ref != g_dr_door[client])
	{
		g_dr_door[client] = ref;
		g_dr_tries[client] = 0;
		g_dr_skipUntil[client] = 0.0;
	}
	else if (now < g_dr_skipUntil[client])
		return false;
	if (now < g_dr_next[client])
		return true;
	if (g_dr_tries[client] >= 2)
	{
		g_dr_skipUntil[client] = now + 10.0;
		g_dr_tries[client] = 0;
		return false;
	}
	float c[3];
	Doors_Center(door, c);
	Address ctrl = bot.GetPlayerControllerInterface();
	NavBotPlayerControllerInterface.AimAtPos(ctrl, c, LOOK_PRIORITY, 0.6, "Opening door (E)");
	NavBotPlayerControllerInterface.PressButtonByID(ctrl, NAVBOT_BUTTON_USE, 0.2);
	g_dr_tries[client]++;
	g_dr_next[client] = now + 1.0;
	return true;
}

// Every think: a closed door right in front of us? Open it with E. Returns true while busy.
stock bool Doors_UseAhead(int client, NavBot bot)
{
	int door = Doors_ClosedAhead(client);
	if (door == -1)
		return false;
	return Doors_Use(client, bot, door);
}

stock void Doors_Reset(int client)
{
	g_dr_door[client] = INVALID_ENT_REFERENCE;
	g_dr_tries[client] = 0;
	g_dr_next[client] = 0.0;
	g_dr_skipUntil[client] = 0.0;
}
