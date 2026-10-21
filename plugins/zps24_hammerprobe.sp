// Logs the barricade hammer's state tick by tick for everyone holding it (players and bots), one
// line whenever something changes, to logs/hammerprobe.log. Read-only: it changes nothing in the
// game. Compare a teacher's working click with a builder's failing one (manual 11.26).
//   sm_hammerprobe 0/1    turn the log off/on (default on)
#include <sourcemod>
#include <sdktools>

public Plugin myinfo =
{
	name = "ZPS 2.4 hammer probe",
	author = "Dead Apocalypse",
	description = "Log the barricade hammer's state for builder debugging",
	version = "1.0"
};

char g_last[MAXPLAYERS + 1][256];
char g_path[PLATFORM_MAX_PATH];
bool g_on = true;

public void OnPluginStart()
{
	BuildPath(Path_SM, g_path, sizeof(g_path), "logs/hammerprobe.log");
	RegServerCmd("sm_hammerprobe", Cmd_Probe, "sm_hammerprobe 0/1: log the hammer's state");
}

Action Cmd_Probe(int args)
{
	char s[8];
	GetCmdArg(1, s, sizeof(s));
	g_on = StringToInt(s) != 0;
	PrintToServer("[hammerprobe] %s, log: %s", g_on ? "on" : "off", g_path);
	return Plugin_Handled;
}

int PropOr(int ent, const char[] name, int def = -1)
{
	return HasEntProp(ent, Prop_Send, name) ? GetEntProp(ent, Prop_Send, name) : def;
}

public void OnPlayerRunCmdPost(int client, int buttons, int impulse, const float vel[3], const float angles[3], int weapon)
{
	if (!g_on || !IsClientInGame(client) || !IsPlayerAlive(client))
		return;
	int w = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	char cls[64];
	if (w <= 0 || !IsValidEntity(w) || !GetEntityClassname(w, cls, sizeof(cls)) || !StrEqual(cls, "weapon_barricade"))
	{
		g_last[client][0] = '\0';
		return;
	}
	char bytes[64];
	for (int o = 1700; o <= 1708; o++)
		Format(bytes, sizeof(bytes), "%s%d ", bytes, GetEntData(w, o, 1));
	char line[256];
	Format(line, sizeof(line), "atk %d att2 %d use %d | attach %d canattach %d | clip %d ammo7 %d | next %.2f idle %.2f | seq %d | %s",
		(buttons & IN_ATTACK) != 0, (buttons & IN_ATTACK2) != 0, (buttons & IN_USE) != 0,
		PropOr(w, "m_bAttachBarricade"), PropOr(w, "m_bCanAttachBoard"),
		GetEntProp(w, Prop_Send, "m_iClip1"), GetEntProp(client, Prop_Send, "m_iAmmo", _, 7),
		GetEntPropFloat(w, Prop_Send, "m_flNextPrimaryAttack") - GetGameTime(),
		HasEntProp(w, Prop_Send, "m_flTimeWeaponIdle") ? GetEntPropFloat(w, Prop_Send, "m_flTimeWeaponIdle") - GetGameTime() : 0.0,
		PropOr(w, "m_nSequence"), bytes);
	// The two timers count down every tick; compare without them.
	char key[256];
	strcopy(key, sizeof(key), line);
	int cut = StrContains(key, " | next");
	int seq = StrContains(key, " | seq");
	if (cut != -1 && seq != -1)
	{
		char a[128];
		strcopy(a, cut + 1, line);
		Format(key, sizeof(key), "%s%s", a, line[seq]);
	}
	if (StrEqual(key, g_last[client]))
		return;
	strcopy(g_last[client], sizeof(g_last[]), key);
	LogToFileEx(g_path, "%.3f %N%s: %s", GetGameTime(), client, IsFakeClient(client) ? " (bot)" : "", line);
}
