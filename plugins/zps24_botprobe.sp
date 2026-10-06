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

	// Log chat/text user messages sent to clients (to debug odd chat text).
	static const char msgs[][] = { "SayText", "SayText2", "TextMsg", "HintText", "KeyHintText" };
	for (int i = 0; i < sizeof(msgs); i++)
	{
		UserMsg id = GetUserMessageId(msgs[i]);
		if (id != INVALID_MESSAGE_ID)
			HookUserMessage(id, Msg_Log, false);
	}
}

Action Msg_Log(UserMsg msg_id, BfRead msg, const int[] players, int playersNum, bool reliable, bool init)
{
	char name[32], buf[256], text[512];
	GetUserMessageName(msg_id, name, sizeof(name));
	text[0] = '\0';
	// Dump the first few fields as strings/bytes; enough to see what the client is asked to print.
	int first = msg.ReadByte();
	Format(text, sizeof(text), "b0=%d", first);
	for (int i = 0; i < 4 && msg.BytesLeft > 0; i++)
	{
		msg.ReadString(buf, sizeof(buf), true);
		Format(text, sizeof(text), "%s | \"%s\"", text, buf);
	}
	char who[64] = "-";
	if (playersNum > 0 && IsClientInGame(players[0]))
		Format(who, sizeof(who), "%N%s", players[0], IsFakeClient(players[0]) ? " (bot)" : "");
	PrintToServer("[usermsg] %s to %d players (first: %s): %s", name, playersNum, who, text);
	return Plugin_Continue;
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
