// Server-wide music radio for ZPS 2.4.
//
// Plays playlists ("stations") of MP3s to every player. Tracks come from
// configs/zps24_radio.cfg, written by scripts/radio-import.sh. Admins control it from the M menu
// (sm_radio): play/stop, next track, station, shuffle, volume. Any player can mute it for
// themselves with !radio (sm_radiomute).
#include <sourcemod>
#include <sdktools>

public Plugin myinfo =
{
	name = "ZPS 2.4 radio",
	author = "Dead Apocalypse",
	description = "Server-wide music playlists",
	version = "1.0"
};

#define MAX_TRACKS 512

ConVar g_volume, g_autostart, g_shuffle;

// Loaded playlist
char  g_stationName[32][32];
int   g_stationFirst[32], g_stationCount[32];
int   g_stations;
char  g_trackFile[MAX_TRACKS][PLATFORM_MAX_PATH];
char  g_trackTitle[MAX_TRACKS][64];
float g_trackLength[MAX_TRACKS];
int   g_tracks;

// Playback state
bool   g_playing;
int    g_station;
int    g_current = -1;          // track index into g_trackFile
Handle g_nextTimer;
bool   g_muted[MAXPLAYERS + 1];

public void OnPluginStart()
{
	g_volume    = CreateConVar("sm_radio_volume", "0.5", "Radio volume (0-1)", _, true, 0.0, true, 1.0);
	g_autostart = CreateConVar("sm_radio_autostart", "1", "Start the radio automatically on each map");
	g_shuffle   = CreateConVar("sm_radio_shuffle", "1", "Play tracks in random order");
	AutoExecConfig(true, "zps24_radio");

	RegAdminCmd("sm_radio", Cmd_Menu, ADMFLAG_GENERIC, "Radio control menu");
	RegAdminCmd("sm_radio_reload", Cmd_Reload, ADMFLAG_GENERIC, "Reload configs/zps24_radio.cfg");
	RegConsoleCmd("sm_radiomute", Cmd_Mute, "Mute/unmute the radio for yourself (chat: !radiomute)");
	RegConsoleCmd("sm_radiooff", Cmd_Mute, "Same as sm_radiomute");
	LoadPlaylist();
}

public void OnMapStart()
{
	g_nextTimer = null;
	g_playing = false;
	g_current = -1;
	LoadPlaylist();
	char path[PLATFORM_MAX_PATH];
	for (int i = 0; i < g_tracks; i++)
	{
		PrecacheSound(g_trackFile[i], true);
		Format(path, sizeof(path), "sound/%s", g_trackFile[i]);
		AddFileToDownloadsTable(path);     // other players download the music on connect
	}
	if (g_autostart.BoolValue && g_tracks > 0)
		CreateTimer(15.0, Timer_AutoStart, _, TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_AutoStart(Handle timer)
{
	if (!g_playing)
		Play(-1);
	return Plugin_Stop;
}

public void OnClientDisconnect(int client)
{
	g_muted[client] = false;
}

public void OnClientPutInServer(int client)
{
	// Late joiners hear the current track from its start (Source can't seek a sound).
	if (g_playing && g_current >= 0 && !IsFakeClient(client))
		CreateTimer(5.0, Timer_LateJoin, GetClientUserId(client));
}

Action Timer_LateJoin(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client && g_playing && g_current >= 0)
		PlayTo(client, g_current);
	return Plugin_Stop;
}

// ---------------------------------------------------------------------------------------------
// Playlist

void LoadPlaylist()
{
	g_stations = 0;
	g_tracks = 0;
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "configs/zps24_radio.cfg");
	KeyValues kv = new KeyValues("Radio");
	if (!kv.ImportFromFile(path) || !kv.GotoFirstSubKey())
	{
		delete kv;
		return;
	}
	do
	{
		if (g_stations >= sizeof(g_stationName))
			break;
		kv.GetSectionName(g_stationName[g_stations], sizeof(g_stationName[]));
		g_stationFirst[g_stations] = g_tracks;
		g_stationCount[g_stations] = 0;
		if (kv.GotoFirstSubKey())
		{
			do
			{
				if (g_tracks >= MAX_TRACKS)
					break;
				kv.GetString("file", g_trackFile[g_tracks], sizeof(g_trackFile[]));
				kv.GetString("title", g_trackTitle[g_tracks], sizeof(g_trackTitle[]));
				g_trackLength[g_tracks] = kv.GetFloat("length", 180.0);
				g_tracks++;
				g_stationCount[g_stations]++;
			} while (kv.GotoNextKey());
			kv.GoBack();
		}
		if (g_stationCount[g_stations] > 0)
			g_stations++;
	} while (kv.GotoNextKey());
	delete kv;
	if (g_station >= g_stations)
		g_station = 0;
}

// ---------------------------------------------------------------------------------------------
// Playback

void PlayTo(int client, int track)
{
	if (!IsClientInGame(client) || IsFakeClient(client) || g_muted[client])
		return;
	EmitSoundToClient(client, g_trackFile[track], SOUND_FROM_PLAYER, SNDCHAN_STATIC, SNDLEVEL_NONE, SND_NOFLAGS, g_volume.FloatValue);
}

