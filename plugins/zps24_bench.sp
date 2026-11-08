// zps24_bench: "sm_cexec_humans <command>" runs a console command on every human client
// (used to record client demos for the engine-comparison benchmark).
#include <sourcemod>

public Plugin myinfo = { name = "zps24_bench", author = "Diogenes", description = "Benchmark helper", version = "1.0" };

public void OnPluginStart()
{
	RegAdminCmd("sm_cexec_humans", Cmd_Exec, ADMFLAG_RCON, "sm_cexec_humans <command>");
}

Action Cmd_Exec(int client, int args)
{
	char cmd[256];
	GetCmdArgString(cmd, sizeof(cmd));
	StripQuotes(cmd);
	int n = 0;
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && !IsFakeClient(i) && !IsClientSourceTV(i))
		{
			ClientCommand(i, "%s", cmd);
			n++;
		}
	ReplyToCommand(client, "sent to %d client(s): %s", n, cmd);
	return Plugin_Handled;
}
