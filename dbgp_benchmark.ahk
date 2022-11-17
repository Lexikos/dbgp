/* DBGp test script
 *  A simple benchmark which was used to determine that Sleep 10
 *  in _DBGp_WaitHandler_Wait() was a massive bottleneck.
 */
#Requires AutoHotkey v1.1.35
#Include dbgp.ahk
#Persistent
#NoTrayIcon
#NoEnv
#Warn

DBGp_OnBegin("TDebuggerConnected")
DBGp_OnEnd("TDebuggerDisconnected")
DBGp_StartListening()
Run "%A_AhkPath%" /Debug nul

TDebuggerConnected(dbg) {
    base64name := DBGp_Base64UTF8Encode("SciTE4AutoHotkey")
    SetBatchLines -1
    T()
    Loop % i := 100 {
        dbg.property_set("-n A_DebuggerName -- " base64name)
        dbg.property_get("-n A_DebuggerName", response)
        dbg.feature_set("-n max_data -v 200")
        dbg.feature_set("-n max_children -v 100")
        dbg.feature_set("-n max_depth -v 0")
        dbg.stdout("-c 2")
        dbg.stderr("-c 2")
	    dbg.feature_get("-n supports_async", response)
    }
    D(T() / i / 8)
    dbg.feature_get("-n max_data", response)
    D("max_data " (InStr(response, ">200<") ? "pass" : "FAIL`n" response))
    dbg.property_get("-n A_DebuggerName", response)
    D("property " (InStr(response, ">" base64name "<") ? "pass" : "FAIL`n" response))
    dbg.stop()
}

TDebuggerDisconnected(dbg) {
    ExitApp
}

D(text, tag="") {
    if tag !=
        text = %tag%: %text%
    FileAppend, %text%`n, *
}

T() {
    local count, t
    static freq := 0, last_count := 0
    if !freq
        DllCall("QueryPerformanceFrequency", "int64*", freq)
    DllCall("QueryPerformanceCounter", "int64*", count := 0)
    t := (count-last_count)/freq, last_count := count
    return t
}
