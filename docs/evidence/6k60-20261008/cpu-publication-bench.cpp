// CPU/RAM microbenchmark only: no GPU, IVSHMEM device, or presentation.
// g++ -std=c++20 -O2 -pthread cpu-publication-bench.cpp -o /tmp/vf-copy-bench
#include "../../../platform/reverse-common/progressive_storage.hpp"
#include <cstdio>
#include <stdexcept>
using namespace viewflow::reverse::shm;
int main() {
    constexpr unsigned width=6144,height=3456,band=1728;
    constexpr std::size_t pitch=width*4,bytes=pitch*height;
    std::vector<std::uint8_t> source(bytes),destination(bytes);
    for(std::size_t i=0;i<bytes;++i)source[i]=std::uint8_t(i^(i>>12));
    ProgressiveFrame header;
    auto workers=std::make_shared<ParallelCopy>(2,true);
    ProgressiveStorage storage(header,destination,{},true,workers);
    struct Result {unsigned chunk;double first_band_ms,total_ms;};
    std::vector<Result> results;results.reserve(48);
    using Clock=std::chrono::steady_clock;
    std::uint64_t sequence=0;
    for(unsigned round=0;round<28;++round)for(unsigned arm=0;arm<2;++arm) {
        // Alternate AB/BA to reduce ordering bias; exclude four warmup pairs.
        const unsigned chunk=((round+arm)%2)?1024:0;
        auto writer=storage.begin({17,++sequence,bytes,0,width,height});
        if(!writer)throw std::runtime_error("writer unavailable");
        auto reader=storage.acquire(writer->reference());
        if(!reader)throw std::runtime_error("reader unavailable");
        const auto begin=Clock::now();
        writer->append_chunked(std::span(source).first(pitch*band),pitch,band,chunk);
        const auto middle=Clock::now();
        writer->append_chunked(std::span(source).subspan(pitch*band),pitch,band,chunk);
        writer->finish();
        const auto end=Clock::now();
        if(!reader->complete() || reader->prefix().size()!=bytes)
            throw std::runtime_error("incomplete publication");
        if(round>=4)results.push_back({chunk,std::chrono::duration<double,std::milli>(middle-begin).count(),std::chrono::duration<double,std::milli>(end-begin).count()});
    }
    // Validate outside timing; concurrent publication is covered separately.
    if(source!=destination)throw std::runtime_error("pixel mismatch");
    std::puts("chunk_rows,first_band_cpu_ms,frame_cpu_ms");
    for(const auto& r:results)std::printf("%u,%.6f,%.6f\n",r.chunk,r.first_band_ms,r.total_ms);
}
