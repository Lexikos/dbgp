/* DBGp console
 *  Basic CLI debugger client for AutoHotkey_L
 *  Requires dbgp.ahk and AutoHotkey_L
 */
#Requires AutoHotkey v2.0-beta.7
#Include dbgp.ahk
Persistent
#NoTrayIcon
; Do not run this script from SciTE, or any other editor that redirects console output.
DllCall("AllocConsole")
; Set up aliases:
AliasMap := Map(
    "r", "run",
    "in", "step_into",
    "ov", "step_over",
    "ou", "step_out",
    "fg", "feature_get",
    "fs", "feature_set",
    "bs", "breakpoint_set",
    "bg", "breakpoint_get",
    "br", "breakpoint_remove",
    "bl", "breakpoint_list",
    "sd", "stack_depth",
    "sg", "stack_get",
    "cn", "context_names",
    "cg", "context_get",
    "tg", "typemap_get",
    "pg", "property_get",
    "ps", "property_set",
    "pv", "property_value",
)
; Set up error code -> text map.
ErrorMap := Map(
      0, "OK",
      1, "Parse error",
      3, "Invalid options",
      4, "Unimplemented command",
      5, "Command unavailable",
    100, "Can not open file",
    201, "Breakpoint type not supported",
    202, "Breakpoint invalid",
    203, "No code on breakpoint line",
    204, "Invalid breakpoint state",
    205, "No such breakpoint",
    300, "Unknown property",
    301, "Invalid stack depth",
    302, "Invalid context",
)

; Set event callbacks.
DBGp_OnBegin(DebuggerConnected)
DBGp_OnStream(DebuggerStream)

Listen()

Listen()
{
    ConWriteLine("*** Listening on port 9000 for a debugger connection.")
    global ListenSocket := DBGp_StartListening()
}

DebuggerConnected(new_session, init)
{
    global
    ; We can handle only one at a time, so stop listening for now.
    DBGp_StopListening(ListenSocket), ListenSocket := -1
    ; Start the interactive loop in a new thread.
    session := new_session
    SetTimer Debug, -1
}

DebuggerStream(session, packet)
{
    if RegExMatch(packet, '<stream type="(.*?)">\K.*(?=</stream>)', &stream)
    {
        ConAttrib(stream.1="stdout" ? 7 : 14)
        ConWriteLine(RegExReplace(DBGp_Base64UTF8Decode(stream.0),"`n$"))
        ConAttrib(7)
    }
}

WriteResponse(session, response)
{
    ; Improve output formatting a little.
    TidyPacket(&response)
    ; Display response with base64-encoded data converted back to text:
    b := 1
    p := 1
    while p := RegExMatch(response, 'encoding="base64"[^>]*?>\s*\K[^<]*?(?=\s*<)', &base64, p)
    {
        ConWrite(SubStr(response, b, p-b))
        ConAttrib(9)
        ConWrite(DBGp_Base64UTF8Decode(base64.0))
        ConAttrib(7)
        b := p + StrLen(base64.0)
    }
    ConWrite(SubStr(response, b) "`n`n")
}

Debug()
{
    ConWriteLine(
    "*** Debugging "  session.File  ; Path of main script file
    "`nide_key:    "  session.IDEKey  ; DBGp_IDEKEY env var
    "`nsession:    "  session.Cookie  ; DBGp_COOKIE env var
    "`nthread id:  "  session.Thread  ; Thread id of script
    "`n")
    Loop
    {
        ; Display prompt.
        ConWrite("> ")
        ; Wait for one line of input.
        ; NOTE: The script cannot respond to messages (such as notification
        ;       of incoming dbgp packets) while waiting for console input.
        static conin := FileOpen("CONIN$", "r")
        line := conin.ReadLine()
        ; Split the command and args.
        if RegExMatch(line, 's)^(\w+)(?: +(?!=)(.*))?$', &m)
            command := AliasMap.Get(m.1, m.1), args := m.2
        else
        {   ; Support var=value
            if RegExMatch(line, '^(.+?)\s*=\s*(.*)$', &m)
                command := "property_set", args := "-n " m.1 " -- " DBGp_Base64UTF8Encode(m.2)
            ; Support ?var
            else if SubStr(line,1,1)="?"
                command := "property_get", args := "-n " RegExReplace(line,"^\?\s*")
            else
                command := line, args := ""
        }
        if command = 'd' ; Decode base64
        {
            ConWrite(DBGp_Base64UTF8Decode(args) "`n`n")
            continue
        }
        if command = 'e' ; Encode base64
        {
            ConWrite(DBGp_Base64UTF8Encode(args) "`n`n")
            continue
        }
        try
        {
            response := session.%command%(args) 
            WriteResponse(session, response)
        }
        catch DbgpError, OSError as e
        {
            response := ""
            if session.Socket = -1 ; Disconnected.
                break
            ConAttrib(12)
            ConWrite(Type(e) ": " (e is DbgpError ? ErrorMap.Get(Integer(e.Extra), e.Extra) : e.Message) "`n`n")
            ConAttrib(7)
        }
        ; If script has stopped, listen for the next connection.
    } Until InStr(response,'status="stopped"') || session.Socket = -1
    ConWriteLine("*** Stopped debugging.")
    Listen()
}

TidyPacket(&xml) {
    xml := RegExReplace(xml, "^<\?.*?\?>")
    i := 1, indent := ""
    while i := RegExMatch(xml, "s)(.*?)(<[^>]*>)", &s, i)
    {
        s2 := s.2
        if (s.1 != "" && out != "")
            out .= "`n" . indent
        out .= s.1 . "`n"
        if is_end_tag := SubStr(s2,2,1)="/"
            indent := SubStr(indent, 3)
        out .= indent
        if StrLen(indent . s2) > 100 && RegExMatch(s2, "^<\w+ ", &n)
            s2 := RegExReplace(s2, '\S+?="[^"]*"\K\s(?!\s*>)'
                    , "`n" . indent . RegExReplace(n.0, "s).", " "))
        out .= s2
        if !is_end_tag && SubStr(s2,-2,1) != "/"
            indent .= "  "
        i += s.Len()
    }
    xml := out
}

ConWrite(s) {
    FileAppend s, "CONOUT$"
}
ConWriteLine(s) {
    FileAppend s "`n", "CONOUT$"
}
ConAttrib(attrib) {
    Console := FileOpen("CONOUT$", "rw")
    return DllCall("SetConsoleTextAttribute", "ptr", Console.Handle, "short", attrib)
}
