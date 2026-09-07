#include "gpu_atlas_compose.cuh"
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <limits>

using namespace viewflow::gpu;
static void check(cudaError_t error) {
    if (error != cudaSuccess) { std::fprintf(stderr, "%s\n", cudaGetErrorString(error)); std::exit(1); }
}
static void require(bool condition) { if (!condition) { std::fprintf(stderr, "atlas oracle mismatch\n"); std::exit(1); } }
int main() {
    constexpr int w = 17, h = 13;
    constexpr size_t rp = 80, ap = 24, sp = 24;
    unsigned char *rgba, *alpha, *source;
    check(cudaMalloc(&rgba, rp * h)); check(cudaMalloc(&alpha, ap * h)); check(cudaMalloc(&source, sp * 4));
    cudaStream_t stream; check(cudaStreamCreateWithFlags(&stream, cudaStreamNonBlocking));
    std::vector<unsigned char> input(sp * 4, 0xDA);
    for (int y = 0; y < 4; ++y) for (int x = 0; x < 5; ++x)
        for (int c = 0; c < 4; ++c) input[y * sp + x * 4 + c] = static_cast<unsigned char>(y * 60 + x * 4 + c);
    check(cudaMemcpy(source, input.data(), input.size(), cudaMemcpyHostToDevice));
    check(cudaMemset(rgba, 0xAB, rp * h)); check(cudaMemset(alpha, 0xAB, ap * h));
    AtlasOutput output{rgba, rp, alpha, ap, w, h};
    AtlasTile tiles[] = {{source, sp, 5, 4, 0, 0}, {source, sp, 5, 4, 12, 9}};
    auto verify = [&](size_t count) {
        check(cudaStreamSynchronize(stream));
        std::vector<unsigned char> r(rp * h), a(ap * h), src(input.size());
        check(cudaMemcpy(r.data(), rgba, r.size(), cudaMemcpyDeviceToHost));
        check(cudaMemcpy(a.data(), alpha, a.size(), cudaMemcpyDeviceToHost));
        check(cudaMemcpy(src.data(), source, src.size(), cudaMemcpyDeviceToHost));
        require(src == input);
        for (int y = 0; y < h; ++y) {
            for (int x = 0; x < w; ++x) {
                const unsigned char* expected = nullptr;
                for (size_t i = 0; i < count; ++i) {
                    auto t = tiles[i];
                    if (x >= t.x && x < t.x + t.width && y >= t.y && y < t.y + t.height)
                        expected = input.data() + (y - t.y) * sp + (x - t.x) * 4;
                }
                for (int c = 0; c < 4; ++c) require(r[y * rp + x * 4 + c] == (expected ? expected[c] : 0));
                require(a[y * ap + x] == (expected ? expected[3] : 0));
            }
            for (size_t x = w * 4; x < rp; ++x) require(r[y * rp + x] == 0xAB);
            for (size_t x = w; x < ap; ++x) require(a[y * ap + x] == 0xAB);
        }
    };
    check(composeAtlas(tiles, 2, output, stream)); verify(2);
    // Every invalid descriptor must leave the previous frame untouched.
    auto reject = [&](AtlasTile bad) {
        AtlasTile candidate[] = {tiles[0], bad};
        require(composeAtlas(candidate, 2, output, stream) == cudaErrorInvalidValue); verify(2);
    };
    reject({source, sp, 5, 4, 4, 3}); // overlap
    reject({source, sp, 5, 4, 13, 9}); // overflow right
    reject({source, sp, 5, 4, -1, 9});
    reject({source, 19, 5, 4, 12, 9}); // short pitch
    reject({rgba, rp, 5, 4, 12, 9}); // output alias
    reject({source, std::numeric_limits<size_t>::max(), 5, 4, 12, 9});
    require(composeAtlas(nullptr, 1, output, stream) == cudaErrorInvalidValue); verify(2);
    check(composeAtlas(tiles, 1, output, stream)); verify(1); // retire second tile
    check(composeAtlas(nullptr, 0, output, stream)); verify(0);
    check(cudaStreamDestroy(stream)); check(cudaFree(source)); check(cudaFree(alpha)); check(cudaFree(rgba));
    std::puts("GPU atlas oracle passed: paired planes, padded pitches, retirement, empty frame, invalid-input atomicity");
}
