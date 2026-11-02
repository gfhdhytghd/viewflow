#include "../reverse-common/encoder_extent.hpp"
#include <cassert>
#include <cmath>
using namespace viewflow::media;
int main() {
    assert((fitExtent({4512,1032},encoderLimit(true))==Extent{4096,936}));
    assert((fitExtent({1032,4512},encoderLimit(true))==Extent{936,4096}));
    assert((fitExtent({8192,4320},encoderLimit(false))==Extent{8192,4320}));
    assert((fitExtent({3840,2400},{2048,2048})==Extent{2048,1280}));
    for(unsigned w=192;w<=16384;w+=127) for(unsigned h=192;h<=8192;h+=251) {
        auto fit=fitExtent({w,h},encoderLimit(true));
        assert(fit.width<=4096 && fit.height<=4096 && !(fit.width%2) && !(fit.height%2));
        assert(std::abs(int64_t(fit.width)*h-int64_t(fit.height)*w)<=2*int64_t(w+h));
        assert(reducedColor(fit,{w+1,h+1}));
    }
    assert(!reducedColor({4512,512},{4096,512}));
    assert(!reducedColor({0,0},{4096,512}));
}
