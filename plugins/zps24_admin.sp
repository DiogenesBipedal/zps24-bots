// ZPS 2.4 admin tools for the bot test server.
//
//   M  (bound automatically)  sm_zpsmenu   admin menu: bots, maps, round, cheats
//   V  (bound automatically)  +zpshook     grappling hook: pulls you toward where you aim
//
// Also keeps human players on the survivor team: before each round's zombie pick, bots are marked
// as zombie volunteers and humans are not, so ZPS picks the Carrier from the bots.
#include <sourcemod>
#include <sdktools>
#undef REQUIRE_EXTENSIONS
#include <navbot>

public Plugin myinfo =
{
	name = "ZPS 2.4 admin tools",
	author = "Dead Apocalypse",
	description = "M admin menu, V grappling hook, humans always survive",
	version = "1.0"
};

// CHL2MP_Player byte that JoinRound sets and CHL2MPRules::ChooseRandomZombie() splits its
// candidate lists on (the "volunteer as zombie" choice in ZPS 2.4).
#define OFFSET_ZOMBIE_VOLUNTEER 0x1369
#define TEAM_SURVIVOR_BOT 2
#define TEAM_ZOMBIE_BOT   3
#define TEAM_READYROOM    4   // between rounds; still being here at round start = auto-assigned zombie

ConVar g_humansSurvive, g_hookSpeed, g_autoBind, g_volunteerValue;
bool   g_joinWindow;   // between ZPS's "Round is starting" and "Round has started" messages
int    g_beamSprite, g_haloSprite;
bool   g_hooking[MAXPLAYERS + 1];
float  g_hookPoint[MAXPLAYERS + 1][3];

static const char g_maps[][] = { "zpo_cabin_outbreak_b8_com", "zpo_church_siege_final_h", "zps_deadend", "zps_town", "zps_asylum",
	"zps_cinema", "zps_policestation", "zps_ruralpanic", "zps_silence", "zps_underground" };

public void OnPluginStart()
{
	g_humansSurvive = CreateConVar("sm_zps24_humans_survive", "1", "Keep human players off the zombie team at round start");
	g_hookSpeed     = CreateConVar("sm_zps24_hook_speed", "900", "Grappling hook pull speed");
	g_autoBind      = CreateConVar("sm_zps24_autobind", "1", "Bind M (menu) and V (hook) for admins when they join");
	g_volunteerValue = CreateConVar("sm_zps24_volunteer_value", "-1", "Experimental: value of ChooseRandomZombie's per-player byte for bots (humans get the opposite); -1 = leave alone");
	AutoExecConfig(true, "zps24_admin");

	RegAdminCmd("sm_zpsmenu", Cmd_Menu, ADMFLAG_GENERIC, "Open the ZPS 2.4 admin menu");
	RegAdminCmd("+zpshook", Cmd_HookOn, ADMFLAG_GENERIC, "Grappling hook (hold)");
	RegAdminCmd("-zpshook", Cmd_HookOff, ADMFLAG_GENERIC, "Grappling hook release");

	RegServerCmd("sm_zps24_humans", Cmd_Humans, "Print human players' teams and the Carrier");
	RegConsoleCmd("sm_here", Cmd_Here, "Log your position (chat: !here) for debugging bot movement");
	HookEventEx("game_round_restart", Event_RoundRestart, EventHookMode_PostNoCopy);
	CreateTimer(1.0, Timer_MarkVolunteers, _, TIMER_REPEAT);
	CreateTimer(0.5, Timer_SpectatorHud, _, TIMER_REPEAT);

	// ZPS announces the join window with TextMsg; track it so humans only ever join inside it.
	UserMsg textmsg = GetUserMessageId("TextMsg");
	if (textmsg != INVALID_MESSAGE_ID)
		HookUserMessage(textmsg, Msg_TextMsg, false);
}

public void OnMapStart()
{
	g_beamSprite = PrecacheModel("materials/sprites/laserbeam.vmt");
	g_haloSprite = PrecacheModel("materials/sprites/halo01.vmt");
}

