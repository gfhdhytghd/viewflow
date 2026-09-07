# Trusted-local rejected-input recovery (VFGP v9)

V9 cancels a native gesture whose selection was rejected before application
input was forwarded. The receiver may issue Cancel only after source native END
is confirmed. V9 is explicit about this cause and does not relax V6's requirement
that resize recovery advance the source geometry epoch.

All integers are big-endian. Both controls are exactly 176 bytes and share the
V6 control-sequence replay floor, independently of picture identities.

| Offset | Field |
| --- | --- |
| 0..3 | `VFGP` |
| 4 | version `9` |
| 5 | kind: `1` Cancel, `2` Resume |
| 6 | cause: `1` rejected selection |
| 7 | zero |
| 8 | u32 record length `176` |
| 12 | u32 zero payload length |
| 16 | u64 control sequence |
| 24, 32 | u64 zero reserved fields |
| 40, 48 | stream id high, low |
| 56, 64 | window id high, low |
| 72, 80 | atlas epoch, configuration generation |
| 88, 96 | previous source geometry epoch, current source geometry epoch |
| 104 | grant generation; zero for Cancel, nonzero for Resume |
| 112, 120, 128 | atlas frame, source frame, placement generation |
| 136, 144 | same-host QPC deadline, frequency |
| 152 | cancellation sequence |
| 160, 168 | previous atlas frame, previous source frame |

Cancel binds the rejected selection: previous/current epochs and frames are
equal, and cancellation sequence equals control sequence. Native must find that
exact stream/window/epoch/configuration/frame/source/placement binding in its
retained committed history; current lineage must not regress. Only that proxy
is suspended. Native retains the admitted key/button ledger and separately
tracks physical drain. It does not emit application input while suspended.

Resume binds the cancellation sequence and rejected previous identity, plus an
exact current committed tile and a fresh source grant validated by the receiver.
Its control sequence must be newer than Cancel. Same geometry and unchanged
frame identities are permitted only for this explicit rejected cause. Native
requires physical release, visible foreground focus, an unexpired deadline,
and a strictly newer grant. Resume clears the cancelled ledger and establishes
a new native timestamp floor, so queued old down/up events cannot replay under
the new grant. Keyboard message timestamps at or before the recovery system-tick
boundary (including ambiguous same-tick messages) are discarded with their
physical release tails; timestamp wrap uses the unsigned half-range rule.
Pointer messages use the recovery QPC floor and likewise drain discarded tails.
Additional physical presses during suspension are drained only;
they never become application input.

Native emits `atlas-input-suspended-v2` with all existing v1 notice fields plus
`cause=rejected cancel_sequence=...`. `phase=cancelled` is the ordered native
input boundary: the Rust stdout dispatcher attaches its current input-ingress
ordinal there. Only matching unforwarded gesture records at or below that
acknowledged boundary may be discarded. `phase=drained` requires both keyboard
and pointer physical drain. A later quarantined press/release may produce a
new drained notice for the same cancellation sequence.

After notices, Cancel emits `atlas-input-cancelled-v2`; Resume emits
`atlas-input-recovered-v2`. Each has the 17 v1 recovery receipt fields (including
`recovered_qpc`, used as the operation timestamp), followed by
`cause=rejected cancel_sequence=...`. Cancel's receipt echoes grant generation
zero. The media owner independently validates this receipt; notices do not
complete the pipe transaction.

Compatibility: V9 is a trusted local Rust-to-native child-pipe record, not a
network protocol version. Deploy the Rust receiver and native presenter from
the same build. The existing native recovery readiness marker remains v1;
an older native parser rejects unknown V9 and terminates the transaction rather
than ignoring it or resuming input. V6 resize recovery retains its original
strict geometry-advancement requirements.

The network `AtlasWindowSelectionRejected` message is separately guarded by
the required bidirectional atlas selection-rejection capability described in
[atlas-peer.md](atlas-peer.md). A legacy peer fails negotiation before input.
A rejection is correlated to the exact outstanding, unforwarded selection,
including its original sequence, frames and deadline. Known source authority
must be covered by the rejection's confirmed END generation. Already-forwarded
or ambiguous input remains terminal.

After the Cancel receipt and physical drain, the receiver fences media and
selects the newest committed tile with a new 24 ms selection-only deadline.
That request carries no original button, wheel or key event. Resume requires
a matching fresh source authorization with a strictly newer generation. A
second rejection or missing fresh authorization fails closed; it never changes
the old event's deadline or retries that event. Expired unforwarded events may
remain correlated for at most 100 ms solely to receive their explicit rejection;
they cannot be forwarded during that wait.
