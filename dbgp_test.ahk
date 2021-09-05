/* DBGp test script
 *  Demonstrates basic interaction with AutoHotkey_L's debugger engine;
 *  specifically, controlling and monitoring execution.
 *  Requires dbgp.ahk and AutoHotkey_L v1.1.09+
 */
#Include dbgp.ahk
#Persistent
#NoTrayIcon
#NoEnv
#Warn

DllCall("AllocConsole")

; Set callback functions.
DBGp_OnBegin("TDebuggerConnected")
DBGp_OnBreak("TDebuggerBreak")
DBGp_OnStream("TDebuggerStream")
DBGp_OnEnd("TDebuggerDisconnected")

; Start listening for connections.
DBGp_StartListening()
Out("
(
Launch a script with the /Debug switch to begin.  For example:
  > AutoHotkey.exe /Debug YourScript.ahk

When a debugger connection is detected, we will execute the script one
line at a time, showing the number and content of each line.  You can
run multiple scripts, or exit by pressing Ctrl+C or closing the window.
)")

return

TDebuggerConnected(session)
{
    Out("`n! Connected to " session.File)

    ; Redirect OutputDebug.
    session.stderr("-c 2")
    
    ; Step onto the first line.
    session.step_into()
}

; TDebuggerBreak is called whenever the debugger breaks, such
; as when step_into has completed or a breakpoint has been hit.
TDebuggerBreak(session, ByRef response)
{
    if InStr(response, "status=""break""")
    {
        ; Get the current context; i.e. file and line.
        session.stack_get("-d 0", response)
        
        ; Retrieve the line number and file URI.
        RegExMatch(response, "lineno=""\K\d+", lineno)
        RegExMatch(response, "filename=""\K.*?(?="")", fileuri)
        
        ; Show the line number and line text.
        filename := DBGp_DecodeFileURI(fileuri)
        FileReadLine line, %filename%, %lineno%
        Out(SubStr("00" lineno, -2) ": " line)
        
        ; Resume the script, breaking when execution reaches the next
        ; line at this stack depth or an outer one.
        session.step_over()
    }
}

TDebuggerStream(session, ByRef packet)
{
    ; OutputDebug was called.
    if RegExMatch(packet, "(?<=<stream type=""stderr"">).*(?=</stream>)", stderr)
        Out("dbg> " DBGp_Base64UTF8Decode(stderr))
}

TDebuggerDisconnected(session)
{
    Out("! Disconnected from " session.File)
}

Out(text, tag="")
{
    if tag !=
        text = %tag%: %text%
    FileAppend, %text%`n, CONOUT$
}