public void OnClientPostAdminCheck(int client)
{
	if (IsFakeClient(client) || !g_autoBind.BoolValue || !CheckCommandAccess(client, "sm_zpsmenu", ADMFLAG_GENERIC))
		return;
	// The 2007 engine still lets servers run binds on clients.
	ClientCommand(client, "bind m sm_zpsmenu");
	ClientCommand(client, "bind v +zpshook");
	PrintToChat(client, "[ZPS] M = admin menu, V = grappling hook");
}

public void OnClientDisconnect(int client)
{
	g_hooking[client] = false;
}

// ---------------------------------------------------------------------------------------------
// Humans always survive

void Event_RoundRestart(Event event, const char[] name, bool dontBroadcast)
{
	// A new round's join window: everyone is back in the ready room. Pick Survivors for humans now;
	// doing it once the round is running counts as a late join and makes them zombies.
	CreateTimer(1.0, Timer_JoinSurvivors, _, TIMER_FLAG_NO_MAPCHANGE);
	CreateTimer(4.0, Timer_JoinSurvivors, _, TIMER_FLAG_NO_MAPCHANGE);
	MarkVolunteers();
}

Action Timer_JoinSurvivors(Handle timer)
{
	if (!g_humansSurvive.BoolValue)
		return Plugin_Stop;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == TEAM_READYROOM)
			FakeClientCommand(i, "choose1");
	}
	return Plugin_Stop;
}

Action Msg_TextMsg(UserMsg msg_id, BfRead msg, const int[] players, int playersNum, bool reliable, bool init)
{
	char text[192];
	msg.ReadByte();
	msg.ReadString(text, sizeof(text), true);
	if (StrContains(text, "Round is starting") != -1)
		g_joinWindow = true;
	else if (StrContains(text, "Round has started") != -1)
		g_joinWindow = false;
	return Plugin_Continue;
}

Action Timer_MarkVolunteers(Handle timer)
{
	if (g_joinWindow)
		Timer_JoinSurvivors(null);
	MarkVolunteers();
	return Plugin_Continue;
}

void MarkVolunteers()
{
	if (!g_humansSurvive.BoolValue)
		return;

	if (g_volunteerValue.IntValue < 0)
		return;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
		{
			int bots = g_volunteerValue.IntValue ? 1 : 0;
			SetEntData(i, OFFSET_ZOMBIE_VOLUNTEER, IsFakeClient(i) ? bots : 1 - bots, 1, false);
		}
	}
}

Action Cmd_Here(int client, int args)
{
	if (client <= 0)
		return Plugin_Handled;
	float pos[3], ang[3];
	GetClientAbsOrigin(client, pos);
	GetClientEyeAngles(client, ang);
	LogMessage("HERE %N at %.0f %.0f %.0f facing yaw %.0f", client, pos[0], pos[1], pos[2], ang[1]);
	PrintToChat(client, "[ZPS] Logged your position %.0f %.0f %.0f", pos[0], pos[1], pos[2]);
	return Plugin_Handled;
}

Action Cmd_Humans(int args)
{
	char weapon[64];
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;
		weapon = "-";
		if (IsPlayerAlive(i))
			GetClientWeapon(i, weapon, sizeof(weapon));
		if (!IsFakeClient(i) || StrEqual(weapon, "weapon_carrierarms"))
			PrintToServer("[humans] %N bot=%d team=%d alive=%d weapon=%s", i, IsFakeClient(i), GetClientTeam(i), IsPlayerAlive(i), weapon);
	}
	return Plugin_Handled;
}

// While an admin spectates a bot, show what the bot is doing: the same data as sm_botprobe.
Action Timer_SpectatorHud(Handle timer)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || IsFakeClient(client) || IsPlayerAlive(client) || !CheckCommandAccess(client, "sm_zpsmenu", ADMFLAG_GENERIC))
			continue;
		int target = GetEntPropEnt(client, Prop_Send, "m_hObserverTarget");
		if (target <= 0 || target > MaxClients || !IsClientInGame(target) || !IsFakeClient(target))
			continue;

		char weapon[64] = "-", task[192] = "";
		if (IsPlayerAlive(target))
			GetClientWeapon(target, weapon, sizeof(weapon));
		if (LibraryExists("navbot") && NavBotManager.IsNavBot(target))
			NavBotBehaviorInterface.GetTaskDebugString(NavBotManager.GetNavBotByIndex(target).GetBehaviorInterface(), task, sizeof(task));
		float pos[3];
		GetClientAbsOrigin(target, pos);
		PrintHintText(client, "%N  [%s]  hp %d  %s\n%s\npos %.0f %.0f %.0f",
			target, GetClientTeam(target) == 2 ? "survivor" : "zombie", GetClientHealth(target), weapon, task, pos[0], pos[1], pos[2]);
	}
	return Plugin_Continue;
}

