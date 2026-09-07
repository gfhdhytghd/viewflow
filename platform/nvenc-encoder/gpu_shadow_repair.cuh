#pragma once

#include "gpu_shadow_math.cuh"
#include <cuda_runtime_api.h>
#include <cstddef>

namespace viewflow::gpu {

// Both planes are device allocations. rgba is already straight RGBA and is
// repaired in place; alpha is kept as the independent alpha plane used later
// in the encode path. snapshot is render-time state, never a live-window view.
struct ShadowRepair {
  unsigned char* rgba;
  size_t rgbaPitch;
  unsigned char* alpha;
  size_t alphaPitch;
  int width;
  int height;
  ShadowSnapshot snapshot;
};

// Enqueues the eight CPU-equivalent repairRegion passes on stream. It does not
// synchronize the device; caller retains both buffers through stream completion.
cudaError_t repairShadow(const ShadowRepair&, cudaStream_t stream);

} // namespace viewflow::gpu
