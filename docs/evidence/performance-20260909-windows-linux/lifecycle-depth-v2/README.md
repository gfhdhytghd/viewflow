# Buffered VPL output, static updates and live mode switching

The depth-2 candidate passes all seven owned-window phases: static first frame, title, move, second window, resize, hide and close. 21 recorded frames pass Linux NVDEC/CUDA/GLES upload, exact alpha and metadata checks. Every accepted PTS is output exactly once, in order; 21 accepted MORE_DATA inputs are completed through 21 successful nonblocking null-input requests. Thus static output does not depend on the fixture producing another frame.

Three live switches produce frame-rate → latency → frame-rate → latency (public limits 4 → 1 → 4 → 1) without a process restart. The sampled foreground stays unchanged and tasks/processes exit normally. Windows installed hash/configuration and main-task state are unchanged. This is source-recording lifecycle qualification, not physical-input or live Wayland lifecycle acceptance. Raw signed phase diagnostics and startup/resize effects remain in summary.json.
