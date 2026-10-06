#include <sourcemod>
#include <navbot>
#include <sdktools>
#undef REQUIRE_EXTENSIONS
#undef REQUIRE_PLUGIN
// #include <tf2_stocks>

#pragma newdecls required
#pragma semicolon 1

ConVar cv_quota_target = null;
ConVar cv_quota_fixed = null;
ConVar cv_quota_empty = null;
ConVar cv_quota_ignore_other_bots = null;
ConVar cv_quota_smart_kick = null;
ConVar cv_quota_check_teams = null;
bool g_bIsRunningChecks = false;

enum QuotaThinkState
{
	STATE_NONE = 0,
	STATE_ADDBOT,
	STATE_REMOVEBOT,

	MAX_THINK_STATES
}

QuotaThinkState g_thinkState;

enum GameMod
{
	GAME_TF2 = 0,
	GAME_OTHER,

	MAX_GAME_TYPES
}

GameMod g_game; // detected game type

public Plugin myinfo =
{
	name = "NavBot Quota System",
	author = "caxanga334",
	description = "Bot quota system for the NavBot extension.",
	version = "1.0.1",
	url = "https://github.com/caxanga334/navbot-plugins"
};

#include "navbot_quota/functions.sp"

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	if (late)
	{
		if (!LibraryExists("navbot"))
		{
			strcopy(error, err_max, "NavBot extension not running!");
			return APLRes_SilentFailure;
		}
	}

	g_game = GAME_OTHER;

	EngineVersion engine = GetEngineVersion();

	if (engine == Engine_TF2)
	{
		g_game = GAME_TF2;
	}

	return APLRes_Success;
}

public void OnPluginStart()
{
	cv_quota_target = CreateConVar("sm_navbot_quota_target", "-1", "Target bot quantity.", FCVAR_NONE, true, -1.0, false);
	cv_quota_fixed = CreateConVar("sm_navbot_quota_fixed", "0", "If enabled, keep a fixed number of bots in-game.", FCVAR_NONE, true, 0.0, true, 1.0);
	cv_quota_empty = CreateConVar("sm_navbot_quota_empty_server", "1", "If enabled, kick all bots when the server is detected to be empty.", FCVAR_NONE, true, 0.0, true, 1.0);
	cv_quota_ignore_other_bots = CreateConVar("sm_navbot_quota_ignore_other_bots", "1", "If enabled, the quota system ignores non NavBot bots in the player count.", FCVAR_NONE, true, 0.0, true, 1.0);
	cv_quota_smart_kick = CreateConVar("sm_navbot_quota_use_smart_kick", "1", "If enabled, uses the smart kick system.", FCVAR_NONE, true, 0.0, true, 1.0);
	cv_quota_check_teams = CreateConVar("sm_navbot_quota_check_teams", "1", "If enabled, ignore unassigned and spectator clients.", FCVAR_NONE, true, 0.0, true, 1.0);

	cv_quota_target.AddChangeHook(OnQuotaConVarChanged);
	cv_quota_fixed.AddChangeHook(OnQuotaConVarChanged);

	AutoExecConfig(true);

	g_thinkState = STATE_NONE;

	HookEvent("player_team", Event_OnPlayerChangeTeam, EventHookMode_PostNoCopy);
}

public void OnConfigsExecuted()
{
	RequestFrame(CheckBotQuota);
}

void OnQuotaConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (!g_bIsRunningChecks)
	{
		g_bIsRunningChecks = true;
		RequestFrame(CheckBotQuota);
	}
}

public void OnMapStart()
{
	g_thinkState = STATE_NONE;
	CreateTimer(2.0, Timer_QuotaThink, 0, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

	if (!cv_quota_empty.BoolValue && cv_quota_target.IntValue > 0)
	{
		RequestFrame(CheckBotQuota);
	}
}

public void OnClientPutInServer(int client)
{
	if (IsClientSourceTV(client) || IsClientReplay(client))
	{
		return;
	}

	if (!g_bIsRunningChecks)
	{
		g_bIsRunningChecks = true;
		RequestFrame(CheckBotQuota);
	}
}

public void OnClientDisconnect_Post(int client)
{
	if (!g_bIsRunningChecks)
	{
		g_bIsRunningChecks = true;
		RequestFrame(CheckBotQuota);
	}
}

void Event_OnPlayerChangeTeam(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_bIsRunningChecks)
	{
		g_bIsRunningChecks = true;
		RequestFrame(CheckBotQuota);
	}
}

// Call this function (either directly or with requestframe) to update the bot quota logic
void CheckBotQuota()
{
	int target = cv_quota_target.IntValue;
	g_bIsRunningChecks = false;

	// Disabled
	if (target <= -1) { return; }

	// No nav mesh available.
	if (!NavBotNavMesh.IsLoaded()) { return; }

	int navbots = NavBotManager.GetNavBotCount();
	int humans = GetHumanClientCount();

	if (target == 0)
	{
		if (navbots > 0)
		{
			g_thinkState = STATE_REMOVEBOT;
		}

		return;
	}

	if (cv_quota_fixed.BoolValue)
	{
		// fixed mode
		if (navbots > target)
		{
			g_thinkState = STATE_REMOVEBOT;
		}
		else if (navbots < target)
		{
			g_thinkState = STATE_ADDBOT;
		}
		else if (navbots == target)
		{
			g_thinkState = STATE_NONE;
		}

		return;
	}

	// normal/fill mode

	// empty server
	if (humans == 0 && cv_quota_empty.BoolValue)
	{
		g_thinkState = STATE_NONE;
		KickAllNavBots();
		return;
	}

	int desired = humans + navbots;

	// over limit, need to remove a bot
	if (desired > target)
	{
		g_thinkState = STATE_REMOVEBOT;
	}
	
	// under limit, need to add a bot
	if (desired < target)
	{
		g_thinkState = STATE_ADDBOT;
	}

	// no change needed
	if (desired == target)
	{
		g_thinkState = STATE_NONE;
	}
}

Action Timer_QuotaThink(Handle timer)
{
	if (g_thinkState == STATE_NONE) { return Plugin_Continue; }

	if (g_thinkState == STATE_ADDBOT)
	{
		NavBot bot = NavBot();

		if (bot.IsNull)
		{
			LogError("Failed to add a NavBot instance!");
		}
	}

	if (g_thinkState == STATE_REMOVEBOT)
	{
		if (cv_quota_target.IntValue == 0)
		{
			KickAllNavBots();
		}
		else
		{
			if (cv_quota_smart_kick.BoolValue)
			{
				SmartBotKick();
			}
			else
			{
				KickRandomNavBot("Bot Quota System: Removing bot!");
			}
		}
	}

	RequestFrame(CheckBotQuota);
	return Plugin_Continue;
}