// ---------------------------------------------------------------------------------------------
// Grappling hook

bool TraceIgnorePlayers(int entity, int mask)
{
	return entity > MaxClients;
}

Action Cmd_HookOn(int client, int args)
{
	if (client <= 0 || !IsPlayerAlive(client))
		return Plugin_Handled;

	float eye[3], ang[3];
	GetClientEyePosition(client, eye);
	GetClientEyeAngles(client, ang);
	TR_TraceRayFilter(eye, ang, MASK_SOLID, RayType_Infinite, TraceIgnorePlayers);
	if (!TR_DidHit())
		return Plugin_Handled;
	TR_GetEndPosition(g_hookPoint[client]);
	if (GetVectorDistance(eye, g_hookPoint[client]) > 4000.0)
		return Plugin_Handled;

	g_hooking[client] = true;
	CreateTimer(0.05, Timer_Hook, GetClientUserId(client), TIMER_REPEAT);
	return Plugin_Handled;
}

Action Cmd_HookOff(int client, int args)
{
	if (client > 0)
		g_hooking[client] = false;
	return Plugin_Handled;
}

Action Timer_Hook(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client == 0 || !g_hooking[client] || !IsPlayerAlive(client))
	{
		if (client) g_hooking[client] = false;
		return Plugin_Stop;
	}

	float pos[3], dir[3];
	GetClientEyePosition(client, pos);
	SubtractVectors(g_hookPoint[client], pos, dir);
	if (GetVectorLength(dir) < 48.0)
	{
		// Arrived: hang there.
		TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, view_as<float>({0.0, 0.0, 0.0}));
	}
	else
	{
		NormalizeVector(dir, dir);
		ScaleVector(dir, g_hookSpeed.FloatValue);
		TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, dir);
	}

	int color[4] = { 200, 200, 255, 220 };
	TE_SetupBeamPoints(pos, g_hookPoint[client], g_beamSprite, g_haloSprite, 0, 0, 0.1, 2.0, 2.0, 0, 0.0, color, 0);
	TE_SendToAll();
	return Plugin_Continue;
}

// ---------------------------------------------------------------------------------------------
// Admin menu

Action Cmd_Menu(int client, int args)
{
	if (client > 0)
		ShowMainMenu(client);
	return Plugin_Handled;
}

void ShowMainMenu(int client)
{
	Menu m = new Menu(Menu_Main);
	m.SetTitle("ZPS 2.4 admin");
	m.AddItem("addzombie", "Add zombie bot");
	m.AddItem("addsurvivor", "Add survivor bot");
	m.AddItem("bots", "Bot count / skill / kick");
	m.AddItem("map", "Change map");
	m.AddItem("restart", "Restart map (new round)");
	m.AddItem("ai", "Toggle survivor AI");
	m.AddItem("me", "Me: noclip / god / weapons");
	m.AddItem("spawn", "Spawn ammo / items / objects");
	m.AddItem("spectate", "Spectate (shows bot info)");
	m.AddItem("radio", "Radio");
	m.Display(client, MENU_TIME_FOREVER);
}

