# Cross-desktop return and reverse-window recovery

2026-09-07: user reported missing Windows-to-Linux failure recovery and a Word
window that stopped appearing after an apparent failure. No live mouse/keyboard
input or focus changes were used for verification.

## Findings and changes

- The desktop cursor worker treated a late native capture receipt as rejection
  and expired its pending operation. Ordered desktop revoke receipts now remain
  registered until confirmation or actual transport/dispatcher loss. Native
  capture commands likewise finish in order; latency misses are logged, not
  converted to session failure. Existing non-desktop revoke deadlines retain
  their previous behavior.
- A rejected return releases locally without transferring the drag. A rejected
  plain release retries locally; channel/owner loss remains an actual error.
  Drag state is committed only after the native return succeeds.
- Windows capture terminal callbacks marked a source closed but inventory
  skipped every already-enrolled HWND forever. Capture is now restarted for
  that source, retaining its ID and last texture/proxy. Initial start failures
  also remain retryable. Texture allocation failure retains the previous
  texture; HWND process identity is rechecked during inventory.
- Linux reverse geometry inventory and per-window placement errors now retry
  without terminating the presenter and removing unrelated proxies.

The retained Linux source log contained `atlas-cursor-handoff failed: deadline
has elapsed` followed by `window-input dispatcher failed: cursor handoff worker
stopped`. The current Windows log did not retain the reported Word failure;
that specific application's original failure cause is not proven.

## Validation

- Rust viewflowd library: 470 passed before the final release-retry test; final
  cursor suite: 16 passed (including delayed receipt and rejected release).
- Linux reverse wire/geometry: 2 passed.
- Windows reverse and capture contract checks: 4 passed.
- Linux GPU-enabled release and Windows reverse release built successfully.
- The Windows receiver and native presenter were also rebuilt from the current
  workspace to align the existing sparse-atlas protocol changes. The first
  deployment attempt with the older Windows receiver failed warmup equality;
  no protocol check was bypassed.

Actual Word dragging and visual acceptance remain user-operated.

## Deployment coordination

The remaining handshake mismatch was identified exactly: Linux offered
`sparse_patch_version=0`, Windows expected `1`; all other public fields and the
TLS binding matched. Read-only `systemctl --user cat viewflow-desktop.service`
showed `/run/user/1000/systemd/user/viewflow-desktop.service.d/90-compatible-runtime.conf`
overriding ExecStart to `~/.local/lib/viewflow/desktop/vf-media-peer-compatible-20260907`,
rather than the newly built repository binary. The concurrent HID task owns
unified deployment from this point; this task stopped further runtime mutations
and supplied the required reverse-backend artifacts to prevent overwrite.

Windows reverse deployed SHA256:
`6ec79a73625e71cd723b995e457f17c44a8f691187047f192f8d43d3d1cfe7c3`.
Linux reverse deployed SHA256:
`7ef1d8c787e0ca48e3542f6d2881c94db6c6f6d9f54e6704cc9a7ef5e40f588d`.
Windows native presenter protocol/parser/identity checks: 9 passed.

Unified deployment subsequently succeeded. The HID task replaced the temporary
compatible override with `~/.local/lib/viewflow/desktop/vf-media-peer-main` built
from integrated source, retaining this task's native reverse artifacts. Local
read-only verification observed the new source and reverse backend running,
clock exchanges continuing, and two mapped reverse proxies in Hyprland:
`ViewflowReverse-1` / `工作簿1 - Excel` and `ViewflowReverse-2` / `文档1 - Word`.
This confirms Word proxy creation on Linux, not manual drag/input acceptance.
