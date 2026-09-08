# Atlas lossless alpha references

Atlas V3 peers can omit an unchanged VFAR alpha payload after agreeing to
`AtlasSession.alpha_reference` (protobuf field 18). The source offers this
optional capability for lossless-alpha V3 sessions. The receiver echoes it
only when supported. An absent/false echo uses ordinary full alpha packets;
an unsolicited true echo is rejected. V1/V2 and other alpha codecs retain
full payloads. Older protobuf readers ignore the new field, so mixed-version
connections use full VFAR in either direction.

A reference payload is 84 bytes: ASCII `VFAF`, followed by the existing
80-byte alpha reference key. That key contains the full baseline's stream ID
(16 bytes), frame ID, geometry epoch and codec generation (three big-endian
u64 values), width and height (two big-endian u32 values), then the SHA-256
of its complete VFAR payload. It is transported as the current frame's alpha
plane, with current frame identity and source timestamp.

The source retains one full alpha baseline only after that frame's exact
`Committed` feedback. It sends a reference only for a later non-color-keyframe
with matching lineage, dimensions, and byte-for-byte identical independently
encoded alpha. Hash equality alone does not select a reference. Payloads of
84 bytes or fewer remain full because referencing would not save bytes.
References do not advance the baseline. A changed full payload replaces it
only after acknowledgement. Color keyframes always carry full alpha.

The receiver retains one full validated baseline on successful pair admission.
It resolves references before codec acceptance and enforces the expanded
pair's negotiated byte limit. Resolution checks the exact reference key,
lineage, dimensions, and advancing frame identity. It does not replace current
color, frame identity or timestamps. Unnegotiated references, missing/wrong
baselines, and references on color keyframes are malformed protocol data.

A full frame that receives `ExpiredUnbound` may temporarily leave sender and
receiver baselines different. Existing V3 recovery requires the next color
keyframe; its full alpha independently restores the baseline. Connection
replacement creates empty caches. This does not add a timing, focus, or input
restriction. The cache never authorizes input or certifies presentation.

The Rust receiver expands references to ordinary VFAR before its native pipe.
The Windows native alpha decoder and pixel composition format are unchanged.
Session tests exercise repeated references, changed alpha, expiration before
binding, full recovery, and preservation of the current frame timestamp.
