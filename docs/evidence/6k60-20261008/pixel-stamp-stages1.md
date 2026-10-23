# Matched pixel frame stage decomposition

Added analyze-pixel-stages.py joining marker identity,source callback,write completion,host ready/accept and Wayland feedback. Validated80 baseline rows partition exactly to total; no subtraction of unrelated percentiles.

Moved marker log after Unmap and separated actual Map API timing from diagnostic decode/log. Windows Release builds and WARP staging lease/reuse/crop/adoption/fallback/pixel test passed. Live bounded6K paced fixture with host stage tracing completed; no foreground changes,1557host markers all match source,zero mismatch. Production binaries/wrappers/probe restored with hash checks; host runtime override removed.

80 matched samples (P50/P95 ms): callback→write9.534/14.605; write→host ready0.588/0.839; host queue0.014/0.144; host accept3.079/5.048; accept end→feedback23.554/29.796. Accept end includes EGL swap submission. Minimum accept end→feedback16.851ms. Existing draw code already uses eglSwapInterval0. This identifies post-submit compositor/presentation scheduling as the largest downstream stage; no evidence receiver thread queue is the dominant cause. Do not call all post-submit time pure compositor CPU or GPU execution; only boundary timestamps observed.

Pixel-generation→feedback52.877/67.916ms; full objective unmet. Normal compositor configuration, no plugin changes. Next bounded scheduling comparison should retain current pixel identities and60Hz generator, examine compositor render/present scheduling, and avoid busy-looping receiver. Photon latency still unmeasured; marker matching verifies transport identity, not full rendered content.
