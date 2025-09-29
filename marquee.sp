#pragma newdecls required
#pragma semicolon 1

#include <sourcemod>

#define LINE_WIDTH 30
#define LINE_EMPTY "▁"
#define LINE_FILLED "█"

StringMap g_hAlphabet;
StringMap g_hCharLength;

char g_sText[MAXPLAYERS + 1][512];
int g_iPosition[MAXPLAYERS + 1] = {-1, ...};
int g_iMessageLength[MAXPLAYERS + 1] = {-1, ...};
Handle g_hWriteMarquee[MAXPLAYERS + 1] = {INVALID_HANDLE, ...};

public Plugin myinfo =
{
    name = "Marquee",
    author = "Original by Jannik \"Peace-Maker\" Hartung, Update/Rewrite by Koen",
    description = "Run text through the menu panel",
    version = "1.0.1",
    url = "https://github.com/notkoen"
};

public void OnPluginStart()
{
    LoadTranslations("common.phrases");

    g_hAlphabet = new StringMap();
    g_hCharLength = new StringMap();
    PopulateAlphabet();

    RegAdminCmd("sm_marquee", Cmd_Marquee, ADMFLAG_ROOT, "Sends a marquee text panel to the target. Usage: sm_marquee <#userid|steamid|name> TEXT");
}

public void OnPluginEnd()
{
    delete g_hAlphabet;
    delete g_hCharLength;
}

public void OnClientDisconnect(int client)
{
    Marquee_Stop(client);
}

public Action Cmd_Marquee(int client, int args)
{
    if (GetCmdArgs() < 2)
    {
        ReplyToCommand(client, "[Marquee] Usage: sm_marquee <#userid|steamid|name> TEXT");
        return Plugin_Handled;
    }

    char sBuffer[512];
    GetCmdArg(1, sBuffer, sizeof(sBuffer));

    char target_name[MAX_TARGET_LENGTH];
    int target_list[MAXPLAYERS], target_count;
    bool tn_is_ml;

    if ((target_count = ProcessTargetString(
            sBuffer,
            client,
            target_list,
            MAXPLAYERS,
            COMMAND_FILTER_CONNECTED,
            target_name,
            sizeof(target_name),
            tn_is_ml)) <= 0)
    {
        /* This function replies to the admin with a failure message */
        ReplyToTargetError(client, target_count);
        return Plugin_Handled;
    }

    GetCmdArg(2, sBuffer, sizeof(sBuffer));

    Marquee_Start(target_list, target_count, sBuffer, true);

    if (tn_is_ml)
        LogAction(client, -1, "%L triggered sm_marquee for %T (text %s)", client, target_name, LANG_SERVER, sBuffer);
    else
        LogAction(client, -1, "%L triggered sm_marquee for %s (text %s)", client, target_name, sBuffer);

    return Plugin_Handled;
}

