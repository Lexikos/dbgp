/* DBGp client functions - v2.0
 *  Enables scripts to debug other scripts via DBGp.
 */

#Requires AutoHotkey v2.0-beta.7

/*
Public API:

DBGp_StartListening(localAddress:="127.0.0.1", localPort:=9000) -> socket
DBGp_OnBegin(func)          ; func(session, initPacket)
DBGp_OnBreak(func)          ; func(session, responsePacket)
DBGp_OnStream(func)         ; func(session, streamPacket)
DBGp_OnEnd(func)            ; func(session)
DBGp_StopListening(socket)

DBGp_Base64UTF8Decode(base64)       -> decoded string
DBGp_Base64UTF8Encode(textdata)     -> encoded string

DBGp_EncodeFileURI(filename)        -> fileuri
DBGp_DecodeFileURI(fileuri)         -> filename

session.Socket                      -> Integer; socket handle
session.IDEKey                      -> String; ide_key attribute of init packet
session.Cookie                      -> String; session attribute of init packet
session.Thread                      -> Integer; thread attribute of init packet
session.File                        -> String; decoded fileuri attribute of init packet

session is DbgpSession
session.%cmd%(args?)                -> response  ; may throw a DbgpError
session.Send(cmd, args?, callback?)
session.Close()

err is DbgpError
err.Extra                           -> DBGp error code

*/

class DbgpSession
{
;public:
    __Call(cmd, args) => DBGp(this, cmd, args*)
    Send     := DBGp_Send
    Close    := DBGp_CloseSession
;internal:
    static OnBegin := "", OnBreak := "", OnStream := "", OnEnd := ""
    static sockets := Map()
    static callQueue := []
    handlers := Map()
    lastID := 0
    buf := Buffer(16384)
    bufLen := 0
    packetLen := ""
    class WaitHandler {
        static prototype.Call := _DBGp_WaitHandler_Call
    }
    class QueueHandler {
        static prototype.Call := _DBGp_QueueHandler_Call
        static prototype.__New := _DBGp_QueueHandler_New
    }
}

class DbgpError extends Error {
    __new(n, what?) {
        super.__new(unset, what?, n)
    }
}

; Start listening for debugger connections. Must be called before any debugger may connect.
DBGp_StartListening(localAddress:="127.0.0.1", localPort:=9000)
{
    static AF_INET:=2, SOCK_STREAM:=1, IPPROTO_TCP:=6
        , FD_ACCEPT:=8, FD_READ:=1, FD_CLOSE:=0x20
    static wsaData
    if !IsSet(wsaData)
    {   ; Initialize Winsock to version 2.2.
        wsaData := Buffer(402)
        wsaError := DllCall("ws2_32\WSAStartup", "ushort", 0x202, "ptr", wsaData)
        if wsaError
            throw DBGp_WSAE(wsaError)
    }
    ; Create socket to be used to listen for connections.
    s := DllCall("ws2_32\socket", "int", AF_INET, "int", SOCK_STREAM, "int", IPPROTO_TCP, "ptr")
    if s = -1
        throw DBGp_WSAE()
    ; Bind to specific local interface, or any/all.
    NumPut("ushort", AF_INET
        , "ushort", DllCall("ws2_32\htons", "ushort", localPort, "ushort")
        , "uint", DllCall("ws2_32\inet_addr", "astr", localAddress)
        , sockaddr_in := Buffer(16, 0))
    if DllCall("ws2_32\bind", "ptr", s, "ptr", sockaddr_in, "int", 16) = 0 ; no error
        ; Request window message-based notification of network events.
        && DllCall("ws2_32\WSAAsyncSelect", "ptr", s, "ptr", DBGp_hwnd(), "uint", 0x8000, "int", FD_ACCEPT|FD_READ|FD_CLOSE) = 0 ; no error
        && DllCall("ws2_32\listen", "ptr", s, "int", 4) = 0 ; no error
            return s
    ; An error occurred.
    DllCall("ws2_32\closesocket", "ptr", s)
    throw DBGp_WSAE()
}

_DBGp_ValidFn(fn, n) {
    if !HasMethod(fn,, n)
        throw ValueError("Invalid callback", -2)
}

