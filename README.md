# dbgp

[DBGp](http://xdebug.org/docs-dbgp.php) client scripts for AutoHotkey_L.

These scripts have been written and tested for [AutoHotkey_L](https://github.com/Lexikos/AutoHotkey_L), but may also work with other (non-AutoHotkey) debugger engines.

## dbgp.ahk

Contains client functions for use by other scripts.


## dbgp_console.ahk

Implements a basic debugger client using a command-line interface. This isn't very user-friendly; it's main uses are testing debugger engines and learning the protocol.


## dbgp_listvars.ahk

Demonstrates asynchronous commands and variable retrieval.

This script is AutoHotkey-specific. It posts the `AHK_ATTACH_DEBUGGER` registered window message to all running scripts. Each script may respond by initiating a debugger connection. If there are successful connections, this test script queries and lists the variables of each connected script.

**Note:** AutoHotkey_L v1.1.09+ allows any command other than run/step to be sent asynchronously, but the spec does not require this. If a command is unavailable because the debugger is not in a break state, error 5 is returned.


## dbgp_test.ahk

Demonstrates basic usage of the dbgp library.

When a connection is made, the client (this script) steps into the script being debugged. Each time the debugger breaks, the client logs the current line and instructs the debugger to step over one line. Stderr is redirected so that if OutputDebug is called, the output will be sent to the client.

Aside from basic usage, this test script hints at some possible uses for DBGp functions in a script. For example, this script could be extended to log variable values each time the debugger breaks, or at specific lines. 

