#include "shared_mapping.hpp"
#include <thread>
#include <chrono>
#include <cstdio>
using namespace viewflow::reverse;
int main(int argc,char** argv){try{
    if(argc!=2)throw std::runtime_error("fixture path");
    constexpr unsigned width=6144,height=3456;constexpr std::size_t row=width*4,capacity=row*height,size=shm::header_bytes+4*capacity;
    int fd=open(argv[1],O_RDWR);if(fd<0 || ftruncate(fd,size))throw std::runtime_error("fixture file");
    auto* memory=mmap(nullptr,size,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);if(memory==MAP_FAILED)throw std::runtime_error("fixture map");
    shm::Frames frames(memory,size);
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(15);
    while(!frames.reader_ready()){if(std::chrono::steady_clock::now()>deadline)throw std::runtime_error("fixture reader timeout");std::this_thread::sleep_for(std::chrono::milliseconds(1));}
    for(unsigned sequence=1;sequence<=8;++sequence){
        auto lease=frames.begin_progressive(1234,sequence,width,height);if(!lease)throw std::runtime_error("fixture bank busy");
        Frame frame;frame.codec=3;frame.keyframe=true;frame.width=width;frame.height=height;frame.pts=sequence;frame.color=lease->reference();
        auto bytes=pack_frame(frame);Writer prefix;prefix.u32(bytes.size());
        if(fwrite(prefix.bytes.data(),1,4,stdout)!=4 || fwrite(bytes.data(),1,bytes.size(),stdout)!=bytes.size() || fflush(stdout))throw std::runtime_error("fixture write");
        std::vector<std::uint8_t> band(row*128,sequence*31);
        if(sequence==8){lease->append(band,row,128);std::this_thread::sleep_for(std::chrono::milliseconds(300));std::_Exit(0);}
        if(sequence==2){
            lease->append(band,row,128);std::this_thread::sleep_for(std::chrono::milliseconds(300));lease.reset();
        }else{
            for(unsigned y=0;y<height;y+=128){lease->append(band,row,std::min(128u,height-y));std::this_thread::sleep_for(std::chrono::milliseconds(5));}
            lease->finish();lease.reset();
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
    }
    munmap(memory,size);close(fd);return 0;
}catch(const std::exception& e){std::fprintf(stderr,"fixture: %s\n",e.what());return 1;}}
