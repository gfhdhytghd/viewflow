#include "../../../platform/reverse-common/shared_copy.hpp"
#include <cassert>
int main(){
 if(!viewflow::reverse::shm::copy_avx2_available())return 77;
 alignas(64) std::array<std::uint8_t,8192> source{},destination{};
 for(unsigned i=0;i<source.size();++i)source[i]=i*37;
 for(unsigned so:{0u,1u,16u,32u})for(unsigned d:{0u,1u,16u,32u})for(unsigned row:{1u,31u,32u,127u,128u,129u,1024u}){
  destination.fill(0xad);viewflow::reverse::shm::streaming_rows_avx2(destination.data()+64+d,source.data()+so,row,row+32,0,3,true);
  for(unsigned y=0;y<3;++y)assert(!std::memcmp(destination.data()+64+d+y*row,source.data()+so+y*(row+32),row));
  for(unsigned i=0;i<64+d;++i)assert(destination[i]==0xad);
  for(unsigned i=64+d+3*row;i<destination.size();++i)assert(destination[i]==0xad);
 }
}
