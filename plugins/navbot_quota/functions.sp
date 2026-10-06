
#define TEAM_UNASSIGNED 0
#define TEAM_SPECTATOR 1
#define TEAM_A 2
#define TEAM_B 3
#define TEAM_ANY -2


void KickAllNavBots()
{
	for (int client = 1; client <=MaxClients; client++)	
	{
		if (IsClientInGame(client) && NavBotManager.IsNavBot(client))
		{
			KickClient(client, "NavBot Quota Manager: Kicking all bots!");
		}
	}
}

void KickFirstDeadBot(const char[] reason, const int team = TEAM_ANY)
{
	for (int client = 1; client <=MaxClients; client++)	
	{
		if (IsClientInGame(client) && !IsPlayerAlive(client) && NavBotManager.IsNavBot(client))
		{
			if (team != TEAM_ANY && GetClientTeam(client) != team)
			{
				continue;
			}

			KickClient(client, reason);
		}
	}
}

void KickRandomNavBot(const char[] reason)
{
	int[] bots = new int[MaxClients + 1];
	int n = 0;

	for (int client = 1; client <=MaxClients; client++)	
	{
		if (IsClientInGame(client) && NavBotManager.IsNavBot(client))
		{
			bots[n] = client;
			n++;
		}
	}

	if (n > 0)
	{
		int target = bots[GetRandomInt(0, n - 1)];
		KickClient(target, reason);
	}
}

int GetHumanClientCount()
{
	int n = 0;

	for (int client = 1; client <=MaxClients; client++)	
	{
		if (IsClientInGame(client))
		{
			if (cv_quota_ignore_other_bots.BoolValue && IsFakeClient(client))
			{
				continue;
			}

			if (NavBotManager.IsNavBot(client))
			{
				continue;
			}

			if (cv_quota_check_teams.BoolValue && GetClientTeam(client) <= TEAM_SPECTATOR)
			{
				continue;
			}

			n++;
		}
	}

	return n;
}

void SmartBotKick()
{
	if (g_game == GAME_TF2 && GameRules_GetProp("m_bPlayingMannVsMachine") == 1)
	{
		// MvM: always kick a random bot.
		KickRandomNavBot("Bot Quota System: Removing bot!");
		return;
	}

	if (cv_quota_check_teams.BoolValue)
	{
		if (GetTeamClientCount(TEAM_A) > GetTeamClientCount(TEAM_B))
		{
			KickFirstDeadBot("Bot Quota System: Removing bot!", TEAM_A);
		}
		else
		{
			KickFirstDeadBot("Bot Quota System: Removing bot!", TEAM_B);
		}
	}
	else
	{
		KickFirstDeadBot("Bot Quota System: Removing bot!", TEAM_ANY);
	}
}