int Menu_Main(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End) { delete menu; return 0; }
	if (action != MenuAction_Select) return 0;

	char info[32];
	menu.GetItem(item, info, sizeof(info));
	if (StrEqual(info, "addzombie"))        { AddBot(TEAM_ZOMBIE_BOT); ShowMainMenu(client); }
	else if (StrEqual(info, "addsurvivor")) { AddBot(TEAM_SURVIVOR_BOT); ShowMainMenu(client); }
	else if (StrEqual(info, "bots"))        ShowBotMenu(client);
	else if (StrEqual(info, "map"))         ShowMapMenu(client);
	else if (StrEqual(info, "restart"))
	{
		// mp_restartround does nothing in ZPS 2.4; reloading the map starts a fresh round.
		char map[64];
		GetCurrentMap(map, sizeof(map));
		PrintToChatAll("[ZPS] Restarting %s", map);
		ForceChangeLevel(map, "Admin restart");
	}
	else if (StrEqual(info, "ai"))
	{
		ConVar ai = FindConVar("sm_zps24ai_enable");
		if (ai) { ai.BoolValue = !ai.BoolValue; PrintToChat(client, "[ZPS] Survivor AI %s", ai.BoolValue ? "on" : "off"); }
		ShowMainMenu(client);
	}
	else if (StrEqual(info, "me"))          ShowMeMenu(client);
	else if (StrEqual(info, "spawn"))       ShowSpawnMenu(client);
	else if (StrEqual(info, "radio"))       FakeClientCommand(client, "sm_radio");
	else if (StrEqual(info, "spectate"))
	{
		FakeClientCommand(client, "choose3");
		PrintToChat(client, "[ZPS] Spectating: click to cycle players, the hint box shows the bot's current task");
	}
	return 0;
}

void AddBot(int team)
{
	if (!LibraryExists("navbot"))
		return;
	NavBot bot = NavBot();
	if (bot == NULL_NAVBOT)
	{
		PrintToChatAll("[ZPS] Server is full");
		return;
	}
	// Mid-round joiners are placed by the game; make sure zombie bots end up on the zombie team.
	if (team == TEAM_ZOMBIE_BOT)
		CreateTimer(1.0, Timer_MakeZombie, GetClientUserId(bot.Index));
	else
		bot.DelayedFakeClientCommand("choose1");
}

Action Timer_MakeZombie(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client && IsClientInGame(client) && GetClientTeam(client) != 3)
	{
		ChangeClientTeam(client, 3);
		DispatchSpawn(client);
	}
	return Plugin_Stop;
}

void ShowBotMenu(int client)
{
	Menu m = new Menu(Menu_Bots);
	ConVar quota = FindConVar("sm_navbot_quota_target");
	char title[64];
	Format(title, sizeof(title), "Bots (quota %d)", quota ? quota.IntValue : -1);
	m.SetTitle(title);
	m.AddItem("q+", "Quota +2");
	m.AddItem("q-", "Quota -2");
	m.AddItem("skill0", "Skill: easy");
	m.AddItem("skill1", "Skill: normal");
	m.AddItem("skill2", "Skill: hard");
	m.AddItem("skill3", "Skill: expert");
	m.AddItem("kickall", "Kick all bots");
	m.ExitBackButton = true;
	m.Display(client, MENU_TIME_FOREVER);
}

int Menu_Bots(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End) { delete menu; return 0; }
	if (action == MenuAction_Cancel && item == MenuCancel_ExitBack) { ShowMainMenu(client); return 0; }
	if (action != MenuAction_Select) return 0;

	char info[32];
	menu.GetItem(item, info, sizeof(info));
	ConVar quota = FindConVar("sm_navbot_quota_target");
	if (StrEqual(info, "q+") && quota)       quota.IntValue = quota.IntValue + 2;
	else if (StrEqual(info, "q-") && quota)  quota.IntValue = quota.IntValue > 2 ? quota.IntValue - 2 : 0;
	else if (StrContains(info, "skill") == 0) ServerCommand("sm_navbot_skill_level %s", info[5]);
	else if (StrEqual(info, "kickall"))
	{
		if (quota) quota.IntValue = 0;
		for (int i = 1; i <= MaxClients; i++)
			if (IsClientInGame(i) && IsFakeClient(i))
				KickClient(i, "Kicked by admin");
	}
	ShowBotMenu(client);
	return 0;
}

void ShowMapMenu(int client)
{
	Menu m = new Menu(Menu_Map);
	m.SetTitle("Change map");
	for (int i = 0; i < sizeof(g_maps); i++)
		if (IsMapValid(g_maps[i]))
			m.AddItem(g_maps[i], g_maps[i]);
	m.ExitBackButton = true;
	m.Display(client, MENU_TIME_FOREVER);
}

