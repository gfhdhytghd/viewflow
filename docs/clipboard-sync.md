# Cross-platform clipboard synchronization

The atlas desktop session starts automatic, bidirectional clipboard sync after
its authenticated startup. Both peers must run a version with this feature.
Linux uses arboard's Wayland data-control backend (with X11 fallback); Windows
uses the native clipboard; macOS uses NSPasteboard. A Wayland compositor must
support data-control. Run the process in the logged-in user's graphical session.
No clipboard commands or additional per-copy approvals are required.

Supported content is UTF-8 text (including empty text) and PNG images. When an
application offers both text and an image, text takes precedence. HTML/RTF,
multiple simultaneous formats, copied files, primary selection and propagation
of an entirely cleared/unsupported clipboard are not implemented. Each transfer
is limited to 16 MiB; decoded images to 16 million pixels. These are resource
limits of this implementation, not session deadlines. Oversized content leaves
the desktop connection and destination clipboard intact.

The initial clipboard is observed as a baseline and is not pushed over the
peer's existing content. Subsequent changes are sampled every 300 ms. Brief
copies between samples can be missed. The most recent pending update replaces
obsolete queued updates; already-started records finish in order. Simultaneous
copies use logical versions with the source endpoint as the tie-breaker.
Installed values become the local baseline to avoid echo; there is no lifetime
64-copy quota. Failed native writes stay pending for retry until superseded.
Successful installation does not prove an application subsequently pasted it.

Clipboard traffic uses a dedicated bidirectional QUIC stream on the existing
mTLS connection, separate from media/control reads. Only the atlas source opens
clipboard streams, after atlas startup; reverse-window streams are initiated in
the opposite direction. A clipboard stream failure reconnects that lane without
closing the desktop. Native clipboard calls run on one persistent OS-owner
thread with a bounded mailbox, outside Tokio workers. Missing/busy native
backends are retried. Set `VIEWFLOW_CLIPBOARD=0` before launching either endpoint
to disable synchronization there. It is not gated on hover, focus or a 33 ms
performance target.

## Standalone use, including macOS

`vf-clipboard-peer` supplies the same clipboard lane independently of GPU atlas
support. macOS's full atlas presenter is not implemented yet; this binary is the
usable macOS clipboard entry point. Build on the target OS:

```sh
cargo build --locked -p viewflowd --bin vf-clipboard-peer --release
./target/release/vf-clipboard-peer --config clipboard.json
```

Use existing paired certificate/key/CA files. A listener config:

```json
{
  "bind": "0.0.0.0:45991",
  "certificate": "/path/to/server.pem",
  "private_key": "/path/to/server-key.pem",
  "certificate_authority": "/path/to/paired-ca.pem"
}
```

The other endpoint connects with the certificate's server name:

```json
{
  "bind": "0.0.0.0:0",
  "remote": "192.168.1.20:45991",
  "server_name": "paired-server-name",
  "certificate": "/path/to/client.pem",
  "private_key": "/path/to/client-key.pem",
  "certificate_authority": "/path/to/paired-ca.pem"
}
```

On Windows use JSON-escaped Windows paths. The standalone listener serves one
paired connection at a time and reconnects after disconnect. Use a separate port
from the atlas endpoint; its stream protocol is clipboard-only. Stop with Ctrl+C.
Do not run both standalone and atlas synchronization for the same pair.

## Verification

`cargo test -p viewflowd --lib clipboard_sync::` exercises content framing,
Unicode/empty text/PNG, malformed and oversized records, conflict convergence,
retry state, echo suppression beyond 64 updates, and real mTLS QUIC bidirectional
automatic synchronization with fake OS clipboards. No test reads or changes the
operator's actual clipboard or injects mouse/keyboard input.

Native copying and pasting between real applications remains a user-operated
acceptance check on each OS. Linux builds are locally verified; Windows/macOS
native delivery requires verification on those systems.
