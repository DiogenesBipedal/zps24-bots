// Logs every bot's team, health, position and active weapon to the server console.
// Used to check from a terminal that NavBot bots spawn, move and fight on ZPS 2.4.
#include <sourcemod>
#include <sdktools>

public Plugin myinfo =
{
	name = "ZPS 2.4 bot probe",
	author = "Dead Apocalypse",
	description = "Logs bot state for headless testing",
	version = "1.0"
};

ConVar g_interval;
Handle g_timer;

public void OnPluginStart()
{
	g_interval = CreateConVar("sm_botprobe_interval", "0", "Seconds between bot state logs (0 = off)");
	g_interval.AddChangeHook(OnIntervalChanged);
	RegServerCmd("sm_botprobe", Cmd_Probe, "Log every bot's state once");
}

void OnIntervalChanged(ConVar cv, const char[] oldv, const char[] newv)
{
	delete g_timer;
	float t = cv.FloatValue;
	if (t > 0.0)
		g_timer = CreateTimer(t, Timer_Probe, _, TIMER_REPEAT);
}

Action Timer_Probe(Handle timer)
{
	LogBots();
	return Plugin_Continue;
}

Action Cmd_Probe(int args)
{
	LogBots();
	return Plugin_Handled;
}

void LogBots()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsFakeClient(i))
			continue;

		float pos[3];
		GetClientAbsOrigin(i, pos);
		char weapon[64] = "-";
		if (IsPlayerAlive(i))
			GetClientWeapon(i, weapon, sizeof(weapon));

		PrintToServer("[probe] %N team=%d alive=%d hp=%d pos=%.0f %.0f %.0f weapon=%s",
			i, GetClientTeam(i), IsPlayerAlive(i), GetClientHealth(i), pos[0], pos[1], pos[2], weapon);
	}
}
