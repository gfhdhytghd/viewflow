# C++ sender → Rust receiver, real local IPC

2026-09-04: C++ `window_stream_sender_test --interop` PID 3985318
connected to Rust `hyprcapture_stream_probe` through a private temporary
SOCK_SEQPACKET listener. Rust required that exact PID and UID 1000.

Three frames arrived on one connection: sequences 1, 2, 3; epoch 1;
logical rectangle `[0,0,1,0.5]`; physical pixels 2×1; 8 bytes each.
Each import checked the ancillary FD, all four memfd seals, exact length and
frame lineage, then converted straight RGBA to premultiplied BGRA.

Observed capture-to-import ages (ns):

- Sequence 1: 6698500445 (producer began before listener; connection wait included).
- Sequence 2: 1046287.
- Sequence 3: 915868.

Both processes exited 0; Rust reported `imported_frames=3`. These were synthetic
pixels, not compositor output. This proves real cross-language IPC acceptance,
not GPU capture, pixel-by-pixel comparison of the imported fixture, network
transport, physical presentation or the two-frame end-to-end requirement.