stock void Marquee_Start(int[] clients, int numClients, const char[] sBuffer, bool bIntercept = true)
{
    // Put the message uppercase
    char sMessage[512], sChar[6];
    int iMessageLength = 0, iCharLength, iBytes;

    for (int i = 0; i < strlen(sBuffer); i++)
    {
        iBytes = GetCharBytes(sBuffer[i]);

        // Get one char at the current position. utf-8 save
        for (int c = 0; c < iBytes; c++)
        {
            sChar[c] = sBuffer[i + c];
            if (iBytes == 1)
                sChar[c + 1] = 0;
        }

        Format(sMessage, sizeof(sMessage), "%s%s", sMessage, sChar);

        if (iBytes == 1)
        {
            sMessage[i] = CharToUpper(sMessage[i]);
            sChar[0] = CharToUpper(sChar[0]);
        }

        // The trie doesn't seem to like umlauts
        ReplaceString(sMessage, sizeof(sMessage), "ä", "Ä", false);
        ReplaceString(sMessage, sizeof(sMessage), "ö", "Ö", false);
        ReplaceString(sMessage, sizeof(sMessage), "ü", "Ü", false);
        ReplaceString(sChar, sizeof(sChar), "ä", "Ä", false);
        ReplaceString(sChar, sizeof(sChar), "ö", "Ö", false);
        ReplaceString(sChar, sizeof(sChar), "ü", "Ü", false);

        // This char isn't in our alphabet.
        if (!g_hCharLength.GetValue(sChar, iCharLength))
        {
            ReplaceString(sMessage, sizeof(sMessage), sChar, " ", false);
            g_hCharLength.GetValue(sChar, iCharLength);
        }

        iMessageLength += iCharLength;

        // Skip the other rubbish bytes
        if (IsCharMB(sBuffer[i]))
            i += iBytes - 1;
    }

    // Create a panel and put the default size of "empty" characters in it
    Panel hPanel = new Panel();
    char sEmptyPanel[256];
    for (int i = 0; i <= LINE_WIDTH; i++)
        Format(sEmptyPanel, sizeof(sEmptyPanel), "%s%s", sEmptyPanel, LINE_EMPTY);

    for (int i = 0; i <= 4; i++)
        hPanel.DrawText(sEmptyPanel);

    // Send the panel
    for (int i = 0; i < numClients; i++)
    {
        if (!bIntercept && Marquee_IsRunning(clients[i]))
            continue;

        if (g_hWriteMarquee[clients[i]] != INVALID_HANDLE)
        {
            KillTimer(g_hWriteMarquee[clients[i]]);
            g_hWriteMarquee[clients[i]] = INVALID_HANDLE;
        }

        g_iPosition[clients[i]] = 0;
        g_iMessageLength[clients[i]] = iMessageLength;
        Format(g_sText[clients[i]], sizeof(g_sText[]), "%s", sMessage);

        g_hWriteMarquee[clients[i]] = CreateTimer(0.1, Timer_DrawMarquee, GetClientUserId(clients[i]), TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
        hPanel.Send(clients[i], Panel_DoNothing, 1);
    }

    delete hPanel;

    return;
}

stock void Marquee_Stop(int client)
{
	if (!(1 <= client <= MaxClients) || !IsClientInGame(client) || IsFakeClient(client))
        return;

    if (g_hWriteMarquee[client] != INVALID_HANDLE)
    {
        KillTimer(g_hWriteMarquee[client]);
        g_hWriteMarquee[client] = INVALID_HANDLE;
    }

    g_iPosition[client] = -1;
    g_iMessageLength[client] = -1;
    Format(g_sText[client], sizeof(g_sText[]), "");
}

stock bool Marquee_IsRunning(int client)
{
	if (!(1 <= client <= MaxClients) || !IsClientInGame(client) || IsFakeClient(client))
        return false;

    return (g_iPosition[client] != -1);
}

public Action Timer_DrawMarquee(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (!client)
        return Plugin_Stop;

    char sLine1[15], sLine2[15], sLine3[15], sLine4[15], sLine5[15];
    char sTotalLine1[256], sTotalLine2[256], sTotalLine3[256], sTotalLine4[256], sTotalLine5[256];

    Panel hPanel = new Panel();

    // Fill with whitespace before
    if (g_iPosition[client] < LINE_WIDTH)
    {
        for (int i = 0; i <= LINE_WIDTH - g_iPosition[client]; i++)
        {
            Format(sTotalLine1, sizeof(sTotalLine1), "%s%s", sTotalLine1, LINE_EMPTY);
            Format(sTotalLine2, sizeof(sTotalLine2), "%s%s", sTotalLine2, LINE_EMPTY);
            Format(sTotalLine3, sizeof(sTotalLine3), "%s%s", sTotalLine3, LINE_EMPTY);
            Format(sTotalLine4, sizeof(sTotalLine4), "%s%s", sTotalLine4, LINE_EMPTY);
            Format(sTotalLine5, sizeof(sTotalLine5), "%s%s", sTotalLine5, LINE_EMPTY);
        }
    }

    // Check which char to start to display and which to stop
    char sChar[3];
    int iCharLength, iMessageLength;
    int iStartChar = -1, iBytes;
    Handle hLine;

    for (int i = 0; i < strlen(g_sText[client]); i++)
    {
        iBytes = GetCharBytes(g_sText[client][i]);
        for (int c = 0; c < iBytes; c++)
        {
            sChar[c] = g_sText[client][i+c];
            if (iBytes == 1)
                sChar[c + 1] = 0;
        }

        g_hCharLength.GetValue(sChar, iCharLength);
        iMessageLength += iCharLength;

        // This is the first char to display
        if (iStartChar == -1 && iMessageLength+LINE_WIDTH >= g_iPosition[client])
        {
            // Save the current position
            iStartChar = iMessageLength-iCharLength;

            // Get the l33t font of the current char
            g_hAlphabet.GetValue(sChar, hLine);
            GetArrayString(hLine, 0, sLine1, sizeof(sLine1));
            GetArrayString(hLine, 1, sLine2, sizeof(sLine2));
            GetArrayString(hLine, 2, sLine3, sizeof(sLine3));
            GetArrayString(hLine, 3, sLine4, sizeof(sLine4));
            GetArrayString(hLine, 4, sLine5, sizeof(sLine5));

            // How many chars to show?
            // Left side?
            // Start hiding the char, if it's moving out of the screen on the left side
            if (g_iPosition[client] > LINE_WIDTH)
            {
                Format(sTotalLine1, sizeof(sTotalLine1), "%s", sLine1[iCharLength - iMessageLength - LINE_WIDTH + g_iPosition[client] - 1]);
                Format(sTotalLine2, sizeof(sTotalLine2), "%s", sLine2[iCharLength - iMessageLength - LINE_WIDTH + g_iPosition[client] - 1]);
                Format(sTotalLine3, sizeof(sTotalLine3), "%s", sLine3[iCharLength - iMessageLength - LINE_WIDTH + g_iPosition[client] - 1]);
                Format(sTotalLine4, sizeof(sTotalLine4), "%s", sLine4[iCharLength - iMessageLength - LINE_WIDTH + g_iPosition[client] - 1]);
                Format(sTotalLine5, sizeof(sTotalLine5), "%s", sLine5[iCharLength - iMessageLength - LINE_WIDTH + g_iPosition[client] - 1]);
            }
            // First time showing this one
            // Start showing part of the char, when moving in from the right
            else if (g_iPosition[client] < iMessageLength)
            {
                sLine1[iMessageLength - iCharLength + g_iPosition[client]] = 0;
                sLine2[iMessageLength - iCharLength + g_iPosition[client]] = 0;
                sLine3[iMessageLength - iCharLength + g_iPosition[client]] = 0;
                sLine4[iMessageLength - iCharLength + g_iPosition[client]] = 0;
                sLine5[iMessageLength - iCharLength + g_iPosition[client]] = 0;
                Format(sTotalLine1, sizeof(sTotalLine1), "%s%s", sTotalLine1, sLine1);
                Format(sTotalLine2, sizeof(sTotalLine2), "%s%s", sTotalLine2, sLine2);
                Format(sTotalLine3, sizeof(sTotalLine3), "%s%s", sTotalLine3, sLine3);
                Format(sTotalLine4, sizeof(sTotalLine4), "%s%s", sTotalLine4, sLine4);
                Format(sTotalLine5, sizeof(sTotalLine5), "%s%s", sTotalLine5, sLine5);
            }
            // Just show it completely
            // This happens during the starting, where the first char hasn't reached the right side yet, so he's just fully there.
            else
            {
                Format(sTotalLine1, sizeof(sTotalLine1), "%s%s", sTotalLine1, sLine1);
                Format(sTotalLine2, sizeof(sTotalLine2), "%s%s", sTotalLine2, sLine2);
                Format(sTotalLine3, sizeof(sTotalLine3), "%s%s", sTotalLine3, sLine3);
                Format(sTotalLine4, sizeof(sTotalLine4), "%s%s", sTotalLine4, sLine4);
                Format(sTotalLine5, sizeof(sTotalLine5), "%s%s", sTotalLine5, sLine5);
            }
        }
        // We already reached and handled the first char to draw. Handle the rest now
        else if (iStartChar != -1)
        {
            // Get the l33t font of the current char
            g_hAlphabet.GetValue(sChar, hLine);
            GetArrayString(hLine, 0, sLine1, sizeof(sLine1));
            GetArrayString(hLine, 1, sLine2, sizeof(sLine2));
            GetArrayString(hLine, 2, sLine3, sizeof(sLine3));
            GetArrayString(hLine, 3, sLine4, sizeof(sLine4));
            GetArrayString(hLine, 4, sLine5, sizeof(sLine5));

            // This char isn't fully visible yet.
            // It's currently comming from the right
            if (g_iPosition[client] < iMessageLength)
            {
                sLine1[g_iPosition[client] - iMessageLength + iCharLength] = 0;
                sLine2[g_iPosition[client] - iMessageLength + iCharLength] = 0;
                sLine3[g_iPosition[client] - iMessageLength + iCharLength] = 0;
                sLine4[g_iPosition[client] - iMessageLength + iCharLength] = 0;
                sLine5[g_iPosition[client] - iMessageLength + iCharLength] = 0;

                Format(sTotalLine1, sizeof(sTotalLine1), "%s%s", sTotalLine1, sLine1);
                Format(sTotalLine2, sizeof(sTotalLine2), "%s%s", sTotalLine2, sLine2);
                Format(sTotalLine3, sizeof(sTotalLine3), "%s%s", sTotalLine3, sLine3);
                Format(sTotalLine4, sizeof(sTotalLine4), "%s%s", sTotalLine4, sLine4);
                Format(sTotalLine5, sizeof(sTotalLine5), "%s%s", sTotalLine5, sLine5);
            }
            // This is only a fully visible char somewhere in the message.
            else
            {
                Format(sTotalLine1, sizeof(sTotalLine1), "%s%s", sTotalLine1, sLine1);
                Format(sTotalLine2, sizeof(sTotalLine2), "%s%s", sTotalLine2, sLine2);
                Format(sTotalLine3, sizeof(sTotalLine3), "%s%s", sTotalLine3, sLine3);
                Format(sTotalLine4, sizeof(sTotalLine4), "%s%s", sTotalLine4, sLine4);
                Format(sTotalLine5, sizeof(sTotalLine5), "%s%s", sTotalLine5, sLine5);
            }
        }

        if (iStartChar != -1 && iMessageLength >= g_iPosition[client])
            break;

        if (IsCharMB(g_sText[client][i]))
            i += iBytes-1;
    }

    // Add whitespace to the end of the message to keep the LINE_WIDTH
    if (g_iPosition[client] > g_iMessageLength[client])
    {
        int iLimit;
        // Reduce the filled space, when the message has disappeared!
        if (g_iPosition[client] < g_iMessageLength[client]+LINE_WIDTH)
            iLimit = g_iPosition[client]-g_iMessageLength[client];
        else
            iLimit = g_iMessageLength[client]+LINE_WIDTH*2-g_iPosition[client];

        for (int i = 0; i <= iLimit; i++)
        {
            Format(sTotalLine1, sizeof(sTotalLine1), "%s%s", sTotalLine1, LINE_EMPTY);
            Format(sTotalLine2, sizeof(sTotalLine2), "%s%s", sTotalLine2, LINE_EMPTY);
            Format(sTotalLine3, sizeof(sTotalLine3), "%s%s", sTotalLine3, LINE_EMPTY);
            Format(sTotalLine4, sizeof(sTotalLine4), "%s%s", sTotalLine4, LINE_EMPTY);
            Format(sTotalLine5, sizeof(sTotalLine5), "%s%s", sTotalLine5, LINE_EMPTY);
        }
    }

    // Replace the readable characters with the full width utf-8 ones
    ReplaceString(sTotalLine1, sizeof(sTotalLine1), "=", LINE_FILLED, false);
    ReplaceString(sTotalLine2, sizeof(sTotalLine2), "=", LINE_FILLED, false);
    ReplaceString(sTotalLine3, sizeof(sTotalLine3), "=", LINE_FILLED, false);
    ReplaceString(sTotalLine4, sizeof(sTotalLine4), "=", LINE_FILLED, false);
    ReplaceString(sTotalLine5, sizeof(sTotalLine5), "=", LINE_FILLED, false);
    ReplaceString(sTotalLine1, sizeof(sTotalLine1), "0", LINE_EMPTY, false);
    ReplaceString(sTotalLine2, sizeof(sTotalLine2), "0", LINE_EMPTY, false);
    ReplaceString(sTotalLine3, sizeof(sTotalLine3), "0", LINE_EMPTY, false);
    ReplaceString(sTotalLine4, sizeof(sTotalLine4), "0", LINE_EMPTY, false);
    ReplaceString(sTotalLine5, sizeof(sTotalLine5), "0", LINE_EMPTY, false);

    hPanel.DrawText(sTotalLine1);
    hPanel.DrawText(sTotalLine2);
    hPanel.DrawText(sTotalLine3);
    hPanel.DrawText(sTotalLine4);
    hPanel.DrawText(sTotalLine5);

    hPanel.Send(client, Panel_DoNothing, 1);
    delete hPanel;

    // Move to the next column
    g_iPosition[client]++;

    // We're done here, stop the timer etc
    if (g_iPosition[client] > g_iMessageLength[client] + LINE_WIDTH * 2 + 1)
    {
        Marquee_Stop(client);
        return Plugin_Stop;
    }

    return Plugin_Continue;
}

public int Panel_DoNothing(Menu menu, MenuAction action, int param1, int param2)
{
    return 0;
}

stock void PopulateAlphabet()
{
    ArrayList hLines = new ArrayList();

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "00==0");
    PushArrayString(hLines, "0=0=0");
    PushArrayString(hLines, "0===0");
    PushArrayString(hLines, "0=0=0");
    PushArrayString(hLines, "0=0=0");
    g_hAlphabet.SetValue("A", hLines);
    g_hCharLength.SetValue("A", 5);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0==000");
    PushArrayString(hLines, "0=0=00");
    PushArrayString(hLines, "0====0");
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "0===00");
    g_hAlphabet.SetValue("B", hLines);
    g_hCharLength.SetValue("B", 6);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0===0");
    PushArrayString(hLines, "0=000");
    PushArrayString(hLines, "0=000");
    PushArrayString(hLines, "0=000");
    PushArrayString(hLines, "0===0");
    g_hAlphabet.SetValue("C", hLines);
    g_hCharLength.SetValue("C", 5);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0===00");
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "0===00");
    g_hAlphabet.SetValue("D", hLines);
    g_hCharLength.SetValue("D", 6);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0===0");
    PushArrayString(hLines, "0=000");
    PushArrayString(hLines, "0===0");
    PushArrayString(hLines, "0=000");
    PushArrayString(hLines, "0===0");
    g_hAlphabet.SetValue("E", hLines);
    g_hCharLength.SetValue("E", 5);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0===0");
    PushArrayString(hLines, "0=000");
    PushArrayString(hLines, "0==00");
    PushArrayString(hLines, "0=000");
    PushArrayString(hLines, "0=000");
    g_hAlphabet.SetValue("F", hLines);
    g_hCharLength.SetValue("F", 5);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "00==00");
    PushArrayString(hLines, "0=0000");
    PushArrayString(hLines, "0=0==0");
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "00==00");
    g_hAlphabet.SetValue("G", hLines);
    g_hCharLength.SetValue("G", 6);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "0====0");
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "0=00=0");
    g_hAlphabet.SetValue("H", hLines);
    g_hCharLength.SetValue("H", 6);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0===0");
    PushArrayString(hLines, "00=00");
    PushArrayString(hLines, "00=00");
    PushArrayString(hLines, "00=00");
    PushArrayString(hLines, "0===0");
    g_hAlphabet.SetValue("I", hLines);
    g_hCharLength.SetValue("I", 5);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "00===0");
    PushArrayString(hLines, "000=00");
    PushArrayString(hLines, "000=00");
    PushArrayString(hLines, "0=0=00");
    PushArrayString(hLines, "00==00");
    g_hAlphabet.SetValue("J", hLines);
    g_hCharLength.SetValue("J", 6);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "0=0=00");
    PushArrayString(hLines, "0==000");
    PushArrayString(hLines, "0=0=00");
    PushArrayString(hLines, "0=00=0");
    g_hAlphabet.SetValue("K", hLines);
    g_hCharLength.SetValue("K", 6);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0=0000");
    PushArrayString(hLines, "0=0000");
    PushArrayString(hLines, "0=0000");
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "0====0");
    g_hAlphabet.SetValue("L", hLines);
    g_hCharLength.SetValue("L", 6);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0=000=0");
    PushArrayString(hLines, "0==0==0");
    PushArrayString(hLines, "0=0=0=0");
    PushArrayString(hLines, "0=000=0");
    PushArrayString(hLines, "0=000=0");
    g_hAlphabet.SetValue("M", hLines);
    g_hCharLength.SetValue("M", 7);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0=000=0");
    PushArrayString(hLines, "0==00=0");
    PushArrayString(hLines, "0=0=0=0");
    PushArrayString(hLines, "0=00==0");
    PushArrayString(hLines, "0=000=0");
    g_hAlphabet.SetValue("N", hLines);
    g_hCharLength.SetValue("N", 7);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "00==00");
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "00==00");
    g_hAlphabet.SetValue("O", hLines);
    g_hCharLength.SetValue("O", 6);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0===0");
    PushArrayString(hLines, "0=0=0");
    PushArrayString(hLines, "0===0");
    PushArrayString(hLines, "0=000");
    PushArrayString(hLines, "0=000");
    g_hAlphabet.SetValue("P", hLines);
    g_hCharLength.SetValue("P", 5);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "00==000");
    PushArrayString(hLines, "0=00=00");
    PushArrayString(hLines, "0=00=00");
    PushArrayString(hLines, "0=0==00");
    PushArrayString(hLines, "00====0");
    g_hAlphabet.SetValue("Q", hLines);
    g_hCharLength.SetValue("Q", 7);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0===00");
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "0===00");
    PushArrayString(hLines, "0=0=00");
    PushArrayString(hLines, "0=00=0");
    g_hAlphabet.SetValue("R", hLines);
    g_hCharLength.SetValue("R", 6);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "00==00");
    PushArrayString(hLines, "0=0000");
    PushArrayString(hLines, "0====0");
    PushArrayString(hLines, "0000=0");
    PushArrayString(hLines, "0===00");
    g_hAlphabet.SetValue("S", hLines);
    g_hCharLength.SetValue("S", 6);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0=====0");
    PushArrayString(hLines, "000=000");
    PushArrayString(hLines, "000=000");
    PushArrayString(hLines, "000=000");
    PushArrayString(hLines, "000=000");
    g_hAlphabet.SetValue("T", hLines);
    g_hCharLength.SetValue("T", 7);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "00===0");
    g_hAlphabet.SetValue("U", hLines);
    g_hCharLength.SetValue("U", 6);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0=000=0");
    PushArrayString(hLines, "0=000=0");
    PushArrayString(hLines, "0=000=0");
    PushArrayString(hLines, "00=0=00");
    PushArrayString(hLines, "000=000");
    g_hAlphabet.SetValue("V", hLines);
    g_hCharLength.SetValue("V", 7);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0=00000=0");
    PushArrayString(hLines, "0=00000=0");
    PushArrayString(hLines, "0=00000=0");
    PushArrayString(hLines, "00=0=0=00");
    PushArrayString(hLines, "000=0=000");
    g_hAlphabet.SetValue("W", hLines);
    g_hCharLength.SetValue("W", 9);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0=000=0");
    PushArrayString(hLines, "00=0=00");
    PushArrayString(hLines, "000=000");
    PushArrayString(hLines, "00=0=00");
    PushArrayString(hLines, "0=000=0");
    g_hAlphabet.SetValue("X", hLines);
    g_hCharLength.SetValue("X", 7);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "=000=0");
    PushArrayString(hLines, "=000=0");
    PushArrayString(hLines, "0=0=00");
    PushArrayString(hLines, "00=000");
    PushArrayString(hLines, "00=000");
    g_hAlphabet.SetValue("Y", hLines);
    g_hCharLength.SetValue("Y", 6);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0=====0");
    PushArrayString(hLines, "0000=00");
    PushArrayString(hLines, "000=000");
    PushArrayString(hLines, "00=0000");
    PushArrayString(hLines, "0=====0");
    g_hAlphabet.SetValue("Z", hLines);
    g_hCharLength.SetValue("Z", 7);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0=0=0");
    PushArrayString(hLines, "00=00");
    PushArrayString(hLines, "0=0=0");
    PushArrayString(hLines, "0===0");
    PushArrayString(hLines, "0=0=0");
    g_hAlphabet.SetValue("Ä", hLines);
    g_hCharLength.SetValue("Ä", 5);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "00==00");
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "00==00");
    g_hAlphabet.SetValue("Ö", hLines);
    g_hCharLength.SetValue("Ö", 6);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "000000");
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "00===0");
    g_hAlphabet.SetValue("Ü", hLines);
    g_hCharLength.SetValue("Ü", 6);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "00000");
    PushArrayString(hLines, "00000");
    PushArrayString(hLines, "0===0");
    PushArrayString(hLines, "00000");
    PushArrayString(hLines, "00000");
    g_hAlphabet.SetValue("-", hLines);
    g_hCharLength.SetValue("-", 5);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "00000");
    PushArrayString(hLines, "00=00");
    PushArrayString(hLines, "0===0");
    PushArrayString(hLines, "00=00");
    PushArrayString(hLines, "00000");
    g_hAlphabet.SetValue("+", hLines);
    g_hCharLength.SetValue("+", 5);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "000");
    PushArrayString(hLines, "0=0");
    PushArrayString(hLines, "000");
    PushArrayString(hLines, "0=0");
    PushArrayString(hLines, "000");
    g_hAlphabet.SetValue(":", hLines);
    g_hCharLength.SetValue(":", 3);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "000");
    PushArrayString(hLines, "0=0");
    PushArrayString(hLines, "000");
    PushArrayString(hLines, "0=0");
    PushArrayString(hLines, "0=0");
    g_hAlphabet.SetValue(";", hLines);
    g_hCharLength.SetValue(";", 3);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0=0");
    PushArrayString(hLines, "0=0");
    PushArrayString(hLines, "000");
    PushArrayString(hLines, "000");
    PushArrayString(hLines, "000");
    g_hAlphabet.SetValue("'", hLines);
    g_hCharLength.SetValue("'", 3);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0==0");
    PushArrayString(hLines, "0==0");
    PushArrayString(hLines, "0000");
    PushArrayString(hLines, "0000");
    PushArrayString(hLines, "0000");
    g_hAlphabet.SetValue("\"", hLines);
    g_hCharLength.SetValue("\"", 4);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "00=0");
    PushArrayString(hLines, "0=00");
    PushArrayString(hLines, "0=00");
    PushArrayString(hLines, "0=00");
    PushArrayString(hLines, "00=0");
    g_hAlphabet.SetValue("(", hLines);
    g_hCharLength.SetValue("(", 4);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0=00");
    PushArrayString(hLines, "00=0");
    PushArrayString(hLines, "00=0");
    PushArrayString(hLines, "00=0");
    PushArrayString(hLines, "0=00");
    g_hAlphabet.SetValue(")", hLines);
    g_hCharLength.SetValue(")", 4);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0==0");
    PushArrayString(hLines, "0=00");
    PushArrayString(hLines, "0=00");
    PushArrayString(hLines, "0=00");
    PushArrayString(hLines, "0==0");
    g_hAlphabet.SetValue("[", hLines);
    g_hCharLength.SetValue("[", 4);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0==0");
    PushArrayString(hLines, "00=0");
    PushArrayString(hLines, "00=0");
    PushArrayString(hLines, "00=0");
    PushArrayString(hLines, "0==0");
    g_hAlphabet.SetValue("]", hLines);
    g_hCharLength.SetValue("]", 4);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0==0");
    PushArrayString(hLines, "0=00");
    PushArrayString(hLines, "==00");
    PushArrayString(hLines, "0=00");
    PushArrayString(hLines, "0==0");
    g_hAlphabet.SetValue("{", hLines);
    g_hCharLength.SetValue("{", 4);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0==00");
    PushArrayString(hLines, "00=00");
    PushArrayString(hLines, "00==0");
    PushArrayString(hLines, "00=00");
    PushArrayString(hLines, "0==00");
    g_hAlphabet.SetValue("}", hLines);
    g_hCharLength.SetValue("}", 5);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "00000");
    PushArrayString(hLines, "0===0");
    PushArrayString(hLines, "00000");
    PushArrayString(hLines, "0===0");
    PushArrayString(hLines, "00000");
    g_hAlphabet.SetValue("=", hLines);
    g_hCharLength.SetValue("=", 5);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "00000");
    PushArrayString(hLines, "000=0");
    PushArrayString(hLines, "00=00");
    PushArrayString(hLines, "0=000");
    PushArrayString(hLines, "00000");
    g_hAlphabet.SetValue("/", hLines);
    g_hCharLength.SetValue("/", 5);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "00000");
    PushArrayString(hLines, "0=000");
    PushArrayString(hLines, "00=00");
    PushArrayString(hLines, "000=0");
    PushArrayString(hLines, "00000");
    g_hAlphabet.SetValue("\\", hLines);
    g_hCharLength.SetValue("\\", 5);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "00==00");
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "000=00");
    PushArrayString(hLines, "00=000");
    PushArrayString(hLines, "00=000");
    g_hAlphabet.SetValue("?", hLines);
    g_hCharLength.SetValue("?", 6);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "00=00");
    PushArrayString(hLines, "00=00");
    PushArrayString(hLines, "00=00");
    PushArrayString(hLines, "00000");
    PushArrayString(hLines, "00=00");
    g_hAlphabet.SetValue("!", hLines);
    g_hCharLength.SetValue("!", 5);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "00=00");
    PushArrayString(hLines, "0==00");
    PushArrayString(hLines, "00=00");
    PushArrayString(hLines, "00=00");
    PushArrayString(hLines, "0===0");
    g_hAlphabet.SetValue("1", hLines);
    g_hCharLength.SetValue("1", 5);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "00==00");
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "000=00");
    PushArrayString(hLines, "00=000");
    PushArrayString(hLines, "0====0");
    g_hAlphabet.SetValue("2", hLines);
    g_hCharLength.SetValue("2", 6);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0===0");
    PushArrayString(hLines, "000=0");
    PushArrayString(hLines, "00==0");
    PushArrayString(hLines, "000=0");
    PushArrayString(hLines, "0===0");
    g_hAlphabet.SetValue("3", hLines);
    g_hCharLength.SetValue("3", 5);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0=0=0");
    PushArrayString(hLines, "0=0=0");
    PushArrayString(hLines, "0===0");
    PushArrayString(hLines, "000=0");
    PushArrayString(hLines, "000=0");
    g_hAlphabet.SetValue("4", hLines);
    g_hCharLength.SetValue("4", 5);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0===0");
    PushArrayString(hLines, "0=000");
    PushArrayString(hLines, "0===0");
    PushArrayString(hLines, "000=0");
    PushArrayString(hLines, "0===0");
    g_hAlphabet.SetValue("5", hLines);
    g_hCharLength.SetValue("5", 5);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0===0");
    PushArrayString(hLines, "0=000");
    PushArrayString(hLines, "0===0");
    PushArrayString(hLines, "0=0=0");
    PushArrayString(hLines, "0===0");
    g_hAlphabet.SetValue("6", hLines);
    g_hCharLength.SetValue("6", 5);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0===0");
    PushArrayString(hLines, "000=0");
    PushArrayString(hLines, "000=0");
    PushArrayString(hLines, "00=00");
    PushArrayString(hLines, "00=00");
    g_hAlphabet.SetValue("7", hLines);
    g_hCharLength.SetValue("7", 5);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0===0");
    PushArrayString(hLines, "0=0=0");
    PushArrayString(hLines, "0===0");
    PushArrayString(hLines, "0=0=0");
    PushArrayString(hLines, "0===0");
    g_hAlphabet.SetValue("8", hLines);
    g_hCharLength.SetValue("8", 5);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0===0");
    PushArrayString(hLines, "0=0=0");
    PushArrayString(hLines, "0===0");
    PushArrayString(hLines, "000=0");
    PushArrayString(hLines, "0===0");
    g_hAlphabet.SetValue("9", hLines);
    g_hCharLength.SetValue("9", 5);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "00==00");
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "0=00=0");
    PushArrayString(hLines, "00==00");
    g_hAlphabet.SetValue("0", hLines);
    g_hCharLength.SetValue("0", 6);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "000");
    PushArrayString(hLines, "000");
    PushArrayString(hLines, "000");
    PushArrayString(hLines, "000");
    PushArrayString(hLines, "0=0");
    g_hAlphabet.SetValue(".", hLines);
    g_hCharLength.SetValue(".", 3);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "000");
    PushArrayString(hLines, "000");
    PushArrayString(hLines, "000");
    PushArrayString(hLines, "0=0");
    PushArrayString(hLines, "0=0");
    g_hAlphabet.SetValue(",", hLines);
    g_hCharLength.SetValue(",", 3);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0000");
    PushArrayString(hLines, "0==0");
    PushArrayString(hLines, "0==0");
    PushArrayString(hLines, "0000");
    PushArrayString(hLines, "0000");
    g_hAlphabet.SetValue("*", hLines);
    g_hCharLength.SetValue("*", 4);

    hLines = CreateArray(ByteCountToCells(15));
    PushArrayString(hLines, "0000");
    PushArrayString(hLines, "0000");
    PushArrayString(hLines, "0000");
    PushArrayString(hLines, "0000");
    PushArrayString(hLines, "0000");
    g_hAlphabet.SetValue(" ", hLines);
    g_hCharLength.SetValue(" ", 4);
}