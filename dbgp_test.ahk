/* DBGp test script
 *  Demonstrates basic interaction with AutoHotkey_L's debugger engine;
 *  specifically, controlling and monitoring execution.
 */
#Requires AutoHotkey v2.0-beta.7
#Include dbgp.ahk
Persistent
#NoTrayIcon

DllCall("AllocConsole")

; Set callback functions.
DBGp_OnBegin(TDebuggerConnected)
DBGp_OnBreak(TDebuggerBreak)
DBGp_OnStream(TDebuggerStream)
DBGp_OnEnd(TDebuggerDisconnected)

; Start listening for connections.
DBGp_StartListening()
Out("
(
Launch a script with the /Debug switch to begin.  For example:
  > AutoHotkey.exe /Debug YourScript.ahk

When a debugger connection is detected, we will execute the script one
line at a time, showing the number and content of each line.  You can
run multiple scripts, or exit by closing the window.
)")

return

TDebuggerConnected(session, init_packet)
{
    Out("`n! Connected to " session.File)

    ; Redirect OutputDebug.
    session.stderr("-c 2")
    
    ; Step onto the first line.
    session.step_into()
}

; TDebuggerBreak is called whenever the debugger breaks, such
; as when step_into has completed or a breakpoint has been hit.
TDebuggerBreak(session, response)
{
    if InStr(response, 'status="break"')
    {
        ; Get the current context; i.e. file and line.
        response := session.stack_get("-d 0")
        
        ; Retrieve the line number and file URI.
        lineno := RegExMatch(response, 'lineno="\K\d+', &lineno) ? lineno.0 : 0
        RegExMatch(response, 'filename="\K.*?(?=")', &fileuri)
        
        ; Show the line number and line text.
        filename := DBGp_DecodeFileURI(fileuri.0)
        Loop Read filename
            if A_Index = lineno {
                line := A_LoopReadLine
                break
            }
        
        Out(Format("{:03i}: {}", lineno, line ?? "(end)"))
        
        ; Resume the script, breaking when execution reaches the next
        ; line at this stack depth or an outer one.
        session.step_over()
    }
}

TDebuggerStream(session, packet)
{
    ; OutputDebug was called.
    if RegExMatch(packet, '(?<=<stream type="stderr">).*(?=</stream>)', &stderr)
        Out("dbg> " DBGp_Base64UTF8Decode(stderr.0))
}

TDebuggerDisconnected(session)
{
    Out("! Disconnected from " session.File)
}

Out(text, tag:="")
{
    if tag != ""
        text := tag ": " text
    FileAppend text "`n", "CONOUT$"
}