void StopFor(int client, int track)
{
	if (IsClientInGame(client) && !IsFakeClient(client))
		StopSound(client, SNDCHAN_STATIC, g_trackFile[track]);
}

void StopAll()
{
	if (g_current >= 0)
		for (int i = 1; i <= MaxClients; i++)
			StopFor(i, g_current);
	delete g_nextTimer;
}

// track = -1: next track of the current station (random if shuffling)
void Play(int track)
{
	if (g_stations == 0)
		return;
	StopAll();
	int first = g_stationFirst[g_station], count = g_stationCount[g_station];
	if (track < 0)
	{
		if (g_shuffle.BoolValue && count > 1)
		{
			do track = first + GetRandomInt(0, count - 1); while (track == g_current);
		}
		else
		{
			track = (g_current >= first && g_current < first + count - 1) ? g_current + 1 : first;
		}
	}
	g_current = track;
	g_playing = true;
	for (int i = 1; i <= MaxClients; i++)
		PlayTo(i, track);
	PrintToChatAll("[Radio] %s: %s", g_stationName[g_station], g_trackTitle[track]);
	g_nextTimer = CreateTimer(g_trackLength[track] + 1.0, Timer_Next, _, TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_Next(Handle timer)
{
	g_nextTimer = null;
	if (g_playing)
		Play(-1);
	return Plugin_Stop;
}

void Stop()
{
	StopAll();
	g_playing = false;
	PrintToChatAll("[Radio] off");
}

// ---------------------------------------------------------------------------------------------
// Commands and menu

Action Cmd_Mute(int client, int args)
{
	if (client <= 0)
		return Plugin_Handled;
	g_muted[client] = !g_muted[client];
	if (g_muted[client] && g_current >= 0)
		StopFor(client, g_current);
	else if (!g_muted[client] && g_playing && g_current >= 0)
		PlayTo(client, g_current);
	PrintToChat(client, "[Radio] %s for you", g_muted[client] ? "muted" : "unmuted");
	return Plugin_Handled;
}

Action Cmd_Reload(int client, int args)
{
	LoadPlaylist();
	ReplyToCommand(client, "[Radio] %d stations, %d tracks (new files need a map change to precache)", g_stations, g_tracks);
	return Plugin_Handled;
}

Action Cmd_Menu(int client, int args)
{
	if (client > 0)
		ShowRadioMenu(client);
	return Plugin_Handled;
}

void ShowRadioMenu(int client)
{
	Menu m = new Menu(Menu_Radio);
	char title[128];
	if (g_stations == 0)
		Format(title, sizeof(title), "Radio: no music imported\n(run scripts/radio-import.sh)");
	else if (g_playing && g_current >= 0)
		Format(title, sizeof(title), "Radio: %s\nNow: %s\nVolume %.0f%%", g_stationName[g_station], g_trackTitle[g_current], g_volume.FloatValue * 100.0);
	else
		Format(title, sizeof(title), "Radio: off (%s)", g_stationName[g_station]);
	m.SetTitle(title);
	m.AddItem("toggle", g_playing ? "Stop" : "Play");
	m.AddItem("next", "Next track");
	m.AddItem("station", "Change station");
	m.AddItem("shuffle", g_shuffle.BoolValue ? "Shuffle: on" : "Shuffle: off");
	m.AddItem("vol+", "Volume +10%");
	m.AddItem("vol-", "Volume -10%");
	m.Display(client, MENU_TIME_FOREVER);
}

int Menu_Radio(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End) { delete menu; return 0; }
	if (action != MenuAction_Select) return 0;
	char info[16];
	menu.GetItem(item, info, sizeof(info));
	if (StrEqual(info, "toggle"))        { if (g_playing) Stop(); else Play(-1); }
	else if (StrEqual(info, "next"))     Play(-1);
	else if (StrEqual(info, "shuffle"))  g_shuffle.BoolValue = !g_shuffle.BoolValue;
	else if (StrEqual(info, "vol+") || StrEqual(info, "vol-"))
	{
		float v = g_volume.FloatValue + (info[3] == '+' ? 0.1 : -0.1);
		g_volume.FloatValue = v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v);
		if (g_playing && g_current >= 0)
			Play(g_current);   // restart the track at the new volume
	}
	else if (StrEqual(info, "station"))  { ShowStationMenu(client); return 0; }
	ShowRadioMenu(client);
	return 0;
}

void ShowStationMenu(int client)
{
	Menu m = new Menu(Menu_Station);
	m.SetTitle("Station");
	char idx[8], label[64];
	for (int i = 0; i < g_stations; i++)
	{
		IntToString(i, idx, sizeof(idx));
		Format(label, sizeof(label), "%s (%d tracks)", g_stationName[i], g_stationCount[i]);
		m.AddItem(idx, label);
	}
	m.ExitBackButton = true;
	m.Display(client, MENU_TIME_FOREVER);
}

int Menu_Station(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End) { delete menu; return 0; }
	if (action == MenuAction_Cancel && item == MenuCancel_ExitBack) { ShowRadioMenu(client); return 0; }
	if (action != MenuAction_Select) return 0;
	char idx[8];
	menu.GetItem(item, idx, sizeof(idx));
	g_station = StringToInt(idx);
	g_current = -1;
	Play(-1);
	ShowRadioMenu(client);
	return 0;
}