int Menu_Map(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End) { delete menu; return 0; }
	if (action == MenuAction_Cancel && item == MenuCancel_ExitBack) { ShowMainMenu(client); return 0; }
	if (action != MenuAction_Select) return 0;

	char map[64];
	menu.GetItem(item, map, sizeof(map));
	PrintToChatAll("[ZPS] Changing map to %s", map);
	ForceChangeLevel(map, "Admin menu");
	return 0;
}

void ShowMeMenu(int client)
{
	Menu m = new Menu(Menu_Me);
	m.SetTitle("Me");
	m.AddItem("noclip", "Toggle noclip");
	m.AddItem("god", "Toggle god mode");
	m.AddItem("weapon_ak47", "Give AK47");
	m.AddItem("weapon_870", "Give Remington 870");
	m.AddItem("weapon_revolver", "Give revolver");
	m.AddItem("weapon_barricade", "Give barricade");
	m.AddItem("ammo", "Refill ammo");
	m.ExitBackButton = true;
	m.Display(client, MENU_TIME_FOREVER);
}

int Menu_Me(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End) { delete menu; return 0; }
	if (action == MenuAction_Cancel && item == MenuCancel_ExitBack) { ShowMainMenu(client); return 0; }
	if (action != MenuAction_Select || !IsPlayerAlive(client)) return 0;

	char info[32];
	menu.GetItem(item, info, sizeof(info));
	if (StrEqual(info, "noclip"))
	{
		bool on = GetEntityMoveType(client) == MOVETYPE_NOCLIP;
		SetEntityMoveType(client, on ? MOVETYPE_WALK : MOVETYPE_NOCLIP);
		PrintToChat(client, "[ZPS] Noclip %s", on ? "off" : "on");
	}
	else if (StrEqual(info, "god"))
	{
		bool on = GetEntProp(client, Prop_Data, "m_takedamage") == 0;
		SetEntProp(client, Prop_Data, "m_takedamage", on ? 2 : 0, 1);
		PrintToChat(client, "[ZPS] God mode %s", on ? "off" : "on");
	}
	else if (StrEqual(info, "ammo"))
	{
		for (int t = 1; t <= 4; t++)
			SetEntProp(client, Prop_Send, "m_iAmmo", 200, _, t);
		SetEntProp(client, Prop_Send, "m_iAmmo", 20, _, 7);   // barricade boards
	}
	else
	{
		GivePlayerItem(client, info);
	}
	ShowMeMenu(client);
	return 0;
}

// ---------------------------------------------------------------------------------------------
// Spawn menu: put ammo, items, weapons or furniture where the admin is aiming

static const char g_spawnAmmo[][][] = {
	{ "item_ammo_pistol",       "Pistol ammo" },
	{ "item_ammo_pistol_large", "Pistol ammo (large)" },
	{ "item_ammo_357",          "Magnum ammo" },
	{ "item_ammo_357_large",    "Magnum ammo (large)" },
	{ "item_box_buckshot",      "Shotgun shells" },
	{ "item_ammo_smg1",         "Rifle ammo" },
	{ "item_ammo_smg1_large",   "Rifle ammo (large)" },
	{ "item_healthkit",         "Health kit" },
	{ "item_healthvial",        "Health vial" }
};

static const char g_spawnWeapons[][][] = {
	{ "weapon_ak47", "AK47" }, { "weapon_m4", "M4" }, { "weapon_mp5", "MP5" }, { "weapon_870", "Remington 870" },
	{ "weapon_supershorty", "Super Shorty" }, { "weapon_winchester", "Winchester" }, { "weapon_revolver", "Revolver" },
	{ "weapon_glock18c", "Glock 18c" }, { "weapon_glock", "Glock" }, { "weapon_usp", "USP" }, { "weapon_ppk", "PPK" },
	{ "weapon_barricade", "Barricade hammer" }, { "weapon_frag", "Grenade" }, { "weapon_ied", "IED" },
	{ "weapon_axe", "Axe" }, { "weapon_machete", "Machete" }, { "weapon_sledgehammer", "Sledgehammer" },
	{ "weapon_crowbar", "Crowbar" }, { "weapon_bat_aluminum", "Aluminium bat" }, { "weapon_shovel", "Shovel" },
	{ "weapon_plank", "Plank" }, { "weapon_pipe", "Pipe" }, { "weapon_golf", "Golf club" }, { "weapon_fryingpan", "Frying pan" }
};

