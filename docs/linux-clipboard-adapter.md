# Linux Wayland clipboard boundary

This document describes the older explicit-transfer adapter. Automatic desktop
clipboard synchronization now uses the cross-platform lane documented in
[clipboard sync](clipboard-sync.md); the old per-operation consent boundary
below does not govern that session-level feature.

`crates/viewflow-platform/src/linux_clipboard.rs` adds a build-tested native
boundary around the real `wl-clipboard` clients. It does not make the Clipboard
acceptance gate complete: a protocol receipt or a successful `wl-copy` launcher
does not prove that a destination application received or pasted the content.

The adapter is deliberately user-consent gated and supports a narrow safe MIME
set (`text/plain` with optional UTF-8 charset, `text/html`, `image/png`). It
turns an explicit local read into a digest-bound `ClipboardTransferOffer`,
preserves its declared type and byte count, and refuses a remote OS write unless
the accepted flavor, nonce, size, and SHA-256 all match. It enforces 1 MiB per
item and 4 MiB per snapshot by default, fences `(offer id, generation, offer
nonce, payload sequence)` replays before `wl-copy`, and suppresses bounded,
recent exact local echoes without losing them on unrelated snapshots.

`ClipboardTransferOffer` / accept / payload / completion protocol controls bind
the data route. The daemon must still drive its accepted/complete transitions
before and after `apply_verified_remote`, reject replayed identities, and pass
only a locally authorized operation into this adapter. `wl-paste` and `wl-copy`
commands are capped at five seconds and reaped on command errors or timeout.
Default `wl-copy` may fork a selection-owner helper after a successful launch;
this is its intentional Wayland ownership behavior, not destination-paste
proof, and the adapter does not add `--paste-once` because that would change
clipboard semantics.

The seven module tests exercise command, consent, type/size/digest, replay,
multiple echo, and owned-subprocess timeout behavior. They do not invoke
`wl-paste` or `wl-copy`, so they are not OS clipboard delivery evidence.
