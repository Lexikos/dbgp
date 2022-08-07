/* DBGp test script
 *  Demonstrates async support and variable retrieval.
 */
#Requires AutoHotkey v2.0-beta.7
#Include dbgp.ahk
Persistent

DetectHiddenWindows true
SetTitleMatchMode 2

listen_port := 9001
current_view := ""
attached := Map()
sessions := Map(), sessions.CaseSense := "off"

OnMessage(0x111, WM_COMMAND, 10)
OnExit Exiting

DBGp_OnBegin(DebuggerAttach)
DBGp_OnBreak(DebuggerBreak)
DBGp_OnEnd(DebuggerDetach)
DBGp_StartListening( , listen_port)

SetView("Variables")

Exiting(*)
{
    OnExit Exiting, false
    SetTimer Disconnect, -10  ; Start a separate thread to allow interruption.
    return true
}

Disconnect()
{
    ; Clone() since sessions might be removed while we're looping.
    for , session in sessions.Clone()
        session.detach()
    ExitApp
}

WM_COMMAND(wParam, lParam, *)
{
    switch wParam
    {
        case 65406: SetView "Lines"
        case 65407: SetView "Variables"
        case 65408: SetView "Hotkeys"
        case 65409: SetView "KeyHistory"
        case 65410: Refresh
    }
}

SetView(view)
{
    global current_view := view
    Refresh
}

SetText(text)
{
    ControlSetText text, 'Edit1', A_ScriptHwnd
}

Refresh()
{
    if (current_view != "Variables")
        return
    
    AttachScripts()
    
    ; Set up an MSXML document for parsing the responses.
    doc := ComObject("MSXML2.DOMDocument")
    doc.async := false
    doc.setProperty("SelectionLanguage", "XPath")
    
    s := ""
    
    for , session in sessions.Clone()
    {
        s .= session.File ":" session.Thread
        . "`n============================================================`n"
        
        response := session.context_get("-c 1")
        
        doc.loadXML(response)
        
        nodes := doc.selectNodes("/response/property")
        Loop nodes.length
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
    
    SetText(StrReplace(s, "`n", "`r`n"))
    WinShow A_ScriptHwnd
    WinActivate A_ScriptHwnd
}

AttachScripts()
{
    static attach_msg := DllCall("RegisterWindowMessage", "str", "AHK_ATTACH_DEBUGGER")
    count := attached.Count
    for hwnd in WinGetList("- AutoHotkey ahk_class AutoHotkey",, A_ScriptFullPath)
    {
        thread := DllCall("GetWindowThreadProcessId", "ptr", hwnd, "ptr", 0, "uint")
        if !attached.Has(thread)
            try
            {
                PostMessage attach_msg, , listen_port,, hwnd  ; May fail due to UAC (admin or run with UI access).
                count++
            }
    }
    ; Wait up to 500ms for all scripts to attach.
    t := A_TickCount
    while attached.Count < count && (A_TickCount-t < 500)
        Sleep 10
}

DebuggerAttach(session, init)
{
    ; D("attached to " session.File ":" session.Thread)
    
    ; Check if the debugger supports async mode, which is required:
    response := session.feature_get("-n supports_async")
    if !InStr(response, ">1<")
    {
        session.detach()
        MsgBox "The following script is running on an outdated "
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
    attached.Delete(session.Thread)
    sessions.Delete(session.File ":" session.Thread)
}

DebuggerBreak(*)
{
    ; We don't need to actually do anything here; the callback just has
    ; to be set so that DBGp() doesn't wait for a response when we call
    ; a continuation command.
}
