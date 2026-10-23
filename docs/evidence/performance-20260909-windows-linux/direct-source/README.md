# Rejected initial direct-source candidate

This private prototype skips atlas clear/copy when a single source exactly covers the atlas, retaining the existing WGC-to-owned-texture copy and holding the source mutex while color conversion and alpha work are queued. It does not retain WGC frame-pool surfaces.

The first source probe failed before any encoded output: `CreateVideoProcessorInputView` returned `0x80070057` because the owned source texture had only `D3D11_BIND_SHADER_RESOURCE`. Source exit was 1; the fixture was terminated by the runner job after its observation wait. All owned processes were gone afterward; the installed reverse hash and main task state matched before/after. This is a rejected candidate, with no usable FPS or latency measurement.

[Microsoft's input-view contract](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-id3d11videodevice-createvideoprocessorinputview) specifies the permitted bind flags. The follow-up `direct-source-rt` candidate adds the render-target bind flag to match the previously working atlas resource. This directory preserves the failed source, binary hashes, and raw logs unchanged.