// Physics props that 2.4 maps ship with (so both the server and clients have them).
static const char g_spawnProps[][][] = {
	{ "models/props_junk/wood_crate001a.mdl",                  "Wooden crate" },
	{ "models/props_junk/wood_crate002a.mdl",                  "Big wooden crate" },
	{ "models/props_c17/oildrum001.mdl",                       "Oil drum" },
	{ "models/props_c17/oildrum001_explosive.mdl",             "Explosive barrel" },
	{ "models/props_c17/lockers001a.mdl",                      "Lockers" },
	{ "models/props_wasteland/controlroom_storagecloset001a.mdl", "Metal closet" },
	{ "models/props_wasteland/controlroom_filecabinet002a.mdl", "Filing cabinet" },
	{ "models/props_interiors/furniture_shelf01a.mdl",         "Shelf" },
	{ "models/props_wasteland/kitchen_shelf001a.mdl",          "Kitchen shelf" },
	{ "models/props_wasteland/controlroom_desk001a.mdl",       "Desk" },
	{ "models/props_wasteland/cafeteria_table001a.mdl",        "Table" },
	{ "models/props_c17/furnituredrawer001a.mdl",              "Drawer" },
	{ "models/props_c17/furniturecouch001a.mdl",               "Couch" },
	{ "models/props_c17/furniturebed001a.mdl",                 "Bed" },
	{ "models/props_c17/furnituremattress001a.mdl",            "Mattress" },
	{ "models/props_c17/furniturechair001a.mdl",               "Chair" },
	{ "models/props_interiors/vendingmachinesoda01a.mdl",      "Vending machine" },
	{ "models/props_junk/trashdumpster01a.mdl",                "Dumpster" },
	{ "models/props_junk/pushcart01a.mdl",                     "Push cart" },
	{ "models/props_wasteland/barricade001a.mdl",              "Road barricade" },
	{ "models/props_junk/wood_pallet001a.mdl",                 "Pallet" },
	{ "models/props_debris/metal_panel02a.mdl",                "Metal panel" },
	{ "models/props_wasteland/dockplank01b.mdl",               "Plank" },
	{ "models/props_junk/trafficcone001a.mdl",                 "Traffic cone" },
	{ "models/props_junk/gascan001a.mdl",                      "Gas can" }
};

int g_spawnPage[MAXPLAYERS + 1];   // 0 ammo/health, 1 weapons, 2 objects

void ShowSpawnMenu(int client)
{
	Menu m = new Menu(Menu_Spawn);
	m.SetTitle("Spawn (at your crosshair)");
	m.AddItem("ammo", "Ammo and health");
	m.AddItem("weapons", "Weapons");
	m.AddItem("props", "Objects / furniture");
	m.AddItem("delete", "Delete what I'm aiming at");
	m.ExitBackButton = true;
	m.Display(client, MENU_TIME_FOREVER);
}

int Menu_Spawn(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End) { delete menu; return 0; }
	if (action == MenuAction_Cancel && item == MenuCancel_ExitBack) { ShowMainMenu(client); return 0; }
	if (action != MenuAction_Select) return 0;
	char info[16];
	menu.GetItem(item, info, sizeof(info));
	if (StrEqual(info, "ammo"))         ShowSpawnList(client, 0);
	else if (StrEqual(info, "weapons")) ShowSpawnList(client, 1);
	else if (StrEqual(info, "props"))   ShowSpawnList(client, 2);
	else if (StrEqual(info, "delete"))  { DeleteAimed(client); ShowSpawnMenu(client); }
	return 0;
}

