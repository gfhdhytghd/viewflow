#pragma once
#include "gpu_atlas_compose.cuh"
#include "sparse_atlas_plan.hpp"
namespace viewflow::gpu {
// Only cell alpha summaries cross to the CPU; RGBA stays in device storage.
cudaError_t classifySparseCells(const AtlasTile*, size_t sourceCount,
                               std::vector<SparseCell>&, cudaStream_t);
cudaError_t composeSparseAtlas(const AtlasTile*, size_t sourceCount,
                              const SparsePlan&, const AtlasOutput&, cudaStream_t);
}
