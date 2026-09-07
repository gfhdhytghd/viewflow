# Real-size Windows GPU decoder verification

Synthetic NVENC H.264 High level 5.1, display 1936x1732, three matched
alpha planes; no desktop capture or GUI required for these tests.

Before the crop fix, the first Submit returned 0xc00d36b4 with no output:
negotiated and DXGI texture dimensions were 1936x1744; the minimum display
aperture was 0,0,1936x1732. The exact-texture-size check incorrectly rejected
legal codec padding. The 256x256 control emitted one frame per Submit.

The fix validates the aperture against the admitted alpha/display dimensions
and texture bounds, rejects fractional/odd NV12 crop offsets, and crops on
the GPU (NV12 copy or VideoProcessor source/destination rectangles). Final
BGRA and alpha dimensions remain the visible dimensions; padding is not scaled
into the window. No CPU color readback was added to the compositor.

After a full clean rebuild (required after the diagnostic header layout change),
1936x1732 emitted exactly one completed frame for each Submit, and all three
alpha readbacks matched their expected bytes. The 256x256 control also passed.
The readback is test-only. These tests do not establish scanout timing or
pixel-exact lossy color reconstruction.

Host Submit times, excluding the later test readback:

| Size | First | Second | Third |
| --- | ---: | ---: | ---: |
| 1936x1732 | 52.898 ms | 7.565 ms | 5.581 ms |
| 256x256 | 35.812 ms | 4.717 ms | 2.268 ms |

Cold initialization therefore cannot be left in the first real frame's
33.333 ms path. Correct-size decode-only prewarming, never presentation or
a successful real-frame ACK, is the next required startup step.

Headless EXE SHA256:
`BA9AD437B5C69006F4DC37E7FA1ACF7DC01F6A2DDB40539AE80A4F0281302AE0`.
Source cpp SHA256:
`818FA3FED6A07B7F77EA8EDC22BCF13EBA001B8D4F62FDBC23A44E24DA7D96C7`.
Logs: `/tmp/viewflow-run1936-round4.log`, `/tmp/viewflow-run256-round4.log`.
The prior non-clean diagnostic run had stale struct-layout output and is not
the evidence relied upon here. The visible preview executable has not yet
been rebuilt with this crop fix.

## Bounded processor cache follow-up

The compositor now retains one VideoProcessor/Enumerator pair for the current
input/output geometry, replacing it on geometry change. It does not reuse or
retain completed frame pixels. A further clean rebuild passed both fixtures
and all three exact alpha comparisons. 1936x1732 host Submit times were
58.706, 9.902, 5.482 ms; 256x256 times were 37.251, 3.864, 2.111 ms.
Three samples do not prove a performance improvement; cold initialization
remains dominant. EXE SHA256
`78AFE1775F6EA2573DE07ADE3AB1676F09F4842A2034341F8F698D987D660517`.
Logs: `/tmp/viewflow-run1936-round5.log`, `/tmp/viewflow-build-round5.log`.
