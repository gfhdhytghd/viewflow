#pragma once
#include <cuda_runtime_api.h>
#include <cstddef>
namespace viewflow::gpu {
struct RgbaPrepare { const unsigned char* src; size_t srcPitch; int srcWidth, srcHeight, cropX, cropY, width, height; bool flipVertical; unsigned char* rgba; size_t rgbaPitch; unsigned char* alpha; size_t alphaPitch; };
// Device buffers must be disjoint and allocated to full pitch*height. Source
// stays immutable. cropY is a source row; flip reverses rows within the crop.
// Caller keeps buffers alive until stream synchronization, including on error.
// No device-wide sync. Temporary scratch uses stream-ordered allocation.
// Unpremultiply commutes with the seam copy; shadow repair remains separate.
cudaError_t prepareRgba(const RgbaPrepare&, cudaStream_t);
}
