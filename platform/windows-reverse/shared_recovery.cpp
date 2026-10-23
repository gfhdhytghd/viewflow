#include "shared_mapping.hpp"
#include <string_view>
// Coordinator must hold all host mapping flocks while running this utility.
// Mapping obtains the exclusive guest writer mutex. Neither endpoint may run.
int main(int argc,char** argv){try{
    if(argc!=2 || std::string_view(argv[1])!="--host-mappings-locked")throw std::runtime_error("requires coordinated host mapping locks");
    viewflow::reverse::shm::Mapping mapping(0);auto frames=mapping.frames();
    frames.recover(false);frames.recover(true);frames.reap_progressive();
    std::puts("shared slots recovered with both endpoints excluded");return 0;
}catch(const std::exception& e){std::fprintf(stderr,"%s\n",e.what());return 1;}}
