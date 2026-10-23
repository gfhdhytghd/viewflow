# Windows -> Mac input recovery

The user reported completely ineffective clicks and keyboard input in Windows
apps presented on Mac. Live source rectangles matched the Mac proxy mapping,
and the Windows source ran in interactive session 1. Temporary diagnostics
counted event kinds/sequences only, never typed content. Mac events reached its
output queue; Windows later recorded successful SendInput calls. Those API
results alone did not establish usable application input.

After recreating the Windows -> Mac source/receiver connection during diagnosis,
the user confirmed that input worked. The final Word trace had target and
foreground HWND both 0x330694; actual/requested cursor coordinates both
1248,3379 were inside the actual Word bounds 314,2690,3030,4308. Keyboard injection
returned 1, error 0. Word was enabled and had no separate active modal popup.
The failed state was not captured with those final placement/focus probes, so
there is no established root cause or proven permanent code fix.

Temporary trace markers were removed on both hosts, the read-only GUI diagnostic
task was unregistered, and diagnostic source changes were removed. The working
connection was retained. Windows future source launches again use the original
configured residency-v2 backend; the currently running diagnostic build has
logging disabled and differs only in observation code. No test input or focus
change was injected. Builds and seven Windows source CTests passed.
