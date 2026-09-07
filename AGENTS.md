# Project guidance

## User-defined security and availability baseline (2026-09-07)

Viewflow must not impose stricter security restrictions on normal remote use
than Windows remote windows/Remote Desktop and Sunshine/Moonlight. This is the
user's project-wide design requirement, not a claim that the current code or
those products have identical implementations.

- Do not invent additional authorization, focus, capture-freshness, or timing
  restrictions in the name of safety. Review existing restrictions against
  this baseline; document actual technical constraints as such.
- 33 ms (or two refresh periods) is a performance target, never a security
  boundary or session-exit condition. Measure misses; drop obsolete frames,
  finish in-flight work, or recover locally while retaining the session.
- Ordinary focus changes, hover, transient congestion, and recoverable input
  failures must not close the entire stream or destroy unrelated proxies.
- Keep normal pairing/authentication, correct target routing, ordered input,
  and release of held keys/buttons on disconnect. Do not use them to justify
  an extra product restriction without concrete evidence and necessity.
- Separate performance targets, operation watchdogs, and real connection or
  resource failures. Renaming or increasing a performance cutoff is not a
  substitute for implementing recovery.

See [the design policy](docs/security-and-availability-policy.md). Older design
documents, comments, tests, and evidence claiming a mandatory 33 ms cutoff or
stricter fail-closed behavior do not override this newer user requirement.

Live mouse/keyboard tests remain user-operated. Build, inspect, and deploy
authorized changes without injecting input or changing focus to test them.