; Set the function to be called when a debugger connection is accepted.
DBGp_OnBegin(fn)
{
    _DBGp_ValidFn fn, 2
    ; Subject to change - do not use this property directly:
    DbgpSession.OnBegin := fn ? DbgpSession.QueueHandler(fn) : ""
}

; Set the function to be called when a response to a continuation command is received.
DBGp_OnBreak(fn)
{
    _DBGp_ValidFn fn, 2
    ; Subject to change - do not use this property directly:
    DbgpSession.OnBreak := fn ? DbgpSession.QueueHandler(fn) : ""
}

; Set the function to be called when a stream packet is received.
DBGp_OnStream(fn)
{
    _DBGp_ValidFn fn, 2
    ; Subject to change - do not use this property directly:
    DbgpSession.OnStream := fn ? DbgpSession.QueueHandler(fn) : ""
}

; Set the function to be called when a debugger connection is lost.
DBGp_OnEnd(fn)
{
    _DBGp_ValidFn fn, 1
    ; Subject to change - do not use this property directly:
    DbgpSession.OnEnd := fn ? DbgpSession.QueueHandler(fn) : ""
}

; Stops listening for debugger connections. Does not disconnect debuggers, but prevents more debuggers from connecting.
DBGp_StopListening(socket)
{
    if DllCall("ws2_32\closesocket", "ptr", socket) = -1
        throw DBGp_WSAE()
}

; Execute a DBGp command.
DBGp(session, command, args:="")
{
    response := ""
    
    handler := ""
    ; If OnBreak has been set and this is a continuation command,
    ; call OnBreak when the response is received instead of waiting.
    if InStr(" run step_into step_over step_out ", " " command " ")
        handler := DbgpSession.OnBreak
    if wait := !handler
        handler := DbgpSession.WaitHandler()
    
    _DBGp_SendEx(session, command, args, handler)
    if wait
    {
        handler.cmd := command ;dbg
        ; Wait for and return a response.
        _DBGp_WaitHandler_Wait(handler, session, &response)
    }
    
    return response
}

; Send a command.
DBGp_Send(session, command, args:="", responseHandler:="")
{
    if responseHandler
        responseHandler := DbgpSession.QueueHandler(responseHandler)
    _DBGp_SendEx(session, command, args, responseHandler)
}

_DBGp_SendEx(session, command, args, responseHandler)
{
    ; Format command line (insert -i transaction_id).
    transaction_id := String(++session.lastID)
    packet := command " -i " transaction_id
    if (args != "")
        packet .= " " args
    
    ; Convert to UTF-8 (regardless of ANSI vs Unicode).
    packetData := Buffer(packetLen := StrPut(packet, "UTF-8"))
    StrPut(packet, packetData, "UTF-8")
    
    ; Set the handler first to avoid a possible race condition.
    if responseHandler
        session.handlers[transaction_id] := responseHandler
    
    ; @Debug-Output => {packet}
    if DllCall("ws2_32\send", "ptr", session.Socket, "ptr", packetData, "int", packetLen, "int", 0) = -1
    {
        ; Remove the handler, since it is unlikely to be called. This
        ; may be unnecessary since it's likely the session is ending.
        if responseHandler
            session.handlers.Delete(transaction_id)
        throw DBGp_WSAE()
    }
}


; ## SESSION API ##

DBGp_CloseSession(session)
{
    return DllCall("ws2_32\closesocket", "ptr", session.Socket) = -1 ? DBGp_WSAE() : 0
}


; ## UTILITY FUNCTIONS ##

DBGp_Base64UTF8Decode(base64) {
    return base64 = "" ? "" : StrGet(DBGp_StringToBinary(base64, 1), "utf-8")
}

DBGp_Base64UTF8Encode(textdata) {
    if (textdata = "")
        return ""
    sz := StrPut(textdata, rawdata := Buffer(StrPut(textdata, "utf-8")), "utf-8") - 1
    return DBGp_BinaryToString(rawdata, sz, 0x40000001)
}

