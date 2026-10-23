#pragma once
#include <cuda_runtime_api.h>
#include <cstddef>

namespace viewflow::gpu {
// Sources are prepared straight RGBA. Alpha is derived from that same pixel,
// never a separately positioned plane. Rectangles must not overlap.
struct AtlasTile {
    const unsigned char* rgba;
    size_t pitch;
    int width, height, x, y;
};
struct AtlasOutput {
    unsigned char* rgba;
    size_t rgbaPitch;
    unsigned char* alpha;
    size_t alphaPitch;
    int width, height;
};
// Host descriptors are consumed synchronously. Device allocations must cover
// pitch*height, remain alive through stream completion, and not alias outputs.
// Validates all descriptors before enqueuing writes; clears uncovered pixels on
// every call. On a CUDA error, prior queued work still requires synchronization.
cudaError_t composeAtlas(const AtlasTile*, size_t count, const AtlasOutput&, cudaStream_t);
}
