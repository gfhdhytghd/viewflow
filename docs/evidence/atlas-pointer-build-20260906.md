# Atlas pointer build preparation — 2026-09-06

WindowsVM was verified live over SSH at `wilf@172.16.105.70`. No running media
peer or native preview process was found before building. Fresh staging:
`C:\Users\wilf\AppData\Local\Temp\viewflow-input-20260906-J4vBWv`.
Scripts/logs and Linux builds: `/tmp/viewflow-input-20260906.J4vBWv/`.

The current Rust receiver built on Windows with the installed MSVC toolchain.
The first atlas test run had 50 passes, one failure and one explicitly ignored
interactive hardware test. The new pointer loopback expired under the default
Windows timer granularity. Its fixture now owns the same timer-resolution guard
as the real receiver CLI; no input deadline was increased. The repeated suite
passed 51 tests with that one hardware test still ignored.

The native Windows preview built in Release and passed 17/17 CTest cases,
including the new atlas pointer history test. Release now explicitly keeps
assertions enabled for test executables. MSVC reported the expected NDEBUG
override and temporary-output-directory warnings; this is not warning-free
build evidence. The first Linux capture Release build exposed the same disabled
assertion issue as unused-variable errors. Keeping test assertions enabled fixed
the build and made its five tests executable checks rather than empty bodies.

Fresh Linux Release builds of the input plugin and independent capture plugin
each passed 5/5 tests. The Qt application-side witness now records its own mouse
press/release as well as motion, without performing click actions or logging
keyboard input. It was rebuilt, but not launched in this preparation step.

Windows source archive SHA-256:
`a091dede942e10f001772069e61c155d56cff1427e0adb9b837a12c79f169751`.
Windows receiver EXE SHA-256:
`916926b34e261f777cf8916f25e45f2cf10f1659b4a996e0539ef2355643ecff`.
Windows native preview EXE SHA-256:
`12b9ccc37c6a3ef403da0b1d75535ce6bad839ed8a7fc98d182256e39fe45543`.

The task-owned nested Lua configuration passed syntax validation. Live host
inspection still showed only the existing main Hyprland PID 3386992, version
0.56.2; no test plugin was loaded there. The prepared nested launch script hides
physical input/DRM card nodes and seat access, uses a separate runtime directory
and pointer socket, and skips user configuration and autostart. It has not yet
been launched. These are build and preparation results, not real cross-host
mouse delivery, click confirmation, compositor switching or full-plan acceptance.
