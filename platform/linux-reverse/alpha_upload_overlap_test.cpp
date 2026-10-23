#include "alpha_upload_overlap.hpp"
#include <cassert>
#include <vector>
using namespace viewflow::reverse;
int main() {
    AlphaUploadOverlap worker;
    std::vector<std::uint8_t> source(4*1024*1024+4),alpha(source.size()/4);
    for(unsigned round=0;round<24;++round) {
        for(std::size_t i=0;i<source.size();++i)source[i]=(i*73+round*17)%256;
        bool uploaded=false,threw=false;
        try {worker.run(source,alpha,[&]{uploaded=true;if(round%3==0)throw std::runtime_error("upload failure");});}
        catch(const std::runtime_error&){threw=true;}
        assert(uploaded && threw==(round%3==0));
        // Failure must also join before the caller can recycle the input bank.
        for(std::size_t i=0;i<alpha.size();++i)assert(alpha[i]==source[4*i+3]);
    }
    bool uploaded=false,threw=false;
    try {worker.run(std::span(source).first(3),alpha,[&]{uploaded=true;});}catch(const std::runtime_error&){threw=true;}
    assert(threw && !uploaded);
    worker.run({}, {}, []{});
}
