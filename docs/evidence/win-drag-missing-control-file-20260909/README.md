# Move/resize Begin rejection: missing local exchange file

After the recovery-fence deployment, five user-operated gestures reached the Linux source and each Begin received Rejected. Receiver diagnostics showed no pending desktop operation or recovery block when sending. Source handler timings were 54–230 us.

The live private native-control directory existed but desktop-window.json did not. DesktopWindowClient::open_private_file used open without create, so enrollment failed before sending the Lua command. This error was silently converted to Rejected. Empty-desktop startup and autostart reuse created only the directory; only explicit-window startup seeded the file.

Live correction: created the missing file with O_CREAT|O_EXCL|O_NOFOLLOW, mode 0600, without restarting the stream or sending native input. The existing running binary opens the file on each operation, so this correction applies immediately. Both launcher paths now create the file (autostart preserves any existing exchange). The Rust adapter now creates a missing private file itself, and source enrollment errors are logged rather than hidden; those Rust changes are tested source changes, not a newly deployed binary in this turn.

Validation: three adapter tests passed, including the fake-IPC enrollment round trip changed to start with a missing file and check mode 0600. The hermetic desktop launcher test passed with an assertion that empty-desktop creates the required file. Autostart configuration test, Python compilation, shell syntax, and git diff --check passed. Physical move/resize success awaits user acceptance.
