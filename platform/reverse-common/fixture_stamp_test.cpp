#include "fixture_stamp.hpp"
#include <cassert>
#include <algorithm>
int main(){namespace f=viewflow::reverse::fixture_stamp;
 for(auto sequence:{0ull,1ull,0xffffffffffffffffull}){
  const f::Stamp stamp{sequence,1234567890123};auto p=f::encode(stamp);auto d=f::decode(p);assert(d && d->sequence==sequence && d->qpc100ns==stamp.qpc100ns);
  for(unsigned i=0;i<p.size();++i){auto corrupt=p;corrupt[i]^=1;assert(!f::decode(corrupt));}
  for(unsigned i=0;i<p.size();++i)assert(!f::decode(std::span(p).first(i)));
  auto mixed=f::encode({sequence^1,stamp.qpc100ns});std::copy(mixed.begin()+64*4,mixed.begin()+128*4,p.begin()+64*4);assert(!f::decode(p));
 }
}
