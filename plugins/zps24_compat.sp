// ZPS 2.4 compatibility for bots.
//
// ZPS 2.4's game code creates game events with IGameEventManager2::CreateEvent() and uses the
// result without a NULL check. The engine returns NULL for events nobody listens to, which is
// normal when only bots are playing (no human client is listening yet). Example: CZPLRules::JoinRound
// creates "zombie_death" and crashes the server. Listening to every defined event avoids that.
#include <sourcemod>
#undef REQUIRE_EXTENSIONS
#include <navbot>

public Plugin myinfo =
{
	name = "ZPS 2.4 bot compatibility",
	author = "Dead Apocalypse",
	description = "Keeps ZPS 2.4 from crashing on unlistened game events",
	version = "1.0"
};

static const char g_eventFiles[][] =
{
	// Paths are relative to the mod folder (zps/); the base events ship in hl2/resource.
	"resource/modevents.res",
	"../hl2/resource/GameEvents.res",
	"../hl2/resource/serverevents.res",
	"../hl2/resource/hltvevents.res"
};

public void OnPluginStart()
{
	int hooked = 0;

	for (int i = 0; i < sizeof(g_eventFiles); i++)
	{
		KeyValues kv = new KeyValues("events");

		if (kv.ImportFromFile(g_eventFiles[i]) && kv.GotoFirstSubKey())
		{
			char name[64];
			do
			{
				kv.GetSectionName(name, sizeof(name));
				if (HookEventEx(name, Event_Ignore, EventHookMode_PostNoCopy))
					hooked++;
			} while (kv.GotoNextKey());
		}

		delete kv;
	}

	LogMessage("Listening to %d game events", hooked);

	// Bots were spamming random text in all-chat. Block chat from bots and log where it came from.
	AddCommandListener(Cmd_BotSay, "say");
	AddCommandListener(Cmd_BotSay, "say_team");
}

Action Cmd_BotSay(int client, const char[] command, int argc)
{
	if (client <= 0 || !IsClientInGame(client) || !IsFakeClient(client))
		return Plugin_Continue;

	char text[192], task[192] = "";
	GetCmdArgString(text, sizeof(text));
	if (LibraryExists("navbot") && NavBotManager.IsNavBot(client))
		NavBotBehaviorInterface.GetTaskDebugString(NavBotManager.GetNavBotByIndex(client).GetBehaviorInterface(), task, sizeof(task));
	LogMessage("Blocked %s from bot %N (task %s): %s", command, client, task, text);
	return Plugin_Stop;
}

void Event_Ignore(Event event, const char[] name, bool dontBroadcast)
{
}
