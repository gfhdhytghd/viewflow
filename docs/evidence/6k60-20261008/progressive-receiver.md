# Receiver early-reference routing

Frame has a local-only ProgressivePixels holder (never serialized). Reader
recognizes SHM2, claims the cross-protocol bank lease, and queues it in the latest
raw-frame lane. Rendering starts/polls a separate progressive decoder so an old
window redraw cannot cancel its upload. Complete textures swap into the active
decoder and enter normal metadata/alpha/presentation handling as preuploaded.
Incomplete/aborted textures never enter accept. Ordinary replacement cancels
older progressive work in the same lane. Poll waits1ms while work is pending;
there is no timeout that terminates a session. Source pipe EOF cancels outstanding
uploads after draining local DMA. Upload exceptions retain the active decoder.
Both decoder instances are destroyed before EGL teardown.

`run-progressive-receiver.py` runs the actual receiver --validate against an
isolated sparse /dev/shm file, with the actual current Wayland socket. No proxy
windows are created, stdout input messages go to /dev/null, no input/focus is
injected, and normal production services are untouched. CMake fixture target:
viewflow_progressive_receiver_fixture. Source emits four6144x3456 frames:
1complete,2aborted after early delivery,3complete,4process exits with unfinished
publication. Log records onlypts1 andpts3 validated; both processes exit0.
The source fixture deliberately sleeps and this is not a performance benchmark.

Wire serialization and cross-protocol ownership tests pass. This is receiver
queue/render/GPU integration evidence using a local producer; it is not proof
of a deployed Windows capture session or interactive UX. Runtime capability
enablement, source/receiver coordinated deployment, profile stage corrections,
and a real frame-identity baseline are still pending.
