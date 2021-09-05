/* DBGp console
 *  Basic CLI debugger client for AutoHotkey_L
 *  Requires dbgp.ahk and AutoHotkey_L
 */
#Include %A_ScriptDir%\dbgp.ahk
#Persistent
#NoTrayIcon
; Do not run this script from SciTE, or any other editor that redirects console output.
DllCall("AllocConsole")
; Get probable process name:
if A_IsCompiled
    A_ExeName := A_ScriptName
else
    SplitPath, A_AhkPath, A_ExeName
; Set up aliases:
alias=
(
r=run
in=step_into
ov=step_over
ou=step_out
fg=feature_get
fs=feature_set
bs=breakpoint_set
bg=breakpoint_get
br=breakpoint_remove
bl=breakpoint_list
sd=stack_depth
sg=stack_get
cn=context_names
cg=context_get
tg=typemap_get
pg=property_get
ps=property_set
pv=property_value
)
Loop, Parse, alias, `n
{
    StringSplit, alias, A_LoopField, =
    DllCall("AddConsoleAlias", "str", alias1, "str", alias2 " $*", "str", A_ExeName)
}
; Set up error code -> text map.
ErrorMap := {0: "OK"
    , 1: "Parse error"
    , 3: "Invalid options"
    , 4: "Unimplemented command"
    , 5: "Command unavailable"
    , 100: "Can not open file"
    , 201: "Breakpoint type not supported"
    , 202: "Breakpoint invalid"
    , 203: "No code on breakpoint line"
    , 204: "Invalid breakpoint state"
    , 205: "No such breakpoint"
    , 300: "Unknown property"
    , 301: "Invalid stack depth"
    , 302: "Invalid context"}

; Set event callback.
DBGp_OnBegin("DebuggerConnected")
DBGp_OnStream("DebuggerStream")
DBGp_OnEnd("DebuggerDisconnected")
Listen:
ConWriteLine("*** Listening on port 9000 for a debugger connection.")
ListenSocket := DBGp_StartListening()
return

DebuggerConnected(new_session)
{
    global
    ; We can handle only one at a time, so stop listening for now.
    DBGp_StopListening(ListenSocket), ListenSocket := -1
    ; Start the interactive loop in a new thread.
    session := new_session
    SetTimer, Debug, -1
}

DebuggerStream(session, ByRef packet)
{
    if RegExMatch(packet, "<stream type=""(.*?)"">\K.*(?=</stream>)", stream)
    {
        ConAttrib(stream1="stdout" ? 7 : 14)
        ConWriteLine(RegExReplace(DBGp_Base64UTF8Decode(stream),"`n$"))
        ConAttrib(7)
    }
}

DebuggerDisconnected()
{
    ; global session := 0
}

WriteResponse(session, ByRef response)
{
    ; Improve output formatting a little.
    TidyPacket(response)
    ; Display response with base64-encoded data converted back to text:
    b := 1
    p := 1
    while p := RegExMatch(response, "encoding=""base64""[^>]*?>\s*\K[^<]+?(?=\s*<)", base64, p)
    {
        ConWrite(SubStr(response, b, p-b))
        ConAttrib(9)
        ConWrite(DBGp_Base64UTF8Decode(base64))
        ConAttrib(7)
        b := p + StrLen(base64)
    }
    ConWrite(SubStr(response, b) "`n`n")
}

Debug:
ConWriteLine("
(C
*** Debugging "  session.File  "  ; Path of main script file
ide_key:    "  session.IDEKey  "  ; DBGp_IDEKEY env var
session:    "  session.Cookie  "  ; DBGp_COOKIE env var
thread id:  "  session.Thread  "  ; Thread id of script
)`n")
Loop
{
    ; Display prompt.
    ConWrite("> ")
    ; Wait for one line of input.
    ; NOTE: The script cannot respond to messages (such as notification
    ;       of incoming dbgp packets) while waiting for console input.
    FileReadLine, line, CONIN$, 1
    ; Split the command and args.
    if RegExMatch(line, "s)^(\w+)(?: +(?!=)(.*))?$", m)
        command := m1, args := m2
    else
    {   ; Support var=value
        if RegExMatch(line, "^(.+?)\s*=\s*(.*)$", m)
            command := "property_set", args := "-n " m1 " -- " DBGp_Base64UTF8Encode(m2)
        ; Support ?var
        else if SubStr(line,1,1)="?"
            command := "property_get", args := "-n " RegExReplace(line,"^\?\s*")
        else
            command := line, args := ""
    }
    if command = d
    {
        ConWrite(DBGp_Base64UTF8Decode(args) "`n`n")
        continue
    }
    if command = e
    {
        ConWrite(DBGp_Base64UTF8Encode(args) "`n`n")
        continue
    }
    if DBGp(session, command, args, response) = 0
    {
        WriteResponse(session, response)
    }
    else
    {
        if session.Socket = -1 ; Disconnected.
            break
        gosub display_error
    }
    ; If script has stopped, listen for the next connection.
} Until InStr(response,"status=""stopped""") || session.Socket = -1
ConWriteLine("*** Stopped debugging.")
gosub Listen
return

display_error:
el := ErrorMap.HasKey(ErrorLevel) ? ErrorMap[ErrorLevel] : ErrorLevel
ConAttrib(12)
ConWrite("Error: " el "`n`n")
ConAttrib(7)
return

TidyPacket(ByRef xml) {
    xml := RegExReplace(xml, "^<\?.*?\?>")
    i := 1
    while i := RegExMatch(xml, "s)(.*?)(<[^>]*>)", s, i)
    {
        if (s1 != "" && out != "")
            out .= "`n" . indent
        out .= s1 . "`n"
        if is_end_tag := SubStr(s2,2,1)="/"
            indent := SubStr(indent, 3)
        out .= indent
        if StrLen(indent . s2) > 100 && RegExMatch(s2, "^<\w+ ", n)
            s2 := RegExReplace(s2, "\S+?=""[^""]*""\K\s(?!\s*>)"
                    , "`n" . indent . RegExReplace(n, "s).", " "))
        out .= s2
        if !is_end_tag && SubStr(s,-1,1) != "/"
            indent .= "  "
        i += StrLen(s)
    }
    xml := out
}

ConWrite(s) {
    FileAppend %s%, CONOUT$
}
ConWriteLine(s) {
    FileAppend %s%`n, CONOUT$
}
ConAttrib(attrib) {
    Console := FileOpen("CONOUT$", "rw")
    return DllCall("SetConsoleTextAttribute", "ptr", Console.__Handle, "short", attrib)
}