;http://www.autohotkey.com/forum/viewtopic.php?p=238120#238120
DBGp_BinaryToString(bin, sz:=bin.size, fmt:=12) {   ; return base64 or formatted-hex
   DllCall("Crypt32.dll\CryptBinaryToString", "ptr",bin, "uint",sz, "uint",fmt, "ptr",0, "uint*",&cp:=0) ; get size
   str := Buffer(cp*2)
   DllCall("Crypt32.dll\CryptBinaryToString", "ptr",bin, "uint",sz, "uint",fmt, "str",str, "uint*",&cp)
   return StrGet(str, cp)
}
DBGp_StringToBinary(str, fmt:=12) {    ; return length, result in bin
   DllCall("Crypt32.dll\CryptStringToBinary", "ptr",StrPtr(str), "uint",StrLen(str), "uint",fmt, "ptr",0, "uint*",&cp:=0, "ptr",0,"ptr",0) ; get size
   bin := Buffer(cp)
   DllCall("Crypt32.dll\CryptStringToBinary", "ptr",StrPtr(str), "uint",StrLen(str), "uint",fmt, "ptr",bin, "uint*",cp, "ptr",0,"ptr",0)
   return bin
}

; Convert file path to URI
; Rewritten by fincs to support Unicode paths
DBGp_EncodeFileURI(s)
{
    s := StrReplace(StrReplace(s, "\", "/"), "%", "%25")
    h := Buffer(4)
    while RegExMatch(s, "[^\w\-.!~*'()/%]", &c)
    {
        StrPut(c[0], h, "UTF-8")
        r := ""
        while n := NumGet(h, A_Index - 1, "UChar")
            r .= Format("%{:02X}", n)
        s := StrReplace(s, c[0], r)
    }
    return s
}

; Convert URI to file path
; Rewritten by fincs to support Unicode paths
DBGp_DecodeFileURI(s)
{
    if SubStr(s, 1, 8) = "file:///"
        s := SubStr(s, 9)
    s := StrReplace(s, "/", "\")
    
    buf := Buffer(StrLen(s)+1)
    i := 0, o := 0
    while i <= StrLen(s)
    {
        c := NumGet(StrPtr(s), i * 2, "ushort")
        if (c = Ord("%"))
            c := "0x" SubStr(s, i+2, 2), i += 2
        NumPut("uchar", c, buf, o)
        i++, o++
    }
    return StrGet(buf, "UTF-8")
}

; Replace XML entities with the appropriate characters.
DBGp_DecodeXmlEntities(s)
{
    ; Replace XML entities which may be returned by AutoHotkey (e.g. in ide_key attribute of init packet if DBGp_IDEKEY env var contains one of "&'<>).
    s := StrReplace(s, "&quot;", Chr(34))
    s := StrReplace(s, "&amp;", "&")
    s := StrReplace(s, "&apos;", "'")
    s := StrReplace(s, "&lt;", "<")
    s := StrReplace(s, "&gt;", ">")
    return s
}


; ## INTERNAL FUNCTIONS ##

; Internal: Window procedure for handling WSAAsyncSelect notifications.
DBGp_HandleWindowMessage(hwnd, uMsg, wParam, lParam)
{
    static FD_ACCEPT:=8, FD_READ:=1, FD_CLOSE:=0x20
    
    ; Must not be interrupted by FD_READ while processing FD_ACCEPT
    ; (e.g. setting up the session which FD_READ may be received for)
    ; or FD_READ (still processing previous data).
    Critical 10000

    uMsg &= 0xFFFFFFFF
    
    if uMsg != 0x8000
        return DllCall("DefWindowProc", "ptr", hwnd, "uint", uMsg, "ptr", wParam, "ptr", lParam, "ptr")
    
    event := lParam & 0xffff
    
    if (event = FD_ACCEPT)
    {
        ; Accept incoming connection.
        s := DllCall("ws2_32\accept", "ptr", wParam, "uint", 0, "uint", 0, "ptr")
        if s = -1
            return 0
        
        ; Create object to store information about this debugging session.
        session := DbgpSession()
        session.Socket := s
        
        DBGp_AddSession(session)
    }
    else if (event = FD_READ) ; Receiving data.
    {
        if !(session := DBGp_FindSessionBySocket(wParam))
            return 0
        
        DBGp_HandleIncomingData(session)
    }
    else if (event = FD_CLOSE) ; Connection closed.
    {
        if !(session := DBGp_FindSessionBySocket(wParam))
            return 0
        
        DBGp_CallHandler(DbgpSession.OnEnd, session)
        
        session.CloseError := (lParam >> 16) & 0xffff
        DBGp_RemoveSession(session), session.Socket := -1
        DllCall("ws2_32\closesocket", "ptr", wParam)
    }
    
    return 0
}

DBGp_HandleIncomingData(session)
{
    cap := session.buf.size
    ptr := session.buf.ptr
    len := session.bufLen
    
    ; Copy available data into the buffer.
    r := DllCall("ws2_32\recv", "ptr", session.Socket
                , "ptr", ptr + len, "int", cap - len, "int", 0)
    ; Be tolerant of errors because WSAEWOULDBLOCK is expected in some
    ; cases, and even if some other error occurs, there may be data in
    ; our buffer that we can try to process.
    if (r != -1)
        session.bufLen := (len += r)
    
    if (packetLen := session.packetLen) = ""
    {
        ; Each message begins with the length of the message body
        ; encoded as a null-terminated numeric string.
        
        ; Ensure the data is null-terminated.
        NumPut("char", 0, ptr+0, len)
        
        headerLen := DllCall("lstrlenA", "ptr", ptr)
        
        ; If we've received the complete string, len must include the 
        ; null-terminator.  Otherwise, the data is invalid/incomplete.
        ; This case should be very rare:
        if (headerLen = len)
        {
            ; Haven't seen the null-terminator yet.
            if (len < 20)
                return
            ; This section can only execute if we've received >= 20
            ; bytes and still don't have a null-terminated string.
            ; No valid message length would be >= 20 characters.
            packetLen := "invalid"
        }
        else
        {
            ; The most common case: we've received the complete header.
            packetLen := StrGet(ptr, headerLen, "utf-8")
        }
        
        if !IsInteger(packetLen)
        {
            ; Recovering from invalid data doesn't seem very useful in
            ; this context, so just shutdown and wait for the other end
            ; to close the connection.
            DllCall("ws2_32\shutdown", "ptr", session.Socket, "int", 2)
            ; @Debug-Breakpoint => DBGp : Invalid message header, len={packetLen}
            return
        }
        
        ; Let packetLen include the null-terminator.
        packetLen += 1
        
        ; Discard the null-terminated header.
        headerLen += 1
        len -= headerLen
        DllCall("RtlMoveMemory", "ptr", ptr, "ptr", ptr + headerLen, "ptr", len)
        
        ; Ensure the buffer is large enough for the complete packet.
        if (cap < packetLen)
        {
            ; Grow exponentially to avoid incrementally reallocating.
            while (cap < packetLen)
                cap *= 2
            session.buf.size := cap
            ptr := session.buf.ptr
        }
        
        ; Update session object.
        session.bufLen := len
        session.packetLen := packetLen
    }
    
    if (len >= packetLen)  ; We have a complete packet.
    {
        ; Retrieve and decode the packet.
        packet := StrGet(ptr, packetLen, "utf-8")
        
        ; Remove it from the buffer.
        session.bufLen := (len -= packetLen)
        DllCall("RtlMoveMemory", "ptr", ptr, "ptr", ptr + packetLen, "ptr", len)
        session.packetLen := ""
        
        if len
        {
            ; Post a message so this function will be called again to
            ; process the rest of the data.  Unlike loop/goto, this
            ; method allows data to be received and processed while one
            ; of the handlers called below is still running.
            PostMessage 0x8000, session.Socket, 1, DBGp_hwnd()
        }
        ; @Debug-Output => {packet}
        
        ; Call the appropriate handler.
        RegExMatch(packet, "<\K\w+", &packetType)
        switch packetType && packetType.0 {
        case "response": DBGp_HandleResponsePacket(session, &packet)
        case "stream": DBGp_HandleStreamPacket(session, &packet)
        case "init": DBGp_HandleInitPacket(session, &packet)
        default:
            ; @Debug-Breakpoint => DBGp : Invalid packet
        }
    }
}

DBGp_CallHandler(handler, session, packet?)
{
    (handler) && handler(session, packet?)
}

_DBGp_QueueHandler_Call(args*)  ; (handler {fn}, session, packet?)
{
    DbgpSession.callQueue.Push(args)
    ; Using a single timer ensures that each handler finishes before
    ; the next is called, and that each runs in its own thread.
    SetTimer _DBGp_DispatchTimer, -1
}

_DBGp_DispatchTimer()
{
    if !DbgpSession.callQueue.Length
        return
    ; Call exactly one handler per new thread.
    next := DbgpSession.callQueue.RemoveAt(1)
    if next.Has(3)
        (next[1].fn)(next[2], %next[3]%)
    else
        (next[1].fn)(next[2])
    ; If the queue is not empty, reset the timer.
    if DbgpSession.callQueue.Length
        SetTimer _DBGp_DispatchTimer, -1
}

_DBGp_QueueHandler_New(handler, fn)
{
    handler.fn := fn
}

_DBGp_WaitHandler_Call(handler, session, response)
{
    handler.r := %response%
}

_DBGp_WaitHandler_Wait(handler, session, &response)
{
    WasCritical := A_IsCritical
    Critical false ; Must be Off to allow data to be received.
    while !handler.HasOwnProp('r')
    {
        if session.Socket = -1
            throw DBGp_WSAE(session.CloseError)
        Sleep 10
    }
    Critical WasCritical
    response := handler.DeleteProp('r')
    if RegExMatch(response, '<error\s+code="\K.*?(?=")', &DBGp_error_code)
        throw DbgpError(DBGp_error_code.0, -2)
}

DBGp_HandleResponsePacket(session, &packet)
{
    if RegExMatch(packet, '(?<=\btransaction_id=").*?(?=")', &transaction_id)
        try handler := session.handlers.Delete(transaction_id.0)
    if IsSet(handler)
        DBGp_CallHandler(handler, session, &packet)
}

DBGp_HandleStreamPacket(session, &packet)
{
    DBGp_CallHandler(DbgpSession.OnStream, session, &packet)
}

DBGp_HandleInitPacket(session, &packet)
{
    ; Parse init packet.
    RegExMatch(packet, '(?<=\bide_key=").*?(?=")', &idekey)
    RegExMatch(packet, '(?<=\bsession=").*?(?=")', &cookie)
    RegExMatch(packet, '(?<=\bfileuri=").*?(?=")', &fileuri)
    RegExMatch(packet, '(?<=\bthread=")\d+(?=")', &thread)
    
    ; Store information in session object.
    session.IDEKey := DBGp_DecodeXmlEntities(idekey.0)
    session.Cookie := DBGp_DecodeXmlEntities(cookie.0)
    session.Thread := thread && Integer(thread.0)
    session.File   := DBGp_DecodeFileURI(fileuri.0)
    
    DBGp_CallHandler(DbgpSession.OnBegin, session, &packet)
}

; Internal: Add new session to list.
DBGp_AddSession(session)
{
    DbgpSession.sockets[session.Socket] := session
}

; Internal: Remove disconnecting session from list.
DBGp_RemoveSession(session)
{
    DbgpSession.sockets.Delete(session.Socket)
}

; Internal: Find session structure given its socket handle.
DBGp_FindSessionBySocket(socket)
{
    return DbgpSession.sockets[socket]
}

; Internal: Creates or returns a handle to a window which can be used for window message-based notifications.
DBGp_hwnd()
{
    static hwnd := 0
    if !hwnd
    {
        hwnd := DllCall("CreateWindowEx", "uint", 0, "str", "Static", "str", "ahkDBGpMsgWin", "uint", 0, "int", 0, "int", 0, "int", 0, "int", 0, "ptr", 0, "ptr", 0, "ptr", 0, "ptr", 0, "ptr")
        DllCall((A_PtrSize=4)?"SetWindowLong":"SetWindowLongPtr", "ptr", hwnd, "int", -4, "ptr", CallbackCreate(DBGp_HandleWindowMessage))
    }
    return hwnd
}

; Internal: Returns an OSError encapsulating a winsock error.
DBGp_WSAE(n := DllCall("ws2_32\WSAGetLastError")) => OSError(n, -1)
