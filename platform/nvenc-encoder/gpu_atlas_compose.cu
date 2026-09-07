#include "gpu_atlas_compose.cuh"
#include <cstdint>
#include <limits>

namespace viewflow::gpu {
namespace {
struct Span { uintptr_t begin, end; };
bool span(const void* pointer, size_t pitch, int width, int height, size_t bpp, Span& result) {
    if (!pointer || width <= 0 || height <= 0 ||
        size_t(width) > std::numeric_limits<size_t>::max() / bpp ||
        pitch < size_t(width) * bpp ||
        pitch > std::numeric_limits<size_t>::max() / size_t(height)) return false;
    const auto begin = reinterpret_cast<uintptr_t>(pointer);
    const size_t bytes = pitch * size_t(height);
    if (bytes > std::numeric_limits<uintptr_t>::max() - begin) return false;
    result = {begin, begin + bytes};
    return true;
}
bool overlaps(Span a, Span b) { return a.begin < b.end && b.begin < a.end; }
__global__ void copyTile(AtlasTile tile, AtlasOutput output) {
    const size_t x = size_t(blockIdx.x) * blockDim.x + threadIdx.x;
    const size_t y = size_t(blockIdx.y) * blockDim.y + threadIdx.y;
    if (x >= size_t(tile.width) || y >= size_t(tile.height)) return;
    const auto* src = tile.rgba + y * tile.pitch + x * 4;
    auto* dst = output.rgba + (y + tile.y) * output.rgbaPitch + (x + tile.x) * 4;
    for (int c = 0; c < 4; ++c) dst[c] = src[c];
    output.alpha[(y + tile.y) * output.alphaPitch + x + tile.x] = src[3];
}
}
cudaError_t composeAtlas(const AtlasTile* tiles, size_t count, const AtlasOutput& output, cudaStream_t stream) {
    Span rgba{}, alpha{};
    // Bound quadratic rectangle validation and CUDA grid dimensions.
    if (count > 4096 || (count && !tiles) || output.width > 65535 || output.height > 65535 ||
        !span(output.rgba, output.rgbaPitch, output.width, output.height, 4, rgba) ||
        !span(output.alpha, output.alphaPitch, output.width, output.height, 1, alpha) ||
        overlaps(rgba, alpha)) return cudaErrorInvalidValue;
    for (size_t i = 0; i < count; ++i) {
        const auto& tile = tiles[i];
        Span source{};
        if (tile.x < 0 || tile.y < 0 || tile.width <= 0 || tile.height <= 0 ||
            tile.width > output.width || tile.height > output.height ||
            tile.x > output.width - tile.width || tile.y > output.height - tile.height ||
            !span(tile.rgba, tile.pitch, tile.width, tile.height, 4, source) ||
            overlaps(source, rgba) || overlaps(source, alpha)) return cudaErrorInvalidValue;
        for (size_t j = 0; j < i; ++j) {
            const auto& other = tiles[j];
            if (tile.x < other.x + other.width && other.x < tile.x + tile.width &&
                tile.y < other.y + other.height && other.y < tile.y + tile.height)
                return cudaErrorInvalidValue;
        }
    }
    auto error = cudaMemset2DAsync(output.rgba, output.rgbaPitch, 0, size_t(output.width) * 4, output.height, stream);
    if (error != cudaSuccess) return error;
    error = cudaMemset2DAsync(output.alpha, output.alphaPitch, 0, output.width, output.height, stream);
    if (error != cudaSuccess) return error;
    for (size_t i = 0; i < count; ++i) {
        copyTile<<<dim3((tiles[i].width + 15) / 16, (tiles[i].height + 15) / 16), dim3(16, 16), 0, stream>>>(tiles[i], output);
        error = cudaGetLastError();
        if (error != cudaSuccess) return error;
    }
    return cudaSuccess;
}
}
