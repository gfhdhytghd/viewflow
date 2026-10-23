# Isolated exit diagnosis

Same native executable as `direct-source-rt`; only the fixture launcher changes. This is debugger-instrumented evidence, not performance data. The CDB variant uses an exception command file; the parent-debugger variant uses DEBUG_ONLY_THIS_PROCESS and captures a minidump only on an unhandled or fail-fast exception. No fail-fast exception was observed in this diagnostic run. Normal launcher exit therefore does not disprove the earlier uninstrumented failure.

The CDB wrapper's exit code is not independent proof of the native exit code. The parent-debugger variant explicitly records EXIT_PROCESS_DEBUG_EVENT and the native code. All owned processes were removed, and the installed reverse binary and main task state remained unchanged. The stream file from the CDB variant may contain debugger stdout and is not a valid video validation artifact. No input events were sent to the desktop.