void ShowSpawnList(int client, int page, int first = 0)
{
	g_spawnPage[client] = page;
	Menu m = new Menu(Menu_SpawnList);
	m.SetTitle(page == 0 ? "Spawn ammo / health" : (page == 1 ? "Spawn weapon" : "Spawn object"));
	char idx[8];
	int count = page == 0 ? sizeof(g_spawnAmmo) : (page == 1 ? sizeof(g_spawnWeapons) : sizeof(g_spawnProps));
	for (int i = 0; i < count; i++)
	{
		IntToString(i, idx, sizeof(idx));
		m.AddItem(idx, page == 0 ? g_spawnAmmo[i][1] : (page == 1 ? g_spawnWeapons[i][1] : g_spawnProps[i][1]));
	}
	m.ExitBackButton = true;
	m.DisplayAt(client, first, MENU_TIME_FOREVER);   // reopen on the same page so you can spawn several
}

int Menu_SpawnList(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End) { delete menu; return 0; }
	if (action == MenuAction_Cancel && item == MenuCancel_ExitBack) { ShowSpawnMenu(client); return 0; }
	if (action != MenuAction_Select) return 0;
	char idx[8];
	menu.GetItem(item, idx, sizeof(idx));
	int i = StringToInt(idx);
	int page = g_spawnPage[client];
	if (page == 0)      SpawnAtAim(client, g_spawnAmmo[i][0], "");
	else if (page == 1) SpawnAtAim(client, g_spawnWeapons[i][0], "");
	else                SpawnAtAim(client, "prop_physics_multiplayer", g_spawnProps[i][0]);
	ShowSpawnList(client, page, menu.Selection);
	return 0;
}

bool TraceNotSelf(int entity, int mask, int self)
{
	return entity != self;
}

bool AimPoint(int client, float pos[3], float normal[3], int &hitEnt)
{
	float eye[3], ang[3];
	GetClientEyePosition(client, eye);
	GetClientEyeAngles(client, ang);
	TR_TraceRayFilter(eye, ang, MASK_SOLID, RayType_Infinite, TraceNotSelf, client);
	if (!TR_DidHit())
		return false;
	TR_GetEndPosition(pos);
	TR_GetPlaneNormal(null, normal);
	hitEnt = TR_GetEntityIndex();
	return GetVectorDistance(eye, pos) < 3000.0;
}

void SpawnAtAim(int client, const char[] classname, const char[] model)
{
	float pos[3], normal[3];
	int hit;
	if (!AimPoint(client, pos, normal, hit))
	{
		PrintToChat(client, "[ZPS] Aim at a spot closer to you");
		return;
	}
	int ent = CreateEntityByName(classname);
	if (ent == -1)
	{
		PrintToChat(client, "[ZPS] Can't create %s", classname);
		return;
	}
	float lift = 10.0;
	if (model[0] != '\0')
	{
		PrecacheModel(model, true);
		DispatchKeyValue(ent, "model", model);
		lift = 40.0;   // furniture: drop it from a little above the floor so it doesn't spawn stuck
	}
	DispatchSpawn(ent);
	// Off the surface we aimed at, then a little up; face the player.
	for (int k = 0; k < 3; k++)
		pos[k] += normal[k] * 16.0;
	pos[2] += lift;
	float ang[3], eyeAng[3];
	GetClientEyeAngles(client, eyeAng);
	ang[1] = eyeAng[1] + 180.0;
	TeleportEntity(ent, pos, ang, NULL_VECTOR);
}

void DeleteAimed(int client)
{
	float pos[3], normal[3];
	int hit;
	if (!AimPoint(client, pos, normal, hit) || hit <= MaxClients || !IsValidEntity(hit))
	{
		PrintToChat(client, "[ZPS] Not aiming at an object");
		return;
	}
	char cls[64];
	GetEntityClassname(hit, cls, sizeof(cls));
	bool deletable = StrContains(cls, "prop_") == 0 || StrContains(cls, "item_") == 0
		|| (StrContains(cls, "weapon_") == 0 && GetEntPropEnt(hit, Prop_Send, "m_hOwnerEntity") == -1);
	if (!deletable)
	{
		PrintToChat(client, "[ZPS] %s can't be deleted from here", cls);
		return;
	}
	AcceptEntityInput(hit, "Kill");
	PrintToChat(client, "[ZPS] Deleted %s", cls);
}
