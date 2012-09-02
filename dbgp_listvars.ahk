/* DBGp test script
 *  Demonstrates async support and variable retrieval.
 *  Requires dbgp.ahk and AutoHotkey_L v1.1.09+
 */
#Include dbgp.ahk
#Persistent
#NoEnv
#Warn

DetectHiddenWindows On
SetTitleMatchMode 2

global listen_port := 9001
global current_view := ""
global attached := {}
global sessions := {}

OnMessage(0x111, "WM_COMMAND", 10)
OnExit Exiting

DBGp_OnBegin("DebuggerAttach")
DBGp_OnBreak("DebuggerBreak")
DBGp_OnEnd("DebuggerDetach")
DBGp_StartListening( , listen_port)

SetView("Variables")

return

Exiting:
OnExit              ; Allow subsequent ExitApp to exit the script.
SetTimer Exit, -10  ; Start a separate thread to allow interruption.
return
Exit:
Disconnect()
ExitApp

Disconnect()
{
    ; Clone() since sessions might be removed while we're looping.
    for _, session in sessions.Clone()
        session.detach()
}

WM_COMMAND(wParam, lParam)
{
    static view := {
    (Join,
        65406: "Lines"
        65407: "Variables"
        65408: "Hotkeys"
        65409: "KeyHistory"
    )}
    if (wParam = 65410) ; Refresh
        return Refresh()
    if view[wParam]
        return SetView(view[wParam])
}

SetView(view)
{
    current_view := view
    return Refresh()
}

SetText(text)
{
    ControlSetText Edit1, %text%, ahk_id %A_ScriptHwnd%
}

Refresh()
{
    if (current_view != "Variables")
        return
    
    AttachScripts()
    
    ; Set up an MSXML document for parsing the responses.
    doc := ComObjCreate("MSXML2.DOMDocument")
    doc.async := false
    doc.setProperty("SelectionLanguage", "XPath")
    
    s := ""
    
    for _, session in sessions.Clone()
    {
        s .= session.File ":" session.Thread
        . "`n============================================================`n"
        
        session.context_get("-c 1", response)
        
        doc.loadXML(response)
        
        nodes := doc.selectNodes("/response/property")
        Loop % nodes.length
        {
            prop := nodes.item[A_Index-1]
            name := prop.getAttribute("fullname")
            type := prop.getAttribute("type")
            facet := prop.getAttribute("facet")
            
            if (type = "undefined" || facet = "Builtin")
                continue
            
            s .= name
            if (type != "object")
            {
                value := DBGp_Base64UTF8Decode(prop.text)
                size := prop.getAttribute("size")
                s .= ": " value . (StrLen(value) != size ? "...`n" : "`n")
            }
            else
            {
                ; For this basic script, we'll just show there's an
                ; object.  It would be possible to convert the object's
                ; contents to a JSON string for display, or similar.
                s .= ": " prop.getAttribute("classname") "(" prop.getAttribute("address") ")`n"
            }
        }
        
        s .= "`n`n"
    }
    
    StringReplace s, s, `n, `r`n, All
    SetText(s)
    WinShow ahk_id %A_ScriptHwnd%
    WinActivate ahk_id %A_ScriptHwnd%
}

AttachScripts()
{
    static attach_msg := DllCall("RegisterWindowMessage", "str", "AHK_ATTACH_DEBUGGER")
    WinGet w, List, - AutoHotkey ahk_class AutoHotkey,, %A_ScriptFullPath%
    Loop % w
    {
        hwnd := w%A_Index%
        thread := DllCall("GetWindowThreadProcessId", "ptr", hwnd, "ptr", 0, "uint")
        if attached[thread]
            continue
        PostMessage attach_msg, , listen_port,, ahk_id %hwnd%
    }
    ; Wait up to 500ms for all scripts to attach.
    t := A_TickCount
    while w && attached.MaxIndex() < w && (A_TickCount-t < 500)
        Sleep 10
}

DebuggerAttach(session, ByRef init)
{
    ; D("attached to " session.File ":" session.Thread)
    
    ; Check if the debugger supports async mode, which is required:
    session.feature_get("-n supports_async", response)
    if !InStr(response, ">1<")
    {
        session.detach()
        MsgBox % "The following script is running on an outdated "
            . "version of AutoHotkey_L and therefore can't be used with "
            . "this script:`n`n" session.File
        return
    }
    
    ; Don't send any more attach requests to this thread.
    attached[session.Thread] := true
    
    ; Store session by file for sorting purposes, and by thread in
    ; case there are multiple instances of this script running.
    sessions[session.File ":" session.Thread] := session
    
    ; Change settings.
    session.feature_set("-n max_depth -v 0")
    session.feature_set("-n max_data -v 200")
    
    ; Resume the script.
    session.run()
}

DebuggerDetach(session)
{
    ; D("detached from " session.File ":" session.Thread)
    attached.Remove(session.Thread)
    sessions.Remove(session.File ":" session.Thread)
}

DebuggerBreak()
{
    ; We don't need to actually do anything here; the callback just has
    ; to be set so that DBGp() doesn't wait for a response when we call
    ; a continuation command.
}
