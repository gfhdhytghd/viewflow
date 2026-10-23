# Direct owned-source texture candidate, render-target bind added

The prototype skips atlas clear/copy only for one source exactly covering the atlas. The capture callback still copies WGC pixels into the owned source texture; the main thread holds the source mutex until video conversion and alpha reads are queued. Source texture creation adds D3D11_BIND_RENDER_TARGET alongside SHADER_RESOURCE, which makes the video-processor input view valid on this device.

The uninstrumented source run emitted 1,031 complete frames. All decoded with valid monotonically increasing markers, exact opaque alpha, and GL error zero. Packet throughput was 35.064/s, but repeated markers reduce distinct throughput to 29.927/s. These figures are diagnostic only: the process terminated at shutdown with 0xC0000409. The run is not qualified and is not suitable for deployment.

Two debugger variants did not reproduce the fail-fast event, so its exact stack remains unavailable. Code inspection identified a possible source lifetime race: map destruction can leave a callback holding the last Source reference and recursively call capture.stop during callback destruction. The follow-up `direct-source-stop` variant stops captures while the map still owns the sources. That is a candidate correction, not proof that the previous crash has been causally identified.

Installed reverse binary hash and main task state match before/after. Raw failure status, all source logs, decode results, and build input hashes are retained. No physical input tests were injected.
