# Mac source inventory worker — 2026-09-12

Periodic window bounds/title and display-scope queries now run on a dedicated
worker. Only one inventory batch can be outstanding. Results are applied on
the main thread by capture ID, and discarded when ordered input has queried
or moved the window in the meantime. Shutdown drains the inventory callback.
The existing capture suspension/resumption and resize paths remain on main.

Two read-only, two-second `sample` captures of the same source window:

| Main-thread sample category | Before | After |
| --- | ---: | ---: |
| Total samples | 792 | 688 |
| Window bounds query | 208 | 0 |
| Display-scope query | 169 | 0 |
| Run-loop port wait | 239 (30.2%) | 557 (81.0%) |

These are main-thread stack proportions, not CPU utilization or end-to-end
latency measurements. Work has moved off main; the system queries still cost
time on the worker. The scene was not a scripted benchmark. Input-time bounds
queries and periodic popup discovery remain synchronous and need separate
profiling. No mouse/keyboard input or focus change was injected.

Strict native arm64 compilation (`-O2 -DNDEBUG -Wall -Wextra -Werror`) and the
serial-worker test passed. Codec and exact Metal alpha/color/orientation tests
passed (`tests.log`). The installed app passed deep strict signature validation.
The installed helper and running source helper both have SHA-256
`beb2c1ddd3fce3afc587d4a0c362b7f0d83bca28736e30daa346e2609417f40a`.
Source PID changed from 21429 to 23770. The existing paired peer relaunched it;
native capture and GPU alpha initialized without errors. Existing Linux shadow
decoration is unchanged. This does not establish physical drag/scroll latency.

The Mac rollback bundle is `~/viewflow-mac-pipeline-20260912/pre-r5.app`;
the signed candidate is `candidate-r5.app` in that directory.
